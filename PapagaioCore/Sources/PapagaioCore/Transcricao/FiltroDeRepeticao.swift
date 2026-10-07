import Foundation

/// Remove repetições consecutivas que são um artefato conhecido do Whisper em
/// silêncio, ruído constante ou trechos muito longos. É deliberadamente
/// conservador: não tenta reescrever texto, apenas remove cópias equivalentes
/// que se repetem sem fala diferente entre elas.
public enum FiltroDeRepeticao {
    /// Limpa primeiro uma frase repetida dentro do mesmo segmento e, depois,
    /// colapsa uma sequência de três ou mais segmentos iguais do mesmo falante.
    /// Duas frases iguais são preservadas porque podem ser uma repetição real da
    /// conversa (por exemplo, confirmação ou pedido de esclarecimento).
    public static func remover(_ trechos: [Trecho]) -> [Trecho] {
        let limpos = trechos.compactMap(limpar)
        guard !limpos.isEmpty else { return [] }

        var resultado: [Trecho] = []
        var inicioDaSequencia = 0
        while inicioDaSequencia < limpos.count {
            let primeiro = limpos[inicioDaSequencia]
            let referencia = normalizar(primeiro.texto)
            var fimDaSequencia = inicioDaSequencia + 1

            while fimDaSequencia < limpos.count,
                  limpos[fimDaSequencia].speaker == primeiro.speaker,
                  normalizar(limpos[fimDaSequencia].texto) == referencia,
                  limpos[fimDaSequencia].start - limpos[fimDaSequencia - 1].end <= 5
            {
                fimDaSequencia += 1
            }

            let quantidade = fimDaSequencia - inicioDaSequencia
            if quantidade >= 3 {
                resultado.append(primeiro)
            } else {
                resultado.append(contentsOf: limpos[inicioDaSequencia..<fimDaSequencia])
            }
            inicioDaSequencia = fimDaSequencia
        }
        return resultado
    }

    private static func limpar(_ trecho: Trecho) -> Trecho? {
        let frases = frasesEm(trecho.texto)
        guard !frases.isEmpty else {
            let texto = trecho.texto.removendoEmojis()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !texto.isEmpty else { return nil }
            let palavrasLimpa = trecho.palavras.filter { !$0.texto.ehSomenteEmoji }
            return trecho.com(texto: texto, palavras: palavrasLimpa)
        }

        var anterior: String?
        var mantidas: [String] = []
        var removeuAlguma = false
        for frase in frases {
            let chave = normalizar(frase)
            if chave == anterior {
                removeuAlguma = true
                continue
            }
            mantidas.append(frase)
            anterior = chave
        }

        // Nada saiu: o trecho volta exatamente como veio — inclusive as
        // palavras com timestamp. Antes o `Trecho` era reconstruído sem elas
        // em todo caso, e qualquer uso do filtro no pipeline matava a
        // navegação palavra a palavra de graça.
        if !removeuAlguma {
            return trecho
        }

        let texto = mantidas.joined(separator: " ").removendoEmojis()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return nil }
        return trecho.com(texto: texto, palavras: palavrasSobreviventes(de: trecho))
    }

    /// As palavras das frases que ficaram. A decisão de manter/sair é
    /// **repetida por posição** (a mesma regra do `limpar`: frase igual à
    /// anterior sai) — casar por texto não serve, porque a cópia repetida é
    /// idêntica à original. Depois as palavras são despachadas para as frases
    /// na ordem cronológica, consumindo os tokens de cada uma: nenhuma âncora
    /// de tempo aponta para fala removida.
    ///
    /// Quando o casamento não fecha (palavras divergem do texto), devolve
    /// vazio: melhor sem timestamps do que timestamps mentirosos.
    private static func palavrasSobreviventes(de trecho: Trecho) -> [Palavra] {
        guard !trecho.palavras.isEmpty else { return [] }

        // Frases com a decisão e os tokens, na ordem do texto.
        var decisoes: [(mantida: Bool, tokens: [String])] = []
        var anterior: String?
        let intervalo = trecho.texto.startIndex..<trecho.texto.endIndex
        trecho.texto.enumerateSubstrings(in: intervalo, options: .bySentences) { frase, _, _, _ in
            guard let frase else { return }
            let limpa = frase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpa.isEmpty else { return }
            let chave = normalizar(limpa)
            defer { anterior = chave }
            let tokens = limpa.split(whereSeparator: \.isWhitespace).map(tokenComparavel)
            decisoes.append((mantida: chave != anterior, tokens: tokens))
        }
        guard !decisoes.isEmpty else { return [] }

        var resultado: [Palavra] = []
        var sentenca = 0
        var indiceToken = 0
        for palavra in trecho.palavras {
            let tokensDaPalavra = palavra.texto
                .split(whereSeparator: \.isWhitespace)
                .map(tokenComparavel)
            guard !tokensDaPalavra.isEmpty else { continue }

            // Procura a frase que encaixa a palavra, avançando as que já
            // fecharam (as palavras chegam cronológicas, como as frases).
            while sentenca < decisoes.count {
                let tokens = decisoes[sentenca].tokens
                if indiceToken + tokensDaPalavra.count <= tokens.count,
                   Array(tokens[indiceToken..<(indiceToken + tokensDaPalavra.count)]) == tokensDaPalavra {
                    break
                }
                sentenca += 1
                indiceToken = 0
            }
            // Não fechou com frase nenhuma: o mapeamento inteiro cai.
            guard sentenca < decisoes.count else { return [] }

            if decisoes[sentenca].mantida {
                resultado.append(palavra)
            }
            indiceToken += tokensDaPalavra.count
        }
        return resultado
    }

    /// Forma de comparação de token: minúscula e sem acento — o Whisper às
    /// vezes diverge só nisso entre a palavra e o texto do trecho.
    private static func tokenComparavel(_ token: Substring) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func frasesEm(_ texto: String) -> [String] {
        let intervalo = texto.startIndex..<texto.endIndex
        guard !intervalo.isEmpty else { return [] }

        var frases: [String] = []
        texto.enumerateSubstrings(in: intervalo, options: .bySentences) { frase, _, _, _ in
            guard let frase else { return }
            let limpa = frase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !limpa.isEmpty { frases.append(limpa) }
        }
        return frases
    }

    static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
