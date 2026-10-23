import Foundation
import Observation
import PapagaioCore

/// Estado dos pesos GGUF para a interface: o que falta, quanto já baixou, o que
/// impede.
///
/// O `DownloadDeModelos` e o `Preflight` são do Passo 3 e já existiam — o que
/// faltava era alguém no app chamá-los. Sem isso o container nasce vazio e
/// nenhuma transcrição é possível.
@MainActor
@Observable
final class ModelosViewModel {
    private(set) var resultado: ResultadoPreflight?
    private(set) var progresso: ProgressoDownload?
    private(set) var erro: String?
    private(set) var baixando = false

    /// Pasta escolhida pelo usuário, quando houver. `nil` significa "usar a do
    /// container", que é onde o download deposita.
    private(set) var pastaEscolhida: URL?

    /// Chamado quando um download deixa os modelos prontos: quem esperava
    /// por eles (a fila de processamento) pode continuar.
    var aoFicarPronto: (@MainActor () -> Void)?

    /// Onde o resumo é gerado. Decide quais pesos são exigidos — e baixados:
    /// na nuvem privada da Apple, só o Whisper.
    private(set) var modo: ModoDeResumo
    /// Chamado quando a escolha muda: quem processa (a `Biblioteca`) acompanha.
    var aoMudarModo: (@MainActor (ModoDeResumo) -> Void)?

    private let pastaDoContainer: URL
    private let download: DownloadDeModelos
    private let preferencias: UserDefaults
    /// Injetável: os testes simulam um Mac que alcança a nuvem privada.
    private let disponibilidadeDaNuvem: @MainActor () -> DisponibilidadeDaNuvemPrivada
    private var tarefa: Task<Void, Never>?

#if OMU_PERF
    init(pastaDoContainer: URL, ignorarPastaEscolhidaPersistida: Bool) {
        self.pastaDoContainer = pastaDoContainer
        self.download = DownloadDeModelos(pastaDeModelos: pastaDoContainer)
        self.pastaEscolhida = ignorarPastaEscolhidaPersistida ? nil : PastaDeModelosDoUsuario.resolver()
        self.preferencias = .standard
        self.disponibilidadeDaNuvem = { NuvemPrivada.disponibilidade }
        // A medição de desempenho é a do pipeline local.
        self.modo = PerfProbe.ativada ? .local : PreferenciaDeResumo.modoAtivo()
    }
#else
    init(
        pastaDoContainer: URL,
        ignorarPastaEscolhidaPersistida: Bool = false,
        preferencias: UserDefaults = .standard,
        disponibilidadeDaNuvem: @escaping @MainActor () -> DisponibilidadeDaNuvemPrivada = { NuvemPrivada.disponibilidade }
    ) {
        self.pastaDoContainer = pastaDoContainer
        self.download = DownloadDeModelos(pastaDeModelos: pastaDoContainer)
        self.pastaEscolhida = ignorarPastaEscolhidaPersistida ? nil : PastaDeModelosDoUsuario.resolver()
        self.preferencias = preferencias
        self.disponibilidadeDaNuvem = disponibilidadeDaNuvem
        self.modo = PreferenciaDeResumo.modoAtivo(em: preferencias, disponibilidade: disponibilidadeDaNuvem())
    }
#endif

    /// A pasta que vale agora. O download só escreve no container: gravar dentro
    /// da pasta do usuário mexeria em arquivos que não são do app.
    var pasta: URL { pastaEscolhida ?? pastaDoContainer }

    var pronto: Bool { resultado == .pronto || resultado == .termicoCritico }

    /// Verificação barata: tamanho em disco, não SHA-256 dos pesos (ver a nota
    /// em `Preflight.pesoValido`).
    func verificar() {
        resultado = Preflight(pastaDeModelos: pasta).avaliar(para: modo)
    }

    // MARK: - Modo de resumo

    /// A nuvem privada da Apple pode ser oferecida neste Mac, neste build.
    var nuvemDisponivel: Bool { disponibilidadeDaNuvem() == .disponivel }

    /// Por que a nuvem privada não pode ser oferecida, quando não pode.
    var motivoDaNuvemIndisponivel: String { disponibilidadeDaNuvem().mensagem }

    /// Guarda a escolha e reavalia o que falta: trocar para a nuvem pode
    /// deixar tudo pronto na hora, sem baixar o Qwen.
    func escolherModo(_ novo: ModoDeResumo) {
        // Um download em curso foi pedido para o modo anterior: seguiria
        // baixando o Qwen em segundo plano depois de a pessoa dispensá-lo.
        // O que já desceu fica em disco e é retomado se voltar a ser pedido.
        if baixando { cancelar() }
        PreferenciaDeResumo.guardar(novo, em: preferencias)
        modo = novo
        verificar()
        aoMudarModo?(novo)
        if pronto { aoFicarPronto?() }
    }

    /// O Qwen que o próprio Ōmu baixou — o único que ele pode apagar.
    private var modeloLocalDoApp: URL {
        pastaDoContainer.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    }

    /// Há o que liberar: o Qwen (ou um download dele pela metade) na pasta
    /// do app, sem uso enquanto o resumo é feito pela nuvem.
    var podeRemoverModeloLocal: Bool {
        guard modo == .nuvemPrivada, !baixando else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: modeloLocalDoApp.path)
            || fm.fileExists(atPath: modeloLocalDoApp.appendingPathExtension("parcial").path)
    }

    /// Apaga o Qwen da pasta do app. Nunca toca na pasta escolhida pela
    /// pessoa: aqueles arquivos não são do Ōmu.
    func removerModeloLocal() {
        guard podeRemoverModeloLocal else { return }
        let fm = FileManager.default
        do {
            for url in [modeloLocalDoApp, modeloLocalDoApp.appendingPathExtension("parcial")]
            where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            erro = nil
        } catch {
            erro = "Não foi possível remover o modelo local: %@".localized(error.localizedDescription)
        }
        verificar()
    }

    /// - Important: `url` precisa vir do `.fileImporter` com o acesso
    ///   security-scoped **já aberto** por quem chama.
    func escolher(_ url: URL) {
        do {
            try PastaDeModelosDoUsuario.guardar(url)
            pastaEscolhida = PastaDeModelosDoUsuario.resolver()
            erro = nil
        } catch {
            erro = "Não foi possível guardar a pasta escolhida: %@".localized(error.localizedDescription)
        }
        verificar()
    }

    func usarOContainer() {
        PastaDeModelosDoUsuario.esquecer()
        pastaEscolhida = nil
        verificar()
    }

    var faltando: [PesoDeModelo] {
        if case let .pesosFaltando(pesos) = resultado { return pesos }
        return []
    }

    func baixar() {
        guard !baixando else { return }
        // O downloader escreve no container. Baixar enquanto uma pasta do
        // usuário está ativa deixaria um peso em cada lugar, e os motores só
        // olham para uma pasta.
        guard pastaEscolhida == nil else {
            erro = "Falta um modelo na pasta escolhida. Complete a pasta ou volte a usar a pasta do app para baixar.".localized
            return
        }
        let pesos = faltando
        guard !pesos.isEmpty else { return }

        baixando = true
        erro = nil
        amostrasDeVelocidade.removeAll()
        ultimaLeitura = nil
        restanteDoDownload = nil
        tarefa = Task {
            for peso in pesos {
                do {
                    _ = try await download.baixar(peso) { andamento in
                        Task { @MainActor in
                            self.registrarVelocidade(de: andamento)
                            self.progresso = andamento
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    erro = "\(error)"
                    break
                }
            }
            progresso = nil
            baixando = false
            verificar()
            if pronto { aoFicarPronto?() }
        }
    }

    /// Quanto falta do download, em segundos, ou `nil` sem medida ainda.
    ///
    /// Mesma ideia da estimativa de transcrição: em vez de supor uma
    /// velocidade, mede a que está acontecendo. A média móvel das últimas
    /// amostras evita que uma oscilação momentânea de rede faça o tempo
    /// restante pular de "2 min" para "40 min" e voltar.
    private(set) var restanteDoDownload: TimeInterval?

    /// Bytes por segundo das últimas leituras.
    private var amostrasDeVelocidade: [Double] = []
    private var ultimaLeitura: (bytes: Int64, quando: Date)?

    private func registrarVelocidade(de andamento: ProgressoDownload) {
        let agora = Date()
        defer { ultimaLeitura = (andamento.bytesRecebidos, agora) }

        guard let anterior = ultimaLeitura else { return }
        // Retomada de download muda o total de bytes para trás; nesse caso a
        // diferença é negativa e não descreve velocidade nenhuma.
        let bytes = Double(andamento.bytesRecebidos - anterior.bytes)
        let segundos = agora.timeIntervalSince(anterior.quando)
        guard bytes > 0, segundos > 0.2 else { return }

        amostrasDeVelocidade.append(bytes / segundos)
        if amostrasDeVelocidade.count > 8 {
            amostrasDeVelocidade.removeFirst(amostrasDeVelocidade.count - 8)
        }

        let media = amostrasDeVelocidade.reduce(0, +) / Double(amostrasDeVelocidade.count)
        guard media > 0 else { return }
        let faltam = Double(andamento.bytesTotais - andamento.bytesRecebidos)
        restanteDoDownload = max(0, faltam / media)
    }

    func cancelar() {
        tarefa?.cancel()
        tarefa = nil
        baixando = false
        progresso = nil
    }

    /// Quanto já existe em disco de cada peso ainda incompleto — o download
    /// retoma daí, e dizer isso evita a impressão de que 10 GB foram perdidos.
    func bytesJaBaixados(de peso: PesoDeModelo) async -> Int64 {
        await download.bytesParciais(de: peso)
    }
}
