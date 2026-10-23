import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

// O resumo pela nuvem privada da Apple muda três coisas no app: qual modo
// vale, o que acontece quando a nuvem não entrega, e o que fica em disco
// esperando. Nenhum teste aqui fala com a Apple nem carrega modelo: a
// `Biblioteca` recebe a nuvem por injeção (`resumirNaNuvem`), e resumir uma
// transcrição que já existe pela nuvem não exige peso nenhum em disco.

// MARK: - Modo escolhido

private func preferenciasDeTeste() -> (UserDefaults, String) {
    let nome = "ResumoPelaNuvemTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: nome)!, nome)
}

@Test("Sem escolha, o resumo é local: nada sai do Mac sem um sim")
func semEscolhaOResumoEhLocal() {
    let (preferencias, nome) = preferenciasDeTeste()
    defer { preferencias.removePersistentDomain(forName: nome) }

    #expect(PreferenciaDeResumo.escolha(em: preferencias) == nil)
    #expect(PreferenciaDeResumo.modoAtivo(em: preferencias, disponibilidade: .disponivel) == .local)
}

@Test("A escolha pela nuvem sobrevive a reabrir o app")
func escolhaPelaNuvemPersiste() {
    let (preferencias, nome) = preferenciasDeTeste()
    defer { preferencias.removePersistentDomain(forName: nome) }

    PreferenciaDeResumo.guardar(.nuvemPrivada, em: preferencias)

    let reaberta = UserDefaults(suiteName: nome)!
    #expect(PreferenciaDeResumo.escolha(em: reaberta) == .nuvemPrivada)
    #expect(PreferenciaDeResumo.modoAtivo(em: reaberta, disponibilidade: .disponivel) == .nuvemPrivada)

    PreferenciaDeResumo.guardar(.local, em: reaberta)
    #expect(PreferenciaDeResumo.modoAtivo(em: preferencias, disponibilidade: .disponivel) == .local)
}

@Test(
    "Indisponibilidade passageira mantém a nuvem; a definitiva volta para o local",
    arguments: [
        (DisponibilidadeDaNuvemPrivada.sistemaNaoPronto, ModoDeResumo.nuvemPrivada),
        (.indisponivel, .nuvemPrivada),
        (.sistemaAntigo, .local),
        (.semEntitlement, .local),
        (.dispositivoNaoElegivel, .local),
    ]
)
func nuvemInalcancavelVoltaParaOLocal(
    disponibilidade: DisponibilidadeDaNuvemPrivada,
    esperado: ModoDeResumo
) {
    let (preferencias, nome) = preferenciasDeTeste()
    defer { preferencias.removePersistentDomain(forName: nome) }
    PreferenciaDeResumo.guardar(.nuvemPrivada, em: preferencias)

    #expect(PreferenciaDeResumo.modoAtivo(em: preferencias, disponibilidade: disponibilidade) == esperado)
}

@MainActor
@Test("Trocar o modo muda o que o app exige em disco")
func modoDecideOsPesosExigidos() throws {
    let (preferencias, nome) = preferenciasDeTeste()
    defer { preferencias.removePersistentDomain(forName: nome) }
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }

    let modelos = ModelosViewModel(
        pastaDoContainer: pasta, ignorarPastaEscolhidaPersistida: true, preferencias: preferencias
    )
    #expect(modelos.modo == .local)

    var avisados: [ModoDeResumo] = []
    modelos.aoMudarModo = { avisados.append($0) }
    modelos.escolherModo(.nuvemPrivada)

    #expect(avisados == [.nuvemPrivada])
    #expect(PreferenciaDeResumo.escolha(em: preferencias) == .nuvemPrivada)
    // Na nuvem o Qwen deixa de ser exigido. (Abaixo do piso de memória o
    // preflight para antes de olhar os pesos.)
    #expect(!modelos.faltando.contains(Pesos.qwen35_9B))
    if Preflight.ramInstalada >= Preflight.ramMinimaNaNuvem {
        #expect(modelos.faltando == [Pesos.whisperLargeV3])
    }

    // Outra instância lê a mesma escolha: é o que acontece ao reabrir o app.
    let reaberto = ModelosViewModel(
        pastaDoContainer: pasta, ignorarPastaEscolhidaPersistida: true,
        preferencias: preferencias, disponibilidadeDaNuvem: { .disponivel }
    )
    #expect(reaberto.modo == .nuvemPrivada)
    #expect(reaberto.nuvemDisponivel)
    // Num build sem acesso à nuvem a mesma escolha volta para o local.
    let semAcesso = ModelosViewModel(
        pastaDoContainer: pasta, ignorarPastaEscolhidaPersistida: true,
        preferencias: preferencias, disponibilidadeDaNuvem: { .semEntitlement }
    )
    #expect(semAcesso.modo == .local)
    #expect(!semAcesso.nuvemDisponivel)
}

@MainActor
@Test("Remover o modelo local só apaga o que o Ōmu baixou, e só com o resumo na nuvem")
func removerModeloLocalRespeitaOModo() throws {
    let (preferencias, nome) = preferenciasDeTeste()
    defer { preferencias.removePersistentDomain(forName: nome) }
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }
    let qwen = pasta.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    let parcial = qwen.appendingPathExtension("parcial")
    try Data("peso".utf8).write(to: qwen)
    try Data("meio".utf8).write(to: parcial)

    let modelos = ModelosViewModel(
        pastaDoContainer: pasta, ignorarPastaEscolhidaPersistida: true, preferencias: preferencias
    )

    // No modo local o Qwen é o modelo em uso.
    #expect(!modelos.podeRemoverModeloLocal)
    modelos.removerModeloLocal()
    #expect(FileManager.default.fileExists(atPath: qwen.path))

    modelos.escolherModo(.nuvemPrivada)
    #expect(modelos.podeRemoverModeloLocal)
    modelos.removerModeloLocal()
    #expect(!FileManager.default.fileExists(atPath: qwen.path))
    #expect(!FileManager.default.fileExists(atPath: parcial.path))
    #expect(!modelos.podeRemoverModeloLocal)
    #expect(modelos.erro == nil)
}

@Test("Resumo adiado é aviso, não erro, e não trava a conversa")
func resumoAdiadoEhAviso() {
    let estado = EstadoDoArquivo.resumoAdiado("Sem internet")
    #expect(estado.estilo == .aviso)
    #expect(estado.descricao == "Sem internet")
    // Dá para pedir o resumo de novo, reprocessar ou mover para a lixeira.
    #expect(!estado.ocupado)
}

// MARK: - O que fazer quando a nuvem falha

@Test("Com o Qwen pronto, nenhuma falha da nuvem espera: o resumo sai neste Mac")
func comModeloLocalNuncaEspera() {
    let erros: [ErroDaNuvemPrivada] = [
        .semConexao, .cotaEsgotada(reiniciaEm: nil), .servicoIndisponivel, .conteudoRecusado,
        .idiomaNaoSuportado, .contextoExcedido(tokens: 40_000, limite: 32_768), .falha("x"),
        .indisponivel(.sistemaNaoPronto),
    ]
    for erro in erros {
        #expect(ReacaoAoErroDaNuvem.para(erro, modeloLocalPronto: true) == .resumirNoMac)
    }
}

@Test("Sem o Qwen, rede, cota e serviço adiam; o resto desiste com o motivo")
func semModeloLocalAdiaOQuePassaSozinho() {
    let agora = Date(timeIntervalSince1970: 1_800_000_000)
    let emBreve = agora.addingTimeInterval(EsperaDoResumo.intervaloDeNovaTentativa)
    let renovacao = agora.addingTimeInterval(6 * 3_600)
    func reacao(_ erro: ErroDaNuvemPrivada) -> ReacaoAoErroDaNuvem {
        ReacaoAoErroDaNuvem.para(erro, modeloLocalPronto: false, agora: agora)
    }

    #expect(reacao(.semConexao) == .adiar(.rede(ate: emBreve)))
    #expect(reacao(.servicoIndisponivel) == .adiar(.servico(ate: emBreve)))
    #expect(reacao(.cotaEsgotada(reiniciaEm: renovacao)) == .adiar(.cota(ate: renovacao)))
    // A Apple nem sempre diz quando o limite zera.
    #expect(reacao(.cotaEsgotada(reiniciaEm: nil))
        == .adiar(.cota(ate: agora.addingTimeInterval(EsperaDoResumo.esperaDaCotaSemData))))
    // Data já vencida não pode virar tentativa em laço.
    #expect(reacao(.cotaEsgotada(reiniciaEm: agora.addingTimeInterval(-3_600)))
        == .adiar(.cota(ate: agora.addingTimeInterval(60))))

    for erro: ErroDaNuvemPrivada in [
        .conteudoRecusado, .idiomaNaoSuportado, .falha("x"),
        .contextoExcedido(tokens: 40_000, limite: 32_768), .indisponivel(.semEntitlement),
    ] {
        #expect(reacao(erro) == .desistir)
    }
}

// MARK: - Fila em disco

@Test("Resumo adiado vira pedido de só-resumo, sem tentativa contada, com o motivo")
func adiamentoViraSomenteResumo() throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let fila = FilaDeProcessamentoPersistida(url: raiz.appendingPathComponent("Processamento/fila.json"))
    let (pessoal, equipe) = (EspacoID(), EspacoID())
    let (completo, daEquipe, novo) = (ArquivoID(), ArquivoID(), ArquivoID())
    let ate = Date(timeIntervalSince1970: 1_800_000_000)

    // O pedido era completo e já tinha começado: a transcrição foi salva e
    // só o resumo ficou devendo.
    fila.registrar(completo, espaco: pessoal, somenteResumo: false)
    fila.marcarInicio(completo)
    fila.adiarResumo(completo, espaco: pessoal, espera: .rede(ate: ate))
    fila.adiarResumo(daEquipe, espaco: equipe, espera: .rede(ate: ate))
    fila.adiarResumo(novo, espaco: pessoal, espera: .cota(ate: ate))

    let reaberta = FilaDeProcessamentoPersistida(url: fila.url)
    let pendencia = try #require(reaberta.pendentes(do: pessoal).first { $0.id == completo.rawValue })
    #expect(pendencia.somenteResumo)
    #expect(pendencia.tentativas == 0)
    #expect(pendencia.espera == .rede(ate: ate))

    // A internet voltou neste espaço: só quem esperava por ela é liberado.
    reaberta.liberarEsperaDeRede(do: pessoal)
    let esperas = Dictionary(uniqueKeysWithValues: fila.todas().map { ($0.id, $0.espera) })
    #expect(esperas[completo.rawValue] == .rede(ate: .distantPast))
    #expect(esperas[novo.rawValue] == .cota(ate: ate))
    #expect(esperas[daEquipe.rawValue] == .rede(ate: ate))

    // Pedir de novo é tentar agora.
    fila.registrar(novo, espaco: pessoal, somenteResumo: true)
    #expect(fila.todas().first { $0.id == novo.rawValue }?.espera == nil)
}

@Test("A fila gravada por versões anteriores continua legível")
func filaAntigaSemEsperaDecodifica() throws {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let url = raiz.appendingPathComponent("Processamento/fila.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let (id, espaco) = (UUID(), UUID())
    try Data("""
    [{"id":"\(id.uuidString)","espaco":"\(espaco.uuidString)","somenteResumo":false,"tentativas":1}]
    """.utf8).write(to: url)

    let pendencias = FilaDeProcessamentoPersistida(url: url).todas()
    #expect(pendencias == [
        PendenciaDeProcessamento(id: id, espaco: espaco, somenteResumo: false, tentativas: 1),
    ])
}

// MARK: - Biblioteca

/// A nuvem de mentira: responde o que o teste mandar, na ordem, e conta as
/// chamadas — cada uma seria uma requisição da cota diária.
private actor NuvemFalsa {
    private var respostas: [Result<Resumo, ErroDaNuvemPrivada>]
    private(set) var chamadas = 0

    init(_ respostas: [Result<Resumo, ErroDaNuvemPrivada>]) {
        self.respostas = respostas
    }

    func resumir() throws -> Resumo {
        chamadas += 1
        guard !respostas.isEmpty else { throw ErroDaNuvemPrivada.falha("sem resposta preparada") }
        return try respostas.removeFirst().get()
    }
}

private let resumoDaNuvem = Resumo(titulo: "Entrevista", visaoGeral: "Resumo vindo da nuvem.")

private struct CenarioDaNuvem {
    let biblioteca: Biblioteca
    let raiz: URL
    let fila: FilaDeProcessamentoPersistida
    let nuvem: NuvemFalsa
    let arquivo: Arquivo
}

/// Biblioteca em modo nuvem com uma conversa já transcrita. A pasta de
/// modelos fica vazia: sem Whisper e sem Qwen em disco.
@MainActor
private func cenarioDaNuvem(_ respostas: [Result<Resumo, ErroDaNuvemPrivada>]) async throws -> CenarioDaNuvem {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    let biblioteca = Biblioteca(
        armazenamento: Armazenamento(raiz: raiz),
        repositorio: SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal(nome: UUID().uuidString, emMemoria: true)
        ),
        espaco: EspacoID()
    )
    biblioteca.processamentoAutomatico = false
    biblioteca.modoDeResumo = .nuvemPrivada
    let nuvem = NuvemFalsa(respostas)
    biblioteca.resumirNaNuvem = { _, _ in try await nuvem.resumir() }

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
    // É a carga da lista que autoriza a retomada dos pedidos em disco.
    await biblioteca.carregar()
    let arquivo = try #require(biblioteca.arquivos.first { $0.id == registrada.id })
    return CenarioDaNuvem(
        biblioteca: biblioteca,
        raiz: raiz,
        fila: FilaDeProcessamentoPersistida(url: raiz.appendingPathComponent("Processamento/fila-pendente.json")),
        nuvem: nuvem,
        arquivo: arquivo
    )
}

@MainActor
private func aguardarFimDoProcessamento(_ biblioteca: Biblioteca, ate limite: TimeInterval = 5) async -> Bool {
    let fim = Date().addingTimeInterval(limite)
    while Date() < fim {
        if !biblioteca.processando { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return !biblioteca.processando
}

@MainActor
private func atual(_ cenario: CenarioDaNuvem) throws -> Arquivo {
    try #require(cenario.biblioteca.arquivos.first { $0.id == cenario.arquivo.id })
}

@MainActor
@Test("No modo nuvem o resumo sai sem nenhum modelo em disco e fica assinado pela engine da Apple")
func resumoPelaNuvemNaoExigePesos() async throws {
    let cenario = try await cenarioDaNuvem([.success(resumoDaNuvem)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }

    cenario.biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(cenario.biblioteca))

    let salvo = try #require(try await cenario.biblioteca.buscarArquivoCompleto(id: cenario.arquivo.id.rawValue))
    #expect(salvo.resumo == resumoDaNuvem)
    #expect(salvo.engineResumo == NuvemPrivadaEngine.identificador)
    #expect(cenario.biblioteca.estado(de: try atual(cenario)) == .transcritoEResumido)
    #expect(cenario.biblioteca.erros.isEmpty)
    #expect(cenario.fila.todas().isEmpty)
    #expect(await cenario.nuvem.chamadas == 1)
}

@MainActor
@Test("Sem internet o resumo espera em disco e sai sozinho quando a rede volta")
func semInternetOResumoEspera() async throws {
    let cenario = try await cenarioDaNuvem([.failure(.semConexao), .success(resumoDaNuvem)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca
    var notificacoes: [String] = []
    biblioteca.aoNotificar = { titulo, _, _ in notificacoes.append(titulo) }

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(biblioteca))

    // Não é falha: a conversa segue transcrita, com o motivo da espera.
    #expect(biblioteca.erros.isEmpty)
    guard case .resumoAdiado = biblioteca.estado(de: try atual(cenario)) else {
        Issue.record("esperava o resumo adiado, veio \(biblioteca.estado(de: try atual(cenario)))")
        return
    }
    let pendencia = try #require(cenario.fila.pendentes(do: cenario.arquivo.espaco).first)
    #expect(pendencia.somenteResumo)
    #expect(pendencia.tentativas == 0)
    #expect(pendencia.espera?.cedeARede == true)
    #expect(notificacoes == ["Resumo adiado".localized])

    // Recarregar a lista antes do prazo não gasta outra requisição.
    await biblioteca.carregar()
    #expect(!biblioteca.processando)
    #expect(await cenario.nuvem.chamadas == 1)

    // A rede voltou: a fila tenta de novo, mesmo com o processamento
    // automático desligado — o pedido já tinha sido feito.
    cenario.fila.liberarEsperaDeRede(do: cenario.arquivo.espaco)
    await biblioteca.carregar()
    #expect(await aguardarFimDoProcessamento(biblioteca))

    #expect(await cenario.nuvem.chamadas == 2)
    #expect(biblioteca.estado(de: try atual(cenario)) == .transcritoEResumido)
    #expect(biblioteca.resumosAdiados.isEmpty)
    #expect(cenario.fila.todas().isEmpty)
}

@MainActor
@Test("Com o limite diário atingido, nada é tentado antes da renovação")
func cotaEsgotadaEsperaARenovacao() async throws {
    let renovacao = Date().addingTimeInterval(2 * 3_600)
    let cenario = try await cenarioDaNuvem([.failure(.cotaEsgotada(reiniciaEm: renovacao))])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(biblioteca))

    let pendencia = try #require(cenario.fila.pendentes(do: cenario.arquivo.espaco).first)
    #expect(pendencia.espera == .cota(ate: renovacao))

    // Nem a volta da rede adianta um pedido que espera pela cota.
    cenario.fila.liberarEsperaDeRede(do: cenario.arquivo.espaco)
    await biblioteca.carregar()
    #expect(!biblioteca.processando)
    #expect(await cenario.nuvem.chamadas == 1)
    // Depois de reabrir a lista o cartão continua explicando a espera.
    #expect(biblioteca.estado(de: try atual(cenario)) == .resumoAdiado(EsperaDoResumo.cota(ate: renovacao).mensagem))
}

@MainActor
@Test("Um resumo novo adiado aparece como espera, mesmo com o resumo antigo ainda na conversa")
func novoResumoAdiadoNaoSeEscondeAtrasDoAntigo() async throws {
    let cenario = try await cenarioDaNuvem([.success(resumoDaNuvem), .failure(.servicoIndisponivel)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(biblioteca))
    #expect(biblioteca.estado(de: try atual(cenario)) == .transcritoEResumido)

    biblioteca.enfileirarNovoResumo(try atual(cenario))
    #expect(await aguardarFimDoProcessamento(biblioteca))

    guard case .resumoAdiado = biblioteca.estado(de: try atual(cenario)) else {
        Issue.record("esperava o resumo adiado, veio \(biblioteca.estado(de: try atual(cenario)))")
        return
    }
    // O resumo que já existia não se perde enquanto o novo espera.
    let salvo = try #require(try await biblioteca.buscarArquivoCompleto(id: cenario.arquivo.id.rawValue))
    #expect(salvo.resumo == resumoDaNuvem)
    #expect(cenario.fila.pendentes(do: cenario.arquivo.espaco).first?.espera?.cedeARede == false)
}

@MainActor
@Test("Uma nova tentativa que esbarra no mesmo motivo não notifica de novo")
func novaTentativaAdiadaNaoRepeteOAviso() async throws {
    let cenario = try await cenarioDaNuvem([.failure(.semConexao), .failure(.semConexao)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca
    var notificacoes: [String] = []
    biblioteca.aoNotificar = { titulo, _, _ in notificacoes.append(titulo) }

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(biblioteca))
    cenario.fila.liberarEsperaDeRede(do: cenario.arquivo.espaco)
    await biblioteca.carregar()
    #expect(await aguardarFimDoProcessamento(biblioteca))

    #expect(await cenario.nuvem.chamadas == 2)
    #expect(notificacoes == ["Resumo adiado".localized])
    #expect(cenario.fila.pendentes(do: cenario.arquivo.espaco).first?.tentativas == 0)
}

@MainActor
@Test("Conteúdo recusado pela Apple vira erro com o motivo, sem ficar tentando")
func conteudoRecusadoNaoEspera() async throws {
    let cenario = try await cenarioDaNuvem([.failure(.conteudoRecusado)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    #expect(await aguardarFimDoProcessamento(biblioteca))

    #expect(biblioteca.erros[cenario.arquivo.id.rawValue]
        == ErroDaNuvemPrivada.conteudoRecusado.localizedDescription.localized)
    #expect(biblioteca.resumosAdiados.isEmpty)
    #expect(cenario.fila.todas().isEmpty)
    // A transcrição continua lá.
    let salvo = try #require(try await biblioteca.buscarArquivoCompleto(id: cenario.arquivo.id.rawValue))
    #expect(salvo.trechos.count == 2)
    #expect(salvo.resumo == nil)
}

@MainActor
@Test(
    "Com o Qwen em disco, a falha da nuvem cai no modelo deste Mac em vez de esperar",
    .enabled(if: Preflight.ramInstalada >= Preflight.ramMinima)
)
func falhaDaNuvemCaiNoModeloLocal() async throws {
    let cenario = try await cenarioDaNuvem([.failure(.semConexao)])
    defer { try? FileManager.default.removeItem(at: cenario.raiz) }
    let biblioteca = cenario.biblioteca

    // Arquivo esparso do tamanho exato do peso: passa no preflight (que
    // confere tamanho, não conteúdo) sem ocupar 6 GB. Não é um GGUF, então
    // o Qwen recusa a carga — e é esse erro, não o da nuvem, que prova que
    // o plano B foi acionado.
    let pasta = cenario.raiz.appendingPathComponent("ModelosDeTeste")
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    let peso = pasta.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    FileManager.default.createFile(atPath: peso.path, contents: nil)
    let escrita = try FileHandle(forWritingTo: peso)
    try escrita.truncate(atOffset: UInt64(Pesos.qwen35_9B.bytes))
    try escrita.close()
    biblioteca.pastaDeModelos = pasta

    biblioteca.enfileirarNovoResumo(cenario.arquivo)
    // Iniciar o backend do llama e recusar o arquivo leva alguns segundos.
    #expect(await aguardarFimDoProcessamento(biblioteca, ate: 60))

    #expect(await cenario.nuvem.chamadas == 1)
    #expect(biblioteca.resumosAdiados.isEmpty)
    #expect(cenario.fila.todas().isEmpty)
    let erro = try #require(biblioteca.erros[cenario.arquivo.id.rawValue])
    #expect(erro.contains(Pesos.qwen35_9B.nomeArquivo))
}
