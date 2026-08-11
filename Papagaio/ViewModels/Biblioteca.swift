import Foundation
import Observation
import PapagaioCore

/// A biblioteca de arquivos do app: o que está salvo, o que está processando e
/// o que falhou.
///
/// É aqui que o app finalmente **chama o pipeline**. Antes disso a transcrição e
/// o resumo existiam só em `PapagaioCore` e na CLI — gravar pelo app produzia um
/// `.m4a` e nada mais.
@MainActor
@Observable
final class Biblioteca {
    private(set) var arquivos: [Arquivo] = []
    /// Arquivos removidos da listagem principal, mas ainda recuperáveis. A
    /// mídia continua no container até a exclusão definitiva.
    private(set) var arquivosNaLixeira: [Arquivo] = []

    /// Fase corrente por arquivo. Chaveado pelo `UUID` cru porque é o que a view
    /// tem em mãos na navegação.
    private(set) var fases: [UUID: PipelineDeArquivo.Fase] = [:]
    /// Quando cada processamento começou, para estimar o quanto falta.
    private(set) var iniciadoEm: [UUID: Date] = [:]
    private(set) var erros: [UUID: String] = [:]

    /// O Whisper e o Qwen juntos podem ocupar 13,7 GB. A fila mantém os
    /// pedidos em ordem de chegada e permite que somente um deles carregue os
    /// modelos por vez.
    private var filaDeProcessamento: [ArquivoID] = []
    private var arquivoEmProcessamento: ArquivoID?
    private var identificadorDaExecucao: UUID?
    private var tarefaDeProcessamento: Task<Void, Never>?

    /// Uma operação de lixeira pode suspender ao salvar no SwiftData. Rastrear
    /// os itens em transição evita dois cliques concorrentes e também impede
    /// que um item seja re-enfileirado enquanto está sendo removido.
    private var operacoesDeLixeiraEmAndamento: Set<ArquivoID> = []
    private(set) var erroDaLixeira: String?

    let armazenamento: Armazenamento

    /// De onde os pesos são carregados. A `ContentView` mantém isto igual à
    /// pasta ativa do `ModelosViewModel` — pode ser a do container ou uma
    /// escolhida pelo usuário.
    var pastaDeModelos: URL

    /// Controla somente a entrada automática de áudios novos na fila. A fila
    /// continua sendo o único caminho para qualquer processamento manual ou
    /// automático, mantendo um único par de modelos carregado por vez.
    var processamentoAutomatico = true
    var aoNotificar: (@MainActor (_ titulo: String, _ mensagem: String, _ tipo: NotificacaoDoApp.Tipo) -> Void)?
    var aoConcluirProcessamento: (@MainActor (_ arquivo: Arquivo) -> Void)?

    private let repositorio: SwiftDataRepository
    private let ciclo = CicloDeVidaDeModelos()
    private let espaco: EspacoID

    init() throws {
        let armazenamento = try Armazenamento.padrao()
        self.armazenamento = armazenamento
        self.pastaDeModelos = armazenamento.pastaDeModelos
        self.repositorio = SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal()
        )
        self.espaco = Self.espacoIndividual()
    }

    /// O espaço individual é um só e precisa sobreviver a relançamentos: sem
    /// isto, cada abertura criaria um espaço novo e a lista voltaria vazia.
    private static func espacoIndividual() -> EspacoID {
        let chave = "espacoIndividual"
        if let guardado = UserDefaults.standard.string(forKey: chave),
           let id = UUID(uuidString: guardado) {
            return EspacoID(rawValue: id)
        }
        let novo = UUID()
        UserDefaults.standard.set(novo.uuidString, forKey: chave)
        return EspacoID(rawValue: novo)
    }

    // MARK: - Ciclo de vida

    func preparar() async {
        await ciclo.iniciarMonitoramento()
        await ciclo.encerrarNaSaidaDoApp()
        await carregar()
    }

    func carregar() async {
        do {
            arquivos = try await repositorio.listar(espaco: espaco)
            arquivosNaLixeira = try await repositorio.listarNaLixeira(espaco: espaco)
        } catch {
            erros[UUID()] = "Não foi possível abrir a biblioteca: \(error)"
        }
    }

    // MARK: - Entrada de áudio

    /// Registra um áudio recém-gravado ou importado. Com o processamento
    /// automático ativo ele entra na fila; caso contrário fica pronto para a
    /// pessoa iniciar pela aba Transcrição. As notas são criadas antes da fila,
    /// para que os saves do pipeline apenas as preservem junto de transcrição
    /// e resumo.
    @discardableResult
    func registrar(
        titulo: String,
        pastaRelativa: String,
        duracao: TimeInterval,
        notas: [NotaDaConversa] = []
    ) async -> Arquivo? {
        let arquivo = Arquivo(
            titulo: titulo,
            duracao: duracao,
            pastaRelativa: pastaRelativa,
            espaco: espaco,
            notas: notas
        )
        do {
            try await repositorio.salvar(arquivo)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar: \(error)"
            return nil
        }
        arquivos.insert(arquivo, at: 0)
        if processamentoAutomatico {
            enfileirarProcessamento(arquivo)
        }
        return arquivo
    }

    // MARK: - Lixeira

    /// Move um arquivo para a lixeira. Se ele estiver resumindo/transcrevendo,
    /// a execução atual é cancelada antes do soft delete para a UI não ficar
    /// presa esperando o pipeline terminar.
    func moverParaLixeira(_ arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return }

        cancelarProcessamentoDoArquivo(arquivo.id)

        let indiceNaFila = filaDeProcessamento.firstIndex(of: arquivo.id)
        if let indiceNaFila { filaDeProcessamento.remove(at: indiceNaFila) }

        let chave = arquivo.id.rawValue
        let faseAnterior = fases[chave]
        let erroAnterior = erros[chave]
        fases[chave] = nil
        iniciadoEm[chave] = nil
        erros[chave] = nil
        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            try await repositorio.moverParaLixeira(arquivo.id)
            arquivos.removeAll { $0.id == arquivo.id }

            var movido = arquivo
            movido.apagadoEm = Date()
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }
            arquivosNaLixeira.insert(movido, at: 0)
        } catch {
            // O registro continuou ativo porque o soft delete não foi salvo;
            // devolvemos a posição anterior da fila em vez de perder trabalho.
            fases[chave] = faseAnterior
            erros[chave] = erroAnterior
            if let indiceNaFila {
                filaDeProcessamento.insert(
                    arquivo.id,
                    at: min(indiceNaFila, filaDeProcessamento.count)
                )
                iniciarProximoProcessamentoSeNecessario()
            }
            erroDaLixeira = "Não foi possível mover o arquivo para a lixeira: \(error.localizedDescription)"
        }
    }

    /// Restaura o arquivo para Todos os arquivos sem iniciar processamento de
    /// novo. Se ele tiver sido removido enquanto aguardava, a pessoa escolhe
    /// explicitamente quando reprocessá-lo — nunca carregamos modelos de surpresa.
    @discardableResult
    func restaurarDaLixeira(_ arquivo: Arquivo) async -> Bool {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return false }

        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            try await repositorio.restaurar(arquivo.id)
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }

            var restaurado = arquivo
            restaurado.apagadoEm = nil
            arquivos.removeAll { $0.id == arquivo.id }
            arquivos.append(restaurado)
            arquivos.sort { $0.criadoEm > $1.criadoEm }
            return true
        } catch {
            erroDaLixeira = "Não foi possível recuperar o arquivo: \(error.localizedDescription)"
            return false
        }
    }

    /// Exclusão irreversível. O repositório remove o registro, a pasta relativa
    /// correta e todos os arquivos derivados apenas neste ponto.
    func apagarDefinitivamente(_ arquivo: Arquivo) async {
        guard arquivo.apagadoEm != nil,
              arquivosNaLixeira.contains(where: { $0.id == arquivo.id }),
              arquivoEmProcessamento != arquivo.id,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else {
            erroDaLixeira = "Mova o arquivo para a lixeira antes de apagá-lo definitivamente."
            return
        }

        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            try await repositorio.apagar(arquivo.id)
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }
            filaDeProcessamento.removeAll { $0 == arquivo.id }
            fases[arquivo.id.rawValue] = nil
            erros[arquivo.id.rawValue] = nil
        } catch {
            erroDaLixeira = "Não foi possível apagar o arquivo definitivamente: \(error.localizedDescription)"
        }
    }

    func restaurarTudoDaLixeira() async {
        let arquivos = arquivosNaLixeira
        guard !arquivos.isEmpty else { return }

        for arquivo in arquivos {
            _ = await restaurarDaLixeira(arquivo)
            if erroDaLixeira != nil { break }
        }
    }

    func esvaziarLixeira() async {
        let arquivos = arquivosNaLixeira
        guard !arquivos.isEmpty else { return }

        for arquivo in arquivos {
            await apagarDefinitivamente(arquivo)
            if erroDaLixeira != nil { break }
        }
    }

    func estaEmOperacaoDeLixeira(_ arquivo: Arquivo) -> Bool {
        operacoesDeLixeiraEmAndamento.contains(arquivo.id)
    }

    func dispensarErroDaLixeira() {
        erroDaLixeira = nil
    }

    // MARK: - Edição de arquivos

    func renomear(_ arquivo: Arquivo, para novoTitulo: String) async {
        let tituloLimpo = novoTitulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return }

        var editado = arquivo
        editado.titulo = tituloLimpo
        if let resumo = arquivo.resumo {
            editado.resumo = Resumo(
                titulo: tituloLimpo,
                visaoGeral: resumo.visaoGeral,
                temas: resumo.temas,
                citacoes: resumo.citacoes,
                proximosPassos: resumo.proximosPassos
            )
        }

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível renomear: \(error.localizedDescription)"
        }
    }

    func atualizarMetadados(
        _ arquivo: Arquivo,
        titulo novoTitulo: String,
        criadoEm: Date,
        duracao: TimeInterval
    ) async {
        let tituloLimpo = novoTitulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return }

        var editado = arquivo
        editado.titulo = tituloLimpo
        editado.criadoEm = criadoEm
        editado.duracao = max(0, duracao)
        if let resumo = arquivo.resumo {
            editado.resumo = Resumo(
                titulo: tituloLimpo,
                visaoGeral: resumo.visaoGeral,
                temas: resumo.temas,
                citacoes: resumo.citacoes,
                proximosPassos: resumo.proximosPassos
            )
        }

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar as informações: \(error.localizedDescription)"
        }
    }

    func atualizarNotas(_ notas: [NotaDaConversa], de arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }

        var editado = arquivo
        editado.notas = notas

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar as notas: \(error.localizedDescription)"
        }
    }

    /// Salva a transcrição corrigida à mão.
    ///
    /// O resumo **não** é refeito: ele já foi gerado e regerar sozinho gastaria
    /// minutos de modelo sem a pessoa ter pedido. Quem quiser o resumo alinhado
    /// à correção reprocessa pelo menu.
    func atualizarTrechos(_ trechos: [Trecho], de arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }

        var editado = arquivo
        editado.trechos = trechos

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar a transcrição: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func duplicar(_ arquivo: Arquivo) async -> Arquivo? {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return nil }

        let novoID = ArquivoID()
        let pastaNovaRelativa = Armazenamento.caminhoRelativo(id: novoID.rawValue)
        let origem = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        let destino = armazenamento.resolver(relativo: pastaNovaRelativa)

        do {
            if FileManager.default.fileExists(atPath: origem.path) {
                try FileManager.default.copyItem(at: origem, to: destino)
            } else {
                try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
            }

            var copia = Arquivo(
                id: novoID,
                titulo: "\(arquivo.titulo) cópia",
                criadoEm: Date(),
                duracao: arquivo.duracao,
                pastaRelativa: pastaNovaRelativa,
                espaco: espaco,
                trechos: arquivo.trechos.map {
                    Trecho(start: $0.start, end: $0.end, texto: $0.texto, speaker: $0.speaker, palavras: $0.palavras)
                },
                notas: arquivo.notas.map {
                    NotaDaConversa(texto: $0.texto, start: $0.start, critica: $0.critica, tipo: $0.tipo)
                },
                resumo: arquivo.resumo,
                engineTranscricao: arquivo.engineTranscricao,
                engineResumo: arquivo.engineResumo
            )
            if let resumo = arquivo.resumo {
                copia.resumo = Resumo(
                    titulo: "\(resumo.titulo) cópia",
                    visaoGeral: resumo.visaoGeral,
                    temas: resumo.temas,
                    citacoes: resumo.citacoes,
                    proximosPassos: resumo.proximosPassos
                )
            }

            try await repositorio.salvar(copia)
            arquivos.insert(copia, at: 0)
            return copia
        } catch {
            try? FileManager.default.removeItem(at: destino)
            erros[arquivo.id.rawValue] = "Não foi possível duplicar: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Processamento

    var processando: Bool {
        arquivoEmProcessamento != nil || !filaDeProcessamento.isEmpty
    }

    func enfileirarProcessamento(_ arquivo: Arquivo) {
        guard arquivoEmProcessamento != arquivo.id,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id),
              !filaDeProcessamento.contains(arquivo.id) else { return }

        erros[arquivo.id.rawValue] = nil
        filaDeProcessamento.append(arquivo.id)
        iniciarProximoProcessamentoSeNecessario()
    }

    private func cancelarProcessamentoDoArquivo(_ arquivoID: ArquivoID) {
        filaDeProcessamento.removeAll { $0 == arquivoID }
        guard arquivoEmProcessamento == arquivoID else { return }

        tarefaDeProcessamento?.cancel()
        tarefaDeProcessamento = nil
        arquivoEmProcessamento = nil
        identificadorDaExecucao = nil
        fases[arquivoID.rawValue] = nil
        iniciarProximoProcessamentoSeNecessario()
    }

    func estaProcessando(_ arquivo: Arquivo) -> Bool {
        arquivoEmProcessamento == arquivo.id
    }

    func estaNaFila(_ arquivo: Arquivo) -> Bool {
        filaDeProcessamento.contains(arquivo.id)
    }

    private func iniciarProximoProcessamentoSeNecessario() {
        guard arquivoEmProcessamento == nil else { return }

        while let proximoID = filaDeProcessamento.first {
            filaDeProcessamento.removeFirst()
            guard let arquivo = arquivos.first(where: { $0.id == proximoID }) else {
                continue
            }

            let execucao = UUID()
            arquivoEmProcessamento = proximoID
            identificadorDaExecucao = execucao
            tarefaDeProcessamento = Task { [weak self] in
                await self?.executarProcessamento(arquivo, execucao: execucao)
            }
            return
        }
    }

    /// Transcreve um trecho ditado e devolve o texto corrido.
    ///
    /// Mesmo Whisper das conversas, e descarrega no fim: uma nota ditada não
    /// justifica deixar 13,7 GB residentes.
    func transcreverDitado(_ audio: URL) async throws -> String {
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            throw ErroDeDitado.modelosIndisponiveis(preflight.mensagem)
        }

        let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)
        defer { Task { await motores.descarregarTudo() } }

        return try await motores.transcrever(audio, speaker: nil, initialPrompt: nil)
            .map(\.texto)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ErroDeDitado: LocalizedError {
        case modelosIndisponiveis(String)

        var errorDescription: String? {
            switch self {
            case let .modelosIndisponiveis(motivo): motivo
            }
        }
    }

    private func executarProcessamento(_ arquivo: Arquivo, execucao: UUID) async {
        let chave = arquivo.id.rawValue
        defer { finalizarProcessamento(chave, execucao: execucao) }

        // Sem os pesos, o Whisper falharia lá dentro com um erro de carga. Dizer
        // o que falta é mais útil que repassar o erro do llama.cpp.
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            erros[chave] = preflight.mensagem
            return
        }

        erros[chave] = nil
        fases[chave] = .transcrevendo
        iniciadoEm[chave] = Date()
        let promptDeEntidades = await PromptDeEntidades.construir(para: arquivo)

        // Criado por execução, e descarregado no fim: os dois modelos somam
        // 13,7 GB e não podem ficar residentes entre gravações num Mac de 18 GB.
        let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)

        let pipeline = PipelineDeArquivo(
            armazenamento: armazenamento,
            repositorio: repositorio,
            idTranscricao: WhisperEngine.identificador,
            idResumo: QwenEngine.identificador,
            transcrever: { [motores, promptDeEntidades] url, speaker in
                try await motores.transcrever(
                    url,
                    speaker: speaker,
                    initialPrompt: promptDeEntidades
                )
            },
            resumir: { [motores] trechos in
                try await motores.resumir(trechos)
            }
        )

        do {
            let final = try await pipeline.processar(arquivo) { fase in
                Task { @MainActor [weak self] in
                    guard self?.identificadorDaExecucao == execucao else { return }
                    self?.fases[chave] = fase
                }
            }
            guard identificadorDaExecucao == execucao,
                  arquivos.contains(where: { $0.id == arquivo.id })
            else { return }
            substituir(final)
            aoConcluirProcessamento?(final)
            if final.trechos.isEmpty {
                erros[chave] = "Nenhuma fala reconhecida neste áudio."
                aoNotificar?(
                    "Transcrição finalizada sem falas",
                    "\(final.resumo?.titulo ?? final.titulo) não teve fala reconhecida.",
                    .aviso
                )
            } else {
                aoNotificar?(
                    "Transcrição concluída",
                    "\(final.resumo?.titulo ?? final.titulo) já está com transcrição e resumo prontos.",
                    .sucesso
                )
            }
        } catch {
            erros[chave] = "\(error)"
            aoNotificar?(
                "Transcrição falhou",
                "\(arquivo.titulo): \(error.localizedDescription)",
                .erro
            )
        }

        // 13,7 GB não podem ficar residentes depois que o trabalho acabou.
        await motores.descarregarTudo()
    }

    private func finalizarProcessamento(_ chave: UUID, execucao: UUID) {
        guard identificadorDaExecucao == execucao else { return }

        fases[chave] = nil
        iniciadoEm[chave] = nil
        arquivoEmProcessamento = nil
        identificadorDaExecucao = nil
        tarefaDeProcessamento = nil
        iniciarProximoProcessamentoSeNecessario()
    }

    private func substituir(_ arquivo: Arquivo) {
        if let indice = arquivos.firstIndex(where: { $0.id == arquivo.id }) {
            arquivos[indice] = arquivo
        } else {
            arquivos.insert(arquivo, at: 0)
        }
    }

    // MARK: - Consulta pela view

    func arquivo(id: UUID) -> Arquivo? {
        arquivos.first { $0.id.rawValue == id }
    }

    /// Canal principal para reprodução, na nova convenção: `microfone.wav`.
    ///
    /// Gravações antigas e arquivos importados têm **um único arquivo** (a
    /// mixagem legada `gravacao.m4a` ou o original copiado como `gravacao.<ext>`);
    /// nesses casos ele é o canal único. A reprodução em dois canais usa
    /// `audioSecundario` junto.
    func audio(de arquivo: Arquivo) -> URL {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        let microfone = pasta.appendingPathComponent(Armazenamento.Nome.microfone)
        if Self.existe(microfone) { return microfone }
        return Self.arquivoDeCanalUnico(em: pasta)
    }

    /// Veio de arquivo escolhido pela pessoa, e não do microfone.
    ///
    /// Deduzido do disco, e não guardado no modelo: gravação sempre escreve
    /// `microfone.wav`, importação sempre escreve `gravacao.<extensão>`. Um
    /// campo novo em `Arquivo` obrigaria a migrar o que já está salvo para
    /// responder algo que os próprios arquivos já dizem.
    func importado(_ arquivo: Arquivo) -> Bool {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        return !Self.existe(pasta.appendingPathComponent(Armazenamento.Nome.microfone))
    }

    /// Canal do sistema tocado em paralelo ao microfone — `sistema.m4a`.
    ///
    /// Só existe quando a gravação capturou os dois canais (o tap subiu).
    /// Importado e legado são canal único: `nil` aqui, e a reprodução toca
    /// só o principal.
    func audioSecundario(de arquivo: Arquivo) -> URL? {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        guard Self.existe(pasta.appendingPathComponent(Armazenamento.Nome.microfone)) else {
            return nil
        }
        let sistema = pasta.appendingPathComponent(Armazenamento.Nome.sistema)
        return Self.existe(sistema) ? sistema : nil
    }

    private static func existe(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// O arquivo único de quando não há canais separados: a mixagem legada
    /// `gravacao.m4a`, ou o importado copiado como veio (`gravacao.<ext>`).
    private static func arquivoDeCanalUnico(em pasta: URL) -> URL {
        let mixagem = pasta.appendingPathComponent(Armazenamento.Nome.mixagem)
        if existe(mixagem) { return mixagem }
        let conteudo = (try? FileManager.default.contentsOfDirectory(
            at: pasta, includingPropertiesForKeys: nil
        )) ?? []
        if let importado = conteudo.first(where: {
            $0.lastPathComponent.hasPrefix(Armazenamento.Nome.prefixoImportado + ".")
        }) {
            return importado
        }
        return mixagem
    }

    /// Estado do arquivo no pipeline.
    ///
    /// Devolvia `String`, e cada tela reclassificava esse texto por conta
    /// própria: o cartão por lista de literais, o detalhe por `contains("erro")`.
    /// O mesmo arquivo aparecia vermelho numa tela e neutro na outra, e trocar
    /// uma palavra em `Fase.descricao` quebrava a cor sem quebrar o build.
    /// Quanto do processamento já passou e quanto falta, em segundos.
    ///
    /// É uma **estimativa por tempo decorrido**, não medição real: nem o
    /// whisper nem o Qwen reportam percentual daqui. A referência é a duração
    /// do áudio — na prática o large-v3 leva algo perto de metade dela para
    /// transcrever, e o resumo some num punhado de segundos por minuto de
    /// conversa. Erra, e por isso a interface fala em "cerca de".
    ///
    /// A fração satura em 95% enquanto o trabalho não termina: barra parada em
    /// 100% com o app ainda pensando é pior que barra lenta.
    func progresso(de arquivo: Arquivo) -> (inicio: Date, estimativa: TimeInterval)? {
        let chave = arquivo.id.rawValue
        guard fases[chave] != nil, let inicio = iniciadoEm[chave] else { return nil }
        return (inicio, max(20, arquivo.duracao * 0.75))
    }

    func estado(de arquivo: Arquivo) -> EstadoDoArquivo {
        let chave = arquivo.id.rawValue
        if let fase = fases[chave] { return .processando(fase) }
        if let posicao = filaDeProcessamento.firstIndex(of: arquivo.id) {
            return .naFila(posicao: posicao + 1)
        }
        if let erro = erros[chave] { return .falhou(erro) }
        if arquivo.resumo != nil { return .transcritoEResumido }
        if !arquivo.trechos.isEmpty { return .transcrito }
        return .prontoParaTranscrever
    }
}
