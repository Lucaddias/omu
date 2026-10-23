import Foundation

// MARK: - Erro comum

/// Lançado pelas implementações vazias do Passo 1. Cada uma some quando o passo
/// correspondente entrega a implementação real.
public struct NotImplemented: Error, CustomStringConvertible {
    public let quem: String
    public let passo: Int

    public init(_ quem: String, passo: Int) {
        self.quem = quem
        self.passo = passo
    }

    public var description: String {
        "\(quem) ainda não foi implementado — chega no Passo \(passo)."
    }
}

// MARK: - Transcrição

/// Contrato de transcrição. Uma engine só no projeto inteiro: Whisper large-v3
/// via `whisper.cpp` linkado (D-0.5/D-0.6). Ver skill `papagaio-asr`.
///
/// Sem parâmetro de `locale`: o peso do Whisper já traz o idioma e não há
/// gestão de asset de locale.
public protocol TranscriptionEngine: Sendable {
    var identifier: String { get }
    func transcribe(_ url: URL) async throws -> [Trecho]
}

// MARK: - Sumarização

/// Contrato de sumarização. Uma engine só: Qwen3.5-9B-Q4_K_M via
/// `llama.cpp` linkado (D-0.5/D-0.6). Ver skill `papagaio-summarization`.
public protocol SummarizationEngine: Sendable {
    var identifier: String { get }
    func summarize(_ trechos: [Trecho]) async throws -> Resumo
}

// MARK: - Diarização

/// Contrato de diarização acústica: quem falou quando, em segmentos.
///
/// Uma engine só: pyannote community-1 em CoreML via FluidAudio (ver
/// skill `papagaio-speaker-attribution`). O alinhamento palavra×segmento não
/// é responsabilidade da engine — é do `AlinhamentoDeFalantes`, puro e
/// testável.
public protocol DiarizationEngine: Sendable {
    var identifier: String { get }
    func diarizar(_ audio: URL) async throws -> [SegmentoDeFalante]
}

// MARK: - Persistência

/// Contrato de repositório da biblioteca local, implementado por
/// `SwiftDataRepository`.
///
/// A assinatura de `buscar` precisa sobreviver a uma eventual migração para
/// FTS5 sem mudar — ver Passo 9.
public protocol ArquivoRepository: Sendable {
    func salvar(_ a: Arquivo) async throws
    func buscar(termo: String, espaco: EspacoID) async throws -> [Arquivo]
    func listar(espaco: EspacoID) async throws -> [Arquivo]
    func apagar(_ id: ArquivoID) async throws

    /// Grava **só o que o processamento produz** — transcrição e/ou resumo —
    /// sobre o registro que já existe, sem tocar em título, data, duração,
    /// notas ou lixeira.
    ///
    /// O pipeline trabalha minutos sobre uma fotografia do `Arquivo`. Gravá-la
    /// inteira com `salvar` desfazia tudo o que a pessoa editou nesse
    /// intervalo (renomear, preencher a ficha, escrever notas).
    func salvarResultadoDoProcessamento(
        _ a: Arquivo,
        partes: PartesDoProcessamento
    ) async throws
}

/// O que um salvamento do pipeline tem permissão de escrever.
public struct PartesDoProcessamento: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Trechos (com palavras e falantes) e a engine de transcrição.
    public static let transcricao = PartesDoProcessamento(rawValue: 1 << 0)
    /// Resumo (ou a ausência dele) e a engine de resumo.
    public static let resumo = PartesDoProcessamento(rawValue: 1 << 1)
    public static let tudo: PartesDoProcessamento = [.transcricao, .resumo]
}

public extension ArquivoRepository {
    /// Repositórios simples (CLI, testes) não distinguem as partes: gravam o
    /// arquivo como veio.
    func salvarResultadoDoProcessamento(
        _ a: Arquivo,
        partes: PartesDoProcessamento
    ) async throws {
        try await salvar(a)
    }
}
