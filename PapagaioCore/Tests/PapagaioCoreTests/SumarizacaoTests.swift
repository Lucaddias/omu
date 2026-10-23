import Foundation
import LlamaRuntime
import Testing
@testable import PapagaioCore

private var modeloQwen: URL? {
    let caminho = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/InterviewLab/Models")
        .appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    return FileManager.default.fileExists(atPath: caminho.path) ? caminho : nil
}

// MARK: - Formatação do prompt

@Test("Transcrição formatada carrega tempo e falante em cada linha")
func formatacaoDaTranscricao() {
    let trechos = [
        Trecho(start: 0, end: 40, texto: "abertura", speaker: Speaker.eu),
        Trecho(start: 95, end: 130, texto: "resposta", speaker: Speaker.interlocutor),
        Trecho(start: 200, end: 240, texto: "sem canal", speaker: nil),
    ]
    let texto = QwenEngine.formatar(trechos)

    #expect(texto.contains("[00:00] (eu) abertura"))
    #expect(texto.contains("[01:35] (interlocutor) resposta"))
    #expect(texto.contains("[03:20] (desconhecido) sem canal"))
}

@Test("Prompt do Qwen3.5 desativa thinking antes do JSON estruturado")
func promptQwen35SemThinking() {
    let prompt = QwenEngine.prompt(paraTranscricao: "[00:00] (eu) Vamos decidir hoje.")
    #expect(prompt.contains("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
}

// MARK: - Decodificação

@Test("Decodifica JSON válido mesmo com texto em volta")
func decodificaComRuido() {
    let json = """
    Claro! Aqui está:
    {"titulo":"Kickoff","visaoGeral":"Alinhamento.","temas":[],"citacoes":[],"proximosPassos":[]}
    Espero ter ajudado.
    """
    let resumo = QwenEngine.decodificar(json)
    #expect(resumo?.titulo == "Kickoff")
    #expect(resumo?.visaoGeral == "Alinhamento.")
}

@Test("JSON malformado devolve nil em vez de explodir")
func decodificaMalformado() {
    #expect(QwenEngine.decodificar("não é json") == nil)
    #expect(QwenEngine.decodificar("{ incompleto") == nil)
    #expect(QwenEngine.decodificar("") == nil)
}

@Test("Resumo completo faz round-trip pelo decodificador")
func decodificaCompleto() {
    let json = """
    {"titulo":"Reunião","visaoGeral":"Resumo.",
     "temas":[{"titulo":"Prazo","detalhe":"Sete dias."}],
     "citacoes":[{"texto":"vamos negociar","speaker":"eu","start":91.2}],
     "proximosPassos":[{"descricao":"ligar","responsavel":"Luca"}]}
    """
    let resumo = QwenEngine.decodificar(json)
    #expect(resumo?.temas.first?.titulo == "Prazo")
    #expect(resumo?.citacoes.first?.start == 91.2)
    #expect(resumo?.proximosPassos.first?.responsavel == "Luca")
}

@Test("Citações só recebem âncora de um trecho que realmente contém o texto")
func validaCitacoesContraATranscricao() {
    let trechos = [
        Trecho(
            start: 42,
            end: 50,
            texto: "Éé, putz, precisamos ouvir os alunos antes de decidir o próximo passo.",
            speaker: Speaker.eu
        ),
        Trecho(
            start: 80,
            end: 88,
            texto: "Vamos marcar a reunião para sexta-feira e enviar o convite hoje.",
            speaker: Speaker.interlocutor
        ),
    ]
    let resumo = Resumo(
        titulo: "Teste",
        visaoGeral: "Teste.",
        citacoes: [
            Citacao(
                texto: "Éé, putz, precisamos ouvir os alunos antes de decidir o próximo passo.",
                speaker: nil,
                start: 999
            ),
            Citacao(texto: "Uma frase inventada que não existe nesta reunião.", speaker: nil, start: 80),
        ]
    )

    let citacoesValidadas = ValidacaoDeCitacoes.validar(resumo.citacoes, contra: trechos)

    #expect(citacoesValidadas.count == 1)
    #expect(citacoesValidadas[0].texto == "Precisamos ouvir os alunos antes de decidir o próximo passo.")
    #expect(citacoesValidadas[0].start == 42)
    #expect(citacoesValidadas[0].speaker == Speaker.eu)
}

// MARK: - Gramática

@Test("Gramática GBNF tem uma regra por linha e define root")
func gramaticaBemFormada() {
    let linhas = GramaticaDoResumo.gbnf
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // O parser do llama.cpp termina a regra na quebra de linha: toda linha
    // não vazia precisa ser uma regra completa.
    for linha in linhas {
        #expect(linha.contains("::="), "linha sem ::= quebra o parser: \(linha)")
    }
    #expect(linhas.contains { $0.hasPrefix("root ::=") })

    // As cinco chaves do Resumo têm que estar na gramática.
    for chave in ["titulo", "visaoGeral", "temas", "citacoes", "proximosPassos"] {
        #expect(GramaticaDoResumo.gbnf.contains(chave))
    }
}

// MARK: - Decisão passe único vs. map-reduce

@Test("Teto de entrada deixa margem para a saída dentro da janela")
func tetoDeEntrada() {
    #expect(ContextoLlama.tetoDeEntrada < Int(ContextoLlama.janelaPadrao))
    // Sobra pelo menos 4k para gerar.
    #expect(Int(ContextoLlama.janelaPadrao) - ContextoLlama.tetoDeEntrada >= 4_000)
    // O chunk do map-reduce cabe folgado no passe único.
    #expect(QwenEngine.tokensPorChunk < ContextoLlama.tetoDeEntrada)
}

@Test("Lote de prefill respeita o limite que o llama_decode impõe")
func lotePrefill() {
    // `llama_decode` aborta o processo se o lote passar de n_batch. O prefill
    // é fatiado por isso — este teste trava a invariante.
    #expect(ContextoLlama.tokensPorLote > 0)
    #expect(ContextoLlama.tokensPorLote <= Int(ContextoLlama.janelaPadrao))
}

// MARK: - Real

/// Testes que carregam o Qwen. Serializados para não disputar a GPU com o Whisper.
@Suite(.serialized)
struct TestesComModeloQwen {
    @Test("Qwen produz Resumo tipado válido a partir de trechos reais",
          .enabled(if: modeloQwen != nil),
          .timeLimit(.minutes(10)))
    func sumarizacaoReal() async throws {
        let trechos = [
            Trecho(start: 0, end: 40,
                   texto: "Gente, a reunião de amanhã ficou para 9h30 ou 10h? O convite mostra 10h.",
                   speaker: Speaker.eu),
            Trecho(start: 40, end: 85,
                   texto: "Sobre o orçamento: estimamos R$4.850 mas apareceu um custo extra de R$1.730.",
                   speaker: Speaker.interlocutor),
            Trecho(start: 85, end: 130,
                   texto: "O fornecedor prometeu três dias úteis e agora fala em sete dias. Vamos negociar.",
                   speaker: Speaker.eu),
        ]

        let engine = QwenEngine(modelo: try #require(modeloQwen))
        let resumo = try await engine.summarize(trechos)

        #expect(!resumo.titulo.isEmpty)
        #expect(!resumo.visaoGeral.isEmpty)

        // O que justifica um modelo de 32k em vez de um de 4k: os números
        // atravessam o resumo sem se perder.
        let tudo = ([resumo.titulo, resumo.visaoGeral]
            + resumo.temas.map { "\($0.titulo) \($0.detalhe)" }
            + resumo.proximosPassos.map(\.descricao)).joined(separator: " ")
        #expect(tudo.contains("1.730") || tudo.contains("1730"))

        await engine.descarregar()
    }

    @Test("Transcrição vazia é recusada em vez de virar resumo inventado")
    func sumarizacaoVazia() async {
        let engine = QwenEngine(modelo: URL(fileURLWithPath: "/nao/existe/modelo.gguf"))
        await #expect(throws: (any Error).self) {
            _ = try await engine.summarize([])
        }
    }
}

@Test("Strings da gramática não aceitam caracteres de controle crus (S-01)")
func gramaticaRecusaControleCruEmString() {
    // Quebra de linha crua dentro de string é JSON inválido: o `JSONDecoder`
    // recusava a saída e o resumo caía no reprompt. A classe tem de excluir
    // 0x00–0x1F, como a `json.gbnf` de referência do llama.cpp.
    let classe = #"[^"\\\x7F\x00-\x1F]"#
    #expect(GramaticaDoResumo.gbnf.contains(classe))
    #expect(GramaticaDaTraducao.gbnf(quantidade: 2).contains(classe))
}

@Test("Falhas do resumo dizem o que aconteceu, não 'gramática recusada' (S-02, S-05)")
func errosDoResumoTemMensagemPropria() {
    #expect(ErroDeResumo.transcricaoVazia.localizedDescription.contains("transcrição"))
    let incompleto = ErroDeResumo.resumoIncompleto.localizedDescription
    #expect(incompleto.contains("resumo"))
    #expect(!incompleto.lowercased().contains("gbnf"))
    #expect(!incompleto.contains("operation couldn"))
}
