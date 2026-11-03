import Foundation

/// Forma canônica de texto para medir WER e CER.
///
/// Segue a ideia do `BasicTextNormalizer` que o Whisper usa nos idiomas que não
/// são inglês: caixa baixa, sem pontuação nem símbolos, espaços colapsados. O
/// acento **fica**: "e" e "é" são palavras diferentes em português, e tirar o
/// acento esconderia erros reais do modelo.
///
/// O que está entre colchetes ou parênteses sai antes: é onde o Whisper põe
/// marcações como "[Música]", que não são fala.
public enum NormalizacaoDeTexto {
    public static func normalizar(_ texto: String) -> String {
        let semMarcacoes = texto
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        let composto = semMarcacoes.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "pt_BR"))
        let escalares = composto.unicodeScalars.map { escalar -> Character in
            CharacterSet.alphanumerics.contains(escalar) ? Character(escalar) : " "
        }
        return String(escalares)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func palavras(_ texto: String) -> [String] {
        normalizar(texto).split(separator: " ").map(String.init)
    }

    /// Caracteres para o CER: a forma normalizada, sem os espaços — eles já
    /// são contados pelo WER.
    public static func caracteres(_ texto: String) -> [Character] {
        Array(normalizar(texto).filter { $0 != " " })
    }
}

/// Substituições, deleções e inserções de um alinhamento de Levenshtein.
///
/// Guarda as três parcelas, e não só o total, porque elas contam histórias
/// diferentes: deleção alta é fala perdida (VAD cortando, janela engolida),
/// inserção alta é alucinação.
public struct ContagemDeErros: Sendable, Codable, Equatable {
    public var substituicoes: Int
    public var delecoes: Int
    public var insercoes: Int
    /// Tamanho da referência — o denominador da taxa.
    public var referencia: Int

    public init(substituicoes: Int = 0, delecoes: Int = 0, insercoes: Int = 0, referencia: Int = 0) {
        self.substituicoes = substituicoes
        self.delecoes = delecoes
        self.insercoes = insercoes
        self.referencia = referencia
    }

    public var erros: Int { substituicoes + delecoes + insercoes }

    /// Pode passar de 1: inserções não têm teto.
    public var taxa: Double { referencia > 0 ? Double(erros) / Double(referencia) : 0 }

    /// Soma para a taxa do corpus inteiro: erros totais sobre referência total,
    /// e não a média das taxas — uma frase de três palavras não pode pesar
    /// tanto quanto uma de trinta.
    public static func + (a: ContagemDeErros, b: ContagemDeErros) -> ContagemDeErros {
        ContagemDeErros(
            substituicoes: a.substituicoes + b.substituicoes,
            delecoes: a.delecoes + b.delecoes,
            insercoes: a.insercoes + b.insercoes,
            referencia: a.referencia + b.referencia
        )
    }
}

public enum DistanciaDeEdicao {
    /// Alinhamento de custo mínimo, com custo 1 para cada operação.
    ///
    /// Programação dinâmica com duas linhas: cada célula carrega as três
    /// parcelas do melhor caminho até ali, então não é preciso guardar a
    /// matriz inteira para reconstruir a contagem.
    public static func contar<T: Equatable>(referencia: [T], hipotese: [T]) -> ContagemDeErros {
        typealias Celula = (custo: Int, s: Int, d: Int, i: Int)

        var anterior: [Celula] = (0...hipotese.count).map { (custo: $0, s: 0, d: 0, i: $0) }
        var atual = anterior

        for (r, itemDaReferencia) in referencia.enumerated() {
            atual[0] = (custo: r + 1, s: 0, d: r + 1, i: 0)
            for h in stride(from: 1, through: hipotese.count, by: 1) {
                let diagonal = anterior[h - 1]
                let iguais = itemDaReferencia == hipotese[h - 1]
                let viaDiagonal: Celula = iguais
                    ? diagonal
                    : (diagonal.custo + 1, diagonal.s + 1, diagonal.d, diagonal.i)
                let cima = anterior[h]
                let viaDelecao: Celula = (cima.custo + 1, cima.s, cima.d + 1, cima.i)
                let esquerda = atual[h - 1]
                let viaInsercao: Celula = (esquerda.custo + 1, esquerda.s, esquerda.d, esquerda.i + 1)

                // Empate prefere a diagonal: é o alinhamento que um leitor faria.
                var melhor = viaDiagonal
                if viaDelecao.custo < melhor.custo { melhor = viaDelecao }
                if viaInsercao.custo < melhor.custo { melhor = viaInsercao }
                atual[h] = melhor
            }
            swap(&anterior, &atual)
        }

        let final = anterior[hipotese.count]
        return ContagemDeErros(
            substituicoes: final.s,
            delecoes: final.d,
            insercoes: final.i,
            referencia: referencia.count
        )
    }

    public static func wer(referencia: String, hipotese: String) -> ContagemDeErros {
        contar(
            referencia: NormalizacaoDeTexto.palavras(referencia),
            hipotese: NormalizacaoDeTexto.palavras(hipotese)
        )
    }

    public static func cer(referencia: String, hipotese: String) -> ContagemDeErros {
        contar(
            referencia: NormalizacaoDeTexto.caracteres(referencia),
            hipotese: NormalizacaoDeTexto.caracteres(hipotese)
        )
    }
}
