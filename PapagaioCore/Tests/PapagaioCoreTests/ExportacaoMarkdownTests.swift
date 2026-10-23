import Foundation
import Testing
@testable import PapagaioCore

@Test("Exportação Markdown contém resumo, metadados e transcrição")
func exportacaoMarkdownCompleta() {
    let arquivo = Arquivo(
        titulo: "Reunião de produto",
        criadoEm: Date(timeIntervalSince1970: 0),
        duracao: 125,
        pastaRelativa: "Gravacoes/id",
        espaco: EspacoID(),
        trechos: [Trecho(start: 12, end: 20, texto: "Vamos fechar o orçamento.", speaker: Speaker.eu)],
        notas: [
            NotaDaConversa(
                texto: "Validar o risco jurídico.",
                start: 35,
                critica: true,
                tipo: .marcador
            ),
        ],
        resumo: Resumo(
            titulo: "Decisões da reunião",
            visaoGeral: "A decisão registrada aprovou o orçamento.",
            temas: [Tema(titulo: "Orçamento", detalhe: "Aprovar R$ 9.600")],
            citacoes: [Citacao(texto: "Fechamos hoje.", speaker: Speaker.interlocutor, start: 12)],
            proximosPassos: [ProximoPasso(descricao: "Enviar contrato", responsavel: "Luca")]
        ),
        engineTranscricao: "whisper-large-v3",
        engineResumo: "qwen2.5-14b-instruct-q5_k_m"
    )

    let markdown = ExportacaoMarkdown.gerar(arquivo: arquivo)

    #expect(markdown.contains("# Decisões da reunião"))
    #expect(markdown.contains("## Visão geral"))
    #expect(markdown.contains("## Temas"))
    #expect(markdown.contains("## Citações"))
    #expect(!markdown.contains("## Próximos passos"))
    #expect(markdown.contains("## Notas"))
    #expect(markdown.contains("## Transcrição"))
    #expect(markdown.contains("**[0:35 · Marcador · Crítica]** Validar o risco jurídico."))
    #expect(markdown.contains("**[0:12 · Eu]** Vamos fechar o orçamento."))
    #expect(!markdown.contains("Enviar contrato"))
}

@Test("Nome de exportação é seguro para o sistema de arquivos")
func nomeDeExportacaoSeguro() {
    let arquivo = Arquivo(
        titulo: "Reunião: Orçamento / Q3!",
        pastaRelativa: "Gravacoes/id",
        espaco: EspacoID()
    )

    #expect(ExportacaoMarkdown.nomeDeArquivo(para: arquivo) == "reuniao-orcamento-q3.md")
}

@Test("Duração indefinida não derruba a exportação", arguments: [Double.nan, .infinity, -5])
func exportacaoComDuracaoIndefinida(duracao: Double) {
    let arquivo = Arquivo(
        titulo: "Mídia sem duração",
        criadoEm: Date(timeIntervalSince1970: 0),
        duracao: duracao,
        pastaRelativa: "Gravacoes/id",
        espaco: EspacoID(),
        trechos: [Trecho(start: .nan, end: .infinity, texto: "Fala sem instante.", speaker: Speaker.eu)]
    )

    let markdown = ExportacaoMarkdown.gerar(arquivo: arquivo)

    #expect(markdown.contains("Fala sem instante."))
    #expect(markdown.contains("0:00"))
}

@Test("Exportação usa as vozes nomeadas, a ficha e os rótulos traduzidos (V-29)")
func exportacaoComVozesNomeadas() {
    func palavra(_ texto: String, _ inicio: TimeInterval, _ voz: String?) -> Palavra {
        Palavra(start: inicio, end: inicio + 0.4, texto: texto, falanteAcustico: voz)
    }
    let editado = Trecho(start: 20, end: 24, texto: "Texto corrigido à mão.", speaker: Speaker.interlocutor)
    let arquivo = Arquivo(
        titulo: "Entrevista",
        criadoEm: Date(timeIntervalSince1970: 0),
        duracao: 30,
        pastaRelativa: "Gravacoes/id",
        espaco: EspacoID(),
        trechos: [
            Trecho(start: 0, end: 4, texto: "Bom dia. Tudo certo?", speaker: Speaker.interlocutor, palavras: [
                palavra("Bom", 0, "interlocutor-S1"), palavra("dia.", 0.5, "interlocutor-S1"),
                palavra("Tudo", 2, "interlocutor-S2"), palavra("certo?", 2.5, "interlocutor-S2"),
            ]),
            editado,
        ]
    )
    let nomes = ["interlocutor-S1": "Ana", "interlocutor-S3": "Caio"]
    let opcoes = OpcoesDeExportacao(
        traduzir: { ["Transcrição": "Transcript", "Interlocutor": "Other side"][$0] ?? $0 },
        nomeDeVoz: { nomes[$0] ?? "Falante \($0.suffix(1))" },
        falantePreservado: { $0 == editado.id ? "interlocutor-S3" : nil },
        ficha: [("Entrevistados", "Ana, Caio"), ("Descrição", "  ")]
    )

    let markdown = ExportacaoMarkdown.gerar(arquivo: arquivo, opcoes: opcoes)

    // Uma linha por fala, com o nome dado à voz — e não uma por trecho.
    #expect(markdown.contains("**[0:00 · Other side · Ana]** Bom dia."))
    #expect(markdown.contains("**[0:02 · Other side · Falante 2]** Tudo certo?"))
    // A fala corrigida à mão perdeu as palavras, mas não a voz.
    #expect(markdown.contains("**[0:20 · Other side · Caio]** Texto corrigido à mão."))
    #expect(markdown.contains("## Transcript"))
    #expect(markdown.contains("- **Entrevistados:** Ana, Caio"))
    #expect(!markdown.contains("Descrição"))

    // Sem as opções do app, o documento continua por trecho e por canal.
    let simples = ExportacaoMarkdown.gerar(arquivo: arquivo)
    #expect(simples.contains("**[0:00 · Interlocutor]** Bom dia. Tudo certo?"))
}
