import Foundation
import NaturalLanguage

/// Idiomas de saída que o produto oferece para transcrições e resumos locais.
///
/// O Whisper continua multilíngue; este tipo limita somente a preferência de
/// exibição que o Ōmu consegue garantir hoje (português e inglês).
public enum IdiomaDeProcessamento: String, Sendable, Codable, CaseIterable, Equatable {
    case portugues
    case ingles

    /// Código que o Whisper/BCP-47 entende para a língua, sem variante regional.
    public var codigoISO639_1: String {
        switch self {
        case .portugues: "pt"
        case .ingles: "en"
        }
    }

    /// Nome explícito para prompts do modelo local. Não usar o locale atual:
    /// um prompt precisa ser estável e reproduzível na fila em segundo plano.
    var nomeParaPrompt: String {
        switch self {
        case .portugues: "Brazilian Portuguese"
        case .ingles: "English"
        }
    }

    /// Converte o idioma preferido do sistema para um dos idiomas suportados.
    /// Em qualquer sistema diferente de PT/EN, mantemos português como fallback
    /// explícito em vez de passar um código que a interface não oferece.
    public init(locale: Locale) {
        switch locale.language.languageCode?.identifier.lowercased() {
        case "en": self = .ingles
        default: self = .portugues
        }
    }
}

/// Preferência persistida pela camada de app e consumida pelo pipeline.
///
/// Desligada, a transcrição é mantida no idioma que o Whisper detectou e o
/// resumo é pedido no mesmo idioma. Ligada, um texto cujo idioma detectado
/// diverge da preferência recebe tradução local antes do resumo.
public struct ConfiguracaoDeTraducaoAutomatica: Sendable, Equatable {
    public var habilitada: Bool
    public var idiomaPadrao: IdiomaDeProcessamento

    public init(habilitada: Bool, idiomaPadrao: IdiomaDeProcessamento) {
        self.habilitada = habilitada
        self.idiomaPadrao = idiomaPadrao
    }
}

/// Detecção local pós-ASR e decisão pura de tradução.
///
/// `NLLanguageRecognizer` é uma API de sistema local; não baixa modelo nem
/// envia texto à rede. A decisão recebe o resultado como String para que os
/// testes não dependam do classificador do sistema.
public enum DetectorDeIdiomaDaTranscricao {
    public static func detectar(em trechos: [Trecho]) -> String? {
        let texto = trechos.map(\.texto).joined(separator: " ")
        return detectar(em: texto)
    }

    public static func detectar(em texto: String) -> String? {
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reconhecedor = NLLanguageRecognizer()
        reconhecedor.processString(texto)
        return reconhecedor.dominantLanguage?.rawValue.lowercased()
    }

    public static func deveTraduzir(
        idiomaDetectado: String?,
        configuracao: ConfiguracaoDeTraducaoAutomatica
    ) -> Bool {
        guard configuracao.habilitada,
              let idiomaDetectado,
              let idiomaBase = idiomaDetectado
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased(),
              !idiomaBase.isEmpty
        else { return false }

        return idiomaBase != configuracao.idiomaPadrao.codigoISO639_1
    }

    public static func correspondeAoIdiomaPadrao(
        idiomaDetectado: String?,
        configuracao: ConfiguracaoDeTraducaoAutomatica
    ) -> Bool {
        guard let idiomaDetectado,
              let idiomaBase = idiomaDetectado
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased()
        else { return false }
        return idiomaBase == configuracao.idiomaPadrao.codigoISO639_1
    }
}
