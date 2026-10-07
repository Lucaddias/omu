import Foundation
import Testing
@testable import PapagaioCore

/// Constrói segmentos como o Whisper devolve: curtos, encadeados, com uma
/// pequena pausa entre eles.
private func segmentos(
    quantidade: Int,
    duracao: TimeInterval = 6,
    pausa: TimeInterval = 0.5,
    inicio: TimeInterval = 0,
    speaker: String? = nil
) -> [Trecho] {
    var trechos: [Trecho] = []
    var t = inicio
    for i in 0..<quantidade {
        trechos.append(Trecho(start: t, end: t + duracao, texto: "frase \(i)", speaker: speaker))
        t += duracao + pausa
    }
    return trechos
}

@Test("Agrupamento junta segmentos curtos até a janela alvo")
func agrupamentoJunta() {
    // 20 segmentos de 6 s ≈ 130 s → deve dar ~3-4 trechos de ~40 s.
    let agrupados = Segmentacao.agrupar(segmentos(quantidade: 20))

    #expect(agrupados.count >= 3)
    #expect(agrupados.count <= 5)

    // Nenhum trecho, exceto possivelmente o último, foge de 20–60 s.
    for trecho in agrupados.dropLast() {
        let duracao = trecho.end - trecho.start
        #expect(duracao >= 20, "trecho de \(duracao) s é curto demais")
        #expect(duracao <= Segmentacao.maxima, "trecho de \(duracao) s passou do teto")
    }
}

@Test("Nenhum segmento do Whisper é dividido")
func agrupamentoNaoDivide() {
    let originais = segmentos(quantidade: 20)
    let agrupados = Segmentacao.agrupar(originais)

    // Toda fronteira de trecho tem que coincidir com uma fronteira de segmento.
    let inicios = Set(originais.map(\.start))
    let fins = Set(originais.map(\.end))
    for trecho in agrupados {
        #expect(inicios.contains(trecho.start))
        #expect(fins.contains(trecho.end))
    }

    // E o texto todo sobrevive, na ordem.
    let textoOriginal = originais.map(\.texto).joined(separator: " ")
    let textoAgrupado = agrupados.map(\.texto).joined(separator: " ")
    #expect(textoOriginal == textoAgrupado)
}

@Test("Silêncio inicial preserva o start do primeiro trecho")
func agrupamentoPreservaInicio() {
    // A fala só começa aos 12,5 s.
    let agrupados = Segmentacao.agrupar(segmentos(quantidade: 10, inicio: 12.5))
    #expect(agrupados.first?.start == 12.5)
}

@Test("Troca de falante fecha o trecho, sem misturar as vozes")
func agrupamentoRespeitaFalante() {
    var entrada = segmentos(quantidade: 3, inicio: 0, speaker: Speaker.eu)
    entrada += segmentos(quantidade: 3, inicio: 20, speaker: Speaker.interlocutor)
    entrada += segmentos(quantidade: 3, inicio: 40, speaker: Speaker.eu)

    let agrupados = Segmentacao.agrupar(entrada)

    #expect(agrupados.count >= 3)
    // Cada trecho tem um falante só.
    for trecho in agrupados {
        #expect(trecho.speaker != nil)
    }
    let falantes = agrupados.map(\.speaker)
    #expect(falantes.first == Speaker.eu)
    #expect(falantes.contains(Speaker.interlocutor))
}

@Test("Segmento maior que o teto vira trecho próprio, sem ser cortado")
func agrupamentoSegmentoGigante() {
    let gigante = Trecho(start: 0, end: 75, texto: "monólogo longo", speaker: nil)
    let agrupados = Segmentacao.agrupar([gigante] + segmentos(quantidade: 3, inicio: 76))

    #expect(agrupados.first?.end == 75)
    #expect(agrupados.first?.texto == "monólogo longo")
}

@Test("Pausa longa fecha o trecho antes do alvo")
func agrupamentoPausaLonga() {
    // 4 segmentos de 6 s, depois 5 s de silêncio, depois mais 4.
    var entrada = segmentos(quantidade: 4, inicio: 0)
    entrada += segmentos(quantidade: 4, inicio: 45)

    let agrupados = Segmentacao.agrupar(entrada)
    #expect(agrupados.count >= 2)
    // O primeiro trecho não atravessa o silêncio.
    #expect((agrupados.first?.end ?? 999) < 45)
}

@Test("Agrupamento concatena as palavras na ordem dos segmentos")
func agrupamentoConcatenaPalavras() {
    let a = Trecho(start: 0, end: 6, texto: "oi mundo", palavras: [
        Palavra(start: 0, end: 1, texto: "oi"),
        Palavra(start: 1, end: 2, texto: "mundo"),
    ])
    let b = Trecho(start: 6, end: 9, texto: "tudobem", palavras: [
        Palavra(start: 6, end: 7, texto: "tudo"),
        Palavra(start: 7, end: 9, texto: "bem"),
    ])

    let agrupados = Segmentacao.agrupar([a, b])
    #expect(agrupados.count == 1)
    #expect(agrupados.first?.palavras.map(\.texto) == ["oi", "mundo", "tudo", "bem"])
    // A linha do tempo das palavras segue a do trecho combinado.
    #expect(agrupados.first?.palavras.last?.end ?? 0 <= agrupados.first?.end ?? -1)
}

@Test("Mesclagem de canais ordena por tempo e atribui falante pela origem")
func mesclagemDeCanais() {
    let microfone = segmentos(quantidade: 2, inicio: 0).map {
        Trecho(start: $0.start, end: $0.end, texto: "minha fala \($0.start)", speaker: nil)
    }
    let sistema = segmentos(quantidade: 2, inicio: 3).map {
        Trecho(start: $0.start, end: $0.end, texto: "fala remota \($0.start)", speaker: nil)
    }

    let mesclados = Segmentacao.mesclarCanais(microfone: microfone, sistema: sistema)

    #expect(!mesclados.isEmpty)
    // A linha do tempo é crescente.
    var anterior: TimeInterval = -1
    for trecho in mesclados {
        #expect(trecho.start >= anterior)
        anterior = trecho.start
    }
    // Os dois falantes aparecem, e nenhum trecho fica sem atribuição.
    let falantes = Set(mesclados.compactMap(\.speaker))
    #expect(falantes == [Speaker.eu, Speaker.interlocutor])
}

@Test("Mesclagem remove eco igual e simultâneo do microfone")
func mesclagemRemoveEco() {
    let microfone = [Trecho(start: 10, end: 14, texto: "vamos aprovar o orçamento", speaker: nil)]
    let sistema = [Trecho(start: 10.2, end: 14.1, texto: "vamos aprovar o orçamento", speaker: nil)]

    let mesclados = Segmentacao.mesclarCanais(microfone: microfone, sistema: sistema)

    #expect(mesclados.count == 1)
    #expect(mesclados.first?.speaker == Speaker.interlocutor)
}

@Test("Texto igual fora de sobreposição de tempo não é eco — fica nos dois canais")
func textoIgualSemSobreposicaoNaoEhEco() {
    // Repetição real da conversa (frase dita de novo minutos depois) não pode
    // ser confundida com eco: o filtro só olha pares que se sobrepõem no tempo.
    let microfone = [Trecho(start: 60, end: 64, texto: "vamos aprovar o orçamento", speaker: nil)]
    let sistema = [Trecho(start: 10, end: 14, texto: "vamos aprovar o orçamento", speaker: nil)]

    let mesclados = Segmentacao.mesclarCanais(microfone: microfone, sistema: sistema)

    #expect(mesclados.count == 2)
    #expect(Set(mesclados.compactMap(\.speaker)) == [Speaker.eu, Speaker.interlocutor])
}

@Test("Entrada vazia devolve vazio, sem crashar")
func agrupamentoVazio() {
    #expect(Segmentacao.agrupar([]).isEmpty)
    #expect(Segmentacao.mesclarCanais(microfone: [], sistema: []).isEmpty)
}

@Test("Resposta curta do microfone fica na conversa (T-04)")
func respostaCurtaDoMicrofoneNaoSome() {
    let sistema = [Trecho(start: 0, end: 4, texto: "Você consegue entregar na sexta?")]

    // "Sim." depois da pergunta, sem sobreposição: é fala, não ruído.
    let depois = Segmentacao.mesclarCanais(
        microfone: [Trecho(start: 4.2, end: 4.5, texto: "Sim.", noSpeechProb: 0.4)],
        sistema: sistema
    )
    #expect(depois.contains { $0.speaker == Speaker.eu && $0.texto == "Sim." })

    // Sobreposto ao sistema, mas o Whisper não desconfia dele: fica.
    let confiante = Segmentacao.mesclarCanais(
        microfone: [Trecho(start: 3.6, end: 3.9, texto: "Ok.", noSpeechProb: 0.05)],
        sistema: sistema
    )
    #expect(confiante.contains { $0.speaker == Speaker.eu && $0.texto == "Ok." })

    // Sem a probabilidade (motor antigo), não há evidência para cortar.
    let semEvidencia = Segmentacao.mesclarCanais(
        microfone: [Trecho(start: 3.6, end: 3.9, texto: "Não.")],
        sistema: sistema
    )
    #expect(semEvidencia.contains { $0.speaker == Speaker.eu && $0.texto == "Não." })

    // As três evidências juntas — curto, sobreposto e suspeito — ainda cortam
    // o ruído residual do alto-falante.
    let ruido = Segmentacao.mesclarCanais(
        microfone: [Trecho(start: 3.6, end: 3.9, texto: "hm", noSpeechProb: 0.45)],
        sistema: sistema
    )
    #expect(!ruido.contains { $0.speaker == Speaker.eu })
}

@Test("Agrupar preserva a confiança do trecho (T-05)")
func agruparPreservaConfianca() throws {
    // Com palavras: a confiança sai delas, ponderada pela duração.
    let comPalavras = [
        Trecho(
            start: 0, end: 2, texto: "bom dia",
            palavras: [
                Palavra(start: 0, end: 1, texto: "bom", confianca: 0.9),
                Palavra(start: 1, end: 2, texto: "dia", confianca: 0.5),
            ],
            confianca: 0.7, noSpeechProb: 0.1
        ),
        Trecho(
            start: 2.1, end: 3.1, texto: "pessoal",
            palavras: [Palavra(start: 2.1, end: 3.1, texto: "pessoal", confianca: 0.7)],
            confianca: 0.7, noSpeechProb: 0.3
        ),
    ]
    let agrupado = try #require(Segmentacao.agrupar(comPalavras).first)
    #expect(abs(try #require(agrupado.confianca) - 0.7) < 0.001)
    #expect(abs(try #require(agrupado.noSpeechProb) - 0.2) < 0.001)

    // Sem palavras (legado): média dos segmentos pela duração.
    let semPalavras = [
        Trecho(start: 0, end: 3, texto: "um", confianca: 0.8),
        Trecho(start: 3.1, end: 4.1, texto: "dois", confianca: 0.4),
    ]
    let legado = try #require(Segmentacao.agrupar(semPalavras).first)
    #expect(abs(try #require(legado.confianca) - 0.7) < 0.001)
}
