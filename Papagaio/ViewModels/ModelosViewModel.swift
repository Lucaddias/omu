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

    private let pastaDoContainer: URL
    private let download: DownloadDeModelos
    private var tarefa: Task<Void, Never>?

    init(pastaDoContainer: URL) {
        self.pastaDoContainer = pastaDoContainer
        self.download = DownloadDeModelos(pastaDeModelos: pastaDoContainer)
        self.pastaEscolhida = PastaDeModelosDoUsuario.resolver()
    }

    /// A pasta que vale agora. O download só escreve no container: gravar dentro
    /// da pasta do usuário mexeria em arquivos que não são do app.
    var pasta: URL { pastaEscolhida ?? pastaDoContainer }

    var pronto: Bool { resultado == .pronto || resultado == .termicoCritico }

    /// Verificação barata: tamanho em disco, não SHA-256 dos pesos (ver a nota
    /// em `Preflight.pesoValido`).
    func verificar() {
        resultado = Preflight(pastaDeModelos: pasta).avaliar()
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
