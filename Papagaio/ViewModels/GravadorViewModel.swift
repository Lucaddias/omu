import AppKit
import AVFoundation
import Foundation
import Speech
import Observation
import PapagaioCore

/// Estado de gravação para a UI. Fica no app, não em `PapagaioCore` — a
/// biblioteca não conhece SwiftUI nem `@Observable` de tela.
@MainActor
@Observable
final class GravadorViewModel {
    enum Estado: Equatable {
        case ocioso
        case gravando
        case pausado
        case processando
        case falhou(String)
    }

    private(set) var estado: Estado = .ocioso
    private(set) var avisos: [String] = [] {
        didSet { agendarSumicoDosAvisos() }
    }

    /// Entrega o áudio pronto para quem persiste e processa (`Biblioteca`).
    /// A gravação em si não sabe o que é um `Arquivo` — só produz bytes.
    ///
    /// `dataDeGravacao` é `nil` numa gravação normal (o instante é agora
    /// mesmo, não há nada a distinguir) e vem preenchido só na importação,
    /// com a data real lida do arquivo original — ver `importar(_:)`.
    ///
    /// `usavaFones` é o que a sessão observou ao começar a gravar; `nil` na
    /// importação, onde não há como saber. É o que decide se o microfone
    /// passa pelo cancelamento de eco antes de ser transcrito.
    var aoProduzirAudio: (@MainActor (_ titulo: String, _ pastaRelativa: String,
                                      _ duracao: TimeInterval,
                                      _ notas: [NotaDaConversa],
                                      _ dataDeGravacao: Date?,
                                      _ usavaFones: Bool?) async -> Void)?

    /// Limpa o contexto de destino da gravação em qualquer superfície da UI.
    var aoCancelarGravacao: (@MainActor () -> Void)?

    /// Pergunta antes de descartar. Injetável para os testes não abrirem um
    /// `NSAlert`; em produção é o alerta modal do app, que funciona de
    /// qualquer superfície — janela, painel flutuante ou menu da barra.
    var confirmarCancelamento: @MainActor () -> Bool = GravadorViewModel.alertaDeCancelamento

    /// Importações em andamento. Estado próprio, separado de `estado`: a
    /// importação escrevia `.processando`/`.ocioso` por cima de uma gravação
    /// em curso, que seguia capturando sem nenhum indicador.
    private(set) var importacoesEmCurso = 0
    var importando: Bool { importacoesEmCurso > 0 }

    /// Amostras de nível para a waveform ao vivo, ~20 Hz, janela de ~6 s.
    private(set) var waveform: [Float] = []
    /// A waveform da saída do sistema é independente: não confunda uma linha
    /// plana do microfone com ausência de áudio do interlocutor.
    private(set) var waveformSistema: [Float] = []
    private let quadrosWaveform = 120

    /// O valor vem da quantidade de amostras que já entrou na mixagem, não do
    /// relógio do sistema. Assim o carimbo de uma nota aponta para o mesmo
    /// instante que será reproduzido depois.
    private(set) var tempoDeGravacao: TimeInterval = 0
    private(set) var notasDaGravacao: [NotaDaConversa] = []
    var rascunhoDaNota = ""
    var proximaNotaSeraCritica = false

    /// Posição e tamanho, em coordenadas de tela, do cartão de gravação
    /// dentro da janela principal — atualizado a cada mudança de layout
    /// enquanto ele está visível.
    ///
    /// Vive aqui, e não como `@State` da view, para que o painel flutuante
    /// (que nasce fora da hierarquia da `ContentView`) saiba de onde "nascer"
    /// e encolher até o canto, em vez de simplesmente aparecer lá.
    var origemDoPainelNaTela: CGRect?

    private var sessao: SessaoGravacao?
    private var tarefaNivel: Task<Void, Never>?
    private var tarefaDeSumicoDosAvisos: Task<Void, Never>?
    /// Quanto tempo um aviso de "cancelada", "importada" ou "concluída" fica na
    /// tela. Eles descrevem algo que já terminou; passado esse tempo viram
    /// ruído fixo num lugar onde a pessoa já está fazendo outra coisa.
    private let duracaoDosAvisos: Duration = .seconds(30)
    private var identificadorDaGravacao: UUID?
    private let armazenamento: Armazenamento?
    /// Pastas de gravações já encerradas cuja conversa ainda está sendo
    /// registrada pela biblioteca.
    private var pastasEmEntrega: Set<String> = []

    /// Pastas em `Gravacoes/` que existem no disco mas ainda não têm conversa
    /// no banco **por estarem em uso agora** — a gravação em curso e as
    /// entregas a caminho. A recuperação de gravações órfãs as ignora.
    ///
    /// `nil` enquanto há uma importação copiando: a pasta dela só é conhecida
    /// quando a cópia termina, então não dá para listar o que está em uso.
    var pastasEmUso: Set<String>? {
        guard !importando else { return nil }
        var pastas = pastasEmEntrega
        if let sessao {
            pastas.insert(Armazenamento.caminhoRelativo(id: sessao.id))
        }
        return pastas
    }

    /// Finaliza a gravação em curso (se houver) e espera a conversa ser
    /// registrada. É o que o encerramento do app chama antes de sair: sem
    /// isso, ⌘Q no meio de uma reunião deixava o áudio sem registro.
    func finalizarAntesDeEncerrar() async {
        guard gravando else { return }
        await parar()
    }

    /// - Parameters:
    ///   - armazenamento: injetado na build de perf e nos testes; em produção
    ///     é o container do app.
    ///   - estadoInicial: só os testes passam algo diferente de `.ocioso`,
    ///     para exercitar as regras de "gravando"/"pausado" sem microfone.
    init(armazenamento: Armazenamento? = nil, estadoInicial: Estado = .ocioso) {
        self.armazenamento = armazenamento ?? (try? Armazenamento.padrao())
        estado = estadoInicial
        if self.armazenamento == nil {
            estado = .falhou("não foi possível abrir a pasta de suporte do app".localized)
        }
    }

    var gravando: Bool { estado == .gravando || estado == .pausado }
    var pausado: Bool { estado == .pausado }

    // MARK: - Gravação

    func alternarGravacao() async {
        if gravando {
            await parar()
        } else {
            await iniciar()
        }
    }

    func pausar() async {
        guard estado == .gravando, let sessao else { return }
        tempoDeGravacao = sessao.tempoDecorrido
        await sessao.pausar()
        tarefaNivel?.cancel()
        tarefaNivel = nil
        estado = .pausado
    }

    func continuar() async {
        guard estado == .pausado, let sessao else { return }
        await sessao.continuar()
        estado = .gravando
        iniciarMonitoramentoDeNivel(sessao: sessao, identificador: identificadorDaGravacao ?? UUID())
    }

    /// Cancelar apaga áudio e notas da gravação em curso, sem lixeira. Toda
    /// superfície que não tem a própria confirmação passa por aqui — um
    /// clique errado ao tentar finalizar não pode custar a reunião inteira.
    func cancelarComConfirmacao() async {
        guard gravando else { return }
        guard confirmarCancelamento() else { return }
        await cancelar()
    }

    private static func alertaDeCancelamento() -> Bool {
        let alerta = NSAlert()
        alerta.alertStyle = .warning
        alerta.messageText = "Cancelar a gravação?".localized
        alerta.informativeText = "O áudio capturado até agora é descartado.".localized
        let descartar = alerta.addButton(withTitle: "Cancelar gravação".localized)
        descartar.hasDestructiveAction = true
        alerta.addButton(withTitle: "Continuar gravando".localized)
        NSApp.activate(ignoringOtherApps: true)
        return alerta.runModal() == .alertFirstButtonReturn
    }

    func cancelar() async {
        aoCancelarGravacao?()
        tarefaNivel?.cancel()
        tarefaNivel = nil
        guard let sessao else {
            limparDepoisDeGravar()
            estado = .ocioso
            return
        }
        await sessao.descartar()
        self.sessao = nil
        identificadorDaGravacao = nil
        avisos = ["Gravação cancelada — nenhum arquivo foi criado.".localized]
        tempoDeGravacao = 0
        waveform = []
        waveformSistema = []
        limparDepoisDeGravar()
        estado = .ocioso
    }

    /// Erros não somem sozinhos: um `.falhou` pede ação da pessoa e sumir
    /// sozinho esconderia o motivo de a gravação não ter acontecido.
    private func agendarSumicoDosAvisos() {
        tarefaDeSumicoDosAvisos?.cancel()
        tarefaDeSumicoDosAvisos = nil
        guard !avisos.isEmpty else { return }

        // `[weak self]`: a tarefa dorme 30 s; reter o view model inteiro por
        // causa de um sumiço de aviso seguraria a gravação toda junto.
        tarefaDeSumicoDosAvisos = Task { [weak self, duracaoDosAvisos] in
            try? await Task.sleep(for: duracaoDosAvisos)
            guard !Task.isCancelled else { return }
            self?.avisos = []
        }
    }

    private func iniciar() async {
        guard let armazenamento else { return }

        // Descarta qualquer sessão que tenha sobrado.
        //
        // O `Timer` de medição é criado com `target:`, e alvo de timer é
        // retido: uma sessão que não foi encerrada continua viva, com o
        // `AVAudioRecorder` dela segurando o microfone. A tentativa seguinte
        // então falhava com "recusou começar a gravar" sem motivo aparente.
        if let anterior = sessao {
            await anterior.descartar()
            sessao = nil
        }
        tarefaNivel?.cancel()
        tarefaNivel = nil

        avisos = []
        waveform = []
        waveformSistema = []
        tempoDeGravacao = 0
        notasDaGravacao = []
        rascunhoDaNota = ""
        proximaNotaSeraCritica = false

        let sessao = SessaoGravacao(armazenamento: armazenamento)
        do {
            try await sessao.iniciar()
        } catch {
            // Sem isto a sessão que falhou continuava sendo a `self.sessao` de
            // uma tentativa anterior, e nada a soltava.
            self.sessao = nil
            estado = .falhou(error.localizedDescription)
            return
        }

        self.sessao = sessao
        estado = .gravando
        let identificador = UUID()
        identificadorDaGravacao = identificador

        // Waveform: amostra o nível a ~20 Hz. O medidor é atômico, então
        // ler daqui não toca na thread de áudio. O tempo vem da própria
        // sessão, para manter notas e áudio sincronizados mesmo com buffers.
        iniciarMonitoramentoDeNivel(sessao: sessao, identificador: identificador)
    }

    private func parar() async {
        tarefaNivel?.cancel()
        tarefaNivel = nil
        guard let sessao else { return }

        // A última atualização visual acontece a cada 50 ms. Antes de anexar
        // um rascunho ao término, consultamos a sessão diretamente para que o
        // timestamp final não fique preso à última atualização da waveform.
        tempoDeGravacao = sessao.tempoDecorrido
        confirmarRascunhoDaNota()

        estado = .processando
        let resultado = await sessao.parar()
        self.sessao = nil
        identificadorDaGravacao = nil

        avisos = resultado.avisos
        estado = .ocioso
        tempoDeGravacao = resultado.duracao

        // As notas saem daqui antes de qualquer `await`: com o estado já
        // ocioso, a pessoa pode começar outra gravação enquanto a biblioteca
        // registra esta, e uma limpeza tardia apagaria as notas da NOVA.
        let notasDestaGravacao = notasDaGravacao
        limparDepoisDeGravar()

        // Gravação descartada por ser curta demais volta com duração 0 e já foi
        // apagada do disco — não entra na biblioteca.
        if resultado.duracao > 0 {
            let notas = notasDestaGravacao.map { nota in
                var notaAjustada = nota
                notaAjustada.start = min(max(0, nota.start), resultado.duracao)
                return notaAjustada
            }
            pastasEmEntrega.insert(resultado.pastaRelativa)
            await aoProduzirAudio?(
                Self.tituloParaAgora(),
                resultado.pastaRelativa,
                resultado.duracao,
                Self.notasParaArquivo(notas),
                nil,
                resultado.usavaFones
            )
            pastasEmEntrega.remove(resultado.pastaRelativa)
        } else if !notasDestaGravacao.isEmpty {
            // Uma gravação curta é descartada junto com o áudio, portanto não
            // há um arquivo ao qual as notas possam pertencer.
            avisos.append(
                "As notas também foram descartadas porque a gravação era curta demais para criar um arquivo.".localized
            )
        }
    }

    /// O sistema encerrou o gravador sozinho (entrada removida, disco cheio).
    /// Finaliza como se a pessoa tivesse parado: o que foi gravado vira
    /// conversa, em vez de a tela seguir "gravando" algo que já acabou.
    private func finalizarPorInterrupcao(_ identificador: UUID) async {
        guard identificadorDaGravacao == identificador, gravando else { return }
        await parar()
    }

    private func iniciarMonitoramentoDeNivel(sessao: SessaoGravacao, identificador: UUID) {
        identificadorDaGravacao = identificador
        let nivel = sessao.nivelMicrofone
        let nivelSistema = sessao.nivelSistema
        tarefaNivel = Task { [weak self] in
            while !Task.isCancelled {
                let valor = nivel.normalizado
                let valorSistema = nivelSistema.normalizado
                let tempo = sessao.tempoDecorrido
                let interrompida = sessao.interrompida
                await MainActor.run {
                    guard self?.identificadorDaGravacao == identificador,
                          self?.estado == .gravando
                    else { return }
                    self?.acrescentarAoWaveform(valor)
                    self?.acrescentarAoWaveformSistema(valorSistema)
                    self?.tempoDeGravacao = tempo
                }
                if interrompida {
                    // Tarefa nova: `parar()` cancela esta, e o registro na
                    // biblioteca não pode herdar o cancelamento.
                    Task { @MainActor [weak self] in
                        await self?.finalizarPorInterrupcao(identificador)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func limparDepoisDeGravar() {
        notasDaGravacao = []
        rascunhoDaNota = ""
        proximaNotaSeraCritica = false
    }

    /// Título provisório de uma gravação. O resumo produz um título melhor
    /// (`Resumo.titulo`) — mas só depois de rodar, e a lista precisa mostrar
    /// alguma coisa enquanto isso.
    private static func tituloParaAgora() -> String {
        let formato = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return "Gravação de %@".localized(Date().formatted(formato))
    }

    /// Cada nota da gravação continua sendo uma nota na conversa.
    ///
    /// Antes elas eram fundidas num bloco único ancorado em 0:00, com o tempo
    /// virando prefixo de texto — "[0:23] fulano disse tal". O resultado é que
    /// tudo o que a pessoa anotou ao vivo, em instantes diferentes, chegava na
    /// conversa como um parágrafo só que apontava para o começo do áudio:
    /// clicar no tempo levava sempre a 0:00, editar significava mexer num
    /// bloco com cinco assuntos, e apagar uma anotação exigia editar texto.
    ///
    /// Preservando uma nota por anotação, o que foi escrito durante a gravação
    /// aparece na aba Notas igual ao que se escreve depois — mesma linha, mesmo
    /// instante clicável, mesmo lápis, mesma lixeira.
    private static func notasParaArquivo(_ notas: [NotaDaConversa]) -> [NotaDaConversa] {
        notas.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }

    private func acrescentarAoWaveform(_ valor: Float) {
        waveform.append(valor)
        if waveform.count > quadrosWaveform {
            waveform.removeFirst(waveform.count - quadrosWaveform)
        }
    }

    private func acrescentarAoWaveformSistema(_ valor: Float) {
        waveformSistema.append(valor)
        if waveformSistema.count > quadrosWaveform {
            waveformSistema.removeFirst(waveformSistema.count - quadrosWaveform)
        }
    }

    // MARK: - Notas da gravação

    /// Registra o texto atual com o carimbo de tempo do áudio. Rascunhos vazios
    /// não viram cartões silenciosos no detalhe.
    ///
    /// Vale também com a gravação pausada — é justamente quando sobra tempo
    /// para anotar. O instante é `tempoDeGravacao`, congelado na pausa.
    func adicionarNota() {
        let texto = rascunhoDaNota.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gravando, !texto.isEmpty else { return }

        notasDaGravacao.append(
            NotaDaConversa(
                texto: texto,
                start: tempoDeGravacao,
                critica: proximaNotaSeraCritica,
                tipo: .nota
            )
        )
        rascunhoDaNota = ""
        proximaNotaSeraCritica = false
    }

    /// Corrige o texto de uma nota já registrada.
    ///
    /// Anotar ao vivo produz erro de digitação e frase pela metade — a atenção
    /// está na conversa, não no teclado. Sem corrigir na hora, o engano só sai
    /// depois que a transcrição terminar, minutos ou dezenas de minutos depois.
    ///
    /// Texto vazio devolve a nota à condição de marcador: o instante continua
    /// guardado, que é o que ela tinha de mais valioso.
    func editarNota(_ nota: NotaDaConversa, texto: String) {
        guard let indice = notasDaGravacao.firstIndex(where: { $0.id == nota.id }) else { return }
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        notasDaGravacao[indice].texto = limpo
        notasDaGravacao[indice].tipo = limpo.isEmpty ? .marcador : .nota
    }

    /// Apaga uma nota tomada durante a gravação.
    ///
    /// Existe porque anotar ao vivo erra: a pessoa aperta Enter sem querer, ou
    /// registra algo que percebe em seguida ser irrelevante. Sem isso, o engano
    /// só sairia depois de a transcrição terminar.
    func removerNota(_ nota: NotaDaConversa) {
        notasDaGravacao.removeAll { $0.id == nota.id }
    }

    /// Um marcador é uma nota sem texto livre que conserva o instante exato da
    /// conversa. Pode ser usado depois para localizar um ponto relevante.
    func inserirMarcador() {
        guard gravando else { return }

        notasDaGravacao.append(
            NotaDaConversa(
                texto: "Marcador".localized,
                start: tempoDeGravacao,
                critica: proximaNotaSeraCritica,
                tipo: .marcador
            )
        )
        proximaNotaSeraCritica = false
    }

    private func confirmarRascunhoDaNota() {
        adicionarNota()
    }

    // MARK: - Importação

    /// - Important: `url` precisa vir do `.fileImporter` **com o acesso
    ///   security-scoped já aberto** por quem chama.
    func importar(_ url: URL) async {
        guard let armazenamento else { return }
        // Com uma gravação em curso, importar mexia no estado dela: o selo
        // "Gravando" sumia e a próxima gravação descartava a que seguia viva.
        guard !gravando else {
            avisos.append("Finalize a gravação em andamento antes de importar um áudio.".localized)
            return
        }
        importacoesEmCurso += 1
        defer { importacoesEmCurso -= 1 }
        if case .falhou = estado { estado = .ocioso }
#if OMU_PERF
        let inicioImportacao = DispatchTime.now().uptimeNanoseconds
        PerfProbe.shared.registrarImportacaoInicio(url)
#endif
        do {
            let importado = try await ImportadorAudio(armazenamento: armazenamento).importar(de: url)
            avisos = ["Arquivo importado: um canal só, sem separação de falante.".localized]
            await aoProduzirAudio?(
                importado.tituloSugerido, importado.pastaRelativa, importado.duracao, [],
                importado.dataOriginal,
                nil
            )
#if OMU_PERF
            let duracao = Double(DispatchTime.now().uptimeNanoseconds &- inicioImportacao) / 1_000_000_000
            PerfProbe.shared.registrarImportacaoFim(
                duracao: duracao,
                bytes: importado.bytes,
                duracaoAudio: importado.duracao
            )
#endif
        } catch {
            let mensagem = Self.mensagemAmigavelDeImportacao(error)
            // Uma gravação pode ter começado enquanto a cópia rodava; a falha
            // da importação não pode derrubar o estado dela.
            if gravando {
                avisos.append(mensagem)
            } else {
                estado = .falhou(mensagem)
            }
#if OMU_PERF
            let duracao = Double(DispatchTime.now().uptimeNanoseconds &- inicioImportacao) / 1_000_000_000
            PerfProbe.shared.registrarImportacaoFim(
                duracao: duracao,
                bytes: 0,
                erro: String(describing: error)
            )
#endif
        }
    }

    private static func mensagemAmigavelDeImportacao(_ error: Error) -> String {
        let nsError = error as NSError
        let texto = "\(nsError.localizedDescription) \(nsError.localizedFailureReason ?? "")"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if texto.contains("iphone") || texto.contains("locked") || texto.contains("bloqueado") {
            return "Você precisa desbloquear seu iPhone antes de importar esse áudio.".localized
        }
        if nsError.domain == NSCocoaErrorDomain && [257, 260, 513].contains(nsError.code) {
            return "Não consegui acessar esse áudio. Se ele estiver no iPhone, desbloqueie o aparelho e tente importar de novo.".localized
        }
        return error.localizedDescription
    }
}

/// Captura do ditado — **fora do `MainActor` de propósito**.
///
/// O `installTap` entrega buffers na thread de áudio em tempo real. Tocar em
/// estado isolado no `MainActor` a partir dali derruba o processo com
/// `_dispatch_assert_queue_fail` ("Block was not expected to execute on
/// queue") — não é exceção, é o libdispatch abortando. Foi exatamente o que
/// acontecia na primeira versão deste ditado.
///
/// Por isso tudo que o bloco toca vive aqui, sem isolação: o arquivo de saída e
/// o pedido do Speech. O texto reconhecido sai por um callback que quem recebe
/// leva para a main.
final class CapturaDeDitado: @unchecked Sendable {
    let arquivoDeAudio: URL

    private let motor = AVAudioEngine()
    private let pedido = SFSpeechAudioBufferRecognitionRequest()
    private var tarefa: SFSpeechRecognitionTask?
    private var saida: AVAudioFile?

    init(arquivoDeAudio: URL) {
        self.arquivoDeAudio = arquivoDeAudio
    }

    /// - Parameter reconhecedor: `nil` quando o Mac não reconhece fala no
    ///   próprio dispositivo. Nesse caso só o arquivo é gravado e o Whisper
    ///   transcreve no fim — sem parciais, mas também sem enviar áudio a
    ///   servidor nenhum, que é o que a descrição de uso promete.
    func iniciar(
        reconhecedor: SFSpeechRecognizer?,
        aoReconhecer: @escaping @Sendable (String) -> Void
    ) throws {
        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)

        // Sem microfone o formato vem com 0 Hz, e o `installTap` com formato
        // inválido aborta o processo em vez de lançar erro.
        guard formato.sampleRate > 0, formato.channelCount > 0 else {
            throw ErroDeDitado.semEntradaDeAudio
        }

        let arquivo = try AVAudioFile(forWriting: arquivoDeAudio, settings: formato.settings)
        saida = arquivo

        // Só no dispositivo: sem essa exigência o `SFSpeechRecognizer` manda
        // o áudio para os servidores da Apple quando o Mac não tem o modelo
        // local do idioma.
        let pedidoDoTap: SFSpeechAudioBufferRecognitionRequest?
        if let reconhecedor, reconhecedor.supportsOnDeviceRecognition {
            pedido.shouldReportPartialResults = true
            pedido.requiresOnDeviceRecognition = true
            tarefa = reconhecedor.recognitionTask(with: pedido) { resultado, _ in
                guard let texto = resultado?.bestTranscription.formattedString else { return }
                aoReconhecer(texto)
            }
            pedidoDoTap = pedido
        } else {
            pedidoDoTap = nil
        }

        entrada.installTap(onBus: 0, bufferSize: 2_048, format: formato) { buffer, _ in
            pedidoDoTap?.append(buffer)
            try? arquivo.write(from: buffer)
        }

        motor.prepare()
        try motor.start()
    }

    func encerrar() {
        if motor.isRunning { motor.stop() }
        motor.inputNode.removeTap(onBus: 0)
        pedido.endAudio()
        tarefa?.cancel()
        tarefa = nil
        saida = nil
    }

    enum ErroDeDitado: LocalizedError {
        case semEntradaDeAudio
        case reconhecimentoIndisponivel

        var errorDescription: String? {
            switch self {
            case .semEntradaDeAudio: "Nenhum microfone disponível.".localized
            case .reconhecimentoIndisponivel: "O reconhecimento de fala não está disponível agora.".localized
            }
        }
    }
}

/// Ditado de uma nota: texto ao vivo enquanto a pessoa fala, refinado pelo
/// Whisper ao terminar.
///
/// Os dois reconhecedores fazem o que cada um faz melhor. O `Speech` da Apple
/// devolve parciais em tempo real; o Whisper do app acerta mais mas precisa do
/// arquivo inteiro. Se o Whisper falhar, o que a Apple entendeu continua
/// valendo — nunca se perde o ditado.
@MainActor
@Observable
final class DitadoDeNota {
    enum Estado: Equatable {
        case ocioso
        case gravando
        case transcrevendo
        case falhou(String)
    }

    private(set) var estado: Estado = .ocioso
    private(set) var textoParcial = ""

    var gravando: Bool { estado == .gravando }
    var ocupado: Bool { estado == .gravando || estado == .transcrevendo }

    @ObservationIgnored private var captura: CapturaDeDitado?

    func iniciar() async {
        guard !ocupado else { return }
        estado = .ocioso
        textoParcial = ""

        // Microfone primeiro: tocar no `inputNode` antes da permissão devolve
        // formato inválido, e formato inválido no tap aborta o processo.
        guard await autorizarMicrofone() else {
            estado = .falhou("Autorize o microfone em Ajustes do Sistema › Privacidade › Microfone.".localized)
            return
        }
        guard await autorizarFala() else {
            estado = .falhou("Autorize o reconhecimento de fala em Ajustes do Sistema › Privacidade.".localized)
            return
        }

        // Os parciais seguem o idioma do app. Sem reconhecimento local nesse
        // idioma o ditado continua — o Whisper transcreve no fim —, só não
        // mostra texto enquanto a pessoa fala.
        let reconhecedor = Self.reconhecedorLocal()

        let destino = FileManager.default.temporaryDirectory
            .appendingPathComponent("ditado-\(UUID().uuidString).caf")
        let nova = CapturaDeDitado(arquivoDeAudio: destino)

        do {
            try nova.iniciar(reconhecedor: reconhecedor) { [weak self] texto in
                Task { @MainActor [weak self] in
                    self?.textoParcial = texto
                }
            }
            captura = nova
            estado = .gravando
        } catch {
            nova.encerrar()
            try? FileManager.default.removeItem(at: destino)
            estado = .falhou(error.localizedDescription)
        }
    }

    func concluir(transcrever: (URL) async throws -> String) async -> String? {
        guard estado == .gravando, let captura else { return nil }

        captura.encerrar()
        self.captura = nil
        let gravado = captura.arquivoDeAudio
        let parcial = textoParcial.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(at: gravado) }

        estado = .transcrevendo
        do {
            let refinado = try await transcrever(gravado).trimmingCharacters(in: .whitespacesAndNewlines)
            estado = .ocioso
            return refinado.isEmpty ? (parcial.isEmpty ? nil : parcial) : refinado
        } catch {
            estado = .ocioso
            return parcial.isEmpty ? nil : parcial
        }
    }

    /// Reconhecedor do idioma do app, e só se funcionar no próprio Mac.
    private static func reconhecedorLocal() -> SFSpeechRecognizer? {
        let candidatos = [
            SFSpeechRecognizer(locale: LocalizacaoDoApp.localeAtual),
            SFSpeechRecognizer(),
            SFSpeechRecognizer(locale: Locale(identifier: "pt_BR")),
        ]
        return candidatos
            .compactMap { $0 }
            .first { $0.isAvailable && $0.supportsOnDeviceRecognition }
    }

    func cancelar() {
        if let captura {
            captura.encerrar()
            try? FileManager.default.removeItem(at: captura.arquivoDeAudio)
        }
        captura = nil
        textoParcial = ""
        estado = .ocioso
    }

    func limparFalha() {
        if case .falhou = estado { estado = .ocioso }
    }

    private func autorizarMicrofone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func autorizarFala() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuacao in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuacao.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }
}
