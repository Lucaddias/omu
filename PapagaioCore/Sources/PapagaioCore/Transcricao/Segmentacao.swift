import Foundation

/// Normaliza os segmentos nativos do Whisper em trechos navegáveis.
///
/// O Whisper já corta em fronteira de fala — o que falta é **tamanho**: os
/// segmentos nativos têm 2 a 10 s, curtos demais para ler e para servir de
/// unidade de navegação. Aqui eles são agrupados até a janela alvo.
///
/// Isto é normalização, não re-segmentação: **nenhum segmento do Whisper é
/// dividido**, porque cortar no meio de um significa cortar no meio de uma
/// frase. Ver skill `papagaio-segmentation`.
public enum Segmentacao {
    /// Janela alvo. O agrupamento fecha o trecho ao cruzar `alvo`, e nunca
    /// começa um segmento novo se isso for passar de `maxima`.
    public static let alvo: TimeInterval = 40
    public static let maxima: TimeInterval = 60

    /// Uma pausa longa é fronteira natural: fecha o trecho mesmo antes do alvo.
    public static let pausaQueSepara: TimeInterval = 2.0

    /// Agrupa segmentos de um único canal.
    ///
    /// - Precondition: `segmentos` vem ordenado por `start` — é o que o
    ///   `whisper_full` devolve.
    public static func agrupar(_ segmentos: [Trecho]) -> [Trecho] {
        guard !segmentos.isEmpty else { return [] }

        var trechos: [Trecho] = []
        var acumulados: [Trecho] = []

        func fechar() {
            guard let primeiro = acumulados.first, let ultimo = acumulados.last else { return }
            let palavras = acumulados.flatMap(\.palavras)
            let noSpeech: Float? = {
                let vals = acumulados.compactMap(\.noSpeechProb)
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Float(vals.count)
            }()
            // Sem confiança por palavra (transcrição legada), vale a média
            // dos segmentos ponderada pela duração de cada um.
            let confiancaDosSegmentos: Float? = {
                let pares = acumulados.compactMap { s in s.confianca.map { ($0, max(0, s.end - s.start)) } }
                guard !pares.isEmpty else { return nil }
                let total = pares.reduce(0) { $0 + $1.1 }
                guard total > 0 else { return pares.reduce(Float(0)) { $0 + $1.0 } / Float(pares.count) }
                return pares.reduce(Float(0)) { $0 + $1.0 * Float($1.1) } / Float(total)
            }()
            trechos.append(Trecho(
                id: primeiro.id,
                start: primeiro.start,
                end: ultimo.end,
                texto: acumulados.map(\.texto).joined(separator: " "),
                speaker: primeiro.speaker,
                // As palavras já vêm na linha do tempo do arquivo; concatena
                // na ordem dos segmentos, como o texto.
                palavras: palavras,
                confianca: Trecho.confiancaMedia(palavras) ?? confiancaDosSegmentos,
                noSpeechProb: noSpeech
            ))
            acumulados.removeAll()
        }

        for segmento in segmentos {
            guard let ultimo = acumulados.last else {
                acumulados.append(segmento)
                continue
            }

            let inicio = acumulados[0].start
            let duracaoSeIncluir = segmento.end - inicio
            let pausa = segmento.start - ultimo.end
            let trocouDeFalante = segmento.speaker != ultimo.speaker

            // Troca de falante fecha o trecho sempre: misturar as duas vozes
            // num trecho só destruiria a atribuição por canal.
            if trocouDeFalante || duracaoSeIncluir > maxima
                || (pausa >= pausaQueSepara && (ultimo.end - inicio) >= alvo / 2)
            {
                fechar()
            }
            acumulados.append(segmento)

            if let comeco = acumulados.first, segmento.end - comeco.start >= alvo {
                fechar()
            }
        }
        fechar()
        return trechos
    }

    /// Abaixo disto o trecho do microfone é candidato a ruído residual do
    /// alto-falante — mas só com as outras duas evidências (ver `mesclarCanais`).
    static let duracaoDeRespostaCurta: TimeInterval = 0.5
    static let noSpeechDeRuidoCurto: Float = 0.3

    /// Mescla os dois canais numa linha do tempo única e agrupa.
    ///
    /// O falante vem do **canal de origem** — microfone é `"eu"`, tap do
    /// sistema é `"interlocutor"` — e não de um modelo de diarização. Ver skill
    /// `papagaio-speaker-attribution`.
    public static func mesclarCanais(
        microfone: [Trecho],
        sistema: [Trecho]
    ) -> [Trecho] {
        // Remove trechos do microfone que são provavelmente silêncio/ruído
        // (Whisper alucina texto em áudio limpo pós-AEC).
        let microfoneLimpo = microfone.filter { trecho in
            // Se o Whisper indica alta probabilidade de "sem fala", descarta.
            if let p = trecho.noSpeechProb, p > 0.6 { return false }
            // Um trecho muito curto só é ruído residual quando o sistema
            // está tocando ao mesmo tempo **e** o próprio Whisper desconfia
            // dele. Cortar todo trecho curto apagava "Sim.", "Não." e "Ok."
            // da conversa — e do resumo.
            if trecho.end - trecho.start < duracaoDeRespostaCurta,
               let p = trecho.noSpeechProb, p > noSpeechDeRuidoCurto,
               sistema.contains(where: { sobrepoe(trecho, $0) }) {
                return false
            }
            return true
        }

        let microfoneMarcado = microfoneLimpo.map { marcar($0, como: Speaker.eu) }
        let sistemaMarcado = sistema.map { marcar($0, como: Speaker.interlocutor) }

        // Eco: texto igual e simultâneo nos dois canais. A versão anterior
        // tokenizava cada texto de novo a cada par (N×M tokenizações);
        // aqui os tokens são pré-computados uma vez por trecho e o Jaccard
        // só roda em pares que se sobrepõem no tempo.
        let sistemaComTokens = sistemaMarcado.map { trecho in
            (trecho: trecho, tokens: tokensDe(trecho.texto))
        }
        let microfoneSemEco = microfoneMarcado.filter { trechoDoMicrofone in
            let tokensDoMicrofone = tokensDe(trechoDoMicrofone.texto)
            return !sistemaComTokens.contains { item in
                sobrepoe(trechoDoMicrofone, item.trecho)
                    && jaccard(tokensDoMicrofone, item.tokens) >= 0.75
            }
        }
        let comFalante = microfoneSemEco + sistemaMarcado
        let ordenados = comFalante.sorted { $0.start < $1.start }
        return agrupar(ordenados)
    }

    private static func marcar(_ trecho: Trecho, como speaker: String) -> Trecho {
        Trecho(
            id: trecho.id,
            start: trecho.start,
            end: trecho.end,
            texto: trecho.texto,
            speaker: speaker,
            palavras: trecho.palavras,
            confianca: trecho.confianca,
            noSpeechProb: trecho.noSpeechProb
        )
    }

    private static func sobrepoe(_ lhs: Trecho, _ rhs: Trecho) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    private static func tokensDe(_ texto: String) -> Set<Substring> {
        Set(texto.lowercased().split { !$0.isLetter && !$0.isNumber })
    }

    private static func jaccard(_ lhs: Set<Substring>, _ rhs: Set<Substring>) -> Double {
        let uniao = lhs.union(rhs)
        guard !uniao.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(uniao.count)
    }
}
