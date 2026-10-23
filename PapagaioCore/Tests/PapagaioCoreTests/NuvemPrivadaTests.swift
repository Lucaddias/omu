import Foundation
import LlamaRuntime
import Testing
@testable import PapagaioCore
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

// Resumo pela nuvem privada da Apple (Private Cloud Compute). A rede nunca
// entra aqui: o modelo de servidor é trocado por um falso que conta as
// requisições — é a contagem delas que gasta o limite diário de quem usa.

// MARK: - Modelo falso

private actor GeradorFalso: GeradorDaNuvemPrivada {
    enum Chamada: Equatable {
        case ata(String)
        case parte(String)
    }

    private(set) var chamadas: [Chamada] = []
    private var errosDaAta: [any Error]
    private var errosDaParte: [any Error]
    private let resumo: Resumo
    private let tokensDeEntrada: Int?

    init(
        resumo: Resumo = Resumo(titulo: "Kickoff", visaoGeral: "Alinhamento."),
        errosDaAta: [any Error] = [],
        errosDaParte: [any Error] = [],
        tokensDeEntrada: Int? = nil
    ) {
        self.resumo = resumo
        self.errosDaAta = errosDaAta
        self.errosDaParte = errosDaParte
        self.tokensDeEntrada = tokensDeEntrada
    }

    func resumoEstruturado(
        _ mensagens: PromptsDoResumo.Mensagens
    ) async throws -> RespostaDaNuvem<Resumo> {
        chamadas.append(.ata(mensagens.usuario))
        if !errosDaAta.isEmpty { throw errosDaAta.removeFirst() }
        return RespostaDaNuvem(resumo, tokensDeEntrada: tokensDeEntrada)
    }

    func texto(
        _ mensagens: PromptsDoResumo.Mensagens
    ) async throws -> RespostaDaNuvem<String> {
        chamadas.append(.parte(mensagens.usuario))
        if !errosDaParte.isEmpty { throw errosDaParte.removeFirst() }
        let numero = chamadas.filter { if case .parte = $0 { true } else { false } }.count
        return RespostaDaNuvem("parcial \(numero)", tokensDeEntrada: tokensDeEntrada)
    }

    var partes: [String] {
        chamadas.compactMap { if case let .parte(texto) = $0 { texto } else { nil } }
    }

    var atas: [String] {
        chamadas.compactMap { if case let .ata(texto) = $0 { texto } else { nil } }
    }
}

/// Guarda o que a engine aprendeu, como o `UserDefaults` faria.
private final class CalibragemEmMemoria: @unchecked Sendable {
    private let trava = NSLock()
    private var valor: Double?

    init(_ valor: Double? = nil) { self.valor = valor }

    var atual: Double? { trava.withLock { valor } }

    var calibragem: NuvemPrivadaEngine.Calibragem {
        .init(
            ler: { self.trava.withLock { self.valor } },
            gravar: { novo in self.trava.withLock { self.valor = novo } }
        )
    }
}

private func reuniao(trechos quantidade: Int, palavrasPorTrecho: Int = 12) -> [Trecho] {
    (0..<quantidade).map { indice in
        Trecho(
            start: TimeInterval(indice * 10),
            end: TimeInterval(indice * 10 + 9),
            texto: Array(repeating: "palavra", count: palavrasPorTrecho).joined(separator: " ")
                + " \(indice)",
            speaker: indice.isMultiple(of: 2) ? Speaker.eu : Speaker.interlocutor
        )
    }
}

// MARK: - Prompts

@Test("Instruções da nuvem não carregam a moldura ChatML do Qwen")
func promptsDaNuvemSemChatML() {
    let ata = PromptsDoResumo.ata(
        transcricao: "[00:00] (eu) Vamos decidir hoje.", idiomaDeSaida: nil
    )
    for texto in [ata.sistema, ata.usuario] {
        #expect(!texto.contains("<|im_start|>"))
        #expect(!texto.contains("<|im_end|>"))
        #expect(!texto.contains("<think>"))
    }
    #expect(ata.usuario.contains("[00:00] (eu) Vamos decidir hoje."))
    #expect(ata.usuario.contains(GramaticaDoResumo.descricaoDoFormato))
    #expect(ata.sistema.contains("não a traduza"))

    let emIngles = PromptsDoResumo.ata(transcricao: "x", idiomaDeSaida: .ingles)
    #expect(emIngles.sistema.contains("English"))
}

@Test("O Qwen continua recebendo as mesmas instruções, dentro do ChatML")
func promptDoQwenEmbrulhaAsInstrucoesCompartilhadas() {
    let ata = PromptsDoResumo.ata(transcricao: "[00:00] (eu) Oi.", idiomaDeSaida: nil)
    let prompt = QwenEngine.prompt(paraTranscricao: "[00:00] (eu) Oi.")

    #expect(prompt.hasPrefix("<|im_start|>system\n\(ata.sistema)<|im_end|>\n<|im_start|>user\n"))
    #expect(prompt.contains("\(ata.usuario)<|im_end|>\n<|im_start|>assistant\n"))
}

// MARK: - Passe único

@Test("Reunião que cabe na janela custa uma requisição só")
func passeUnicoGastaUmaRequisicao() async throws {
    let trechos = [
        Trecho(
            start: 42, end: 50,
            texto: "Precisamos ouvir os alunos antes de decidir o próximo passo do projeto.",
            speaker: Speaker.eu
        ),
        Trecho(start: 80, end: 88, texto: "Combinado, eu mando o convite hoje.", speaker: Speaker.interlocutor),
    ]
    let gerador = GeradorFalso(resumo: Resumo(
        titulo: "Ata: Pesquisa com alunos",
        visaoGeral: "Decisão adiada.",
        citacoes: [
            Citacao(
                texto: "Precisamos ouvir os alunos antes de decidir o próximo passo do projeto.",
                speaker: nil, start: 999
            ),
            Citacao(texto: "Uma frase inventada que ninguém disse nesta reunião aqui.", speaker: nil, start: 1),
        ]
    ))

    let resumo = try await NuvemPrivadaEngine(gerador: gerador).summarize(trechos)

    #expect(await gerador.chamadas.count == 1)
    #expect(await gerador.atas.first?.contains("[00:42] (eu) Precisamos ouvir") == true)
    #expect(resumo.titulo == "Pesquisa com alunos")
    // O modelo sugere; a transcrição decide — igual ao Qwen.
    #expect(resumo.citacoes.count == 1)
    #expect(resumo.citacoes.first?.start == 42)
    #expect(resumo.citacoes.first?.speaker == Speaker.eu)
}

@Test("Transcrição vazia não gasta requisição")
func transcricaoVaziaNaoChegaNaNuvem() async {
    let gerador = GeradorFalso()
    await #expect(throws: ErroDeResumo.transcricaoVazia) {
        _ = try await NuvemPrivadaEngine(gerador: gerador).summarize([])
    }
    #expect(await gerador.chamadas.isEmpty)
}

@Test("O idioma de saída pedido chega nas instruções")
func idiomaDeSaidaVaiParaAsInstrucoes() async throws {
    let gerador = GeradorFalso()
    _ = try await NuvemPrivadaEngine(gerador: gerador)
        .summarize(reuniao(trechos: 2), idiomaDeSaida: .ingles)
    #expect(await gerador.chamadas.count == 1)
}

// MARK: - Map-reduce

@Test("Reunião longa vai em poucas partes grandes e uma consolidação")
func reuniaoLongaUsaChunksGrandes() async throws {
    // ~110 bytes por linha formatada; 2.000 linhas ≈ 73 mil tokens estimados.
    let trechos = reuniao(trechos: 2_000)
    let estimativa = OrcamentoDeTokens().estimar(QwenEngine.formatar(trechos))
    #expect(estimativa > NuvemPrivadaEngine.tetoDeEntrada)

    let gerador = GeradorFalso()
    _ = try await NuvemPrivadaEngine(gerador: gerador).summarize(trechos)

    let partes = await gerador.partes
    let esperado = Int((Double(estimativa) / Double(NuvemPrivadaEngine.tokensPorChunk)).rounded(.up))
    #expect(partes.count >= esperado)
    #expect(partes.count <= esperado + 1)
    // Uma consolidação, depois de todas as partes, com elas em ordem.
    let atas = await gerador.atas
    #expect(atas.count == 1)
    #expect(await gerador.chamadas.last == .ata(atas[0]))
    #expect(atas[0].contains("## Parte 1\nparcial 1"))
    #expect(atas[0].contains("## Parte \(partes.count)\nparcial \(partes.count)"))
    // Nenhum trecho fica de fora nem aparece duas vezes.
    #expect(partes.first?.contains("palavra 0") == true)
    #expect(partes.last?.contains("palavra 1999") == true)
    let linhas = partes.reduce(0) { $0 + $1.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count }
    #expect(linhas == trechos.count)
}

@Test("Janela excedida no passe único vira map-reduce e corrige a estimativa")
func janelaExcedidaCaiNoMapReduce() async throws {
    let trechos = reuniao(trechos: 500)
    let memoria = CalibragemEmMemoria()
    let gerador = GeradorFalso(errosDaAta: [
        ErroDaNuvemPrivada.contextoExcedido(tokens: 40_000, limite: NuvemPrivadaEngine.janela),
    ])

    _ = try await NuvemPrivadaEngine(gerador: gerador, calibragem: memoria.calibragem)
        .summarize(trechos)

    let chamadas = await gerador.chamadas
    // 1 ata recusada + partes + 1 consolidação.
    #expect(await gerador.atas.count == 2)
    #expect(await gerador.partes.count >= 2)
    if case .ata = chamadas.first {} else { Issue.record("a primeira tentativa é o passe único") }
    // A proporção aprendida fica abaixo da inicial e sobrevive à execução.
    let aprendida = try #require(memoria.atual)
    #expect(aprendida < OrcamentoDeTokens.bytesPorTokenInicial)
}

@Test("Parte que excede a janela é recortada sem repetir as que já passaram")
func parteExcedidaNaoRefazAsAnteriores() async throws {
    let trechos = reuniao(trechos: 2_000)
    let gerador = GeradorFalso(errosDaParte: [
        ErroDaNuvemPrivada.contextoExcedido(tokens: 60_000, limite: NuvemPrivadaEngine.janela),
    ])

    _ = try await NuvemPrivadaEngine(gerador: gerador).summarize(trechos)

    let partes = await gerador.partes
    // A primeira tentativa foi recusada; a seguinte recomeça do mesmo trecho,
    // menor.
    #expect(partes[0].contains("palavra 0"))
    #expect(partes[1].contains("palavra 0"))
    #expect(partes[1].utf8.count < partes[0].utf8.count)
    // As partes aceitas cobrem a reunião inteira, uma vez.
    let aceitas = partes.dropFirst()
    let linhas = aceitas.reduce(0) { $0 + $1.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count }
    #expect(linhas == trechos.count)
}

@Test("Um trecho sozinho maior que a janela desiste em vez de insistir")
func trechoGiganteNaoEntraEmLaco() async {
    let gigante = [Trecho(
        start: 0, end: 10,
        texto: String(repeating: "palavra ", count: 30_000),
        speaker: nil
    )]
    let erro = ErroDaNuvemPrivada.contextoExcedido(tokens: 90_000, limite: NuvemPrivadaEngine.janela)
    let gerador = GeradorFalso(errosDaParte: [erro, erro, erro])

    await #expect(throws: erro) {
        _ = try await NuvemPrivadaEngine(gerador: gerador).summarize(gigante)
    }
    #expect(await gerador.partes.count == 1)
}

@Test("Chunk nunca é vazio e respeita o teto estimado")
func proximoChunkRespeitaOTeto() {
    let trechos = reuniao(trechos: 1_500)[...]
    let orcamento = OrcamentoDeTokens()
    let chunk = NuvemPrivadaEngine.proximoChunk(de: trechos, orcamento: orcamento)

    #expect(!chunk.isEmpty)
    #expect(chunk.count < trechos.count)
    #expect(orcamento.estimar(QwenEngine.formatar(Array(chunk))) <= NuvemPrivadaEngine.tokensPorChunk)

    let enorme = [Trecho(start: 0, end: 1, texto: String(repeating: "x", count: 200_000), speaker: nil)][...]
    #expect(NuvemPrivadaEngine.proximoChunk(de: enorme, orcamento: orcamento).count == 1)
}

// MARK: - Orçamento de tokens

@Test("Orçamento de tokens deixa a saída caber na janela")
func orcamentoCabeNaJanela() {
    #expect(
        NuvemPrivadaEngine.tetoDeEntrada + NuvemPrivadaEngine.tokensDeSaida
            < NuvemPrivadaEngine.janela
    )
    #expect(
        NuvemPrivadaEngine.tokensPorChunk + NuvemPrivadaEngine.tokensDeSaidaParcial
            < NuvemPrivadaEngine.janela
    )
    // Chunk grande é o ponto: menos requisições que os 8 mil do Qwen.
    #expect(NuvemPrivadaEngine.tokensPorChunk > QwenEngine.tokensPorChunk)
    #expect(NuvemPrivadaEngine.janela == Int(ContextoLlama.janelaPadrao))
}

@Test("A estimativa aprende com a contagem real, com margem e dentro da faixa")
func orcamentoCalibra() {
    var orcamento = OrcamentoDeTokens()
    let texto = String(repeating: "a", count: 3_000)
    #expect(orcamento.estimar(texto) == 1_000)

    // 3.000 bytes em 750 tokens = 4 bytes por token; com 10% de margem, 3,6.
    orcamento.calibrar(texto: texto, tokensReais: 750)
    #expect(abs(orcamento.bytesPorToken - 3.6) < 0.001)
    #expect(orcamento.estimar(texto) > 750)

    // Contagens absurdas não tiram a proporção da faixa útil.
    orcamento.calibrar(texto: texto, tokensReais: 1)
    #expect(orcamento.bytesPorToken == 6.0)
    orcamento.calibrar(texto: texto, tokensReais: 1_000_000)
    #expect(orcamento.bytesPorToken == 1.5)
    orcamento.calibrar(texto: texto, tokensReais: 0)
    #expect(orcamento.bytesPorToken == 1.5)

    #expect(OrcamentoDeTokens(bytesPorToken: 4.2).bytesPorToken == 4.2)
    #expect(OrcamentoDeTokens(bytesPorToken: 0).bytesPorToken == 1.5)
}

@Test("O que a Apple cobrou de entrada calibra a próxima reunião")
func usoRealCalibraAProximaExecucao() async throws {
    let trechos = reuniao(trechos: 10)
    let ata = PromptsDoResumo.ata(transcricao: QwenEngine.formatar(trechos), idiomaDeSaida: nil)
    // Tokenizador imaginário de 4 bytes por token.
    let gerador = GeradorFalso(tokensDeEntrada: ata.texto.utf8.count / 4)
    let memoria = CalibragemEmMemoria()

    _ = try await NuvemPrivadaEngine(gerador: gerador, calibragem: memoria.calibragem)
        .summarize(trechos)

    let aprendida = try #require(memoria.atual)
    #expect(abs(aprendida - 3.6) < 0.01)
}

// MARK: - Erros

@Test("Rede, cota e serviço adiam o resumo; o resto não se resolve esperando")
func errosAdiaveis() {
    #expect(ErroDaNuvemPrivada.semConexao.adiavel)
    #expect(ErroDaNuvemPrivada.cotaEsgotada(reiniciaEm: nil).adiavel)
    #expect(ErroDaNuvemPrivada.servicoIndisponivel.adiavel)

    #expect(!ErroDaNuvemPrivada.conteudoRecusado.adiavel)
    #expect(!ErroDaNuvemPrivada.idiomaNaoSuportado.adiavel)
    #expect(!ErroDaNuvemPrivada.contextoExcedido(tokens: 1, limite: 1).adiavel)
    #expect(!ErroDaNuvemPrivada.indisponivel(.sistemaAntigo).adiavel)
    #expect(!ErroDaNuvemPrivada.falha("x").adiavel)
}

@Test("Erros da nuvem chegam à tela com mensagem própria")
func errosDaNuvemTemMensagem() {
    let erros: [ErroDaNuvemPrivada] = [
        .semConexao, .cotaEsgotada(reiniciaEm: nil), .servicoIndisponivel,
        .conteudoRecusado, .idiomaNaoSuportado, .indisponivel(.dispositivoNaoElegivel),
    ]
    for erro in erros {
        #expect(!erro.localizedDescription.contains("operation couldn"))
        #expect(!erro.localizedDescription.isEmpty)
    }
    #expect(ErroDaNuvemPrivada.conteudoRecusado.localizedDescription.contains("neste Mac"))
}

@Test("Erros adiáveis sobem intactos para quem decide adiar")
func erroAdiavelAtravessaAEngine() async {
    let gerador = GeradorFalso(errosDaAta: [ErroDaNuvemPrivada.cotaEsgotada(reiniciaEm: nil)])
    await #expect(throws: ErroDaNuvemPrivada.cotaEsgotada(reiniciaEm: nil)) {
        _ = try await NuvemPrivadaEngine(gerador: gerador).summarize(reuniao(trechos: 3))
    }
    #expect(await gerador.chamadas.count == 1)
}

@Test("Sem entitlement, a engine de produção recusa em vez de tocar na rede")
func semEntitlementNaoHaNuvem() async {
    // O host de testes não carrega o entitlement gerenciado da Apple.
    #expect(NuvemPrivada.disponibilidade != .disponivel)
    #expect(NuvemPrivada.cota == .livre)

    do {
        _ = try await NuvemPrivadaEngine(calibragem: .nenhuma).summarize(reuniao(trechos: 2))
        Issue.record("esperava ErroDaNuvemPrivada.indisponivel")
    } catch let erro as ErroDaNuvemPrivada {
        guard case .indisponivel = erro else {
            Issue.record("esperava .indisponivel, veio \(erro)")
            return
        }
    } catch {
        Issue.record("erro inesperado: \(error)")
    }
}

// MARK: - Preflight por modo

@Test("Na nuvem privada só o Whisper precisa estar em disco")
func pesosPorModo() {
    #expect(Pesos.necessarios(para: .local) == Pesos.todos)
    #expect(Pesos.necessarios(para: .nuvemPrivada) == [Pesos.whisperLargeV3])
    #expect(Preflight.ramMinima(para: .local) == Preflight.ramMinima)
    #expect(Preflight.ramMinima(para: .nuvemPrivada) == 8 * 1_073_741_824)
    #expect(Preflight.ramMinimaNaNuvem < Preflight.ramMinima)
}

@Test("Preflight da nuvem pede só o download do Whisper")
func preflightDaNuvem() {
    guard Preflight.ramInstalada >= Preflight.ramMinimaNaNuvem else { return }
    let vazia = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let gb: Int64 = 1_073_741_824

    // 6 GB livres bastam para o Whisper (3,1 GB) mais a folga…
    let preflight = Preflight(pastaDeModelos: vazia, discoLivre: 6 * gb)
    #expect(preflight.avaliar(para: .nuvemPrivada) == .pesosFaltando([Pesos.whisperLargeV3]))

    // …mas não para os dois pesos do modo local.
    if Preflight.ramInstalada >= Preflight.ramMinima {
        #expect(preflight.avaliar(para: .local).bloqueia)
    }
}

@Test("Mensagem de memória aponta a nuvem quando ela resolve")
func mensagemDeMemoriaPorSituacao() {
    let gb: Int64 = 1_073_741_824

    let comNuvem = ResultadoPreflight.mensagemDeRAM(
        instalada: 8 * gb, minima: Preflight.ramMinima, nuvemDisponivel: true
    )
    #expect(comNuvem.contains("nuvem privada da Apple"))
    #expect(!comNuvem.lowercased().contains("não há modo reduzido"))

    let semNuvem = ResultadoPreflight.mensagemDeRAM(
        instalada: 8 * gb, minima: Preflight.ramMinima, nuvemDisponivel: false
    )
    #expect(semNuvem.lowercased().contains("não há modo reduzido"))

    // Nem o Whisper cabe: a nuvem não é saída, e a frase não promete resumo local.
    let pequeno = ResultadoPreflight.mensagemDeRAM(
        instalada: 4 * gb, minima: Preflight.ramMinimaNaNuvem, nuvemDisponivel: true
    )
    #expect(pequeno.contains("8 GB"))
    #expect(pequeno.contains("transcrever"))
    #expect(!pequeno.contains("nuvem privada"))
}

// MARK: - Falantes com outro modelo

private func palavra(
    _ texto: String, _ inicio: TimeInterval, falante: String? = nil
) -> Palavra {
    Palavra(start: inicio, end: inicio + 0.5, texto: texto, falanteAcustico: falante)
}

/// `casos` falas curtas sem falante, cada uma entre S1 e S2.
private func conversa(casos: Int) -> Arquivo {
    var trechos: [Trecho] = []
    var relogio: TimeInterval = 0
    func trecho(_ palavras: [Palavra]) -> Trecho {
        Trecho(
            start: palavras.first?.start ?? relogio,
            end: (palavras.last?.end ?? relogio),
            texto: palavras.map(\.texto).joined(separator: " "),
            palavras: palavras
        )
    }
    for indice in 0..<casos {
        trechos.append(trecho([
            palavra("pergunta", relogio, falante: "S1"),
            palavra("\(indice)", relogio + 1, falante: "S1"),
        ]))
        relogio += 5
        trechos.append(trecho([palavra("sim", relogio), palavra("claro", relogio + 1)]))
        relogio += 5
        trechos.append(trecho([
            palavra("seguindo", relogio, falante: "S2"),
            palavra("\(indice)", relogio + 1, falante: "S2"),
        ]))
        relogio += 5
    }
    return Arquivo(titulo: "T", pastaRelativa: "x", espaco: EspacoID(), trechos: trechos)
}

private func falantesDasDuvidosas(_ arquivo: Arquivo) -> [String?] {
    arquivo.trechos
        .filter { $0.texto == "sim claro" }
        .map { $0.palavras.first?.falanteAcustico }
}

@Test("Instruções da resolução de falantes também saem sem ChatML")
func mensagensDeFalantesSemChatML() {
    let arquivo = conversa(casos: 2)
    let casos = ResolvedorDeFalantes.casosElegiveis(
        falas: FalasDaConversa.agrupar(arquivo.trechos)!
    )
    let mensagens = ResolvedorDeFalantes.mensagens(para: casos)

    #expect(!mensagens.sistema.contains("<|im_start|>"))
    #expect(!mensagens.usuario.contains("<|im_end|>"))
    #expect(mensagens.sistema.contains("\"indeterminado\""))
    #expect(mensagens.usuario.contains("CASO 1"))
    #expect(mensagens.usuario.contains("CASO 2"))
    #expect(ResolvedorDeFalantes.prompt(para: casos).contains(mensagens.usuario))
}

@Test("Resolução em lotes aplica as respostas e tolera um lote perdido")
func resolucaoEmLotesToleraFalha() async throws {
    let arquivo = conversa(casos: 5)
    let lotes = LockedBox<[Int]>([])

    let resolvido = try await ResolvedorDeFalantes.resolver(arquivo, casosPorChamada: 2) { casos in
        let numero = lotes.withLock { $0.append(casos.count); return $0.count }
        // O segundo lote falha: os casos dele ficam sem dono, os outros seguem.
        if numero == 2 { throw ErroDaNuvemPrivada.servicoIndisponivel }
        let pares = casos.indices.map { "\"\($0 + 1)\":\"voz-2\"" }.joined(separator: ",")
        return "{\(pares)}"
    }

    #expect(lotes.withLock { $0 } == [2, 2, 1])
    #expect(falantesDasDuvidosas(resolvido) == ["S2", "S2", nil, nil, "S2"])
}

@Test("Sem caso para resolver, o modelo nem é chamado")
func resolucaoSemCasosNaoChamaOModelo() async throws {
    let semDuvida = Arquivo(
        titulo: "T", pastaRelativa: "x", espaco: EspacoID(),
        trechos: [Trecho(
            start: 0, end: 1, texto: "oi tudo",
            palavras: [palavra("oi", 0, falante: "S1"), palavra("tudo", 1, falante: "S1")]
        )]
    )
    let chamadas = LockedBox(0)

    let resultado = try await ResolvedorDeFalantes.resolver(semDuvida) { _ in
        chamadas.withLock { $0 += 1 }
        return "{}"
    }

    #expect(chamadas.withLock { $0 } == 0)
    #expect(resultado.trechos == semDuvida.trechos)
}

@Test("Cancelar interrompe a resolução em vez de virar lote perdido")
func resolucaoPropagaCancelamento() async {
    let arquivo = conversa(casos: 3)
    await #expect(throws: CancellationError.self) {
        _ = try await ResolvedorDeFalantes.resolver(arquivo, casosPorChamada: 1) { _ in
            throw CancellationError()
        }
    }
}

private final class LockedBox<Valor>: @unchecked Sendable {
    private let trava = NSLock()
    private var valor: Valor

    init(_ valor: Valor) { self.valor = valor }

    func withLock<R>(_ corpo: (inout Valor) -> R) -> R {
        trava.withLock { corpo(&valor) }
    }
}

// MARK: - Tipos da Apple

#if compiler(>=6.4) && canImport(FoundationModels)

@Test("Ata gerada vira Resumo, e \"null\" escrito não vira nome de ninguém")
func ataGeradaViraResumo() {
    let gerado = ResumoGerado(
        titulo: "Ata: Revisão do MVP",
        visaoGeral: "Escopo fechado.",
        temas: [TemaGerado(titulo: "Prazo", detalhe: "Sete dias.")],
        citacoes: [
            CitacaoGerada(texto: "vamos negociar", speaker: "eu", start: 91.2),
            CitacaoGerada(texto: "sem dono", speaker: " null ", start: nil),
        ],
        proximosPassos: [
            PassoGerado(descricao: "ligar", responsavel: "Luca"),
            PassoGerado(descricao: "enviar", responsavel: "null"),
            PassoGerado(descricao: "revisar", responsavel: nil),
        ]
    )

    let resumo = gerado.comoResumo

    #expect(resumo.titulo == "Revisão do MVP")
    #expect(resumo.temas == [Tema(titulo: "Prazo", detalhe: "Sete dias.")])
    #expect(resumo.citacoes.map(\.speaker) == ["eu", nil])
    #expect(resumo.citacoes.first?.start == 91.2)
    #expect(resumo.proximosPassos.map(\.responsavel) == ["Luca", nil, nil])
}

@Test("Esquema dos falantes aceita de um a doze casos")
func esquemaDosFalantes() throws {
    for quantidade in [1, ResolvedorDeFalantesNoDispositivo.casosPorChamada, 12] {
        _ = try ResolvedorDeFalantesNoDispositivo.esquema(quantidade: quantidade)
    }
    #expect(
        ResolvedorDeFalantesNoDispositivo.casosPorChamada
            <= ResolvedorDeFalantes.maxCasosPorChamada
    )
}

@Test("Cada erro da Apple vira o caso que o Ōmu sabe tratar")
func traducaoDosErrosDaApple() throws {
    guard #available(macOS 27.0, *) else { return }
    typealias PCC = PrivateCloudComputeLanguageModel.Error
    let volta = Date(timeIntervalSince1970: 1_800_000_000)

    func traduzido(_ erro: any Error) -> ErroDaNuvemPrivada? {
        TradutorDeErrosDaNuvem.traduzir(erro) as? ErroDaNuvemPrivada
    }

    #expect(traduzido(PCC.networkFailure(.init(debugDescription: "x"))) == .semConexao)
    #expect(
        traduzido(PCC.quotaLimitReached(.init(resetDate: volta, debugDescription: "x")))
            == .cotaEsgotada(reiniciaEm: volta)
    )
    #expect(traduzido(PCC.serviceUnavailable(.init(debugDescription: "x"))) == .servicoIndisponivel)

    #expect(
        traduzido(LanguageModelError.contextSizeExceeded(
            .init(contextSize: 32_768, tokenCount: 40_000, debugDescription: "x")
        )) == .contextoExcedido(tokens: 40_000, limite: 32_768)
    )
    #expect(
        traduzido(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x")))
            == .servicoIndisponivel
    )
    #expect(
        traduzido(LanguageModelError.guardrailViolation(.init(debugDescription: "x")))
            == .conteudoRecusado
    )
    // `.refusal` segue o mesmo ramo do guardrail. Não é construído aqui: o
    // inicializador público de `Refusal` existe no SDK do Xcode 27 beta e
    // falta no macOS 27.0.1 instalado — chamá-lo derruba o processo de testes.
    #expect(traduzido(LanguageModelError.timeout(.init(debugDescription: "x"))) == .servicoIndisponivel)
    #expect(
        traduzido(LanguageModelError.unsupportedLanguageOrLocale(
            .init(languageCode: .portuguese, debugDescription: "x")
        )) == .idiomaNaoSuportado
    )

    #expect(traduzido(URLError(.notConnectedToInternet)) == .semConexao)
    #expect(traduzido(ErroDaNuvemPrivada.conteudoRecusado) == .conteudoRecusado)
    #expect(TradutorDeErrosDaNuvem.traduzir(CancellationError()) is CancellationError)
    if case .falha = traduzido(NSError(domain: "x", code: 1)) {} else {
        Issue.record("erro desconhecido deveria virar .falha")
    }
}

#endif
