import Foundation
import Testing
@testable import MetricasDeAvaliacao

// As métricas são o que dá credibilidade aos números do README: um erro aqui
// não quebra o app, mas publica um WER falso. Por isso os casos abaixo são
// pequenos o bastante para conferir de cabeça.

@Suite struct NormalizacaoDeTextoTests {
    @Test func tiraPontuacaoECaixaMasMantemAcento() {
        #expect(NormalizacaoDeTexto.normalizar("Olá,  Mundo! É você?") == "olá mundo é você")
    }

    @Test func removeMarcacoesDoWhisper() {
        #expect(NormalizacaoDeTexto.normalizar("[Música] bom dia (risos) pessoal") == "bom dia pessoal")
    }

    @Test func hifenViraEspaco() {
        #expect(NormalizacaoDeTexto.palavras("guarda-chuva") == ["guarda", "chuva"])
    }
}

@Suite struct DistanciaDeEdicaoTests {
    @Test func identicoNaoTemErro() {
        let c = DistanciaDeEdicao.wer(referencia: "a casa é azul", hipotese: "A casa é azul.")
        #expect(c.erros == 0)
        #expect(c.referencia == 4)
    }

    @Test func separaAsTresParcelas() {
        // ref:  o gato subiu no telhado azul
        // hip:  o rato subiu telhado azul ontem
        // gato→rato (S), "no" some (D), "ontem" sobra (I). As palavras certas
        // entre a deleção e a inserção impedem um alinhamento só de trocas
        // com o mesmo custo.
        let c = DistanciaDeEdicao.wer(
            referencia: "o gato subiu no telhado azul",
            hipotese: "o rato subiu telhado azul ontem"
        )
        #expect(c == ContagemDeErros(substituicoes: 1, delecoes: 1, insercoes: 1, referencia: 6))
        #expect(abs(c.taxa - 0.5) < 1e-9)
    }

    @Test func hipoteseVaziaEDelecaoTotal() {
        let c = DistanciaDeEdicao.wer(referencia: "três palavras aqui", hipotese: "")
        #expect(c == ContagemDeErros(delecoes: 3, referencia: 3))
    }

    @Test func referenciaVaziaSoTemInsercoes() {
        let c = DistanciaDeEdicao.wer(referencia: "", hipotese: "alucinação total")
        #expect(c == ContagemDeErros(insercoes: 2, referencia: 0))
        #expect(c.taxa == 0)
    }

    @Test func cerIgnoraEspacos() {
        let c = DistanciaDeEdicao.cer(referencia: "bom dia", hipotese: "bom diu")
        #expect(c.referencia == 6)
        #expect(c.substituicoes == 1)
    }

    @Test func somaDoCorpusPesaPeloTamanho() {
        let curta = ContagemDeErros(substituicoes: 1, referencia: 2)
        let longa = ContagemDeErros(referencia: 18)
        // Média das taxas daria 25%; a taxa do corpus é 1/20.
        #expect(abs((curta + longa).taxa - 0.05) < 1e-9)
    }
}

@Suite struct ErroDeDiarizacaoTests {
    private let referencia = [
        IntervaloDeFala(falante: "ana", inicio: 0, fim: 10),
        IntervaloDeFala(falante: "bia", inicio: 10, fim: 20),
    ]

    @Test func rotulosTrocadosNaoSaoErro() {
        let hipotese = [
            IntervaloDeFala(falante: "S2", inicio: 0, fim: 10),
            IntervaloDeFala(falante: "S1", inicio: 10, fim: 20),
        ]
        let r = ErroDeDiarizacao.avaliar(referencia: referencia, hipotese: hipotese, colar: 0)
        #expect(r.der < 1e-6)
    }

    @Test func umFalanteParaTudoEMetadeDeConfusao() {
        let hipotese = [IntervaloDeFala(falante: "S1", inicio: 0, fim: 20)]
        let r = ErroDeDiarizacao.avaliar(referencia: referencia, hipotese: hipotese, colar: 0)
        #expect(abs(r.confusao - 10) < 0.02)
        #expect(abs(r.der - 0.5) < 1e-3)
    }

    @Test func silencioNaoDetectadoEFalaPerdida() {
        let hipotese = [IntervaloDeFala(falante: "S1", inicio: 0, fim: 10)]
        let r = ErroDeDiarizacao.avaliar(referencia: referencia, hipotese: hipotese, colar: 0)
        #expect(abs(r.falaPerdida - 10) < 0.02)
        #expect(r.falsoAlarme < 1e-6)
    }

    @Test func falaInventadaEFalsoAlarme() {
        let hipotese = referencia + [IntervaloDeFala(falante: "S9", inicio: 20, fim: 25)]
        let r = ErroDeDiarizacao.avaliar(referencia: referencia, hipotese: hipotese, colar: 0)
        #expect(abs(r.falsoAlarme - 5) < 0.02)
    }

    @Test func colarIgnoraAFronteira() {
        // A hipótese erra a troca de turno por 0,2 s: dentro do colar de 0,25 s.
        let hipotese = [
            IntervaloDeFala(falante: "S1", inicio: 0, fim: 10.2),
            IntervaloDeFala(falante: "S2", inicio: 10.2, fim: 20),
        ]
        let r = ErroDeDiarizacao.avaliar(referencia: referencia, hipotese: hipotese)
        #expect(r.der < 1e-6)
    }

    @Test func mapeamentoEInjetivo() {
        let mapa = ErroDeDiarizacao.melhorMapeamento([
            "S1": ["ana": 9, "bia": 8],
            "S2": ["ana": 8.5],
        ])
        // O guloso pegaria S1→ana (9) e deixaria S2 sem par. O ótimo divide:
        // S1→bia + S2→ana = 16,5, e nenhum rótulo repete "ana".
        #expect(mapa == ["S1": "bia", "S2": "ana"])
    }
}

@Suite struct AcertoDeFalantePorPalavraTests {
    private let referencia = [
        IntervaloDeFala(falante: "ana", inicio: 0, fim: 5),
        IntervaloDeFala(falante: "bia", inicio: 6, fim: 10),
    ]

    @Test func contaPalavraSemFalanteComoErro() {
        let palavras = [
            PalavraAtribuida(inicio: 1, fim: 1.3, falante: "S1"),
            PalavraAtribuida(inicio: 2, fim: 2.3, falante: "S1"),
            PalavraAtribuida(inicio: 7, fim: 7.3, falante: "S2"),
            PalavraAtribuida(inicio: 8, fim: 8.3, falante: nil),
        ]
        let r = AcertoDeFalantePorPalavra.avaliar(palavras: palavras, referencia: referencia)
        #expect(r == AcertoDeFalantePorPalavra(total: 4, atribuidas: 3, corretas: 3))
        #expect(abs(r.acuracia - 0.75) < 1e-9)
    }

    @Test func palavraNoBuracoVaiParaOTurnoMaisProximo() {
        let palavra = PalavraAtribuida(inicio: 5.7, fim: 5.9, falante: nil)
        #expect(AcertoDeFalantePorPalavra.falanteDeReferencia(de: palavra, em: referencia) == "bia")
    }
}

@Suite struct CoberturaDeFatosTests {
    private let fato = CoberturaDeFatos.Fato(
        descricao: "Ana entrega o relatório na sexta",
        termos: [["ana"], ["relatorio"], ["sexta", "sexta-feira"]]
    )

    @Test func passaComQualquerAlternativa() {
        #expect(CoberturaDeFatos.cobre(fato, texto: "A Ana fica com o relatório até sexta-feira."))
    }

    @Test func faltandoUmGrupoNaoPassa() {
        #expect(!CoberturaDeFatos.cobre(fato, texto: "A Ana fica com o relatório."))
    }

    @Test func casaPalavraInteira() {
        // "ana" não pode casar dentro de "semana".
        #expect(!CoberturaDeFatos.cobre(fato, texto: "O relatório sai na sexta da semana que vem."))
    }
}
