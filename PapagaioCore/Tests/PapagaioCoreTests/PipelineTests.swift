import Foundation
import Synchronization
import Testing
@testable import PapagaioCore

// Testes do pipeline que liga gravação → transcrição → resumo → persistência.
// Motores falsos: o que está sob teste é a orquestração (qual insumo, em que
// ordem, o que é salvo quando), não a qualidade do Whisper ou do Qwen — isso já
// tem teste próprio nas suítes com modelo.

/// Repositório de mentira que registra cada `salvar`, para provar que a
/// transcrição é persistida **antes** do resumo começar.
private actor RepositorioEspiao: ArquivoRepository {
    private(set) var salvos: [Arquivo] = []

    func salvar(_ a: Arquivo) async throws { salvos.append(a) }
    func buscar(termo: String, espaco: EspacoID) async throws -> [Arquivo] { [] }
    func listar(espaco: EspacoID) async throws -> [Arquivo] { salvos }
    func apagar(_ id: ArquivoID) async throws {}
}

private func montarGravacao(
    microfone: Bool,
    sistema: Bool,
    mixagem: Bool
) throws -> (Armazenamento, Arquivo) {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let armazenamento = Armazenamento(raiz: raiz)
    let id = UUID()
    let pasta = try armazenamento.criarPastaDaGravacao(id: id)

    // Conteúdo irrelevante: os motores são falsos. Só o *tamanho* importa —
    // é como o pipeline decide se o canal existe.
    let bytes = Data(repeating: 0, count: 64)
    if microfone {
        try bytes.write(to: pasta.appendingPathComponent(Armazenamento.Nome.microfone))
    }
    if sistema {
        try bytes.write(to: pasta.appendingPathComponent(Armazenamento.Nome.sistema))
    }
    if mixagem {
        try bytes.write(to: pasta.appendingPathComponent(Armazenamento.Nome.mixagem))
    }

    let arquivo = Arquivo(
        titulo: "Reunião",
        pastaRelativa: Armazenamento.caminhoRelativo(id: id),
        espaco: EspacoID()
    )
    return (armazenamento, arquivo)
}

private let resumoDeMentira = Resumo(
    titulo: "Resumo", visaoGeral: "visão", temas: [Tema(titulo: "t", detalhe: "d")]
)

@Test("Gravação com dois canais separa 'eu' de 'interlocutor'")
func pipelineMesclaOsCanais() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: true, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let repositorio = RepositorioEspiao()
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: repositorio,
        idTranscricao: "whisper-falso",
        idResumo: "qwen-falso",
        transcrever: { url, speaker in
            // O speaker recebido é o do canal; o texto identifica a origem.
            let doMicrofone = url.lastPathComponent == Armazenamento.Nome.microfone
            #expect(speaker == (doMicrofone ? Speaker.eu : Speaker.interlocutor))
            return doMicrofone
                ? [Trecho(start: 0, end: 3, texto: "oi")]
                : [Trecho(start: 4, end: 7, texto: "tudo bem")]
        },
        resumir: { _ in resumoDeMentira }
    )

    let final = try await pipeline.processar(arquivo)

    #expect(final.trechos.count == 2)
    #expect(final.trechos[0].speaker == Speaker.eu)
    #expect(final.trechos[1].speaker == Speaker.interlocutor)
    #expect(final.trechos[0].start < final.trechos[1].start)
    #expect(final.engineTranscricao == "whisper-falso")
    #expect(final.engineResumo == "qwen-falso")
    #expect(final.resumo?.titulo == "Resumo")
}

@Test("Arquivo importado (só mixagem) transcreve sem inventar falante")
func pipelineUsaMixagemQuandoNaoHaCanais() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { url, speaker in
            #expect(url.lastPathComponent == Armazenamento.Nome.mixagem)
            #expect(speaker == nil, "mixagem não permite atribuir falante")
            return [Trecho(start: 0, end: 2, texto: "conteúdo")]
        },
        resumir: { _ in resumoDeMentira }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(final.trechos.count == 1)
    #expect(final.trechos[0].speaker == nil)
}

@Test("Gravação legada (PCM) continua transcrevendo pelo fallback")
func pipelineLePcmLegado() async throws {
    // Mesma montagem do backend antigo: só `.pcm`, sem WAVs.
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let armazenamento = Armazenamento(raiz: raiz)
    let id = UUID()
    let pasta = try armazenamento.criarPastaDaGravacao(id: id)
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let bytes = Data(repeating: 0, count: 64)
    try bytes.write(to: pasta.appendingPathComponent(Armazenamento.Nome.pcmMicrofone))
    try bytes.write(to: pasta.appendingPathComponent(Armazenamento.Nome.pcmSistema))

    let arquivo = Arquivo(
        titulo: "Legada",
        pastaRelativa: Armazenamento.caminhoRelativo(id: id),
        espaco: EspacoID()
    )

    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { url, speaker in
            let eDoMicrofone = url.lastPathComponent == Armazenamento.Nome.pcmMicrofone
            #expect(eDoMicrofone || url.lastPathComponent == Armazenamento.Nome.pcmSistema)
            #expect(speaker == (eDoMicrofone ? Speaker.eu : Speaker.interlocutor))
            return [Trecho(start: 0, end: 1, texto: url.lastPathComponent)]
        },
        resumir: { _ in resumoDeMentira }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(final.trechos.count == 2)
    #expect(Set(final.trechos.map(\.speaker)) == [Speaker.eu, Speaker.interlocutor])
}

@Test("A transcrição é salva antes de o resumo começar")
func pipelineSalvaAntesDeResumir() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let repositorio = RepositorioEspiao()
    let fases = Mutex<[PipelineDeArquivo.Fase]>([])

    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: repositorio,
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in [Trecho(start: 0, end: 2, texto: "oi")] },
        resumir: { _ in
            // Neste ponto a transcrição já tem de estar no disco: se o resumo
            // falhar, o trabalho caro não pode ser perdido.
            let salvos = await repositorio.salvos
            #expect(salvos.count == 1)
            #expect(salvos[0].trechos.count == 1)
            #expect(salvos[0].resumo == nil)
            return resumoDeMentira
        }
    )

    try await pipeline.processar(arquivo) { fase in
        fases.withLock { $0.append(fase) }
    }

    let salvos = await repositorio.salvos
    #expect(salvos.count == 2)
    #expect(salvos[1].resumo != nil)
    #expect(fases.withLock { $0 } == [.transcrevendo, .diarizando, .salvando, .resumindo, .salvando])
}

@Test("Diarização roda por canal e casa falantes com as palavras")
func pipelineDiarizaPorCanal() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: true, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let diarizados = Mutex<[String]>([])
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { url, _ in
            // Palavras com timestamps por canal — o que a diarização vai casar.
            if url.lastPathComponent == Armazenamento.Nome.microfone {
                return [Trecho(
                    start: 0, end: 3, texto: "oi tudo", speaker: Speaker.eu,
                    palavras: [
                        Palavra(start: 0, end: 1, texto: "oi"),
                        Palavra(start: 1, end: 3, texto: "tudo"),
                    ]
                )]
            }
            return [Trecho(
                start: 4, end: 6, texto: "bem", speaker: Speaker.interlocutor,
                palavras: [Palavra(start: 4, end: 6, texto: "bem")]
            )]
        },
        resumir: { _ in resumoDeMentira },
        diarizar: { url in
            diarizados.withLock { $0.append(url.lastPathComponent) }
            // Um só falante em cada canal, cobrindo tudo: cada palavra herda S1.
            return [SegmentoDeFalante(falanteId: "S1", inicio: 0, fim: 10)]
        }
    )

    let final = try await pipeline.processar(arquivo)

    #expect(diarizados.withLock { $0 } == [
        Armazenamento.Nome.microfone, Armazenamento.Nome.sistema
    ])
    // O rótulo do canal não muda — diarização não é o speaker.
    #expect(final.trechos[0].speaker == Speaker.eu)
    #expect(final.trechos[1].speaker == Speaker.interlocutor)
    // As palavras herdaram o falante acústico com namespace do canal.
    #expect(final.trechos[0].palavras.allSatisfy { $0.falanteAcustico == "eu-S1" })
    #expect(final.trechos[1].palavras.allSatisfy { $0.falanteAcustico == "interlocutor-S1" })
}

@Test("Falha de diarização nunca derruba transcrição nem resumo")
func pipelineIsolaFalhaDeDiarizacao() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: true, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let repositorio = RepositorioEspiao()
    struct ErroDiarizacaoDeTeste: Error {}
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: repositorio,
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in [
            Trecho(
                start: 0, end: 2, texto: "oi", speaker: Speaker.eu,
                palavras: [Palavra(start: 0, end: 2, texto: "oi")]
            )
        ] },
        resumir: { _ in resumoDeMentira },
        diarizar: { _ in throw ErroDiarizacaoDeTeste() }
    )

    let final = try await pipeline.processar(arquivo)

    // Salvou tudo, duas vezes, e o resumo saiu — a diarização só faltou.
    #expect(await repositorio.salvos.count == 2)
    #expect(final.resumo?.titulo == "Resumo")
    #expect(final.trechos[0].palavras[0].falanteAcustico == nil)
}

@Test("Só com mixagem, a diarização é a única fonte de vozes e é chamada")
func pipelineDiarizaMixagemQuandoNaoHaCanais() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    // O trecho transcrito não faz Palavra — usa comPalavras para ancorar as
    // palavras à mixagem, como o Whisper faria num importado.
    let palavra = Palavra(start: 0, end: 1, texto: "oi")
    let chamouDiarizacao = Mutex(false)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            [Trecho(start: 0, end: 2, texto: "oi", palavras: [palavra])]
        },
        resumir: { _ in resumoDeMentira },
        diarizar: { url in
            chamouDiarizacao.withLock { $0 = true }
            #expect(url.lastPathComponent == Armazenamento.Nome.mixagem)
            return [SegmentoDeFalante(falanteId: "S1", inicio: 0, fim: 2)]
        }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(chamouDiarizacao.withLock { $0 } == true)
    #expect(final.trechos[0].palavras[0].falanteAcustico == "S1")
}

@Test("Diarizar arquivo existente não re-transcreve nem resume, só casa falantes")
func pipelineDiarizaExistenteSemRetranscrever() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: true, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    // O arquivo "antigo" já tem transcrição com palavras sem falante acústico.
    let antigo = Arquivo(
        id: arquivo.id,
        titulo: arquivo.titulo,
        criadoEm: arquivo.criadoEm,
        duracao: arquivo.duracao,
        pastaRelativa: arquivo.pastaRelativa,
        espaco: arquivo.espaco,
        trechos: [
            Trecho(
                start: 0, end: 3, texto: "oi tudo", speaker: Speaker.eu,
                palavras: [
                    Palavra(start: 0, end: 1, texto: "oi"),
                    Palavra(start: 1, end: 3, texto: "tudo"),
                ]
            )
        ],
        notas: arquivo.notas,
        resumo: resumoDeMentira,
        engineTranscricao: arquivo.engineTranscricao,
        engineResumo: arquivo.engineResumo,
        apagadoEm: arquivo.apagadoEm
    )

    let transcreveu = Mutex(false)
    let resumiu = Mutex(false)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            transcreveu.withLock { $0 = true }
            return []
        },
        resumir: { _ in
            resumiu.withLock { $0 = true }
            return resumoDeMentira
        },
        diarizar: { _ in
            [SegmentoDeFalante(falanteId: "S1", inicio: 0, fim: 10)]
        }
    )

    let diarizado = await pipeline.diarizarExistente(antigo)

    // Leve: nada de Whisper nem de Qwen.
    #expect(transcreveu.withLock { $0 } == false)
    #expect(resumiu.withLock { $0 } == false)
    // Só a diarização casou os falantes com as palavras já existentes,
    // com namespace do canal de origem.
    #expect(diarizado.trechos.flatMap(\.palavras).allSatisfy { $0.falanteAcustico == "eu-S1" })
    #expect(diarizado.resumo?.titulo == "Resumo")
}

@Test("Diarizar arquivo existente também resolve falantes pelo contexto quando há closure")
func pipelineDiarizaExistenteResolvePorContexto() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: true, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    // "oi" dentro do segmento S1; "sim" exatamente a meio caminho entre S1 e
    // S2 (empate de distâncias) — o alinhamento deixa sem falante de propósito,
    // caso do contexto.
    let antigo = Arquivo(
        id: arquivo.id,
        titulo: arquivo.titulo,
        criadoEm: arquivo.criadoEm,
        duracao: arquivo.duracao,
        pastaRelativa: arquivo.pastaRelativa,
        espaco: arquivo.espaco,
        trechos: [
            Trecho(
                start: 0, end: 3, texto: "oi sim", speaker: Speaker.eu,
                palavras: [
                    Palavra(start: 0, end: 1, texto: "oi"),
                    Palavra(start: 1.4, end: 1.6, texto: "sim"),
                ]
            )
        ],
        notas: arquivo.notas,
        resumo: resumoDeMentira,
        engineTranscricao: arquivo.engineTranscricao,
        engineResumo: arquivo.engineResumo,
        apagadoEm: arquivo.apagadoEm
    )

    let resolverChamado = Mutex(false)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in [] },
        resumir: { _ in resumoDeMentira },
        diarizar: { _ in
            [
                SegmentoDeFalante(falanteId: "S1", inicio: 0, fim: 1),
                SegmentoDeFalante(falanteId: "S2", inicio: 2, fim: 3),
            ]
        },
        resolverFalantes: { arquivo in
            resolverChamado.withLock { $0 = true }
            let trechos = arquivo.trechos.map { umTrecho in
                umTrecho.comPalavras(umTrecho.palavras.map { palavra in
                    guard palavra.falanteAcustico == nil else { return palavra }
                    // O namespace do canal já veio da diarização ("eu-S1").
                    // A resolução usa o mesmo prefixo para o segundo falante.
                    let canalPrefixo = umTrecho.speaker.map { "\($0)-" } ?? ""
                    return Palavra(
                        id: palavra.id,
                        start: palavra.start,
                        end: palavra.end,
                        texto: palavra.texto,
                        falanteAcustico: "\(canalPrefixo)S2"
                    )
                })
            }
            return Arquivo(
                id: arquivo.id,
                titulo: arquivo.titulo,
                criadoEm: arquivo.criadoEm,
                duracao: arquivo.duracao,
                pastaRelativa: arquivo.pastaRelativa,
                espaco: arquivo.espaco,
                trechos: trechos,
                notas: arquivo.notas,
                resumo: arquivo.resumo,
                engineTranscricao: arquivo.engineTranscricao,
                engineResumo: arquivo.engineResumo,
                apagadoEm: arquivo.apagadoEm
            )
        }
    )

    let diarizado = await pipeline.diarizarExistente(antigo)

    // A resolução contextual rodou em cima do resultado da diarização: "oi"
    // veio rotulado eu-S1 e continuou intacto; "sim" ganhou eu-S2.
    #expect(resolverChamado.withLock { $0 } == true)
    #expect(diarizado.trechos[0].palavras[0].falanteAcustico == "eu-S1")
    #expect(diarizado.trechos[0].palavras[1].falanteAcustico == "eu-S2")
}

@Test("Silêncio total não vira resumo inventado")
func pipelineNaoResumeTranscricaoVazia() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: true, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let chamouResumo = Mutex(false)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in [] },
        resumir: { _ in
            chamouResumo.withLock { $0 = true }
            return resumoDeMentira
        }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(final.trechos.isEmpty)
    #expect(final.resumo == nil)
    #expect(chamouResumo.withLock { $0 } == false)
}

@Test("Áudio ausente falha com mensagem que diz qual gravação")
func pipelineFalhaSemAudio() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: false
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in [] },
        resumir: { _ in resumoDeMentira }
    )

    await #expect(throws: ErroCaptura.self) {
        try await pipeline.processar(arquivo)
    }
}

@Test("Decisão de tradução respeita toggle, PT/EN e idioma já correspondente")
func decisaoDeTraducaoAutomatica() {
    let portugues = ConfiguracaoDeTraducaoAutomatica(habilitada: true, idiomaPadrao: .portugues)
    let ingles = ConfiguracaoDeTraducaoAutomatica(habilitada: true, idiomaPadrao: .ingles)
    let desligada = ConfiguracaoDeTraducaoAutomatica(habilitada: false, idiomaPadrao: .portugues)

    #expect(DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: "en", configuracao: portugues
    ))
    #expect(DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: "pt-BR", configuracao: ingles
    ))
    #expect(!DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: "pt", configuracao: portugues
    ))
    #expect(!DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: "en-US", configuracao: ingles
    ))
    #expect(!DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: "en", configuracao: desligada
    ))
    #expect(!DetectorDeIdiomaDaTranscricao.deveTraduzir(
        idiomaDetectado: nil, configuracao: portugues
    ))
}

@Test("Pipeline traduz antes de salvar e resume no idioma de destino")
func pipelineTraduzAntesDeSalvarEResumir() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let traducoes = Mutex(0)
    let idiomaDoResumo = Mutex<IdiomaDeProcessamento?>(nil)
    let fases = Mutex<[PipelineDeArquivo.Fase]>([])
    let idDoTrecho = UUID()
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            [Trecho(
                id: idDoTrecho,
                start: 2,
                end: 5,
                texto: "We need to approve the budget tomorrow.",
                speaker: Speaker.eu,
                palavras: [Palavra(start: 2, end: 3, texto: "We")]
            )]
        },
        resumir: { _ in resumoDeMentira },
        resumirNoIdioma: { _, idioma in
            idiomaDoResumo.withLock { $0 = idioma }
            return resumoDeMentira
        },
        traducaoAutomatica: .init(habilitada: true, idiomaPadrao: .portugues),
        traduzir: { trechos, destino in
            #expect(destino == .portugues)
            #expect(trechos[0].id == idDoTrecho)
            #expect(trechos[0].start == 2)
            #expect(trechos[0].end == 5)
            #expect(trechos[0].speaker == Speaker.eu)
            traducoes.withLock { $0 += 1 }
            return trechos.map {
                Trecho(
                    id: $0.id,
                    start: $0.start,
                    end: $0.end,
                    texto: "Precisamos aprovar o orçamento amanhã.",
                    speaker: $0.speaker,
                    palavras: []
                )
            }
        }
    )

    let final = try await pipeline.processar(arquivo) { fase in
        fases.withLock { $0.append(fase) }
    }

    #expect(traducoes.withLock { $0 } == 1)
    #expect(final.trechos[0].texto == "Precisamos aprovar o orçamento amanhã.")
    #expect(final.trechos[0].palavras.isEmpty)
    #expect(final.trechos[0].id == idDoTrecho)
    #expect(final.trechos[0].start == 2)
    #expect(final.trechos[0].end == 5)
    #expect(final.trechos[0].speaker == Speaker.eu)
    #expect(idiomaDoResumo.withLock { $0 } == .portugues)
    let observadas = fases.withLock { $0 }
    #expect(observadas.firstIndex(of: .traduzindo)! < observadas.firstIndex(of: .salvando)!)
    #expect(observadas.firstIndex(of: .traduzindo)! < observadas.firstIndex(of: .resumindo)!)
}

@Test("Pipeline não traduz inglês para sistema em inglês")
func pipelineMantemIdiomaQueJaEoPadrao() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let chamouTraducao = Mutex(false)
    let idiomaDoResumo = Mutex<IdiomaDeProcessamento?>(nil)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            [Trecho(start: 0, end: 3, texto: "The team will review the roadmap on Friday.")]
        },
        resumir: { _ in resumoDeMentira },
        resumirNoIdioma: { _, idioma in
            idiomaDoResumo.withLock { $0 = idioma }
            return resumoDeMentira
        },
        traducaoAutomatica: .init(habilitada: true, idiomaPadrao: .ingles),
        traduzir: { trechos, _ in
            chamouTraducao.withLock { $0 = true }
            return trechos
        }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(!chamouTraducao.withLock { $0 })
    #expect(final.trechos[0].texto == "The team will review the roadmap on Friday.")
    #expect(idiomaDoResumo.withLock { $0 } == .ingles)
}

@Test("Toggle desligado mantém a fonte e pede resumo sem idioma forçado")
func pipelineComTraducaoDesligadaMantemFonte() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let chamouTraducao = Mutex(false)
    let idiomaDoResumo = Mutex<IdiomaDeProcessamento?>(.portugues)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            [Trecho(start: 0, end: 2, texto: "The notes must remain in English.")]
        },
        resumir: { _ in resumoDeMentira },
        resumirNoIdioma: { _, idioma in
            idiomaDoResumo.withLock { $0 = idioma }
            return resumoDeMentira
        },
        traducaoAutomatica: .init(habilitada: false, idiomaPadrao: .portugues),
        traduzir: { trechos, _ in
            chamouTraducao.withLock { $0 = true }
            return trechos
        }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(!chamouTraducao.withLock { $0 })
    #expect(final.trechos[0].texto == "The notes must remain in English.")
    #expect(idiomaDoResumo.withLock { $0 } == nil)
}

@Test("Pipeline traduz português para inglês quando o sistema usa inglês")
func pipelineTraduzPortuguesParaIngles() async throws {
    let (armazenamento, arquivo) = try montarGravacao(
        microfone: false, sistema: false, mixagem: true
    )
    defer { try? FileManager.default.removeItem(at: armazenamento.raiz) }

    let chamouTraducao = Mutex(false)
    let pipeline = PipelineDeArquivo(
        armazenamento: armazenamento,
        repositorio: RepositorioEspiao(),
        idTranscricao: "w", idResumo: "q",
        transcrever: { _, _ in
            [Trecho(start: 0, end: 2, texto: "Vamos revisar o cronograma na sexta-feira.")]
        },
        resumir: { _ in resumoDeMentira },
        traducaoAutomatica: .init(habilitada: true, idiomaPadrao: .ingles),
        traduzir: { trechos, destino in
            #expect(destino == .ingles)
            chamouTraducao.withLock { $0 = true }
            return trechos.map {
                Trecho(id: $0.id, start: $0.start, end: $0.end, texto: "We will review the schedule on Friday.")
            }
        }
    )

    let final = try await pipeline.processar(arquivo)
    #expect(chamouTraducao.withLock { $0 })
    #expect(final.trechos[0].texto == "We will review the schedule on Friday.")
}
