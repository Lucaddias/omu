import Foundation

/// Mede se o resumo preservou os fatos que importam numa reunião: decisões,
/// responsáveis, prazos e números.
///
/// É uma checagem por termos, e não um segundo modelo julgando o primeiro: o
/// resultado é reproduzível byte a byte e qualquer pessoa confere à mão por
/// que um fato passou ou não. O preço é ser conservadora — uma paráfrase boa
/// que troca "sexta-feira" por "fim da semana" conta como fato perdido.
public enum CoberturaDeFatos {
    public struct Fato: Sendable, Codable, Equatable {
        public let descricao: String
        /// Todos os grupos precisam aparecer; dentro de um grupo, basta uma
        /// das alternativas. `[["ana"], ["sexta", "sexta-feira"]]` pede "ana"
        /// **e** alguma forma de "sexta".
        public let termos: [[String]]

        public init(descricao: String, termos: [[String]]) {
            self.descricao = descricao
            self.termos = termos
        }
    }

    public static func cobre(_ fato: Fato, texto: String) -> Bool {
        let alvo = " " + comparavel(texto) + " "
        return fato.termos.allSatisfy { alternativas in
            alternativas.contains { alvo.contains(" " + comparavel($0) + " ") }
        }
    }

    /// Ignora acento além da normalização do WER: aqui interessa se o fato
    /// está lá, não a grafia — o Qwen às vezes escreve "Joao".
    static func comparavel(_ texto: String) -> String {
        NormalizacaoDeTexto.normalizar(texto)
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
    }
}
