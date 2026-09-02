import CloudKit
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

@Test("Configurações iguais comparam iguais, venham de onde vierem")
func configuracoesDaEquipeComparamPorValor() throws {
    // O botão "Salvar configurações" é habilitado por
    // `configuracoes != equipe.configuracoes`. Uma configuração recém-editada
    // na interface e a mesma configuração vinda do CloudKit precisam comparar
    // iguais; senão o botão fica aceso sem haver o que salvar e o SwiftUI
    // rediffa `EquipeDisponivel` sem motivo.
    var editada = ConfiguracoesDaEquipe()
    editada.recebimentoDeArquivos = .aguardarRevisao

    let doCloudKit = try JSONDecoder().decode(
        ConfiguracoesDaEquipe.self,
        from: try JSONEncoder().encode(editada)
    )

    #expect(editada == doCloudKit)
    #expect(editada.hashValue == doCloudKit.hashValue)

    // Blob gravado por uma versão anterior, sem nenhuma das chaves atuais:
    // cai nos padrões em vez de falhar a decodificação da equipe inteira.
    let legado = try JSONDecoder().decode(
        ConfiguracoesDaEquipe.self,
        from: Data("{}".utf8)
    )
    #expect(legado == ConfiguracoesDaEquipe())

    // Blob de uma versão que gravava `versao`: a chave desconhecida é
    // ignorada e não muda a igualdade.
    let comVersaoAntiga = try JSONDecoder().decode(
        ConfiguracoesDaEquipe.self,
        from: Data("""
        {"versao":1,"recebimentoDeArquivos":"Aguardar revisão"}
        """.utf8)
    )
    #expect(comVersaoAntiga == editada)
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

@MainActor
@Test("Página parcialmente falha não é apresentada como equipe sincronizada")
func downloadParcialNaoAnunciaSincronizacaoConcluida() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let espaco = EspacoID()
    let recebida = Arquivo(titulo: "Chegou", pastaRelativa: "", espaco: espaco)
    // O fetch trouxe uma conversa e recusou duas: sucesso para o result block
    // do CloudKit, mas a equipe não está sincronizada.
    let transporte = TransporteDeConversasFake(
        paginas: [[try JSONEncoder().encode(recebida)]],
        falhasPorRegistro: [
            FalhaDeConversaCloudKit(id: "conversa-1", mensagem: "Registro recusado pelo servidor."),
            FalhaDeConversaCloudKit(id: "conversa-2", mensagem: "Registro recusado pelo servidor."),
        ]
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
    var notificacao: String?
    biblioteca.aoNotificar = { _, mensagem, _ in notificacao = mensagem }

    await biblioteca.usarEspaco(espaco, equipeCloudKit: equipeCloudKitDeTeste(espaco: espaco))

    // A conversa boa chegou; o estado, mesmo assim, não pode ser `.sincronizado`.
    #expect(biblioteca.arquivos.contains { $0.id == recebida.id })
    guard case let .falhou(mensagem) = biblioteca.estadoDaSincronizacaoCloudKit else {
        Issue.record("Download parcial foi reportado como \(biblioteca.estadoDaSincronizacaoCloudKit)")
        return
    }
    #expect(mensagem.contains("2 conversa(s) não puderam ser baixadas"))
    #expect(notificacao?.contains("2 conversa(s) não puderam ser baixadas") == true)
}

@Test("Uma segunda conta consegue entrar na equipe com o código publicado")
func entradaPorCodigoChegaAoAccept() async throws {
    // O duble modela a regra do CloudKit que importa aqui: um `CKShare` com
    // `publicPermission == .none` só aceita identidades previamente incluídas
    // por `addParticipant(_:)`. Como o app nunca adiciona participante nenhum,
    // esse cenário faz `accept` falhar para qualquer conta. Este teste falha
    // se `permissaoDaEntradaPorCodigo` voltar a ser `.none`.
    let servidor = ServidorDeEquipesFake()
    let proprietario = ServicoDeEquipesCloudKit(transporte: servidor)
    let equipe = EquipeDisponivel(
        id: "produto",
        nome: "Produto",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        espacoID: UUID().uuidString,
        codigoDeEntrada: "K8CE9H"
    )

    let publicada = try await proprietario.criarWorkspace(para: equipe)
    #expect(publicada.compartilhamentoCloudKit != nil)

    // Segunda conta: só tem o código, nunca foi adicionada ao share.
    let convidado = ServicoDeEquipesCloudKit(transporte: servidor)
    let entrou = try await convidado.entrarNaEquipe(com: "k8ce-9h")

    #expect(entrou.id == equipe.id)
    #expect(entrou.bancoCloudKit == BancoCloudKitDaEquipe.compartilhado.rawValue)
    #expect(await servidor.aceitesRealizados() == 1)
}

@Test("Código inválido não encontra equipe nenhuma")
func entradaComCodigoInvalidoFalha() async throws {
    let servidor = ServidorDeEquipesFake()
    let servico = ServicoDeEquipesCloudKit(transporte: servidor)
    _ = try await servico.criarWorkspace(
        para: EquipeDisponivel(
            id: "produto",
            nome: "Produto",
            papel: "Administrador",
            quantidadeDeMembros: 1,
            espacoID: UUID().uuidString,
            codigoDeEntrada: "K8CE9H"
        )
    )

    await #expect(throws: ErroDeEquipeCloudKit.codigoInvalido) {
        try await servico.entrarNaEquipe(com: "ZZZZZZ")
    }
}

@Test("Resolver o código não depende de consulta ao banco público")
func entradaPorCodigoNaoUsaConsulta() async throws {
    // O tipo `CodigoDeEquipe` deixa de precisar do índice QUERYABLE — que era
    // o que permitia a qualquer conta enumerar `urlDoCompartilhamento` de
    // todas as equipes com um `NSPredicate(value: true)`. O duble falha se o
    // serviço tentar publicar ou resolver um código sem `recordID` derivado.
    let servidor = ServidorDeEquipesFake()
    let servico = ServicoDeEquipesCloudKit(transporte: servidor)
    _ = try await servico.criarWorkspace(
        para: EquipeDisponivel(
            id: "produto",
            nome: "Produto",
            papel: "Administrador",
            quantidadeDeMembros: 1,
            espacoID: UUID().uuidString,
            codigoDeEntrada: "K8CE9H"
        )
    )

    let publicados = await servidor.registrosPublicos()
    #expect(publicados.count == 1)
    let unico = try #require(publicados.first)
    // Endereçado por um nome derivado, e não aleatório...
    #expect(unico.key.recordName.hasPrefix("codigo."))
    // ...e o código em claro não fica guardado no banco público.
    #expect(unico.value["codigoDeEntrada"] == nil)
    #expect(unico.value["urlDoCompartilhamento"] as? String != nil)
}

@Test("Reconfigurar entrada por código só é oferecida quando não lançaria erro")
func reconfiguracaoExigeCompartilhamentoGravado() async throws {
    // Contrato entre a flag da interface e o serviço: toda equipe para a qual
    // o botão aparece precisa sobreviver a `idDoCompartilhamento(de:na:)`.
    let semShare = EquipeDisponivel(
        id: "local",
        nome: "Local",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        zonaCloudKit: "equipe.local",
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )
    #expect(!semShare.precisaReconfigurarEntradaPorCodigo)

    let servico = ServicoDeEquipesCloudKit(transporte: ServidorDeEquipesFake())
    await #expect(throws: ErroDeEquipeCloudKit.equipeAindaLocal) {
        try await servico.ativarEntradaPorCodigo(na: semShare)
    }
}

@Test("Somente equipe legada do proprietário pede reconfiguração do código")
func reconfiguracaoDaEntradaPorCodigoSoEhExibidaParaEquipeLegada() {
    // Equipe nova: share publicado e código já emitido, nada a reconfigurar.
    let equipeNova = EquipeDisponivel(
        id: "nova",
        nome: "Nova",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        zonaCloudKit: "equipe.nova",
        compartilhamentoCloudKit: "share-nova",
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue,
        codigoDeEntrada: "K8CE9H"
    )
    // Equipe legada do proprietário: o `CKShare` existe (foi criado pelo fluxo
    // de convite antigo) mas nunca teve código. É exatamente esta a população
    // que o botão de ativar entrada por código atende.
    let equipeLegada = EquipeDisponivel(
        id: "legada",
        nome: "Legada",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        zonaCloudKit: "equipe.legada",
        compartilhamentoCloudKit: "share-legada",
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )
    // Equipe ainda local: sem share gravado, `ativarEntradaPorCodigo` lançaria
    // `equipeAindaLocal`. Oferecer o botão aqui só produz erro.
    let equipeAindaLocal = EquipeDisponivel(
        id: "local",
        nome: "Local",
        papel: "Administrador",
        quantidadeDeMembros: 1,
        bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue
    )

    #expect(!equipeNova.precisaReconfigurarEntradaPorCodigo)
    #expect(equipeLegada.precisaReconfigurarEntradaPorCodigo)
    #expect(!equipeAindaLocal.precisaReconfigurarEntradaPorCodigo)
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

@Test("Erro de esquema desconhecido chega à interface sem ser desfigurado")
func diagnosticoCloudKitPreservaOTextoOriginalDoErro() {
    // `Tarefa` não é um dos tipos que `mensagem(paraTexto:)` conhece, então o
    // fallback devolve o texto recebido. Ele precisa chegar legível: é dele
    // que o proprietário tira o nome do tipo a publicar no CloudKit Dashboard.
    let original = "Cannot create new type Tarefa in production schema"
    let erro = CKError(
        _nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: [NSLocalizedDescriptionKey: original]
        )
    )

    #expect(DiagnosticoDaSincronizacaoCloudKit.mensagem(para: erro) == original)
}

@Test("Erro de índice orienta a atualizar uma versão anterior do app")
func diagnosticoCloudKitExplicaErroDeIndiceDeConversa() {
    let mensagem = DiagnosticoDaSincronizacaoCloudKit.mensagem(
        paraTexto: "Type is not marked indexable: Conversa"
    )

    #expect(mensagem.contains("Atualize o Papagaio"))
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

@Test("Fila com schema incompatível avisa em vez de sumir em silêncio")
func filaIlegivelEhIsoladaComAviso() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("fila.json")
    // Formato de uma versão anterior: nenhum elemento decodifica como
    // `OperacaoPendenteCloudKit`. É o que acontece quando um campo
    // não-opcional é acrescentado a `EquipeDisponivel` ou a `Arquivo`.
    try Data("""
    [{"id":"1","acao":"enviar"},{"id":"2","acao":"remover"}]
    """.utf8).write(to: url)

    let fila = FilaPersistenteCloudKit(url: url)

    #expect(try await fila.operacoesPendentes().isEmpty)
    let aviso = try #require(await fila.consumirAvisoDeAbertura())
    #expect(aviso.descartadas == 2)
    #expect(aviso.recuperadas == 0)
    #expect(aviso.mensagem.contains("não puderam ser lidas"))
    // O aviso é consumido: a interface não repete a notificação a cada ciclo.
    #expect(await fila.consumirAvisoDeAbertura() == nil)

    let naPasta = try FileManager.default.contentsOfDirectory(atPath: raiz.path)
    #expect(!naPasta.contains("fila.json"))
    #expect(naPasta.contains { $0.hasPrefix("fila.json.corrupted-") })
}

@Test("Um item ilegível não leva junto o resto da fila")
func filaRecuperaOperacoesLegiveis() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("fila.json")
    let espaco = EspacoID()
    let equipe = equipeCloudKitDeTeste(espaco: espaco)
    let arquivo = Arquivo(titulo: "Sobrevivente", pastaRelativa: "", espaco: espaco)

    // Fila válida gravada normalmente, depois contaminada com um elemento que
    // o decoder não entende — o caso que a decodificação item a item cobre.
    let original = FilaPersistenteCloudKit(url: url)
    try await original.agendarEnvio(arquivo, para: equipe, revisao: Date(timeIntervalSince1970: 10))
    var elementos = try #require(
        try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [Any]
    )
    elementos.append(["id": "lixo", "acao": "enviar"])
    try JSONSerialization.data(withJSONObject: elementos).write(to: url)

    let reaberta = FilaPersistenteCloudKit(url: url)

    let pendentes = try await reaberta.operacoesPendentes()
    #expect(pendentes.count == 1)
    #expect(pendentes.first?.arquivoID == arquivo.id)
    let aviso = try #require(await reaberta.consumirAvisoDeAbertura())
    #expect(aviso.recuperadas == 1)
    #expect(aviso.descartadas == 1)

    // O que foi recuperado é regravado, para não depender de um `salvar`
    // posterior que pode nunca acontecer.
    let apos = FilaPersistenteCloudKit(url: url)
    #expect(try await apos.operacoesPendentes().count == 1)
    #expect(await apos.consumirAvisoDeAbertura() == nil)
}

@Test("Quarentenas antigas não se acumulam indefinidamente")
func quarentenasAntigasSaoLimpas() async throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("fila.json")
    for timestamp in 1...5 {
        try Data("[]".utf8).write(
            to: raiz.appendingPathComponent("fila.json.corrupted-\(timestamp)")
        )
    }

    _ = FilaPersistenteCloudKit(url: url)

    let restantes = try FileManager.default.contentsOfDirectory(atPath: raiz.path)
        .filter { $0.hasPrefix("fila.json.corrupted-") }
        .sorted()
    #expect(restantes == ["fila.json.corrupted-3", "fila.json.corrupted-4", "fila.json.corrupted-5"])
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
    private let falhasPorRegistro: [FalhaDeConversaCloudKit]
    private var falharAoSalvar: Bool
    private var indiceDaPagina = 0
    private var arquivoSalvo: Data?

    init(
        paginas: [[Data]],
        falharAoPaginar: Bool = false,
        falharAoSalvar: Bool = false,
        falhasPorRegistro: [FalhaDeConversaCloudKit] = []
    ) {
        self.paginas = paginas
        self.falharAoPaginar = falharAoPaginar
        self.falharAoSalvar = falharAoSalvar
        self.falhasPorRegistro = falhasPorRegistro
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
        return PaginaDeConversasCloudKit(
            registros: paginas[atual],
            proxima: proxima,
            // Como no transporte real, as falhas por registro acompanham a
            // primeira página do fetch.
            falhas: atual == 0 ? falhasPorRegistro : []
        )
    }

    func remover(id: String, equipe: EquipeDisponivel) {}

    func quantidadeDePaginasLidas() -> Int { indiceDaPagina }
    func ultimoArquivoSalvo() -> Data? { arquivoSalvo }
    func definirFalhaAoSalvar(_ falhar: Bool) { falharAoSalvar = falhar }
}

/// Servidor de equipes falso que modela as regras do CloudKit relevantes para
/// a entrada por código.
///
/// A que importa aqui: um `CKShare` com `publicPermission == .none` é privado
/// e só aceita identidades incluídas por `addParticipant(_:)`. Como o app
/// nunca adiciona participante nenhum, `aceitarCompartilhamento` falha com
/// `permissionFailure` nesse caso — igual ao CloudKit real.
private actor ServidorDeEquipesFake: TransporteDeEquipesCloudKit {
    private var registrosPorID: [CKRecord.ID: CKRecord] = [:]
    private var zonaPorURL: [URL: CKRecordZone.ID] = [:]
    private var permissaoPorURL: [URL: CKShare.ParticipantPermission] = [:]
    private var participantesPorURL: [URL: Set<String>] = [:]
    private var publicos: [CKRecord.ID: CKRecord] = [:]
    private var aceites = 0

    func garantirContaDisponivel() throws {}

    func criarEquipeCompartilhada(
        zona: CKRecordZone.ID,
        registroDaEquipe: CKRecord,
        titulo: String,
        permissaoPublica: CKShare.ParticipantPermission
    ) throws -> CompartilhamentoDaEquipe {
        registrosPorID[registroDaEquipe.recordID] = registroDaEquipe
        let url = URL(string: "https://www.icloud.com/share/\(zona.zoneName)")!
        zonaPorURL[url] = zona
        permissaoPorURL[url] = permissaoPublica
        participantesPorURL[url] = []
        return CompartilhamentoDaEquipe(recordName: "cloudkit.zoneshare", url: url)
    }

    func salvarRegistroPublico(_ registro: CKRecord) throws {
        publicos[registro.recordID] = registro
    }

    func registroPublico(comID id: CKRecord.ID) throws -> CKRecord {
        guard let registro = publicos[id] else {
            throw CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue))
        }
        return registro
    }

    func apagarRegistroPublico(comID id: CKRecord.ID) throws {
        publicos[id] = nil
    }

    func aceitarCompartilhamento(em url: URL) throws -> CKShare {
        guard let zona = zonaPorURL[url] else {
            throw CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue))
        }
        // A regra do CloudKit: sem permissão pública, só entra quem já foi
        // adicionado como participante.
        if permissaoPorURL[url] == CKShare.ParticipantPermission.none,
           participantesPorURL[url]?.contains("conta-convidada") != true {
            throw CKError(
                _nsError: NSError(domain: CKErrorDomain, code: CKError.Code.permissionFailure.rawValue)
            )
        }
        aceites += 1
        return CKShare(recordZoneID: zona)
    }

    func registroDaZonaCompartilhada(comID id: CKRecord.ID) throws -> CKRecord {
        guard let registro = registrosPorID[id] else {
            throw CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue))
        }
        return registro
    }

    func aceitesRealizados() -> Int { aceites }
    func registrosPublicos() -> [CKRecord.ID: CKRecord] { publicos }
}
