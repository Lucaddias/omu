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

@Test("Download CloudKit consome todos os lotes enquanto houver mais alterações")
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
    // O servidor já tem exatamente a revisão que ainda consta como pendente:
    // é o próprio envio voltando, não há nada a aplicar por cima do local.
    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: revisaoRemota,
            revisaoLocalPendente: revisaoRemota
        ) == .ignorarEco
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
    private var paginas: [[Data]]
    private var removidos: [String]
    private let falharAoPaginar: Bool
    private var falharAoSalvar: Bool
    private var indiceDaPagina = 0
    private var arquivoSalvo: Data?
    private(set) var marcadoresRecebidos: [Data?] = []

    init(
        paginas: [[Data]],
        removidos: [String] = [],
        falharAoPaginar: Bool = false,
        falharAoSalvar: Bool = false
    ) {
        self.paginas = paginas
        self.removidos = removidos
        self.falharAoPaginar = falharAoPaginar
        self.falharAoSalvar = falharAoSalvar
    }

    /// Prepara a próxima baixa, como se a zona tivesse mudado no servidor.
    func preparar(paginas: [[Data]], removidos: [String] = []) {
        self.paginas = paginas
        self.removidos = removidos
        indiceDaPagina = 0
    }

    func salvar(_ dados: Data, id: String, equipe: EquipeDisponivel) throws {
        if falharAoSalvar { throw FalhaCloudKitFake() }
        arquivoSalvo = dados
    }

    func alteracoes(
        da equipe: EquipeDisponivel,
        desde marcador: Data?
    ) throws -> AlteracoesDeConversasCloudKit {
        if falharAoPaginar { throw FalhaCloudKitFake() }
        marcadoresRecebidos.append(marcador)
        guard indiceDaPagina < paginas.count else {
            return AlteracoesDeConversasCloudKit(
                registros: [], removidos: removidos, marcador: Data("fim".utf8), haMais: false
            )
        }
        let atual = indiceDaPagina
        indiceDaPagina += 1
        let ultima = indiceDaPagina == paginas.count
        return AlteracoesDeConversasCloudKit(
            registros: paginas[atual],
            removidos: ultima ? removidos : [],
            marcador: Data("pagina-\(indiceDaPagina)".utf8),
            haMais: !ultima
        )
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

    func alteracoes(da equipe: EquipeDisponivel, desde marcador: Data?) -> AlteracoesDeConversasCloudKit {
        AlteracoesDeConversasCloudKit(registros: [], removidos: [], marcador: nil, haMais: false)
    }

    func remover(id: String, equipe: EquipeDisponivel) {}
}

// MARK: - Autenticidade de marcadores, códigos e convites

@Test("Marcador de exclusão só autoriza a limpeza se concluído e criado pelo dono da zona")
func marcadorDeExclusaoExigeDonoDaZona() {
    // O caso legítimo: o dono publicou "concluída".
    #expect(ServicoDeEquipesCloudKit.marcadorAutorizaLimpeza(
        estado: "concluida", criador: "_dono_", donoDaZona: "_dono_"
    ))
    // Qualquer conta cria registros no banco público: um participante (ou
    // ex-participante) não pode mandar os Macs da equipe se limparem.
    #expect(!ServicoDeEquipesCloudKit.marcadorAutorizaLimpeza(
        estado: "concluida", criador: "_outra-conta_", donoDaZona: "_dono_"
    ))
    #expect(!ServicoDeEquipesCloudKit.marcadorAutorizaLimpeza(
        estado: "preparando", criador: "_dono_", donoDaZona: "_dono_"
    ))
    // Sem criador ou sem o dono guardado não há o que conferir: nada é apagado.
    #expect(!ServicoDeEquipesCloudKit.marcadorAutorizaLimpeza(
        estado: "concluida", criador: nil, donoDaZona: "_dono_"
    ))
    #expect(!ServicoDeEquipesCloudKit.marcadorAutorizaLimpeza(
        estado: "concluida", criador: "_dono_", donoDaZona: nil
    ))
}

@Test("Registro de código só vale quando criado pelo dono do compartilhamento")
func registroDeCodigoExigeDonoDoCompartilhamento() {
    #expect(ServicoDeEquipesCloudKit.registroDeCodigoEhDoDono(
        criador: "_dono_", donoDoCompartilhamento: "_dono_"
    ))
    #expect(!ServicoDeEquipesCloudKit.registroDeCodigoEhDoDono(
        criador: "_terceiro_", donoDoCompartilhamento: "_dono_"
    ))
    #expect(!ServicoDeEquipesCloudKit.registroDeCodigoEhDoDono(
        criador: nil, donoDoCompartilhamento: "_dono_"
    ))
    #expect(!ServicoDeEquipesCloudKit.registroDeCodigoEhDoDono(
        criador: "_dono_", donoDoCompartilhamento: nil
    ))
}

private func equipeDeTeste(
    id: String = "produto-a1b2c3",
    espaco: UUID = UUID(),
    dono: String? = "_dono_",
    banco: BancoCloudKitDaEquipe = .compartilhado
) -> EquipeDisponivel {
    EquipeDisponivel(
        id: id,
        nome: "Produto",
        papel: "Membro",
        quantidadeDeMembros: 2,
        espacoID: espaco.uuidString,
        zonaCloudKit: "equipe.\(id)",
        donoDaZonaCloudKit: dono,
        bancoCloudKit: banco.rawValue
    )
}

@Test("Convite não toma o id nem o espaço de uma equipe já conhecida")
func conviteNaoSubstituiEquipeExistente() {
    let pessoal = EspacoID()
    let minha = equipeDeTeste(dono: "__defaultOwner__", banco: .privado)
    let espacoDaMinha = UUID(uuidString: minha.espacoID ?? "") ?? UUID()

    // Mesma equipe, mesma zona e dono: é atualização, não conflito.
    #expect(!EquipesDoUsuario.conflita(minha, com: [minha], espacoPessoal: pessoal))
    // Equipe nova, sem relação com as existentes.
    #expect(!EquipesDoUsuario.conflita(
        equipeDeTeste(id: "vendas-ffffff"), com: [minha], espacoPessoal: pessoal
    ))
    // Convite de outra conta reivindicando o `id` da minha equipe.
    #expect(EquipesDoUsuario.conflita(
        equipeDeTeste(dono: "_atacante_"), com: [minha], espacoPessoal: pessoal
    ))
    // Convite com outro `id`, mas apontando para o espaço da minha equipe:
    // as conversas dela passariam a sincronizar com a zona do remetente.
    #expect(EquipesDoUsuario.conflita(
        equipeDeTeste(id: "outra-000000", espaco: espacoDaMinha, dono: "_atacante_"),
        com: [minha],
        espacoPessoal: pessoal
    ))
    // Nem o espaço pessoal pode ser reivindicado por um convite.
    #expect(EquipesDoUsuario.conflita(
        equipeDeTeste(id: "outra-111111", espaco: pessoal.rawValue, dono: "_atacante_"),
        com: [],
        espacoPessoal: pessoal
    ))
    // Entrada antiga, sem o dono guardado: reentrar na mesma zona atualiza.
    let legada = equipeDeTeste(dono: nil)
    #expect(!EquipesDoUsuario.conflita(equipeDeTeste(), com: [legada], espacoPessoal: pessoal))
}

@Test("Lista de equipes ilegível não é sobrescrita por uma lista vazia")
func listaDeEquipesIlegivelFicaEmQuarentena() throws {
    let nome = "teste-equipes-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: nome))
    defer { defaults.removePersistentDomain(forName: nome) }
    let ilegivel = Data("{ isto não é uma lista de equipes".utf8)
    defaults.set(ilegivel, forKey: "equipesDoUsuario")

    #expect(EquipesDoUsuario.carregar(em: defaults).isEmpty)
    EquipesDoUsuario.salvar([], em: defaults)

    #expect(defaults.data(forKey: "equipesDoUsuario.ilegivel") == ilegivel)
}

// MARK: - Fila e download tolerantes a falhas

@Test("Fila do iCloud ilegível vai para a quarentena e volta a funcionar")
func filaIlegivelNaoTravaParaSempre() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("fila.json")
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)

    // Uma operação válida gravada por uma execução anterior…
    let anterior = FilaPersistenteCloudKit(url: url)
    try await anterior.agendarEnvio(Arquivo(titulo: "Boa", pastaRelativa: "", espaco: espaco), para: equipe)
    // …e ao lado dela um item que esta versão não sabe ler.
    let valida = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
    )
    let misturado = valida + [["id": "não é uma operação"]]
    try JSONSerialization.data(withJSONObject: misturado).write(to: url)

    let fila = FilaPersistenteCloudKit(url: url)

    // A legível continua; a fila aceita operações novas em vez de lançar.
    #expect(try await fila.operacoesPendentes().map(\.arquivo?.titulo) == ["Boa"])
    try await fila.agendarEnvio(Arquivo(titulo: "Nova", pastaRelativa: "", espaco: espaco), para: equipe)
    #expect(try await fila.operacoesPendentes().count == 2)
    let quarentena = try #require(fila.quarentena)
    #expect(FileManager.default.fileExists(atPath: quarentena.path))

    // Arquivo que nem JSON é: fila vazia, original preservado.
    let outro = raiz.appendingPathComponent("truncada.json")
    try Data("[{\"id\": \"".utf8).write(to: outro)
    let truncada = FilaPersistenteCloudKit(url: outro)
    #expect(try await truncada.operacoesPendentes().isEmpty)
    #expect(truncada.quarentena != nil)
}

@Test("Falhas do iCloud que repetir não resolve saem das tentativas automáticas")
func classificacaoDeFalhasDaFila() {
    // Remover o que já não existe é o resultado desejado.
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.unknownItem], acao: .remover) == .jaConcluida)
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.zoneNotFound], acao: .remover) == .jaConcluida)
    // No envio, registro ausente não é sucesso.
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.unknownItem], acao: .enviar) == .tentarDeNovo)
    // Sem permissão de escrita ou sem cota: parar e avisar.
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.permissionFailure], acao: .enviar) == .bloqueada)
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.quotaExceeded], acao: .enviar) == .bloqueada)
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.permissionFailure], acao: .remover) == .bloqueada)
    // Rede e servidor: repetir com espera.
    #expect(DestinoDaFalhaCloudKit.classificar(codigos: [.networkUnavailable], acao: .enviar) == .tentarDeNovo)
    #expect(DestinoDaFalhaCloudKit.classificar(FalhaCloudKitFake(), acao: .enviar) == .tentarDeNovo)
}

@Test("Uma conversa ilegível não derruba o download das outras")
func downloadPulaRegistroIlegivel() async throws {
    let espaco = EspacoID()
    let boa = Arquivo(titulo: "Legível", pastaRelativa: "", espaco: espaco)
    let payload = try JSONEncoder().encode(
        PayloadDeConversaCloudKit(arquivo: boa, atualizadoEm: Date(timeIntervalSince1970: 10))
    )
    let transporte = TransporteDeConversasFake(
        paginas: [[Data("{\"versao\": 99, \"campoNovo\": true}".utf8), payload]]
    )
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)

    let recebidas = try await sincronizador.baixarComVersoes(da: equipeCloudKitDeTeste(espaco: espaco))

    #expect(recebidas.map(\.arquivo.titulo) == ["Legível"])
    #expect(await sincronizador.ignoradasNoUltimoDownload == 1)
}

@Test("Remoto mais novo que a edição local pendente é conflito; mais antigo é só eco")
func conflitoCloudKitDistingueEcoDeEdicaoAlheia() {
    let pendente = Date(timeIntervalSince1970: 2_000)

    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: pendente.addingTimeInterval(60),
            revisaoLocalPendente: pendente
        ) == .conflito
    )
    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: pendente.addingTimeInterval(-60),
            revisaoLocalPendente: pendente
        ) == .preservarLocalPendente
    )
    #expect(
        PoliticaDeConflitoCloudKit.decidir(
            revisaoRemota: pendente,
            revisaoLocalPendente: nil,
            revisoesEntreguesDaqui: [pendente]
        ) == .ignorarEco
    )
}

@Test("Baixa incremental repassa o marcador entre lotes e relata as conversas apagadas")
func baixaIncrementalRelataRemocoes() async throws {
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let mantida = Arquivo(titulo: "Mantida", pastaRelativa: "", espaco: espaco)
    let apagada = ArquivoID()
    let codificador = JSONEncoder()
    let transporte = TransporteDeConversasFake(
        paginas: [[try codificador.encode(mantida)], []],
        removidos: [apagada.rawValue.uuidString, mantida.id.rawValue.uuidString, "nao-e-uuid"]
    )
    let sincronizador = SincronizadorDaBibliotecaCloudKit(transporte: transporte)
    let anterior = Data("anterior".utf8)

    let baixado = try await sincronizador.baixarAlteracoes(da: equipe, desde: anterior)

    #expect(baixado.conversas.map(\.arquivo.id) == [mantida.id])
    // Alterada e removida na mesma baixa: prevalece a versão que preserva dados.
    #expect(baixado.removidas == [apagada])
    #expect(baixado.marcador == Data("pagina-2".utf8))
    #expect(await transporte.marcadoresRecebidos == [anterior, Data("pagina-1".utf8)])
}

@Test("Marcador de sincronização sobrevive ao relançamento e não vale para outra zona")
func marcadorDeSincronizacaoEhPersistente() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("marcadores.json")
    let equipe = equipeCloudKitDeTeste(espaco: EspacoID())
    let marcador = Data("ponto".utf8)

    try await MarcadoresDeSincronizacaoCloudKit(url: url).guardar(marcador, para: equipe)

    let aposRelancamento = MarcadoresDeSincronizacaoCloudKit(url: url)
    #expect(await aposRelancamento.marcador(para: equipe) == marcador)

    var emOutraZona = equipe
    emOutraZona.zonaCloudKit = "equipe.outra"
    #expect(await aposRelancamento.marcador(para: emOutraZona) == nil)

    try await aposRelancamento.descartar(daEquipeComID: equipe.id)
    #expect(await MarcadoresDeSincronizacaoCloudKit(url: url).marcador(para: equipe) == nil)
}

@MainActor
@Test("Conversa apagada por um colega vai para a lixeira local; edição pendente a mantém ativa")
func remocaoRemotaRecolheConversaSemDestruirDados() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let apagada = Arquivo(titulo: "Apagada pelo colega", pastaRelativa: "", espaco: espaco)
    let emEdicao = Arquivo(titulo: "Com edição local", pastaRelativa: "", espaco: espaco)
    let codificador = JSONEncoder()
    let transporte = TransporteDeConversasFake(
        paginas: [[try codificador.encode(apagada), try codificador.encode(emEdicao)]]
    )
    let fila = FilaPersistenteCloudKit(url: raiz.appendingPathComponent("fila.json"))
    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal(
                nome: UUID().uuidString,
                emMemoria: true
            )
        ),
        espaco: espaco,
        sincronizadorCloudKit: SincronizadorDaBibliotecaCloudKit(transporte: transporte),
        filaCloudKit: fila
    )
    biblioteca.intervaloDeAtualizacaoDaEquipe = .seconds(3_600)

    await biblioteca.usarEspaco(espaco, equipeCloudKit: equipe)
    #expect(Set(biblioteca.arquivos.map(\.id)) == [apagada.id, emEdicao.id])

    try await fila.agendarEnvio(emEdicao, para: equipe)
    await transporte.preparar(
        paginas: [],
        removidos: [apagada.id.rawValue.uuidString, emEdicao.id.rawValue.uuidString]
    )
    await biblioteca.atualizarEquipeEmSegundoPlano()

    #expect(biblioteca.arquivos.map(\.id) == [emEdicao.id])
    #expect(biblioteca.arquivosNaLixeira.map(\.id) == [apagada.id])
    // A primeira baixa parte do zero; a segunda continua do marcador guardado.
    #expect(await transporte.marcadoresRecebidos == [nil, Data("pagina-1".utf8)])
}

@MainActor
@Test("Biblioteca da equipe vazia ignora marcador herdado e baixa a zona inteira")
func bibliotecaVaziaBaixaZonaInteira() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    try await MarcadoresDeSincronizacaoCloudKit(
        url: raiz
            .appendingPathComponent("CloudKit", isDirectory: true)
            .appendingPathComponent("marcadores-de-sincronizacao.json")
    ).guardar(Data("herdado".utf8), para: equipe)
    let transporte = TransporteDeConversasFake(
        paginas: [[try JSONEncoder().encode(Arquivo(titulo: "Da equipe", pastaRelativa: "", espaco: espaco))]]
    )
    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal(
                nome: UUID().uuidString,
                emMemoria: true
            )
        ),
        espaco: espaco,
        sincronizadorCloudKit: SincronizadorDaBibliotecaCloudKit(transporte: transporte)
    )
    biblioteca.intervaloDeAtualizacaoDaEquipe = .seconds(3_600)

    await biblioteca.usarEspaco(espaco, equipeCloudKit: equipe)

    #expect(await transporte.marcadoresRecebidos == [nil])
    #expect(biblioteca.arquivos.map(\.titulo) == ["Da equipe"])
}

@MainActor
@Test("Eco do próprio envio não volta por cima do que avançou neste Mac")
func ecoDoProprioEnvioNaoSobrescreveLocal() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let original = Arquivo(titulo: "Original", pastaRelativa: "", espaco: espaco)
    let transporte = TransporteDeConversasFake(paginas: [[try JSONEncoder().encode(original)]])
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString,
            emMemoria: true
        )
    )
    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: repositorio,
        espaco: espaco,
        sincronizadorCloudKit: SincronizadorDaBibliotecaCloudKit(transporte: transporte),
        filaCloudKit: FilaPersistenteCloudKit(url: raiz.appendingPathComponent("fila.json"))
    )
    biblioteca.intervaloDeAtualizacaoDaEquipe = .seconds(3_600)
    await biblioteca.usarEspaco(espaco, equipeCloudKit: equipe)
    let local = try #require(biblioteca.arquivos.first)

    await biblioteca.renomear(local, para: "Enviado daqui")
    // Salvar só agenda o envio; a rede roda numa tarefa à parte.
    await biblioteca.aguardarEnvioCloudKit()
    let enviado = try #require(await transporte.ultimoArquivoSalvo())
    // O pipeline grava progresso no banco local sem passar pela fila.
    var avancado = try #require(try await repositorio.buscarCompleto(id: original.id))
    avancado.titulo = "Avanço local"
    try await repositorio.salvar(avancado)

    await transporte.preparar(paginas: [[enviado]])
    await biblioteca.atualizarEquipeEmSegundoPlano()

    #expect(try await repositorio.buscarCompleto(id: original.id)?.titulo == "Avanço local")
}
