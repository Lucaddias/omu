import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

@Test("Cleanup estruturado executa em sucesso, erro e cancelamento")
func cleanupDeModelosEhGarantido() async {
    let contador = ContadorDeCleanup()

    let valor = await OperacaoComLimpeza.executar {
        42
    } limpar: {
        await contador.registrar()
    }
    #expect(valor == 42)

    do {
        _ = try await OperacaoComLimpeza.executar {
            throw FalhaDeCleanupTeste()
        } limpar: {
            await contador.registrar()
        }
    } catch {
        #expect(error is FalhaDeCleanupTeste)
    }

    let cancelada = Task {
        try await OperacaoComLimpeza.executar {
            try await Task.sleep(for: .seconds(30))
        } limpar: {
            await contador.registrar()
        }
    }
    cancelada.cancel()
    do {
        try await cancelada.value
    } catch {
        #expect(error is CancellationError)
    }

    #expect(await contador.valor() == 3)
}

private struct FalhaDeCleanupTeste: Error {}

private actor ContadorDeCleanup {
    private var quantidade = 0

    func registrar() { quantidade += 1 }
    func valor() -> Int { quantidade }
}

// A fila serial da `Biblioteca` é a invariante que impede o Whisper (3 GB) e o
// Qwen (10,7 GB) de carregarem ao mesmo tempo num Mac cujo piso é 18 GB. Até
// agora ela não tinha teste nenhum: o `.xcodeproj` tinha um único target.
//
// Os testes não carregam modelo. A pasta de pesos aponta para um diretório
// temporário vazio, então o `Preflight` reprova logo no começo de
// `executarProcessamento` e o pipeline retorna cedo — o que exercita
// exatamente a mecânica da fila (entrar, virar ativo, terminar, chamar o
// próximo) sem tocar em 13,7 GB.

@MainActor
private func bibliotecaDeTeste() throws -> (Biblioteca, URL) {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)

    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal(
                nome: UUID().uuidString, emMemoria: true
            )
        ),
        espaco: EspacoID()
    )
    return (biblioteca, raiz)
}

/// Espera uma condição virar verdadeira, com teto. Evita `sleep` fixo, que ou
/// deixa o teste lento ou o deixa instável.
@MainActor
private func aguardar(
    ate limite: TimeInterval = 5,
    _ condicao: () -> Bool
) async -> Bool {
    let fim = Date().addingTimeInterval(limite)
    while Date() < fim {
        if condicao() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condicao()
}

@Test("Migração de remoção de equipes apaga o estado legado uma única vez")
func migracaoDeRemocaoDeEquipesLimpaSomenteEstadoLegado() throws {
    let suite = "MigracaoDeRemocaoDeEquipesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(Data([1]), forKey: "membrosDaEquipe.primeira")
    defaults.set(Data([2]), forKey: "membrosDaEquipe.segunda")
    defaults.set(Data([3]), forKey: "equipesDoUsuario")
    defaults.set("primeira", forKey: "equipeAtiva")
    defaults.set("equipe", forKey: "contextoDaConta")
    defaults.set(true, forKey: "limpezaDeDadosFabricados.v1")
    defaults.set("permanece", forKey: "preferenciaSemRelacao")

    MigracaoDeRemocaoDeEquipes.executarUmaVez(defaults)

    #expect(defaults.object(forKey: "membrosDaEquipe.primeira") == nil)
    #expect(defaults.object(forKey: "membrosDaEquipe.segunda") == nil)
    #expect(defaults.object(forKey: "equipesDoUsuario") == nil)
    #expect(defaults.object(forKey: "equipeAtiva") == nil)
    #expect(defaults.object(forKey: "contextoDaConta") == nil)
    #expect(defaults.object(forKey: "limpezaDeDadosFabricados.v1") == nil)
    #expect(defaults.string(forKey: "preferenciaSemRelacao") == "permanece")

    // Depois de concluída, a migração não deve apagar preferências que uma
    // versão futura venha a gravar com o antigo prefixo por coincidência.
    defaults.set(Data([4]), forKey: "membrosDaEquipe.posterior")
    MigracaoDeRemocaoDeEquipes.executarUmaVez(defaults)
    #expect(defaults.data(forKey: "membrosDaEquipe.posterior") == Data([4]))
}

@Test("Migração de equipes reúne ativos e lixeira no espaço pessoal")
func migracaoDeEquipesPreservaBibliotecaCompleta() async throws {
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString, emMemoria: true
        )
    )
    let pessoal = EspacoID()
    let equipe = EspacoID()
    let outroEspacoLegado = EspacoID()
    let ativoDaEquipe = Arquivo(
        titulo: "Reunião da equipe",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: equipe
    )
    let naLixeira = Arquivo(
        titulo: "Conversa arquivada",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: outroEspacoLegado
    )

    try await repositorio.salvar(ativoDaEquipe)
    try await repositorio.salvar(naLixeira)
    try await repositorio.moverParaLixeira(naLixeira.id)

    try await repositorio.migrarTodosOsEspacos(para: pessoal)

    #expect(try await repositorio.listar(espaco: pessoal).map(\.id) == [ativoDaEquipe.id])
    #expect(try await repositorio.listarNaLixeira(espaco: pessoal).map(\.id) == [naLixeira.id])
    #expect(try await repositorio.listar(espaco: equipe).isEmpty)
    #expect(try await repositorio.listarNaLixeira(espaco: outroEspacoLegado).isEmpty)
}

// MARK: - Fila serial

@MainActor
@Test("Dois arquivos na fila nunca processam ao mesmo tempo")
func filaProcessaUmPorVez() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Primeira", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)
    await biblioteca.registrar(titulo: "Segunda", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)

    let primeira = try #require(biblioteca.arquivos.last)
    let segunda = try #require(biblioteca.arquivos.first)

    biblioteca.enfileirarProcessamento(primeira)
    biblioteca.enfileirarProcessamento(segunda)

    // Enquanto a fila roda, no máximo um arquivo pode estar ativo.
    var maiorSimultaneo = 0
    _ = await aguardar {
        let ativos = [primeira, segunda].filter { biblioteca.estaProcessando($0) }.count
        maiorSimultaneo = max(maiorSimultaneo, ativos)
        return !biblioteca.processando
    }

    #expect(maiorSimultaneo <= 1, "houve \(maiorSimultaneo) arquivos processando juntos")
    #expect(!biblioteca.processando)
}

@MainActor
@Test("O mesmo arquivo não entra duas vezes na fila")
func naoDuplicaNaFila() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Única", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)
    let arquivo = try #require(biblioteca.arquivos.first)

    biblioteca.enfileirarProcessamento(arquivo)
    biblioteca.enfileirarProcessamento(arquivo)
    biblioteca.enfileirarProcessamento(arquivo)

    _ = await aguardar { !biblioteca.processando }
    #expect(!biblioteca.estaNaFila(arquivo))
}

@MainActor
@Test("Duplicar recria os bookmarks dos anexos na pasta copiada")
func duplicacaoMantemAnexosVisiveisNaCopia() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    let pastaOriginal = Armazenamento.caminhoRelativo(id: UUID())
    let original = try #require(
        await biblioteca.registrar(titulo: "Com anexo", pastaRelativa: pastaOriginal, duracao: 30)
    )
    defer { MidiasDaConversa.remover(original.id) }

    let raizOriginal = raiz.appendingPathComponent(pastaOriginal, isDirectory: true)
    let pastaDeAnexos = raizOriginal.appendingPathComponent("documentos", isDirectory: true)
    try FileManager.default.createDirectory(at: pastaDeAnexos, withIntermediateDirectories: true)
    let anexoOriginal = pastaDeAnexos.appendingPathComponent("roteiro.pdf")
    try Data("conteúdo".utf8).write(to: anexoOriginal)
    try MidiasDaConversa.salvar(
        [try MidiasDaConversa.anexo(para: anexoOriginal)],
        para: original.id
    )

    let copia = try #require(await biblioteca.duplicar(original))
    defer { MidiasDaConversa.remover(copia.id) }

    let anexosDaCopia = MidiasDaConversa.carregar(copia.id)
    let esperado = raiz
        .appendingPathComponent(copia.pastaRelativa, isDirectory: true)
        .appendingPathComponent("documentos/roteiro.pdf")
        .standardizedFileURL
    #expect(anexosDaCopia.map(\.url.standardizedFileURL) == [esperado])
    #expect(FileManager.default.fileExists(atPath: esperado.path))
}

@MainActor
@Test("Duplicar preserva o estado das tarefas com novos ids")
func duplicacaoMantemTarefasIndependentes() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    let original = try #require(
        await biblioteca.registrar(
            titulo: "Com tarefas",
            pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
            duracao: 30
        )
    )
    defer { TarefasGeraisStore.remover(original.id) }

    let prazo = Date(timeIntervalSinceReferenceDate: 12_345)
    let tarefaOriginal = TarefaDaConversa(
        titulo: "Enviar ata",
        origem: original.titulo,
        prioridade: .baixa,
        status: .emAndamento,
        responsavel: "Ana",
        prazo: prazo,
        descricao: "Incluir os encaminhamentos.",
        sugestaoPendente: true,
        prioridadeDefinidaManualmente: true,
        atrasoReconhecido: true
    )
    TarefasGeraisStore.salvar([tarefaOriginal], para: original.id)

    let copia = try #require(await biblioteca.duplicar(original))
    defer { TarefasGeraisStore.remover(copia.id) }

    let tarefasDaCopia = TarefasGeraisStore.carregar(copia)
    #expect(tarefasDaCopia.count == 1)
    let tarefaDaCopia = try #require(tarefasDaCopia.first)
    #expect(tarefaDaCopia.id != tarefaOriginal.id)
    #expect(tarefaDaCopia.titulo == tarefaOriginal.titulo)
    #expect(tarefaDaCopia.origem == copia.titulo)
    #expect(tarefaDaCopia.prioridade == tarefaOriginal.prioridade)
    #expect(tarefaDaCopia.status == tarefaOriginal.status)
    #expect(tarefaDaCopia.responsavel == tarefaOriginal.responsavel)
    #expect(tarefaDaCopia.prazo == prazo)
    #expect(tarefaDaCopia.descricao == tarefaOriginal.descricao)
    #expect(tarefaDaCopia.pendenteDeRevisao)
    #expect(tarefaDaCopia.prioridadeEhManual)
    #expect(tarefaDaCopia.atrasoFoiReconhecido)
}

// B-01: `pastaRelativa` vazia resolvia para a raiz do armazenamento, e a
// duplicação copiava a biblioteca inteira (e os modelos) para dentro da cópia.
@MainActor
@Test("Duplicar conversa sem áudio copia só o registro, nunca a raiz do armazenamento")
func duplicacaoSemAudioNaoCopiaARaiz() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    // Conteúdo que não pode ser arrastado para dentro de uma cópia.
    let modelos = raiz.appendingPathComponent(Armazenamento.pastaModelos, isDirectory: true)
    try FileManager.default.createDirectory(at: modelos, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 1_024).write(to: modelos.appendingPathComponent("pesos.gguf"))

    let reuniao = ReuniaoExterna(
        id: "reuniao-1",
        titulo: "Reunião do Granola",
        data: Date(timeIntervalSinceReferenceDate: 1_000),
        notas: "Pauta",
        resumo: "Resumo pronto",
        transcricao: nil
    )
    let original = try #require(await biblioteca.registrarExterna(reuniao, identificador: "granola"))
    #expect(original.semAudio)

    let copia = try #require(await biblioteca.duplicar(original))
    defer { TarefasGeraisStore.remover(copia.id) }

    #expect(copia.semAudio)
    #expect(copia.id != original.id)
    #expect(copia.notas.map(\.texto) == ["Pauta"])
    #expect(biblioteca.arquivos.contains { $0.id == copia.id })

    let gravacoes = raiz.appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
    let conteudo = (try? FileManager.default.contentsOfDirectory(atPath: gravacoes.path)) ?? []
    #expect(conteudo.isEmpty, "a duplicação criou \(conteudo) em Gravacoes/")
}

@MainActor
@Test("Processamento automático desligado não enfileira ao registrar")
func automaticoDesligadoNaoEnfileira() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Pausada", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)

    let arquivo = try #require(biblioteca.arquivos.first)
    #expect(!biblioteca.processando)
    #expect(biblioteca.estado(de: arquivo) == .prontoParaTranscrever)
}

// MARK: - Estado

@MainActor
@Test("Estado de um arquivo recém-registrado é pronto para transcrever")
func estadoInicial() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Nova", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 30)
    let arquivo = try #require(biblioteca.arquivos.first)

    #expect(biblioteca.estado(de: arquivo) == .prontoParaTranscrever)
    #expect(!biblioteca.estado(de: arquivo).ocupado)
}

@MainActor
@Test("Falta de pesos vira estado de falha, não silêncio")
func faltaDePesosViraFalha() async throws {
    // A pasta de modelos está vazia: o `Preflight` reprova e o motivo precisa
    // chegar ao usuário como estado, não sumir.
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Sem pesos", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)
    let arquivo = try #require(biblioteca.arquivos.first)

    biblioteca.enfileirarProcessamento(arquivo)
    _ = await aguardar { !biblioteca.processando }

    guard case .falhou = biblioteca.estado(de: arquivo) else {
        Issue.record("esperava .falhou, veio \(biblioteca.estado(de: arquivo))")
        return
    }
}

// MARK: - Lixeira e fila

@MainActor
@Test("Mover para a lixeira tira o arquivo da fila")
func lixeiraRemoveDaFila() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "A", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)
    await biblioteca.registrar(titulo: "B", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60)

    let primeira = try #require(biblioteca.arquivos.last)
    let segunda = try #require(biblioteca.arquivos.first)
    biblioteca.enfileirarProcessamento(primeira)
    biblioteca.enfileirarProcessamento(segunda)

    await biblioteca.moverParaLixeira(segunda)

    #expect(!biblioteca.estaNaFila(segunda))
    #expect(biblioteca.arquivosNaLixeira.contains { $0.id == segunda.id })
    _ = await aguardar { !biblioteca.processando }
}

@MainActor
@Test("Apagar definitivamente esquece as preferências visuais do arquivo")
func exclusaoLimpaPreferencias() async throws {
    // Sem isto, cada arquivo apagado deixava três chaves órfãs em UserDefaults
    // para sempre.
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    await biblioteca.registrar(titulo: "Com favorito", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 30)
    let arquivo = try #require(biblioteca.arquivos.first)

    // O caminho precisa ser o canonico `Gravacoes/<UUID>`: `apagar` recusa
    // qualquer outra coisa antes de remover, e a limpeza nunca aconteceria.
    PreferenciasVisuaisDoArquivo.definirFavorito(true, para: arquivo.id)
    PreferenciasVisuaisDoArquivo.definirPasta("Clientes", para: arquivo.id)
    #expect(PreferenciasVisuaisDoArquivo.favorito(arquivo.id))

    await biblioteca.moverParaLixeira(arquivo)
    let naLixeira = try #require(biblioteca.arquivosNaLixeira.first)
    await biblioteca.apagarDefinitivamente(naLixeira)

    #expect(!PreferenciasVisuaisDoArquivo.favorito(arquivo.id))
    #expect(PreferenciasVisuaisDoArquivo.pasta(arquivo.id) == nil)
}

@MainActor
@Test("Erro de carregamento fica visível em vez de sumir num dicionário")
func erroDeCarregamentoEhObservavel() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    await biblioteca.carregar()
    // Container em memória e vazio: carrega sem erro, e o campo precisa ficar
    // limpo em vez de guardar lixo de execuções anteriores.
    #expect(biblioteca.erroDeCarregamento == nil)
}

@MainActor
@Test("Excluir o perfil limpa só auxiliares dos arquivos pessoais e é idempotente")
func exclusaoDaContaLimpaStoresDoEspacoPessoal() throws {
    let suite = "LimpezaDeContaTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let pessoal = ArquivoID()
    let equipe = ArquivoID()
    let sufixoPessoal = pessoal.rawValue.uuidString
    let sufixoEquipe = equipe.rawValue.uuidString
    let prefixosPorArquivo = [
        "tarefasDaConversa.", "midiasDaConversa.", "arquivoFavorito.",
        "arquivoPasta.", "arquivoCapa.", "arquivoMetadados.",
        "arquivoNomesDeVoz.", "corDaFaixaDoCartao.", "bannerDoCartao.",
        "ajusteDoBannerDoCartao.", "faixaSemCorDoCartao.",
    ]
    for prefixo in prefixosPorArquivo {
        defaults.set(Data([1]), forKey: prefixo + sufixoPessoal)
        defaults.set(Data([2]), forKey: prefixo + sufixoEquipe)
    }

    // Estes stores não têm dono por espaço. A opção A os preserva porque
    // podem continuar servindo às conversas da equipe.
    defaults.set(["Cliente"], forKey: "pastasDaBiblioteca")
    defaults.set(Data([3]), forKey: "corDaPasta.Cliente")
    defaults.set(Data([4]), forKey: "fotoDaPessoa.ana")
    defaults.set("escuro", forKey: "aparenciaDoApp")
    defaults.set(false, forKey: "processamentoAutomatico")
    defaults.set(UUID().uuidString, forKey: "espacoIndividual")

    LimpezaDeConta.executar(arquivos: [pessoal], em: defaults)
    LimpezaDeConta.executar(arquivos: [pessoal], em: defaults)

    for prefixo in prefixosPorArquivo {
        #expect(defaults.object(forKey: prefixo + sufixoPessoal) == nil)
        #expect(defaults.object(forKey: prefixo + sufixoEquipe) != nil)
    }
    #expect(defaults.stringArray(forKey: "pastasDaBiblioteca") == ["Cliente"])
    #expect(defaults.object(forKey: "corDaPasta.Cliente") != nil)
    #expect(defaults.object(forKey: "fotoDaPessoa.ana") != nil)
    #expect(defaults.string(forKey: "aparenciaDoApp") == "escuro")
    #expect(defaults.object(forKey: "processamentoAutomatico") != nil)
    #expect(defaults.object(forKey: "espacoIndividual") == nil)
}

@MainActor
@Test("Excluir o perfil cria um novo espaço pessoal estável no relançamento")
func exclusaoDaContaRenovaEspacoPessoalNoRelancamento() throws {
    let suite = "EspacoAposExclusaoTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let anterior = Biblioteca.espacoPessoal(em: defaults)
    LimpezaDeConta.executar(arquivos: [], em: defaults)
    let novo = Biblioteca.espacoPessoal(em: defaults)
    let restauradoNoRelancamento = Biblioteca.espacoPessoal(em: defaults)

    #expect(novo != anterior)
    #expect(restauradoNoRelancamento == novo)
}

private final class CofreDeCredenciaisFake: CofreDeCredenciaisDaConta, @unchecked Sendable {
    var contas: Set<String>

    init(_ contas: Set<String>) {
        self.contas = contas
    }

    func apagar(conta: String) {
        contas.remove(conta)
    }
}

@Test("Excluir o perfil apaga credenciais Google e Granola sem herança")
func exclusaoDaContaLimpaCredenciaisDasIntegracoes() {
    let google = CofreDeCredenciaisFake([
        "access_token", "access_token_expires", "refresh_token", "pkce", "outra",
    ])
    let granola = CofreDeCredenciaisFake([
        "access_token", "access_token_expires", "refresh_token", "client", "pkce", "outra",
    ])

    LimpezaDeCredenciaisDaConta.executar(google: google, granola: granola)
    LimpezaDeCredenciaisDaConta.executar(google: google, granola: granola)

    #expect(google.contas == ["outra"])
    #expect(granola.contas == ["outra"])
}

@Test("Excluir o perfil persiste a remoção dos vínculos de equipe")
func exclusaoDaContaRemoveEquipesNoRelancamento() throws {
    let suite = "EquipesAposExclusaoTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let equipe = EquipeDisponivel(
        id: "produto", nome: "Produto", papel: "Administrador",
        quantidadeDeMembros: 1, espacoID: UUID().uuidString
    )
    let membro = MembroDaEquipe(
        nome: "Ana", email: "ana@example.com", cargo: "Design",
        status: .ativo
    )
    EquipesDoUsuario.salvar([equipe], em: defaults)
    MembrosDasEquipes.salvar([membro], equipeID: equipe.id, em: defaults)
    defaults.set(equipe.id, forKey: "equipeAtiva")
    defaults.set("equipe", forKey: "contextoDaConta")
    defaults.set("preservar", forKey: "preferenciaGlobal")

    LimpezaDeVinculosDeEquipe.executar(equipes: [equipe], em: defaults)
    LimpezaDeVinculosDeEquipe.executar(equipes: [equipe], em: defaults)

    #expect(EquipesDoUsuario.carregar(em: defaults).isEmpty)
    #expect(MembrosDasEquipes.carregar(equipeID: equipe.id, em: defaults).isEmpty)
    #expect(defaults.object(forKey: "equipeAtiva") == nil)
    #expect(defaults.object(forKey: "contextoDaConta") == nil)
    #expect(defaults.string(forKey: "preferenciaGlobal") == "preservar")
}

@MainActor
@Test("Excluir o perfil pessoal com equipe ativa preserva o espaço da equipe")
func exclusaoDaContaPreservaMidiaDeOutroEspaco() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }

    let armazenamento = Armazenamento(raiz: raiz)
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString, emMemoria: true
        )
    )
    let espacoAtual = EspacoID()
    let outroEspaco = EspacoID()
    let bibliotecaAtual = Biblioteca(
        armazenamento: armazenamento, repositorio: repositorio, espaco: espacoAtual
    )
    let bibliotecaDoOutroEspaco = Biblioteca(
        armazenamento: armazenamento, repositorio: repositorio, espaco: outroEspaco
    )
    bibliotecaAtual.processamentoAutomatico = false
    bibliotecaDoOutroEspaco.processamentoAutomatico = false

    let pastaAtual = Armazenamento.caminhoRelativo(id: UUID())
    let pastaDoOutroEspaco = Armazenamento.caminhoRelativo(id: UUID())
    let arquivoAtual = try #require(
        await bibliotecaAtual.registrar(titulo: "Minha conversa", pastaRelativa: pastaAtual, duracao: 30)
    )
    let arquivoDoOutroEspaco = try #require(
        await bibliotecaDoOutroEspaco.registrar(
            titulo: "Conversa da outra conta", pastaRelativa: pastaDoOutroEspaco, duracao: 30
        )
    )
    try FileManager.default.createDirectory(
        at: armazenamento.resolver(relativo: arquivoAtual.pastaRelativa),
        withIntermediateDirectories: true
    )
    let audioDoOutroEspaco = armazenamento
        .resolver(relativo: arquivoDoOutroEspaco.pastaRelativa)
        .appendingPathComponent(Armazenamento.Nome.microfone)
    try FileManager.default.createDirectory(
        at: audioDoOutroEspaco.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("preservar".utf8).write(to: audioDoOutroEspaco)

    let idsExcluidos = try await bibliotecaDoOutroEspaco.excluirDadosDaConta(
        espaco: espacoAtual
    )

    #expect(idsExcluidos == [arquivoAtual.id])
    #expect(try await repositorio.listar(espaco: espacoAtual).isEmpty)
    #expect(bibliotecaDoOutroEspaco.arquivos.map(\.id) == [arquivoDoOutroEspaco.id])
    #expect(FileManager.default.fileExists(atPath: audioDoOutroEspaco.path))
    #expect(try await repositorio.listar(espaco: outroEspaco).map(\.id) == [arquivoDoOutroEspaco.id])
}

@MainActor
@Test("Callback tardio não recria conversa nem deixa mídia após excluir o perfil")
func exclusaoDaContaBloqueiaRegistroTardio() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }

    let espaco = EspacoID()
    let armazenamento = Armazenamento(raiz: raiz)
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString, emMemoria: true
        )
    )
    let biblioteca = Biblioteca(
        armazenamento: armazenamento, repositorio: repositorio, espaco: espaco
    )

    _ = try await biblioteca.excluirDadosDaConta()

    let pastaRelativa = Armazenamento.caminhoRelativo(id: UUID())
    let pasta = armazenamento.resolver(relativo: pastaRelativa)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    try Data("tardio".utf8).write(
        to: pasta.appendingPathComponent(Armazenamento.Nome.microfone)
    )

    let recriado = await biblioteca.registrar(
        titulo: "Não deve voltar", pastaRelativa: pastaRelativa, duracao: 10
    )

    #expect(recriado == nil)
    #expect(try await repositorio.listar(espaco: espaco).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: pasta.path))
}

@MainActor
@Test("Excluir uma conversa limpa só os dados auxiliares daquele arquivo")
func exclusaoDeArquivoLimpaSomenteSeuEstado() throws {
    let suite = "LimpezaDeArquivoTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let alvo = ArquivoID()
    let outro = ArquivoID()
    let sufixo = alvo.rawValue.uuidString
    let sufixoDoOutro = outro.rawValue.uuidString
    let chavesDoAlvo = [
        "tarefasDaConversa.\(sufixo)", "midiasDaConversa.\(sufixo)",
        "arquivoFavorito.\(sufixo)", "arquivoPasta.\(sufixo)",
        "arquivoCapa.\(sufixo)", "arquivoMetadados.\(sufixo)",
        "arquivoNomesDeVoz.\(sufixo)", "corDaFaixaDoCartao.\(sufixo)",
        "bannerDoCartao.\(sufixo)", "ajusteDoBannerDoCartao.\(sufixo)",
        "faixaSemCorDoCartao.\(sufixo)",
    ]
    for chave in chavesDoAlvo { defaults.set(Data([1]), forKey: chave) }
    defaults.set(Data([2]), forKey: "tarefasDaConversa.\(sufixoDoOutro)")

    let tarefa = TarefaDaConversa(
        titulo: "Revisar", origem: "Conversa", prioridade: .media,
        status: .naoIniciado, responsavel: nil, prazo: nil
    )
    let tarefasNaLixeira = [
        TarefaNaLixeira(arquivoID: alvo, conversaTitulo: "Alvo", tarefa: tarefa),
        TarefaNaLixeira(arquivoID: outro, conversaTitulo: "Outra", tarefa: tarefa),
    ]
    defaults.set(try JSONEncoder().encode(tarefasNaLixeira), forKey: "tarefasNaLixeira")

    let midiasNaLixeira = [
        MidiaNaLixeira(
            arquivoID: alvo, conversaTitulo: "Alvo", nome: "a.wav", tamanho: 1,
            tipo: "Áudio", daGravacao: false, caminhoOriginal: "/a", caminhoNaLixeira: "/b"
        ),
        MidiaNaLixeira(
            arquivoID: outro, conversaTitulo: "Outra", nome: "b.wav", tamanho: 1,
            tipo: "Áudio", daGravacao: false, caminhoOriginal: "/c", caminhoNaLixeira: "/d"
        ),
    ]
    defaults.set(try JSONEncoder().encode(midiasNaLixeira), forKey: "midiaNaLixeira")

    let estado = AparenciaDasPastas.Estado(
        preset: nil, corLivre: nil, favorita: false, semCor: nil,
        criadaEm: nil, capa: nil
    )
    let pastasNaLixeira = [
        PastaNaLixeira(nome: "Cliente", conversas: [alvo.rawValue, outro.rawValue], aparencia: estado),
    ]
    defaults.set(try JSONEncoder().encode(pastasNaLixeira), forKey: "pastasNaLixeira")

    LimpezaDeArquivo.executar(alvo, em: defaults)

    for chave in chavesDoAlvo {
        #expect(defaults.object(forKey: chave) == nil, "sobrou \(chave)")
    }
    #expect(defaults.data(forKey: "tarefasDaConversa.\(sufixoDoOutro)") == Data([2]))
    #expect(try JSONDecoder().decode([TarefaNaLixeira].self, from: #require(defaults.data(forKey: "tarefasNaLixeira"))).map(\.arquivoID) == [outro])
    #expect(try JSONDecoder().decode([MidiaNaLixeira].self, from: #require(defaults.data(forKey: "midiaNaLixeira"))).map(\.arquivoID) == [outro])
    #expect(try JSONDecoder().decode([PastaNaLixeira].self, from: #require(defaults.data(forKey: "pastasNaLixeira"))).first?.conversas == [outro.rawValue])
}

@Test("Apagar anexo não aceita pasta irmã com o mesmo prefixo")
func apagarAnexoRecusaPastaIrma() throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let conversa = raiz.appendingPathComponent("Conversa", isDirectory: true)
    let irma = raiz.appendingPathComponent("Conversa-antiga", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: irma, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }

    let externo = irma.appendingPathComponent("nao-apagar.txt")
    try Data("preservar".utf8).write(to: externo)
    let anexo = AnexoDeMidiaDaConversa(
        id: UUID(), nome: externo.lastPathComponent, tamanho: 9,
        data: Date(), url: externo
    )

    #expect(throws: MidiasDaConversa.Erro.arquivoForaDaConversa) {
        try MidiasDaConversa.apagarArquivoSalvo(anexo, pastaDaConversa: conversa)
    }
    #expect(FileManager.default.fileExists(atPath: externo.path))
}

@Test("Apagar anexo remove arquivo realmente contido na conversa")
func apagarAnexoInterno() throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let conversa = raiz.appendingPathComponent("Conversa", isDirectory: true)
    let midia = conversa.appendingPathComponent("Mídia", isDirectory: true)
    try FileManager.default.createDirectory(at: midia, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }

    let interno = midia.appendingPathComponent("apagar.txt")
    try Data("apagar".utf8).write(to: interno)
    let anexo = AnexoDeMidiaDaConversa(
        id: UUID(), nome: interno.lastPathComponent, tamanho: 6,
        data: Date(), url: interno
    )

    try MidiasDaConversa.apagarArquivoSalvo(anexo, pastaDaConversa: conversa)

    #expect(!FileManager.default.fileExists(atPath: interno.path))
}

@Test("Exportar conversas com o mesmo título cria pastas distintas e completas")
func exportacaoNaoMisturaTitulosIguais() throws {
    let origem = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: origem, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: origem) }

    var conversas: [(arquivo: Arquivo, audio: URL)] = []
    for indice in 1...2 {
        let pasta = origem.appendingPathComponent("origem-\(indice)", isDirectory: true)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let audio = pasta.appendingPathComponent(Armazenamento.Nome.microfone)
        try Data("audio-\(indice)".utf8).write(to: audio)
        conversas.append((
            Arquivo(
                titulo: "Entrevista repetida",
                pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
                espaco: EspacoID()
            ),
            audio
        ))
    }

    let exportada = try DossieDaConversa.pastaComTudo(
        nome: "Cliente/Projeto", conversas: conversas
    )

    #expect(exportada.lastPathComponent == "Cliente-Projeto")
    let pastas = try FileManager.default.contentsOfDirectory(
        at: exportada, includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    #expect(pastas.count == 2)
    #expect(Set(pastas.map(\.lastPathComponent)).count == 2)
    for pasta in pastas {
        let itens = try FileManager.default.contentsOfDirectory(atPath: pasta.path)
        #expect(itens.contains(Armazenamento.Nome.microfone))
        #expect(itens.contains("entrevista-repetida.md"))
    }

    let raizTemporaria = exportada.deletingLastPathComponent()
    DossieDaConversa.descartarPastaTemporaria(exportada)
    #expect(!FileManager.default.fileExists(atPath: raizTemporaria.path))
}

@Test("Exportar uma conversa descarta a pasta intermediária após criar o zip")
func pacoteDaConversaNaoAcumulaPastaIntermediaria() throws {
    let fm = FileManager.default
    let origem = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: origem, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: origem) }

    let audio = origem.appendingPathComponent(Armazenamento.Nome.microfone)
    try Data("audio".utf8).write(to: audio)
    let arquivo = Arquivo(
        titulo: "Pacote temporário \(UUID().uuidString)",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: EspacoID()
    )
    let base = DossieDaConversa.nomeDeArquivo(para: arquivo).replacingOccurrences(of: ".md", with: "")

    let pacote = try DossieDaConversa.pacoteComAudio(arquivo: arquivo, audioPrincipal: audio)

    let intermediarias = try fm.contentsOfDirectory(
        at: fm.temporaryDirectory,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { url in
        url.lastPathComponent.hasPrefix("\(base)-")
            && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    #expect(intermediarias.isEmpty)
    #expect(fm.fileExists(atPath: pacote.path))

    let raizDoPacote = pacote.deletingLastPathComponent()
    DossieDaConversa.descartarArquivoTemporario(pacote)
    #expect(!fm.fileExists(atPath: raizDoPacote.path))
}

@Test("Compactar pasta mantém o nome do pacote e permite limpar o temporário")
func zipDaPastaMantemNomeELimpeza() throws {
    let fm = FileManager.default
    let pasta = fm.temporaryDirectory
        .appendingPathComponent("Projeto-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: pasta) }
    try Data("conteúdo".utf8).write(to: pasta.appendingPathComponent("nota.txt"))

    let zip = try DossieDaConversa.zipar(pasta)

    #expect(zip.lastPathComponent == "\(pasta.lastPathComponent).zip")
    #expect(fm.fileExists(atPath: zip.path))

    let raizDoZip = zip.deletingLastPathComponent()
    DossieDaConversa.descartarArquivoTemporario(zip)
    #expect(!fm.fileExists(atPath: raizDoZip.path))
}

@Test("Fallback Markdown usa raiz temporária exclusiva e removível")
func markdownTemporarioTemCicloDeVidaSeguro() throws {
    let fm = FileManager.default
    let arquivo = Arquivo(
        titulo: "Fallback \(UUID().uuidString)",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        espaco: EspacoID()
    )

    let markdown = try DossieDaConversa.markdownTemporario(arquivo: arquivo)

    #expect(markdown.lastPathComponent == DossieDaConversa.nomeDeArquivo(para: arquivo))
    #expect(fm.fileExists(atPath: markdown.path))

    let raiz = markdown.deletingLastPathComponent()
    DossieDaConversa.descartarArquivoTemporario(markdown)
    #expect(!fm.fileExists(atPath: raiz.path))
}

// MARK: - Edições não se perdem

/// Registra uma conversa com dois trechos já transcritos e devolve a versão
/// completa — a que a tela de detalhe recebe.
@MainActor
private func conversaTranscrita(em biblioteca: Biblioteca) async throws -> Arquivo {
    biblioteca.processamentoAutomatico = false
    let registrada = try #require(await biblioteca.registrar(
        titulo: "Entrevista",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        duracao: 60
    ))
    await biblioteca.atualizarTrechos(
        [
            Trecho(start: 0, end: 2, texto: "primeiro trecho", speaker: "Eu"),
            Trecho(start: 2, end: 4, texto: "segundo trecho", speaker: "Interlocutor"),
        ],
        de: registrada
    )
    return try #require(try await biblioteca.buscarArquivoCompleto(id: registrada.id.rawValue))
}

@MainActor
@Test("Cada edição publica uma revisão nova, e duas correções em sequência sobrevivem as duas")
func correcoesEmSequenciaNaoSeApagam() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let aberta = try await conversaTranscrita(em: biblioteca)
    let id = aberta.id.rawValue

    // Primeira correção, calculada sobre a versão que a tela tem em mãos.
    let revisaoAntes = biblioteca.revisao(de: id)
    var trechos = aberta.trechos
    trechos[0] = Trecho(id: trechos[0].id, start: 0, end: 2, texto: "primeiro corrigido", speaker: "Eu")
    await biblioteca.atualizarTrechos(trechos, de: aberta)

    // É a revisão que faz o detalhe recarregar: sem ela, a segunda correção
    // partiria da lista antiga e desfaria a primeira.
    #expect(biblioteca.revisao(de: id) > revisaoAntes)
    let recarregada = try #require(try await biblioteca.buscarArquivoCompleto(id: id))
    #expect(recarregada.trechos.map(\.texto) == ["primeiro corrigido", "segundo trecho"])

    var segundos = recarregada.trechos
    segundos[1] = Trecho(id: segundos[1].id, start: 2, end: 4, texto: "segundo corrigido", speaker: "Interlocutor")
    await biblioteca.atualizarTrechos(segundos, de: recarregada)

    let final = try #require(try await biblioteca.buscarArquivoCompleto(id: id))
    #expect(final.trechos.map(\.texto) == ["primeiro corrigido", "segundo corrigido"])
}

@MainActor
@Test("Renomear marca o título como escolhido pela pessoa")
func renomearMarcaTituloManual() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let aberta = try await conversaTranscrita(em: biblioteca)
    #expect(aberta.tituloManual != true)

    await biblioteca.renomear(aberta, para: "Entrevista com a Ana")

    let salvo = try #require(try await biblioteca.buscarArquivoCompleto(id: aberta.id.rawValue))
    #expect(salvo.titulo == "Entrevista com a Ana")
    #expect(salvo.tituloManual == true)
}

@MainActor
@Test("Salvar a ficha sem trocar o título não o congela como manual")
func fichaSemTrocarTituloNaoMarcaManual() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let aberta = try await conversaTranscrita(em: biblioteca)

    await biblioteca.atualizarMetadados(
        aberta,
        titulo: aberta.titulo,
        criadoEm: Date(timeIntervalSinceReferenceDate: 5_000),
        duracao: 90
    )

    let salvo = try #require(try await biblioteca.buscarArquivoCompleto(id: aberta.id.rawValue))
    #expect(salvo.duracao == 90)
    #expect(salvo.tituloManual != true)
}

@MainActor
@Test("Fechar a conversa sem editar as notas não regrava nem publica revisão")
func notasIguaisNaoRegravam() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let aberta = try await conversaTranscrita(em: biblioteca)
    let id = aberta.id.rawValue
    let nota = NotaDaConversa(texto: "Decisão", start: 3)
    await biblioteca.atualizarNotas([nota], de: aberta)
    let revisao = biblioteca.revisao(de: id)

    await biblioteca.atualizarNotas([nota], de: aberta)

    #expect(biblioteca.revisao(de: id) == revisao)
}

@MainActor
@Test("Gerar novo resumo sem transcrição avisa em vez de transcrever de novo")
func novoResumoSemTranscricaoNaoTranscreve() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    biblioteca.processamentoAutomatico = false
    let arquivo = try #require(await biblioteca.registrar(
        titulo: "Sem texto",
        pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()),
        duracao: 60
    ))

    biblioteca.enfileirarNovoResumo(arquivo)
    _ = await aguardar { !biblioteca.processando }

    #expect(biblioteca.erros[arquivo.id.rawValue] == "Não há transcrição para resumir.".localized)
}

@MainActor
@Test("Reprocessar pede confirmação quando já há transcrição, e respeita o não")
func reprocessarPedeConfirmacao() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let aberta = try await conversaTranscrita(em: biblioteca)
    var perguntas = 0
    biblioteca.confirmarReprocessamento = { _ in
        perguntas += 1
        return false
    }

    biblioteca.reprocessar(aberta)

    #expect(perguntas == 1)
    #expect(!biblioteca.processando)
    #expect(!biblioteca.estaNaFila(aberta))
}

@MainActor
@Test("Reprocessar conversa sem áudio é recusado sem perguntar nada")
func reprocessarSemAudioEhRecusado() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let reuniao = ReuniaoExterna(
        id: "reuniao-2",
        titulo: "Só texto",
        data: Date(timeIntervalSinceReferenceDate: 2_000),
        notas: nil,
        resumo: "Resumo pronto",
        transcricao: nil
    )
    let externa = try #require(await biblioteca.registrarExterna(reuniao, identificador: "granola"))
    var perguntas = 0
    biblioteca.confirmarReprocessamento = { _ in
        perguntas += 1
        return true
    }

    biblioteca.reprocessar(externa)

    #expect(perguntas == 0)
    #expect(!biblioteca.processando)
    #expect(!biblioteca.estaNaFila(externa))
}

// MARK: - Gravações órfãs

/// WAV PCM 16 bits mono a 16 kHz com o cabeçalho ainda zerado — o que sobra
/// no disco quando o app é encerrado no meio da gravação.
private func wavInterrompido(segundos: Double) -> Data {
    func le(_ valor: UInt32) -> Data { Data([0, 8, 16, 24].map { UInt8((valor >> $0) & 0xFF) }) }
    func le16(_ valor: UInt16) -> Data { Data([UInt8(valor & 0xFF), UInt8(valor >> 8)]) }
    var dados = Data("RIFF".utf8) + le(0) + Data("WAVE".utf8)
    dados += Data("fmt ".utf8) + le(16) + le16(1) + le16(1) + le(16_000) + le(32_000) + le16(2) + le16(16)
    dados += Data("data".utf8) + le(0) + Data(repeating: 1, count: Int(segundos * 32_000))
    return dados
}

@MainActor
@Test("Gravação sem registro volta para a biblioteca; conhecida, em uso e vazia não")
func gravacaoOrfaEhRecuperada() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    biblioteca.processamentoAutomatico = false
    await biblioteca.usarEspaco(Biblioteca.espacoPessoal())
    let armazenamento = Armazenamento(raiz: raiz)

    func criarPasta(_ id: UUID, segundos: Double?) throws -> String {
        let pasta = try armazenamento.criarPastaDaGravacao(id: id)
        if let segundos {
            try wavInterrompido(segundos: segundos)
                .write(to: pasta.appendingPathComponent(Armazenamento.Nome.microfone))
        }
        return Armazenamento.caminhoRelativo(id: id)
    }
    let orfa = try criarPasta(UUID(), segundos: 3)
    let conhecida = try criarPasta(UUID(), segundos: 3)
    let emUso = try criarPasta(UUID(), segundos: 3)
    let cliqueAcidental = try criarPasta(UUID(), segundos: 0.2)
    let vazia = try criarPasta(UUID(), segundos: nil)
    await biblioteca.registrar(titulo: "Já registrada", pastaRelativa: conhecida, duracao: 3)

    let recuperadas = await biblioteca.recuperarGravacoesOrfas(ignorando: [emUso])

    #expect(recuperadas.map(\.pastaRelativa) == [orfa])
    let recuperada = try #require(recuperadas.first)
    #expect(abs(recuperada.duracao - 3) < 0.01)
    #expect(biblioteca.arquivos.contains { $0.id == recuperada.id })
    #expect(biblioteca.arquivos.count == 2)
    // O cabeçalho foi consertado: o áudio agora abre com a duração real.
    let microfone = armazenamento.resolver(relativo: orfa)
        .appendingPathComponent(Armazenamento.Nome.microfone)
    #expect(SessaoGravacao.duracaoDoMicrofone(em: microfone).map { abs($0 - 3) < 0.01 } == true)
    // O que a captura descartaria sozinha sai do disco; o resto fica.
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: armazenamento.resolver(relativo: cliqueAcidental).path))
    #expect(!fm.fileExists(atPath: armazenamento.resolver(relativo: vazia).path))
    #expect(fm.fileExists(atPath: armazenamento.resolver(relativo: emUso).path))

    // Rodar de novo não cria um segundo registro para a mesma pasta.
    #expect(await biblioteca.recuperarGravacoesOrfas(ignorando: [emUso]).isEmpty)
}

// MARK: - Prazo da lixeira (V-06)

@MainActor
@Test("A lixeira cumpre o prazo de 30 dias que anuncia (V-06)")
func lixeiraExpurgaDepoisDoPrazo() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }

    biblioteca.processamentoAutomatico = false
    let id = UUID()
    let pasta = raiz.appendingPathComponent(Armazenamento.caminhoRelativo(id: id), isDirectory: true)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: pasta.appendingPathComponent(Armazenamento.Nome.microfone))
    await biblioteca.registrar(titulo: "Antiga", pastaRelativa: Armazenamento.caminhoRelativo(id: id), duracao: 30)
    await biblioteca.registrar(titulo: "Fica", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 30)
    let antiga = try #require(biblioteca.arquivos.first { $0.titulo == "Antiga" })

    await biblioteca.moverParaLixeira(antiga)
    #expect(biblioteca.arquivosNaLixeira.count == 1)

    // 29 dias depois ainda está lá, com o áudio.
    let quase = Date().addingTimeInterval(29 * 24 * 3_600)
    #expect(await biblioteca.expurgarLixeiraVencida(agora: quase) == 0)
    #expect(biblioteca.arquivosNaLixeira.count == 1)
    #expect(FileManager.default.fileExists(atPath: pasta.path))

    // Passado o prazo, sai o registro e sai o áudio do disco.
    let depois = Date().addingTimeInterval(31 * 24 * 3_600)
    #expect(await biblioteca.expurgarLixeiraVencida(agora: depois) == 1)
    #expect(biblioteca.arquivosNaLixeira.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: pasta.path))
    // Quem não foi para a lixeira não é tocado.
    #expect(biblioteca.arquivos.map(\.titulo) == ["Fica"])
    #expect(biblioteca.erroDaLixeira == nil)
}

@Test("O prazo da lixeira é o mesmo para quem mostra e para quem apaga")
func prazoDaLixeiraEhUmSo() throws {
    let apagadoEm = Date(timeIntervalSince1970: 1_800_000_000)
    let dia: TimeInterval = 24 * 3_600

    #expect(!PrazoDaLixeira.venceu(apagadoEm, agora: apagadoEm))
    #expect(!PrazoDaLixeira.venceu(apagadoEm, agora: apagadoEm.addingTimeInterval(29 * dia)))
    #expect(PrazoDaLixeira.venceu(apagadoEm, agora: apagadoEm.addingTimeInterval(31 * dia)))
    let limite = try #require(PrazoDaLixeira.limite(de: apagadoEm))
    #expect(PrazoDaLixeira.venceu(apagadoEm, agora: limite))
}

// MARK: - Fila persistente (B-08)

@Test("A fila em disco guarda os pedidos por espaço e conta as tentativas")
func filaPersistidaGuardaPedidos() throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let fila = FilaDeProcessamentoPersistida(url: raiz.appendingPathComponent("Processamento/fila.json"))
    let (pessoal, equipe) = (EspacoID(), EspacoID())
    let (primeiro, segundo, daEquipe) = (ArquivoID(), ArquivoID(), ArquivoID())

    fila.registrar(primeiro, espaco: pessoal, somenteResumo: false)
    fila.registrar(segundo, espaco: pessoal, somenteResumo: true)
    fila.registrar(daEquipe, espaco: equipe, somenteResumo: false)
    fila.registrar(primeiro, espaco: pessoal, somenteResumo: false)

    // Outra instância lê o mesmo arquivo: é o que acontece ao reabrir o app.
    let reaberta = FilaDeProcessamentoPersistida(url: fila.url)
    #expect(reaberta.pendentes(do: pessoal).map(\.id) == [primeiro.rawValue, segundo.rawValue])
    #expect(reaberta.pendentes(do: pessoal).map(\.somenteResumo) == [false, true])
    #expect(reaberta.pendentes(do: equipe).map(\.id) == [daEquipe.rawValue])

    reaberta.marcarInicio(primeiro)
    reaberta.marcarInicio(primeiro)
    #expect(fila.pendentes(do: pessoal).first?.tentativas == 2)
    // Recusado antes de começar (faltam modelos): a tentativa não conta.
    fila.adiar(primeiro)
    #expect(fila.pendentes(do: pessoal).first?.tentativas == 0)

    fila.remover(primeiro)
    fila.removerTodas(do: equipe)
    #expect(fila.todas().map(\.id) == [segundo.rawValue])
    fila.remover(segundo)
    #expect(!FileManager.default.fileExists(atPath: fila.url.path))
}

@MainActor
@Test("Pedido recusado por falta de modelos continua pendente e não é repetido às cegas")
func pedidoSemModelosContinuaPendente() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    let fila = FilaDeProcessamentoPersistida(
        url: raiz.appendingPathComponent("Processamento/fila-pendente.json")
    )

    let arquivo = try #require(await biblioteca.registrar(
        titulo: "Reunião", pastaRelativa: Armazenamento.caminhoRelativo(id: UUID()), duracao: 60
    ))
    #expect(fila.pendentes(do: arquivo.espaco).map(\.id) == [arquivo.id.rawValue])
    #expect(await aguardar { !biblioteca.processando })

    // Sem os pesos o Preflight recusa: o pedido fica em disco, sem tentativa
    // contada, esperando os modelos.
    #expect(fila.pendentes(do: arquivo.espaco).first?.tentativas == 0)

    // Recarregar a lista sem modelos não reenfileira — o cartão não pisca.
    await biblioteca.carregar()
    #expect(!biblioteca.processando)
    #expect(fila.pendentes(do: arquivo.espaco).count == 1)

    // Mover para a lixeira é desistir do pedido.
    #expect(await biblioteca.moverParaLixeira(arquivo))
    #expect(fila.todas().isEmpty)
}

@MainActor
@Test("Anexos de conversa sem áudio ficam em Gravacoes/<id> e saem com a conversa (PS-01)")
func anexosDeConversaSemAudioSaemComAConversa() async throws {
    let (biblioteca, raiz) = try bibliotecaDeTeste()
    defer { try? FileManager.default.removeItem(at: raiz) }
    biblioteca.processamentoAutomatico = false
    let fm = FileManager.default

    let arquivo = try #require(await biblioteca.registrar(titulo: "Do Granola", pastaRelativa: "", duracao: 0))
    let pasta = biblioteca.audio(de: arquivo).deletingLastPathComponent()
    // Dentro de `Gravacoes/<id>`: é o que a lixeira de mídia aceita.
    #expect(pasta.standardizedFileURL.path == raiz
        .appendingPathComponent(Armazenamento.caminhoRelativo(id: arquivo.id.rawValue))
        .standardizedFileURL.path)

    try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
    try Data("anexo".utf8).write(to: pasta.appendingPathComponent("contrato.pdf"))
    // Endereço de versões anteriores: também não pode ficar para trás.
    let legado = raiz.appendingPathComponent("MidiaIndisponivel/\(arquivo.id.rawValue.uuidString)")
    try fm.createDirectory(at: legado, withIntermediateDirectories: true)
    try Data("antigo".utf8).write(to: legado.appendingPathComponent("foto.png"))

    #expect(await biblioteca.moverParaLixeira(arquivo))
    let naLixeira = try #require(biblioteca.arquivosNaLixeira.first { $0.id == arquivo.id })
    await biblioteca.apagarDefinitivamente(naLixeira)

    #expect(!fm.fileExists(atPath: pasta.path))
    #expect(!fm.fileExists(atPath: legado.path))
}
