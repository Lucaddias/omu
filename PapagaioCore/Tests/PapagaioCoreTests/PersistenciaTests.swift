import Foundation
import SwiftData
import Testing
@testable import PapagaioCore

/// Container em memória: os testes não podem tocar o banco real do usuário.
private func repositorioDeTeste() throws -> SwiftDataRepository {
    let container = try SwiftDataRepository.containerLocal(
        nome: "PapagaioTeste-\(UUID().uuidString)",
        emMemoria: true
    )
    return SwiftDataRepository(modelContainer: container)
}

private func arquivoDeExemplo(
    titulo: String,
    espaco: EspacoID,
    trechos: [Trecho] = [],
    notas: [NotaDaConversa] = [],
    resumo: Resumo? = nil
) -> Arquivo {
    Arquivo(
        titulo: titulo,
        duracao: 120,
        pastaRelativa: "Gravacoes/\(UUID().uuidString)",
        espaco: espaco,
        trechos: trechos,
        notas: notas,
        resumo: resumo,
        engineTranscricao: "whisper-large-v3",
        engineResumo: "qwen2.5-14b-instruct-q5_k_m"
    )
}

// MARK: - Passo 8

@Test("Salvar e listar preserva trechos, resumo e metadados das engines")
func persistenciaRoundTrip() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()

    let resumo = Resumo(
        titulo: "Kickoff",
        visaoGeral: "Alinhamento de escopo e prazo.",
        temas: [Tema(titulo: "Prazo", detalhe: "Entrega em setembro.")],
        citacoes: [Citacao(texto: "vamos manter o Whisper", speaker: Speaker.eu, start: 91.2)],
        proximosPassos: [ProximoPasso(descricao: "fechar o contrato", responsavel: "Luca")]
    )
    let original = arquivoDeExemplo(
        titulo: "Reunião de kickoff",
        espaco: espaco,
        trechos: [
            Trecho(start: 0, end: 40, texto: "abertura", speaker: Speaker.eu, palavras: [
                Palavra(start: 0, end: 3, texto: "bom"),
                Palavra(start: 3, end: 6, texto: "dia"),
            ]),
            Trecho(start: 40, end: 82, texto: "resposta", speaker: Speaker.interlocutor),
        ],
        resumo: resumo
    )

    try await repo.salvar(original)
    let listados = try await repo.listar(espaco: espaco)

    #expect(listados.count == 1)
    let volta = try #require(listados.first)

    #expect(volta.id == original.id)
    #expect(volta.titulo == "Reunião de kickoff")
    #expect(volta.engineTranscricao == "whisper-large-v3")
    #expect(volta.engineResumo == "qwen2.5-14b-instruct-q5_k_m")

    // Trechos voltam ordenados por tempo, com o falante do canal.
    #expect(volta.trechos.count == 2)
    #expect(volta.trechos[0].speaker == Speaker.eu)
    #expect(volta.trechos[1].speaker == Speaker.interlocutor)
    #expect(volta.trechos[0].start < volta.trechos[1].start)

    // Palavras com timestamps sobrevivem ao JSON; trecho sem palavras volta vazio.
    #expect(volta.trechos[0].palavras.count == 2)
    #expect(volta.trechos[0].palavras[0].texto == "bom")
    #expect(volta.trechos[0].palavras[0].start == 0)
    #expect(volta.trechos[0].palavras[1].end == 6)
    #expect(volta.trechos[1].palavras.isEmpty)

    // O resumo é reconstruído a partir dos insights.
    #expect(volta.resumo?.titulo == "Kickoff")
    #expect(volta.resumo?.temas.first?.detalhe == "Entrega em setembro.")
    #expect(volta.resumo?.citacoes.first?.start == 91.2)
    #expect(volta.resumo?.proximosPassos.first?.responsavel == "Luca")
}

@Test("Preview da biblioteca adia palavras e busca o arquivo completo no detalhe")
func previewDaBibliotecaAdiaPalavras() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let original = arquivoDeExemplo(
        titulo: "Busca preservada",
        espaco: espaco,
        trechos: [
            Trecho(
                start: 4,
                end: 9,
                texto: "decisão sobre o prazo",
                speaker: Speaker.eu,
                palavras: [
                    Palavra(start: 4, end: 6, texto: "decisão", falanteAcustico: "S1"),
                    Palavra(start: 7, end: 9, texto: "prazo", falanteAcustico: "S1"),
                ]
            ),
            Trecho(start: 12, end: 15, texto: "próxima etapa", speaker: Speaker.interlocutor),
        ]
    )

    try await repo.salvar(original)

    let preview = try #require(try await repo.listarParaBiblioteca(espaco: espaco).first)
    #expect(preview.id == original.id)
    #expect(preview.trechos.map(\.texto) == ["decisão sobre o prazo", "próxima etapa"])
    #expect(preview.trechos.map(\.start) == [4, 12])
    #expect(preview.trechos[0].speaker == Speaker.eu)
    #expect(preview.trechos.allSatisfy { $0.palavras.isEmpty })
    #expect(preview.possuiPalavrasComTimestamp == true)

    var previewRejeitado = false
    do {
        try await repo.salvar(preview)
    } catch {
        previewRejeitado = true
    }
    #expect(previewRejeitado)

    let detalhe = try #require(try await repo.buscarCompleto(id: original.id))
    #expect(detalhe.trechos[0].palavras.map(\.texto) == ["decisão", "prazo"])
    #expect(detalhe.trechos[0].palavras.map(\.falanteAcustico) == ["S1", "S1"])
    #expect(detalhe.possuiPalavrasComTimestamp == nil)

    try await repo.moverParaLixeira(original.id)
    let previewDaLixeira = try #require(
        try await repo.listarNaLixeiraParaBiblioteca(espaco: espaco).first
    )
    #expect(previewDaLixeira.trechos.allSatisfy { $0.palavras.isEmpty })
    #expect(previewDaLixeira.possuiPalavrasComTimestamp == true)
    #expect(try await repo.buscarCompleto(id: original.id)?.trechos[0].palavras.count == 2)
}

@Test("Round-trip preserva o falante acústico da diarização")
func persistenciaPreservaFalanteAcustico() async throws {
    // Regressão: o `paraDominio` reconstruía cada palavra sem o
    // `falanteAcustico`, e a atribuição da diarização sumia em todo reload.
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let original = arquivoDeExemplo(
        titulo: "Diarizada", espaco: espaco,
        trechos: [
            Trecho(start: 0, end: 12, texto: "oi, tudo bem?", speaker: Speaker.eu, palavras: [
                Palavra(start: 0, end: 1, texto: "oi", confianca: 0.92, noSpeechProb: 0.03, falanteAcustico: "S1"),
                Palavra(start: 1, end: 6, texto: "tudo bem", falanteAcustico: "S2"),
                Palavra(start: 6, end: 12, texto: "sim"), // sem falante: nil precisa sobreviver também
            ]),
            // Palavra sem diarização (legada) continua sem falante.
            Trecho(start: 40, end: 82, texto: "resposta", speaker: Speaker.interlocutor, palavras: [
                Palavra(start: 40, end: 82, texto: "certo"),
            ]),
        ]
    )

    try await repo.salvar(original)
    let volta = try #require(try await repo.listar(espaco: espaco).first)

    let palavras = try #require(volta.trechos.first?.palavras)
    #expect(palavras.count == 3)
    #expect(palavras[0].falanteAcustico == "S1")
    #expect(palavras[1].falanteAcustico == "S2")
    #expect(palavras[2].falanteAcustico == nil)
    #expect(palavras[0].confianca == 0.92)
    #expect(palavras[0].noSpeechProb == 0.03)
    #expect(volta.trechos[1].palavras[0].falanteAcustico == nil)
}

@Test("Falha ao apagar a mídia preserva o registro e permite repetir")
func persistenciaApagarEhRetomavelSeMidiaFalhar() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let arquivo = arquivoDeExemplo(titulo: "na lixeira", espaco: espaco)
    try await repo.salvar(arquivo)
    try await repo.moverParaLixeira(arquivo.id)

    struct FalhaDeMidia: Error {}
    await #expect(throws: FalhaDeMidia.self) {
        try await repo.apagar(arquivo.id) { _ in throw FalhaDeMidia() }
    }

    // Sem apagar o registro, a lixeira ainda guarda o caminho da mídia e a
    // pessoa pode repetir a operação. Apagar o banco primeiro deixava uma
    // pasta órfã que nenhuma tentativa posterior conseguia mais localizar.
    #expect(try await repo.listarNaLixeira(espaco: espaco).map(\.id) == [arquivo.id])

    try await repo.apagar(arquivo.id) { _ in }

    #expect(try await repo.listarNaLixeira(espaco: espaco).isEmpty)
    #expect(try await repo.listar(espaco: espaco).isEmpty)
}

@Test("Excluir dados de um espaço preserva os demais espaços")
func persistenciaExcluiSomenteODominioDaContaAtual() async throws {
    let repo = try repositorioDeTeste()
    let minhaConta = EspacoID()
    let outraConta = EspacoID()
    let ativo = arquivoDeExemplo(titulo: "ativo", espaco: minhaConta)
    let naLixeira = arquivoDeExemplo(titulo: "lixeira", espaco: minhaConta)
    let deOutraConta = arquivoDeExemplo(titulo: "outra", espaco: outraConta)

    try await repo.salvar(ativo)
    try await repo.salvar(naLixeira)
    try await repo.moverParaLixeira(naLixeira.id)
    try await repo.salvar(deOutraConta)

    try await repo.apagarTodosOsDados(espaco: minhaConta)

    #expect(try await repo.listar(espaco: minhaConta).isEmpty)
    #expect(try await repo.listarNaLixeira(espaco: minhaConta).isEmpty)
    #expect(try await repo.listar(espaco: outraConta).map(\.id) == [deOutraConta.id])
}

@Test("Espaço ausente em registro legado devolve sempre o mesmo id")
func espacoAusenteUsaIdEstavel() {
    // Registro legado sem a relação de espaço: o fallback não pode inventar
    // um UUID novo a cada leitura, senão o mesmo arquivo troca de espaço toda
    // vez que é relido do banco.
    let legado = ArquivoPersistido()
    legado.espaco = nil

    let primeira = SwiftDataRepository.paraDominio(legado).espaco
    let segunda = SwiftDataRepository.paraDominio(legado).espaco

    #expect(primeira == segunda)
}

@Test("Cura de palavras legadas arranca o token especial sem perder a fala")
func curaDePalavrasLegadas() async throws {
    // A primeira versão mesclava o `[_TT_…]` do fim do segmento à última
    // palavra real (`"Alô?[_TT_200]"`) e criava palavras só de código
    // (`[_BEG_]`). A cura tem que devolver a palavra real e descartar só o
    // código — nunca a palavra inteira como o filtro `contains("[")` fazia.
    #expect(SwiftDataRepository.curarTextoDePalavraLegada("Alô?[_TT_200]") == "Alô?")
    #expect(SwiftDataRepository.curarTextoDePalavraLegada("[_BEG_]") == "")
    #expect(SwiftDataRepository.curarTextoDePalavraLegada("marcador[_TT_400]") == "marcador")
    #expect(SwiftDataRepository.curarTextoDePalavraLegada("cara") == "cara")
    #expect(SwiftDataRepository.curarTextoDePalavraLegada("a[_TT_800][_BEG_]b") == "ab")
}

@Test("Salvar e listar preserva notas temporizadas e seus marcadores")
func persistenciaNotasRoundTrip() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let marcador = NotaDaConversa(
        texto: "",
        start: 74.5,
        critica: true,
        tipo: .marcador
    )
    let nota = NotaDaConversa(
        texto: "Confirmar o prazo.",
        start: 12,
        tipo: .nota
    )
    let arquivo = arquivoDeExemplo(
        titulo: "Entrevista",
        espaco: espaco,
        // A persistência entrega cronologicamente, mesmo que a coleção venha
        // de uma edição em ordem diferente.
        notas: [marcador, nota]
    )

    try await repo.salvar(arquivo)
    let volta = try #require(try await repo.listar(espaco: espaco).first)

    #expect(volta.notas == [nota, marcador])
    #expect(volta.notas[1].critica)
    #expect(volta.notas[1].tipo == .marcador)
}

@Test("Salvar novamente substitui notas antigas, sem acumulá-las")
func persistenciaAtualizaNotas() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    var arquivo = arquivoDeExemplo(
        titulo: "Reunião",
        espaco: espaco,
        notas: [NotaDaConversa(texto: "primeira", start: 3)]
    )
    try await repo.salvar(arquivo)

    let atualizada = NotaDaConversa(texto: "segunda", start: 8, critica: true)
    arquivo.notas = [atualizada]
    try await repo.salvar(arquivo)

    let volta = try #require(try await repo.listar(espaco: espaco).first)
    #expect(volta.notas == [atualizada])
}

@Test("Caminho guardado é sempre relativo")
func persistenciaCaminhoRelativo() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    try await repo.salvar(arquivoDeExemplo(titulo: "qualquer", espaco: espaco))

    let volta = try #require(try await repo.listar(espaco: espaco).first)
    #expect(!volta.pastaRelativa.hasPrefix("/"))
    #expect(volta.pastaRelativa.hasPrefix("Gravacoes/"))
}

@Test("Salvar duas vezes atualiza, não duplica")
func persistenciaIdempotente() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    var arquivo = arquivoDeExemplo(
        titulo: "primeiro título", espaco: espaco,
        trechos: [Trecho(start: 0, end: 30, texto: "um", speaker: nil)]
    )

    try await repo.salvar(arquivo)
    arquivo.titulo = "título corrigido"
    arquivo.trechos = [
        Trecho(start: 0, end: 30, texto: "um", speaker: nil),
        Trecho(start: 30, end: 60, texto: "dois", speaker: nil),
    ]
    try await repo.salvar(arquivo)

    let listados = try await repo.listar(espaco: espaco)
    #expect(listados.count == 1)
    #expect(listados.first?.titulo == "título corrigido")
    // Trechos são reescritos por inteiro, sem acumular os antigos.
    #expect(listados.first?.trechos.count == 2)
}

@Test("Espaços diferentes não se enxergam")
func persistenciaIsolaEspacos() async throws {
    let repo = try repositorioDeTeste()
    let meu = EspacoID()
    let outro = EspacoID()

    try await repo.salvar(arquivoDeExemplo(titulo: "meu", espaco: meu))
    try await repo.salvar(arquivoDeExemplo(titulo: "outro", espaco: outro))

    #expect(try await repo.listar(espaco: meu).count == 1)
    #expect(try await repo.listar(espaco: meu).first?.titulo == "meu")
    #expect(try await repo.listar(espaco: outro).count == 1)
}

@Test("Lixeira preserva dados e áudio até a exclusão definitiva")
func persistenciaMoveRestauraEApagaDefinitivamente() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()

    // Cria uma pasta de verdade para garantir que o soft delete não toca no
    // áudio e que apenas a confirmação definitiva remove a mídia.
    let armazenamento = try Armazenamento.padrao()
    let id = UUID()
    let pasta = try armazenamento.criarPastaDaGravacao(id: id)
    defer { try? FileManager.default.removeItem(at: pasta) }
    let m4a = pasta.appendingPathComponent(Armazenamento.Nome.microfone)
    try Data("audio".utf8).write(to: m4a)
    #expect(FileManager.default.fileExists(atPath: m4a.path))

    let arquivo = Arquivo(
        id: ArquivoID(rawValue: id),
        titulo: "para apagar",
        pastaRelativa: Armazenamento.caminhoRelativo(id: id),
        espaco: espaco
    )
    try await repo.salvar(arquivo)

    try await repo.moverParaLixeira(arquivo.id)
    #expect(try await repo.listar(espaco: espaco).isEmpty)

    let naLixeira = try #require(try await repo.listarNaLixeira(espaco: espaco).first)
    #expect(naLixeira.id == arquivo.id)
    #expect(naLixeira.apagadoEm != nil)
    #expect(FileManager.default.fileExists(atPath: m4a.path))

    try await repo.restaurar(arquivo.id)
    let restaurado = try #require(try await repo.listar(espaco: espaco).first)
    #expect(restaurado.id == arquivo.id)
    #expect(restaurado.apagadoEm == nil)
    #expect(try await repo.listarNaLixeira(espaco: espaco).isEmpty)
    #expect(FileManager.default.fileExists(atPath: m4a.path))

    try await repo.moverParaLixeira(arquivo.id)
    try await repo.apagar(arquivo.id)

    #expect(try await repo.listar(espaco: espaco).isEmpty)
    #expect(try await repo.listarNaLixeira(espaco: espaco).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: m4a.path))
    #expect(!FileManager.default.fileExists(atPath: pasta.path))
}

@Test("Apagar id inexistente não explode")
func persistenciaApagaInexistente() async throws {
    let repo = try repositorioDeTeste()
    try await repo.apagar(ArquivoID())
}

@Test("Exclusão definitiva exige que o arquivo esteja na lixeira")
func persistenciaExclusaoDefinitivaExigeLixeira() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let arquivo = arquivoDeExemplo(titulo: "ativo", espaco: espaco)
    try await repo.salvar(arquivo)

    await #expect(throws: ErroLixeira.self) {
        try await repo.apagar(arquivo.id)
    }

    #expect(try await repo.listar(espaco: espaco).map(\.id) == [arquivo.id])
}

@Test("Busca normal não mostra arquivos na lixeira")
func buscaIgnoraArquivosNaLixeira() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let arquivo = arquivoDeExemplo(titulo: "Reunião de orçamento", espaco: espaco)
    try await repo.salvar(arquivo)

    #expect(try await repo.buscar(termo: "orçamento", espaco: espaco).map(\.id) == [arquivo.id])

    try await repo.moverParaLixeira(arquivo.id)
    #expect(try await repo.buscar(termo: "orçamento", espaco: espaco).isEmpty)

    try await repo.restaurar(arquivo.id)
    #expect(try await repo.buscar(termo: "orçamento", espaco: espaco).map(\.id) == [arquivo.id])
}

@Test("Busca não mistura resultados de espaços diferentes")
func buscaRespeitaEspaco() async throws {
    let repo = try repositorioDeTeste()
    let espacoAtual = EspacoID()
    let outroEspaco = EspacoID()
    let atual = arquivoDeExemplo(titulo: "Planejamento confidencial", espaco: espacoAtual)
    let deOutroEspaco = arquivoDeExemplo(
        titulo: "Planejamento confidencial", espaco: outroEspaco,
        trechos: [Trecho(start: 0, end: 1, texto: "informação privada", speaker: nil)]
    )
    try await repo.salvar(atual)
    try await repo.salvar(deOutroEspaco)

    #expect(try await repo.buscar(termo: "confidencial", espaco: espacoAtual).map(\.id) == [atual.id])
    #expect(try await repo.buscar(termo: "privada", espaco: espacoAtual).isEmpty)
    #expect(try await repo.buscar(termo: "privada", espaco: outroEspaco).map(\.id) == [deOutroEspaco.id])
}

@Test("Salvar uma atualização tardia não restaura arquivo da lixeira")
func persistenciaNaoRessuscitaArquivoDaLixeira() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    var arquivo = arquivoDeExemplo(titulo: "Entrevista", espaco: espaco)
    try await repo.salvar(arquivo)
    try await repo.moverParaLixeira(arquivo.id)

    // Simula uma atualização que foi criada antes da ação de lixeira, como a
    // persistência final de um pipeline já iniciado. Ela não pode reativar o
    // item por ter `apagadoEm == nil` em memória.
    arquivo.titulo = "Entrevista atualizada"
    try await repo.salvar(arquivo)

    #expect(try await repo.listar(espaco: espaco).isEmpty)
    let naLixeira = try #require(try await repo.listarNaLixeira(espaco: espaco).first)
    #expect(naLixeira.id == arquivo.id)
    #expect(naLixeira.apagadoEm != nil)
}

// MARK: - Passo 9 — busca

@Test("Título tem prioridade sobre corpo, sem duplicar")
func buscaPrioridadeDeTitulo() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()

    // O termo aparece no título de um e no corpo de vários outros.
    try await repo.salvar(arquivoDeExemplo(
        titulo: "Revisão de orçamento", espaco: espaco,
        trechos: [Trecho(start: 0, end: 30, texto: "orçamento apertado", speaker: nil)]
    ))
    for i in 1...3 {
        try await repo.salvar(arquivoDeExemplo(
            titulo: "Reunião \(i)", espaco: espaco,
            trechos: [Trecho(start: 0, end: 30, texto: "falamos de orçamento", speaker: nil)]
        ))
    }

    let resultados = try await repo.buscar(termo: "orçamento", espaco: espaco)

    #expect(resultados.count == 4)
    #expect(resultados.first?.titulo == "Revisão de orçamento")
    // Nenhum duplicado, mesmo estando nos dois buckets.
    #expect(Set(resultados.map(\.id)).count == resultados.count)
}

@Test("Busca por título ordena importações pela entrada na biblioteca")
func buscaPorTituloOrdenaPelaEntradaNaBiblioteca() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let gravacaoMaisRecente = Arquivo(
        titulo: "Orçamento gravado recentemente",
        criadoEm: Date(timeIntervalSinceReferenceDate: 2_000),
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: espaco
    )
    let importacaoMaisRecente = Arquivo(
        titulo: "Orçamento importado agora",
        criadoEm: Date(timeIntervalSinceReferenceDate: 1_000),
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: espaco,
        importadoEm: Date(timeIntervalSinceReferenceDate: 3_000)
    )

    try await repo.salvar(gravacaoMaisRecente)
    try await repo.salvar(importacaoMaisRecente)

    #expect(
        try await repo.buscar(termo: "orçamento", espaco: espaco).map(\.id)
            == [importacaoMaisRecente.id, gravacaoMaisRecente.id]
    )
}

@Test("Busca com e sem acento devolve o mesmo")
func buscaIgnoraAcento() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    try await repo.salvar(arquivoDeExemplo(titulo: "Revisão de Orçamento", espaco: espaco))

    let comAcento = try await repo.buscar(termo: "orçamento", espaco: espaco)
    let semAcento = try await repo.buscar(termo: "orcamento", espaco: espaco)
    let caixaAlta = try await repo.buscar(termo: "ORCAMENTO", espaco: espaco)

    #expect(comAcento.count == 1)
    #expect(semAcento.map(\.id) == comAcento.map(\.id))
    #expect(caixaAlta.map(\.id) == comAcento.map(\.id))
}

@Test("Busca acha no resumo e no insight, não só no trecho")
func buscaNoResumoEInsight() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()

    try await repo.salvar(arquivoDeExemplo(
        titulo: "Sem menção no título", espaco: espaco,
        resumo: Resumo(
            titulo: "Resumo",
            visaoGeral: "Discutimos a migração do armazenamento local.",
            proximosPassos: [ProximoPasso(descricao: "avaliar Brightworks")]
        )
    ))

    #expect(try await repo.buscar(termo: "armazenamento", espaco: espaco).count == 1)
    #expect(try await repo.buscar(termo: "brightworks", espaco: espaco).count == 1)
}

@Test("Busca acha texto de nota temporizada")
func buscaNasNotas() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    let arquivo = arquivoDeExemplo(
        titulo: "Sem menção no título",
        espaco: espaco,
        notas: [NotaDaConversa(texto: "Revisar a cláusula de confidencialidade.", start: 22)]
    )
    try await repo.salvar(arquivo)

    #expect(try await repo.buscar(termo: "confidencialidade", espaco: espaco).map(\.id) == [arquivo.id])
}

@Test("Termo vazio ou sem correspondência devolve lista vazia")
func buscaVazia() async throws {
    let repo = try repositorioDeTeste()
    let espaco = EspacoID()
    try await repo.salvar(arquivoDeExemplo(titulo: "alguma coisa", espaco: espaco))

    #expect(try await repo.buscar(termo: "", espaco: espaco).isEmpty)
    #expect(try await repo.buscar(termo: "   ", espaco: espaco).isEmpty)
    #expect(try await repo.buscar(termo: "termo-que-nao-existe", espaco: espaco).isEmpty)
}
