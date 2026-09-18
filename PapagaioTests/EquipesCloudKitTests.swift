import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

@Test("Workspace CloudKit usa uma zona estável por equipe")
func zonaDaEquipeEhDeterministica() {
    #expect(
        ServicoDeEquipesCloudKit.nomeDaZona(para: "produto-a1b2c3")
            == "equipe.produto-a1b2c3"
    )
}

@Test("Equipe local legada continua decodificável")
func equipeLegadaNaoExigeMetadadosCloudKit() throws {
    let dados = """
    {"id":"equipe-legada","nome":"Produto","papel":"Administrador","quantidadeDeMembros":1}
    """.data(using: .utf8)!

    let equipe = try JSONDecoder().decode(EquipeDisponivel.self, from: dados)

    #expect(equipe.zonaCloudKit == nil)
    #expect(equipe.compartilhamentoCloudKit == nil)
}

@Test("Download CloudKit consome todos os cursores acima de 200 registros")
func downloadCloudKitEhPaginado() async throws {
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let arquivos = (0..<205).map { indice in
        Arquivo(
            titulo: "Conversa \(indice)",
            pastaRelativa: "",
            espaco: espaco
        )
    }
    let codificador = JSONEncoder()
    let transporte = TransporteDeConversasFake(
        paginas: [
            try arquivos.prefix(200).map(codificador.encode),
            try arquivos.suffix(5).map(codificador.encode),
        ]
    )
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)

    let baixados = try await sincronizador.baixar(da: equipe)

    #expect(baixados.count == 205)
    #expect(await transporte.quantidadeDePaginasLidas() == 2)
}

@Test("Mapeamento CloudKit preserva payload e ignora outro espaço")
func mapeamentoCloudKitRespeitaEspaco() async throws {
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let esperado = Arquivo(
        titulo: "Produto",
        duracao: 42,
        pastaRelativa: "Gravacoes/local",
        espaco: espaco,
        notas: [NotaDaConversa(texto: "Decisão", start: 7)]
    )
    let outro = Arquivo(
        titulo: "Outro espaço",
        pastaRelativa: "",
        espaco: EspacoID()
    )
    let transporte = TransporteDeConversasFake(
        paginas: [[try JSONEncoder().encode(esperado), try JSONEncoder().encode(outro)]]
    )
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)

    try await sincronizador.enviar(esperado, para: equipe)
    let enviado = try #require(await transporte.ultimoArquivoSalvo())
    let baixados = try await sincronizador.baixar(da: equipe)
    let payload = try JSONDecoder().decode(PayloadDeConversaCloudKit.self, from: enviado)

    #expect(payload.arquivo.id == esperado.id)
    #expect(payload.arquivo.titulo == esperado.titulo)
    #expect(payload.arquivo.notas == esperado.notas)
    #expect(payload.versao == 2)
    #expect(payload.arquivo.pastaRelativa.isEmpty)
    #expect(payload.midiaDisponivelNaOrigem == true)
    var esperadoBaixado = esperado
    esperadoBaixado.pastaRelativa = ""
    #expect(baixados == [esperadoBaixado])
}

@Test("Metadados remotos não carregam caminho local e preservam mídia deste Mac")
func fronteiraDeMidiaCloudKitEhExplicita() {
    let espaco = EspacoID()
    let local = Arquivo(
        titulo: "Entrevista",
        pastaRelativa: "Gravacoes/entrevista",
        espaco: espaco
    )
    let remoto = PoliticaDeMidiaCloudKit.prepararParaEnvio(local)

    #expect(remoto.semAudio)
    #expect(
        PoliticaDeMidiaCloudKit.mesclar(
            remoto: remoto,
            local: nil,
            midiaLocalExiste: false
        ).semAudio
    )
    #expect(
        PoliticaDeMidiaCloudKit.mesclar(
            remoto: remoto,
            local: local,
            midiaLocalExiste: true
        ).pastaRelativa == local.pastaRelativa
    )
    #expect(
        PoliticaDeMidiaCloudKit.mesclar(
            remoto: remoto,
            local: local,
            midiaLocalExiste: false
        ).semAudio
    )
}

@MainActor
@Test("Falha de download CloudKit chega ao estado observável e à notificação")
func falhaCloudKitEhObservavel() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let espaco = EspacoID()
    let transporte = TransporteDeConversasFake(paginas: [], falharAoPaginar: true)
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)
    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal(
                nome: UUID().uuidString,
                emMemoria: true
            )
        ),
        espaco: espaco,
        sincronizadorCloudKit: sincronizador
    )
    var notificacao: String?
    biblioteca.aoNotificar = { _, mensagem, _ in notificacao = mensagem }

    await biblioteca.usarEspaco(espaco, equipeCloudKit: equipeCloudKitDeTeste(espaco: espaco))

    guard case let .falhou(mensagem) = biblioteca.estadoDaSincronizacaoCloudKit else {
        Issue.record("A falha do transporte não chegou ao estado da biblioteca")
        return
    }
    #expect(mensagem.contains("Falha simulada"))
    #expect(notificacao?.contains("Falha simulada") == true)
}

@Test("Código libera entrada na equipe com permissão de escrita")
func codigoDaEquipeLiberaEscrita() {
    #expect(ServicoDeEquipesCloudKit.permissaoDaEntradaPorCodigo == .readWrite)
}

@Test("Somente equipe legada do proprietário pede reconfiguração do código")
func reconfiguracaoDaEntradaPorCodigoSoEhExibidaParaEquipeLegada() {
    let equipeNova = EquipeDisponivel(
        id: "nova",
        nome: "Nova",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue,
        codigoDeEntrada: "K8CE9H"
    )
    let equipeLegada = EquipeDisponivel(
        id: "legada",
        nome: "Legada",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )

    #expect(!equipeNova.precisaReconfigurarEntradaPorCodigo)
    #expect(equipeLegada.precisaReconfigurarEntradaPorCodigo)
}

@Test("Equipe participante preserva o dono da zona compartilhada")
func equipeParticipantePreservaDonoDaZonaCloudKit() throws {
    let original = EquipeDisponivel(
        id: "produto",
        nome: "Produto",
        papel: "Membro",
        quantidadeDeMembros: 1,
        espacoID: UUID().uuidString,
        zonaCloudKit: "equipe.produto",
        donoDaZonaCloudKit: "_dono-real_",
        bancoCloudKit: BancoCloudKitDaEquipe.compartilhado.rawValue
    )

    let dados = try JSONEncoder().encode(original)
    let restaurada = try JSONDecoder().decode(EquipeDisponivel.self, from: dados)

    #expect(restaurada.donoDaZonaCloudKit == "_dono-real_")
}

@Test("Contagem desconhecida não é apresentada como equipe vazia")
func equipeComParticipantesAindaNaoCarregadosTemRotuloHonesto() {
    let equipe = EquipeDisponivel(
        id: "produto",
        nome: "Produto",
        papel: "Membro",
        quantidadeDeMembros: 0
    )

    #expect(equipe.resumoDeMembros == "participantes ainda não carregados")
}

@Test("Falhas de esquema e zona orientam o participante sem tentar mascará-las")
func diagnosticoCloudKitExplicaDependenciaDoProprietario() {
    let esquema = DiagnosticoDaSincronizacaoCloudKit.mensagem(
        paraTexto: "Cannot create new type Conversa in production schema"
    )
    let zona = DiagnosticoDaSincronizacaoCloudKit.mensagem(
        paraTexto: "Zone does not exist"
    )

    #expect(esquema.contains("proprietário"))
    #expect(esquema.contains("CloudKit Dashboard"))
    #expect(zona.contains("entre novamente"))
    #expect(DiagnosticoDaSincronizacaoCloudKit.exigeAcaoDoProprietario("Zone does not exist"))
}

@Test("Erro de índice orienta a atualizar uma versão anterior do app")
func diagnosticoCloudKitExplicaErroDeIndiceDeConversa() {
    let mensagem = DiagnosticoDaSincronizacaoCloudKit.mensagem(
        paraTexto: "Type is not marked indexable: Conversa"
    )

    #expect(mensagem.contains("Atualize o Ōmu"))
    #expect(mensagem.contains("zona compartilhada"))
}

@Test("Falha transitória sobrevive ao relançamento e respeita backoff limitado")
func filaCloudKitEhPersistente() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("fila.json")
    let agora = Date(timeIntervalSince1970: 1_000)
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let arquivo = Arquivo(titulo: "Local", pastaRelativa: "", espaco: espaco)
    let transporte = TransporteDeConversasFake(
        paginas: [],
        falharAoSalvar: true
    )
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)
    let primeiraExecucao = FilaPersistenteCloudKit(url: url)

    try await primeiraExecucao.agendarEnvio(
        arquivo,
        para: equipe,
        revisao: agora
    )
    let falha = try await primeiraExecucao.processar(
        com: sincronizador,
        agora: agora
    )

    #expect(falha.pendentes == 1)
    #expect(falha.proximaTentativa == agora.addingTimeInterval(5))

    let aposRelancamento = FilaPersistenteCloudKit(url: url)
    #expect(try await aposRelancamento.operacoesPendentes().first?.tentativas == 1)
    await transporte.definirFalhaAoSalvar(false)

    let cedo = try await aposRelancamento.processar(
        com: sincronizador,
        agora: agora.addingTimeInterval(4)
    )
    #expect(cedo.concluidas == 0)
    #expect(cedo.pendentes == 1)

    let retomada = try await aposRelancamento.processar(
        com: sincronizador,
        agora: agora.addingTimeInterval(5)
    )
    #expect(retomada.concluidas == 1)
    #expect(retomada.pendentes == 0)
    #expect(FilaPersistenteCloudKit.atraso(para: 20) == 15 * 60)
}

@Test("Excluir equipe descarta apenas as retentativas daquela equipe")
func exclusaoDaEquipeDescartaOutboxCorreta() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fila = FilaPersistenteCloudKit(url: raiz.appendingPathComponent("fila.json"))
    let espaco = EspacoID()
    let equipeA = equipeCloudKitDeTeste(espaco: espaco)
    let equipeB = EquipeDisponivel(
        id: "outra-equipe",
        nome: "Outra",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        espacoID: EspacoID().rawValue.uuidString,
        zonaCloudKit: "equipe.outra",
        compartilhamentoCloudKit: "share-outra",
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )
    try await fila.agendarEnvio(Arquivo(titulo: "A", pastaRelativa: "", espaco: espaco), para: equipeA)
    try await fila.agendarEnvio(
        Arquivo(titulo: "B", pastaRelativa: "", espaco: EspacoID(rawValue: UUID(uuidString: equipeB.espacoID!)!)),
        para: equipeB
    )

    try await fila.descartarOperacoes(daEquipeComID: equipeA.id)

    let pendentes = try await fila.operacoesPendentes()
    #expect(pendentes.count == 1)
    #expect(pendentes.first?.equipe.id == equipeB.id)
}

@Test("Download antigo não sobrescreve uma edição local pendente")
func conflitoCloudKitPreservaEdicaoLocal() {
    let revisaoRemota = Date(timeIntervalSince1970: 1_000)
    let revisaoLocal = Date(timeIntervalSince1970: 2_000)

    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: revisaoRemota,
            revisaoLocalPendente: revisaoLocal
        ) == .preservarLocalPendente
    )
    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: revisaoRemota,
            revisaoLocalPendente: nil
        ) == .aplicarRemoto
    )
    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: revisaoRemota,
            revisaoLocalPendente: revisaoRemota
        ) == .aplicarRemoto
    )
}

private func equipeCloudKitDeTeste(espaco: EspacoID) -> EquipeDisponivel {
    EquipeDisponivel(
        id: "produto",
        nome: "Produto",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        espacoID: espaco.rawValue.uuidString,
        zonaCloudKit: "equipe.produto",
        compartilhamentoCloudKit: "share",
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )
}

private struct FalhaCloudKitFake: LocalizedError {
    var errorDescription: String? { "Falha simulada do CloudKit" }
}

private actor TransporteDeConversasFake: TransporteDeConversasCloudKit {
    private let paginas: [[Data]]
    private let falharAoPaginar: Bool
    private var falharAoSalvar: Bool
    private var indiceDaPagina = 0
    private var arquivoSalvo: Data?

    init(
        paginas: [[Data]],
        falharAoPaginar: Bool = false,
        falharAoSalvar: Bool = false
    ) {
        self.paginas = paginas
        self.falharAoPaginar = falharAoPaginar
        self.falharAoSalvar = falharAoSalvar
    }

    func salvar(_ dados: Data, id: String, equipe: EquipeDisponivel) throws {
        if falharAoSalvar { throw FalhaCloudKitFake() }
        arquivoSalvo = dados
    }

    func pagina(
        da equipe: EquipeDisponivel,
        continuando cursor: CursorDeConversasCloudKit?
    ) throws -> PaginaDeConversasCloudKit {
        if falharAoPaginar { throw FalhaCloudKitFake() }
        guard indiceDaPagina < paginas.count else {
            return PaginaDeConversasCloudKit(registros: [], proxima: nil)
        }
        let atual = indiceDaPagina
        indiceDaPagina += 1
        let proxima = indiceDaPagina < paginas.count
            ? CursorDeConversasCloudKit("pagina-\(indiceDaPagina)")
            : nil
        return PaginaDeConversasCloudKit(registros: paginas[atual], proxima: proxima)
    }

    func remover(id: String, equipe: EquipeDisponivel) {}

    func quantidadeDePaginasLidas() -> Int { indiceDaPagina }
    func ultimoArquivoSalvo() -> Data? { arquivoSalvo }
    func definirFalhaAoSalvar(_ falhar: Bool) { falharAoSalvar = falhar }
}

@Test("Consumidores concorrentes não reenviam operação; snapshot pula revisão substituída")
func filaCloudKitSerializaConsumidoresERevalidaSnapshot() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let fila = FilaPersistenteCloudKit(url: raiz.appendingPathComponent("fila.json"))
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let primeiro = Arquivo(titulo: "Primeiro", pastaRelativa: "", espaco: espaco)
    var segundo = Arquivo(titulo: "Antigo", pastaRelativa: "", espaco: espaco)
    let transporte = TransporteCloudKitSuspenso()
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)
    try await fila.agendarEnvio(primeiro, para: equipe)
    try await fila.agendarEnvio(segundo, para: equipe)
    let consumidorA = Task { try await fila.processar(com: sincronizador, ignorarBackoff: true) }
    await transporte.aguardarPrimeiroEnvio()
    let consumidorB = Task { try await fila.processar(com: sincronizador, ignorarBackoff: true) }
    segundo.titulo = "Novo"
    try await fila.agendarEnvio(segundo, para: equipe)
    await transporte.liberar()
    _ = try await consumidorA.value
    _ = try await consumidorB.value
    #expect(await transporte.idsEnviados == [primeiro.id.rawValue.uuidString, segundo.id.rawValue.uuidString])
    #expect(try await fila.operacoesPendentes().isEmpty)
}

private actor TransporteCloudKitSuspenso: TransporteDeConversasCloudKit {
    private(set) var idsEnviados: [String] = []
    private var liberacao: CheckedContinuation<Void, Never>?
    private var inicio: CheckedContinuation<Void, Never>?

    func aguardarPrimeiroEnvio() async {
        if !idsEnviados.isEmpty { return }
        await withCheckedContinuation { inicio = $0 }
    }

    func liberar() { liberacao?.resume(); liberacao = nil }

    func salvar(_ dados: Data, id: String, equipe: EquipeDisponivel) async throws {
        idsEnviados.append(id)
        if idsEnviados.count == 1 {
            await withCheckedContinuation {
                liberacao = $0
                inicio?.resume()
                inicio = nil
            }
        }
    }

    func pagina(da equipe: EquipeDisponivel, continuando cursor: CursorDeConversasCloudKit?) -> PaginaDeConversasCloudKit {
        PaginaDeConversasCloudKit(registros: [], proxima: nil)
    }

    func remover(id: String, equipe: EquipeDisponivel) {}
}
