import Foundation
import Testing
@testable import PapagaioCore

// O Whisper repete a última frase quando encontra silêncio, ruído constante ou
// um trecho longo demais. O filtro é deliberadamente conservador: colapsa o que
// é claramente artefato e preserva o que pode ser repetição real da conversa.

private func trecho(
    _ texto: String,
    _ start: TimeInterval,
    _ end: TimeInterval,
    _ speaker: String? = Speaker.eu
) -> Trecho {
    Trecho(start: start, end: end, texto: texto, speaker: speaker)
}

// MARK: - Colapso de sequências

@Test("Três ou mais segmentos iguais e seguidos viram um só")
func colapsaSequenciaLonga() {
    let entrada = [
        trecho("Legendas pela comunidade Amara.org", 0, 3),
        trecho("Legendas pela comunidade Amara.org", 3, 6),
        trecho("Legendas pela comunidade Amara.org", 6, 9),
        trecho("Legendas pela comunidade Amara.org", 9, 12),
    ]
    let saida = FiltroDeRepeticao.remover(entrada)

    #expect(saida.count == 1)
    #expect(saida.first?.start == 0)
}

// MARK: - Palavras com timestamp

private func trechoComPalavras() -> Trecho {
    Trecho(
        start: 0,
        end: 12,
        texto: "Bom dia. Bom dia. Tudo bem?",
        speaker: Speaker.eu,
        palavras: [
            Palavra(start: 0, end: 2, texto: "Bom"),
            Palavra(start: 2, end: 4, texto: "dia"),
            Palavra(start: 5, end: 7, texto: "Bom"),
            Palavra(start: 7, end: 9, texto: "dia"),
            Palavra(start: 9, end: 11, texto: "Tudo"),
            Palavra(start: 11, end: 12, texto: "bem"),
        ]
    )
}

@Test("Trecho sem repetição atravessa com as palavras intactas")
func filtroPreservaPalavrasSemRepeticao() {
    // Regressão: o filtro reconstruía o `Trecho` sem `palavras` em todo caso,
    // mesmo sem remover nada — ligado ao pipeline, matava a navegação palavra
    // a palavra de graça.
    let original = Trecho(
        start: 0,
        end: 6,
        texto: "Bom dia. Tudo bem?",
        speaker: Speaker.eu,
        palavras: [
            Palavra(start: 0, end: 2, texto: "Bom"),
            Palavra(start: 2, end: 4, texto: "dia"),
            Palavra(start: 4, end: 6, texto: "Tudo bem"),
        ]
    )

    let saida = FiltroDeRepeticao.remover([original])

    #expect(saida.count == 1)
    #expect(saida.first?.palavras == original.palavras)
}

@Test("Repetição removida leva embora só as palavras da frase repetida")
func filtroRemovePalavrasDaFraseRepetida() {
    let saida = FiltroDeRepeticao.remover([trechoComPalavras()])

    let limpo = try! #require(saida.first)
    #expect(limpo.texto == "Bom dia. Tudo bem?")
    // Ficam as palavras das frases mantidas; nenhuma âncora aponta para a
    // cópia removida.
    #expect(limpo.palavras.map(\.texto) == ["Bom", "dia", "Tudo", "bem"])
}

@Test("Duas repetições são preservadas — podem ser fala real")
func preservaRepeticaoCurta() {
    // "Oi? Oi?" numa ligação ruim é conversa, não artefato.
    let entrada = [
        trecho("Alô?", 0, 1),
        trecho("Alô?", 1, 2),
    ]
    #expect(FiltroDeRepeticao.remover(entrada).count == 2)
}

@Test("Repetição com pausa longa entre as cópias não é colapsada")
func pausaLongaQuebraASequencia() {
    // Mais de 5 s de intervalo indica que a frase voltou naturalmente, não que
    // o decodificador travou num laço.
    let entrada = [
        trecho("Perfeito", 0, 1),
        trecho("Perfeito", 30, 31),
        trecho("Perfeito", 60, 61),
    ]
    #expect(FiltroDeRepeticao.remover(entrada).count == 3)
}

@Test("Falantes diferentes não formam sequência, mesmo com texto igual")
func falantesDiferentesNaoColapsam() {
    let entrada = [
        trecho("Combinado", 0, 1, Speaker.eu),
        trecho("Combinado", 1, 2, Speaker.interlocutor),
        trecho("Combinado", 2, 3, Speaker.eu),
    ]
    #expect(FiltroDeRepeticao.remover(entrada).count == 3)
}

@Test("Comparação ignora caixa, acento e pontuação")
func comparacaoNormalizada() {
    let entrada = [
        trecho("Obrigado.", 0, 1),
        trecho("obrigado", 1, 2),
        trecho("OBRIGADO!", 2, 3),
    ]
    #expect(FiltroDeRepeticao.remover(entrada).count == 1)
}

// MARK: - Limpeza dentro do segmento

@Test("Frase repetida dentro do mesmo segmento é removida")
func limpaRepeticaoInterna() throws {
    let entrada = [
        trecho("Vamos fechar. Vamos fechar. Vamos fechar. Amanhã às dez.", 0, 8)
    ]
    let saida = try #require(FiltroDeRepeticao.remover(entrada).first)

    #expect(saida.texto == "Vamos fechar. Amanhã às dez.")
}

@Test("Segmento que sobra vazio é descartado em vez de virar linha em branco")
func segmentoVazioSai() {
    let entrada = [
        trecho("   ", 0, 1),
        trecho("Tudo certo.", 1, 2),
    ]
    let saida = FiltroDeRepeticao.remover(entrada)

    #expect(saida.count == 1)
    #expect(saida.first?.texto == "Tudo certo.")
}

@Test("Identidade e limites de tempo do trecho preservado não mudam")
func preservaIdentidadeETempo() throws {
    let original = Trecho(start: 12, end: 19, texto: "Fechado. Fechado.", speaker: Speaker.interlocutor)
    let saida = try #require(FiltroDeRepeticao.remover([original]).first)

    #expect(saida.id == original.id)
    #expect(saida.start == 12)
    #expect(saida.end == 19)
    #expect(saida.speaker == Speaker.interlocutor)
    #expect(saida.texto == "Fechado.")
}

@Test("Entrada vazia devolve vazio, sem crashar")
func entradaVazia() {
    #expect(FiltroDeRepeticao.remover([]).isEmpty)
}

@Test("Transcrição sem repetição atravessa intacta")
func semRepeticaoNaoMuda() {
    let entrada = [
        trecho("O orçamento subiu para R$4.850.", 0, 4),
        trecho("Confirmo para sexta.", 4, 7),
    ]
    #expect(FiltroDeRepeticao.remover(entrada).map(\.texto) == entrada.map(\.texto))
}

// MARK: - Formatação da visão geral

@Test("Visão geral é repartida em blocos de duas frases")
func visaoGeralEmBlocos() {
    let texto = "Primeira. Segunda. Terceira. Quarta. Quinta."
    let saida = FormatacaoDoResumo.visaoGeralEmBlocosDeDuasFrases(texto)

    #expect(saida == "Primeira. Segunda.\n\nTerceira. Quarta.\n\nQuinta.")
}

@Test("Número decimal não é confundido com fim de frase")
func decimalNaoQuebraFrase() {
    // Dividir manualmente em "." partiria "R$4.850" no meio — é por isso que a
    // formatação usa `enumerateSubstrings(.bySentences)`.
    let saida = FormatacaoDoResumo.visaoGeralEmBlocosDeDuasFrases(
        "O custo foi de R$4.850 no total."
    )
    #expect(saida == "O custo foi de R$4.850 no total.")
}

@Test("Texto de uma frase só atravessa sem quebra")
func fraseUnica() {
    #expect(
        FormatacaoDoResumo.visaoGeralEmBlocosDeDuasFrases("Reunião curta.")
            == "Reunião curta."
    )
}

@Test("Texto vazio não vira quebra de linha solta")
func visaoGeralVazia() {
    #expect(FormatacaoDoResumo.visaoGeralEmBlocosDeDuasFrases("   ").isEmpty)
}

@Test("Limpar uma repetição não apaga confiança nem noSpeechProb (T-05)")
func filtroPreservaMetadadosDoTrecho() throws {
    let original = Trecho(
        start: 0, end: 4,
        texto: "Vamos começar. Vamos começar.",
        speaker: Speaker.eu,
        confianca: 0.82,
        noSpeechProb: 0.07
    )

    let saida = try #require(FiltroDeRepeticao.remover([original]).first)

    #expect(saida.texto == "Vamos começar.")
    #expect(saida.id == original.id)
    #expect(saida.confianca == 0.82)
    #expect(saida.noSpeechProb == 0.07)
}
