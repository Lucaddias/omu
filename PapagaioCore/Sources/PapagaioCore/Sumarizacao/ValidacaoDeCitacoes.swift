import Foundation

/// Filtra as citações sugeridas pelo modelo contra a transcrição real.
///
/// O modelo **sugere**; esta camada decide. A transcrição é a fonte de
/// verdade, e nada chega à tela sem ter sido encontrado literalmente nela.
///
/// A razão é prática, não teórica: um modelo de linguagem parafraseia com
/// naturalidade — troca uma palavra, junta duas frases, "melhora" a fala — e o
/// `start` que ele devolve costuma ser um chute plausível. O resultado é uma
/// citação que soa bem e não existe, com um carimbo de tempo que leva o
/// usuário para o lugar errado do áudio. Validar contra os trechos elimina os
/// dois problemas de uma vez: o texto passa a ser sempre real, e o tempo vem
/// do trecho onde ele foi de fato encontrado.
public enum ValidacaoDeCitacoes {
    /// Teto de citações por conversa.
    ///
    /// Três é o que cabe numa leitura rápida do resumo. Acima disso a seção
    /// vira uma segunda transcrição, e o leitor deixa de distinguir o que era
    /// marcante do que era só falado.
    public static let maximo = 3

    /// Faixa de tamanho, em palavras.
    ///
    /// Abaixo de 8 a frase quase nunca se sustenta fora do contexto ("acho que
    /// sim", "isso mesmo"). Acima de 32 deixa de ser citação e vira parágrafo:
    /// o olho pula, e o valor de "frase marcante" se perde.
    public static let minimoDePalavras = 8
    public static let maximoDePalavras = 32

    /// Vícios de fala e interjeições removidos antes de exibir.
    ///
    /// Só o que é ruído puro de oralidade. Nada que carregue sentido — "tipo"
    /// entra na lista porque na fala espontânea brasileira ele é muleta, mas
    /// palavras como "olha" ou "veja" ficam, porque marcam o tom de quem fala.
    /// Atenção: "é" solto NÃO entra aqui. É o verbo ser na terceira pessoa
    /// ("...é jogar dinheiro fora"), e como a remoção é por token inteiro,
    /// listá-lo apagava uma palavra real da fala — o texto limpo deixava de
    /// existir literalmente na transcrição e a citação verdadeira era
    /// descartada. A hesitação alongada continua coberta por "éé"/"ééé"/"eh".
    static let viciosDeFala: Set<String> = [
        "éé", "ééé", "eh", "ehh", "ahn", "ahm", "ah", "hum", "hmm", "hm",
        "putz", "tipo", "né", "ne", "tá", "ta", "então assim", "assim ó",
        "sabe", "entende", "entendeu", "cara", "pô", "po", "uhum", "aham",
    ]

    /// Aplica todas as regras e devolve o que sobreviveu, em ordem de tempo.
    ///
    /// - Parameters:
    ///   - sugeridas: o que o modelo propôs.
    ///   - trechos: a transcrição, fonte de verdade do texto e do tempo.
    public static func validar(_ sugeridas: [Citacao], contra trechos: [Trecho]) -> [Citacao] {
        guard !trechos.isEmpty else { return [] }

        let indice = trechos.map { (trecho: $0, normalizado: normalizar($0.texto)) }
        var aprovadas: [Citacao] = []
        var trechosUsados: Set<UUID> = []

        for sugerida in sugeridas {
            let limpo = removerVicios(de: sugerida.texto)
            guard estaNaFaixaDeTamanho(limpo) else { continue }
            guard let origem = localizar(limpo, em: indice) else { continue }

            // Uma citação por trecho: duas frases do mesmo parágrafo levariam
            // ao mesmo ponto do áudio e diriam quase a mesma coisa.
            guard !trechosUsados.contains(origem.id) else { continue }
            trechosUsados.insert(origem.id)

            aprovadas.append(
                Citacao(
                    texto: apresentar(limpo),
                    // O falante vem do trecho, não do palpite do modelo.
                    speaker: origem.speaker,
                    // E o tempo é o início real do trecho onde a fala está.
                    start: origem.start
                )
            )

            if aprovadas.count == maximo { break }
        }

        return aprovadas.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    // MARK: - Localização

    /// Acha o trecho que contém a fala, comparando as duas pontas normalizadas.
    ///
    /// A comparação ignora acento, pontuação, caixa e espaços repetidos: são
    /// diferenças que o modelo introduz sem alterar o que foi dito. Qualquer
    /// coisa além disso — palavra trocada, ordem invertida, frase juntada — é
    /// paráfrase, e paráfrase é descartada.
    private static func localizar(
        _ texto: String,
        em indice: [(trecho: Trecho, normalizado: String)]
    ) -> Trecho? {
        let alvo = normalizar(texto)
        guard !alvo.isEmpty else { return nil }
        return indice.first { $0.normalizado.contains(alvo) }?.trecho
    }

    /// Forma canônica para comparar: sem acento, sem pontuação, minúscula e
    /// com espaços colapsados.
    static func normalizar(_ texto: String) -> String {
        let semAcento = texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let semPontuacao = semAcento.unicodeScalars.map { escalar -> Character in
            CharacterSet.alphanumerics.contains(escalar) ? Character(escalar) : " "
        }
        return String(semPontuacao)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Limpeza

    /// Remove vícios de fala isolados, preservando o resto palavra por palavra.
    ///
    /// A remoção é por token inteiro, e não por busca de substring: apagar "né"
    /// como texto solto mutilaria "nenhum", e apagar "ta" quebraria "tarde".
    static func removerVicios(de texto: String) -> String {
        let palavras = texto.split(whereSeparator: \.isWhitespace)
        let mantidas = palavras.filter { palavra in
            let nua = palavra
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            return !viciosDeFala.contains(nua)
        }
        return mantidas.joined(separator: " ")
    }

    private static func estaNaFaixaDeTamanho(_ texto: String) -> Bool {
        let palavras = texto.split(whereSeparator: \.isWhitespace).count
        return palavras >= minimoDePalavras && palavras <= maximoDePalavras
    }

    /// Ajustes finais de apresentação: espaços colapsados, primeira letra
    /// maiúscula e um ponto final quando a frase termina sem pontuação.
    ///
    /// Isto é formatação, não reescrita — nenhuma palavra muda.
    private static func apresentar(_ texto: String) -> String {
        var limpo = texto
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Vírgula ou conectivo no começo é resto de uma frase cortada ao meio.
        while let primeiro = limpo.first, ",;:-–—".contains(primeiro) {
            limpo.removeFirst()
            limpo = limpo.trimmingCharacters(in: .whitespaces)
        }

        guard let inicial = limpo.first else { return limpo }
        limpo.replaceSubrange(limpo.startIndex...limpo.startIndex, with: inicial.uppercased())

        if let ultimo = limpo.last, !".!?…".contains(ultimo) {
            limpo.append(".")
        }
        return limpo
    }
}
