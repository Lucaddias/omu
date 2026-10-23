import CryptoKit
import Foundation

/// Descrição de um peso GGUF que o app precisa ter em disco.
public struct PesoDeModelo: Sendable, Hashable {
    public let nomeArquivo: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL

    public init(nomeArquivo: String, bytes: Int64, sha256: String, url: URL) {
        self.nomeArquivo = nomeArquivo
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
    }
}

/// Os dois pesos do Papagaio. A avaliação atual usa Qwen3.5 9B Q4_K_M para
/// reduzir a memória do resumo sem criar uma segunda engine.
///
/// As URLs apontam para um commit do repositório, não para `main`: o SHA-256
/// é fixo, e um arquivo trocado no ramo faria toda instalação nova falhar no
/// checksum.
public enum Pesos {
    public static let whisperLargeV3 = PesoDeModelo(
        nomeArquivo: "ggml-large-v3.bin",
        bytes: 3_095_033_483,
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin")!
    )

    public static let qwen35_9B = PesoDeModelo(
        nomeArquivo: "Qwen_Qwen3.5-9B-Q4_K_M.gguf",
        bytes: 6_169_341_984,
        sha256: "d784ce9eda1a5a7b51e8f705a9e6310844bf4f173654d115823c775fdea56d43",
        url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/182be2fd6c7bc44887d88a91cb03ff009cc9f549/Qwen_Qwen3.5-9B-Q4_K_M.gguf")!
    )

    public static var todos: [PesoDeModelo] { [whisperLargeV3, qwen35_9B] }
}

/// Resultado do preflight de hardware, na ordem exata do Passo 3.
public enum ResultadoPreflight: Sendable, Equatable {
    /// Tudo pronto: hardware passa e os dois pesos estão íntegros.
    case pronto

    /// `bloqueia` — não existe caminho degradado.
    case ramInsuficiente(instalada: Int64, minima: Int64)
    case discoInsuficiente(livre: Int64, minimo: Int64)

    /// Hardware passa, mas falta baixar (ou rebaixar) peso.
    case pesosFaltando([PesoDeModelo])

    /// Passa, com ressalva: o usuário decide se adia.
    case termicoCritico

    public var bloqueia: Bool {
        switch self {
        case .ramInsuficiente, .discoInsuficiente: true
        case .pronto, .pesosFaltando, .termicoCritico: false
        }
    }

    public var mensagem: String {
        switch self {
        case .pronto:
            "Tudo pronto."
        case let .ramInsuficiente(instalada, minima):
            "O Ōmu precisa de \(Preflight.gb(minima)) de memória e este Mac tem "
                + "\(Preflight.gb(instalada)). Não há modo reduzido: a transcrição e o resumo "
                + "rodam inteiramente no seu Mac, e os modelos não cabem."
        case let .discoInsuficiente(livre, minimo):
            "São necessários \(Preflight.gb(minimo)) livres neste Mac, e há "
                + "\(Preflight.gb(livre)) disponíveis."
        case let .pesosFaltando(pesos):
            "Faltam baixar \(pesos.count) modelo(s): "
                + pesos.map(\.nomeArquivo).joined(separator: ", ")
        case .termicoCritico:
            "Seu Mac está muito quente. Transcrever agora vai ficar lento e esquentar mais. "
                + "Dá para adiar."
        }
    }
}

/// Preflight de hardware e de pesos.
///
/// A ordem é a do Passo 3 e importa: não faz sentido oferecer download de modelos
/// para um Mac que nunca vai conseguir carregar os modelos.
public struct Preflight: Sendable {
    /// Mantido conservadoramente durante a avaliação do Qwen3.5: só uma
    /// medição real pode autorizar reduzir o mínimo de hardware.
    public static let ramMinima: Int64 = 18 * 1_073_741_824
    /// Whisper ≈ 3 GB + Qwen ≈ 6,2 GB + folga. É o piso de uma instalação
    /// **sem nenhum peso**; com os pesos no disco só a folga é exigida.
    public static let discoMinimo: Int64 = 20 * 1_073_741_824
    /// Espaço para o trabalho em si (áudio decodificado, banco, temporários)
    /// e para o sistema não ficar no limite durante um download.
    public static let folgaDeDisco: Int64 = 2 * 1_073_741_824

    private let pastaDeModelos: URL
    /// Injetável nos testes; em produção é o disco de verdade.
    private let discoLivreInjetado: Int64?

    public init(pastaDeModelos: URL, discoLivre: Int64? = nil) {
        self.pastaDeModelos = pastaDeModelos
        self.discoLivreInjetado = discoLivre
    }

    /// Quanto precisa estar livre para baixar o que falta: os bytes dos pesos
    /// ausentes mais a folga. Com tudo instalado, só a folga.
    public static func discoNecessario(paraBaixar faltando: [PesoDeModelo]) -> Int64 {
        faltando.reduce(folgaDeDisco) { $0 + $1.bytes }
    }

    /// Roda os quatro portões na ordem, parando no primeiro que bloqueia.
    public func avaliar(
        pesos: [PesoDeModelo] = Pesos.todos,
        verificarChecksum: Bool = false
    ) -> ResultadoPreflight {
        // 1. RAM física — bloqueia.
        let ram = Self.ramInstalada
        guard ram >= Self.ramMinima else {
            return .ramInsuficiente(instalada: ram, minima: Self.ramMinima)
        }

        // 2. Pesos presentes e íntegros.
        let faltando = pesos.filter { !pesoValido($0, verificarChecksum: verificarChecksum) }

        // 3. Disco livre — bloqueia, mas só pelo que ainda falta baixar.
        //    O piso de 20 GB foi dimensionado para o download; exigi-lo de
        //    quem já tem os 9 GB de modelos no disco recusava toda
        //    transcrição e todo ditado num Mac com pouco espaço.
        let livre = discoLivre
        let necessario = Self.discoNecessario(paraBaixar: faltando)
        guard livre >= necessario else {
            return .discoInsuficiente(livre: livre, minimo: necessario)
        }

        // 4. Faltando peso — oferece download.
        guard faltando.isEmpty else { return .pesosFaltando(faltando) }

        // 5. Térmico — avisa.
        if ProcessInfo.processInfo.thermalState == .critical {
            return .termicoCritico
        }

        return .pronto
    }

    /// Um peso é válido se existe, tem o tamanho esperado e — quando pedido —
    /// bate o SHA-256. Checar os pesos em streaming não é de graça: só na instalação e
    /// quando o usuário pedir verificação, não a cada abertura.
    public func pesoValido(_ peso: PesoDeModelo, verificarChecksum: Bool) -> Bool {
        let caminho = pastaDeModelos.appendingPathComponent(peso.nomeArquivo)
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: caminho.path),
              let tamanho = atributos[.size] as? Int64,
              tamanho == peso.bytes
        else { return false }

        guard verificarChecksum, !peso.sha256.isEmpty else { return true }
        guard let hash = try? Self.sha256(de: caminho) else { return false }
        return hash == peso.sha256
    }

    // MARK: - Medições

    public static var ramInstalada: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    public var discoLivre: Int64 {
        if let discoLivreInjetado { return discoLivreInjetado }
        let valores = try? pastaDeModelos.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let importante = valores?.volumeAvailableCapacityForImportantUsage {
            return Int64(importante)
        }
        // Fallback: a pasta pode ainda não existir.
        let raiz = URL(fileURLWithPath: NSHomeDirectory())
        let deRaiz = try? raiz.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return Int64(deRaiz?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// SHA-256 em streaming: um `Data(contentsOf:)` de vários GB estoura a memória
    /// justamente na máquina que já está no limite.
    public static func sha256(de url: URL) throws -> String {
        let arquivo = try FileHandle(forReadingFrom: url)
        defer { try? arquivo.close() }

        var digestor = SHA256()
        while true {
            let bloco = try autoreleasepool {
                try arquivo.read(upToCount: 4 * 1_048_576)
            }
            guard let bloco, !bloco.isEmpty else { break }
            digestor.update(data: bloco)
        }
        return digestor.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }
}
