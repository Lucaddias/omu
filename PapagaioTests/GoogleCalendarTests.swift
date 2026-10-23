import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

@MainActor
@Test("Ignorar, restaurar e apagar reunião sobrevivem ao relançamento")
func estadoDasPendenciasDoCalendarPersiste() throws {
    let suite = "EstadoCalendarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let agora = Date()
    let evento = eventoCalendar(id: "planejamento", data: agora.addingTimeInterval(3_600))

    let primeiraExecucao = GoogleCalendarViewModel(defaults: defaults)
    primeiraExecucao.aplicar(eventos: [evento], biblioteca: nil, agora: agora)
    let pendente = try #require(primeiraExecucao.reunioesPendentes.first)
    primeiraExecucao.ignorarPendente(pendente)

    let segundaExecucao = GoogleCalendarViewModel(defaults: defaults)
    segundaExecucao.aplicar(eventos: [evento], biblioteca: nil, agora: agora)
    #expect(segundaExecucao.reunioesPendentes.isEmpty)
    #expect(segundaExecucao.reunioesIgnoradas.map(\.id) == ["planejamento"])

    segundaExecucao.restaurarPendente(pendente)
    #expect(segundaExecucao.reunioesPendentes.map(\.id) == ["planejamento"])
    #expect(segundaExecucao.reunioesIgnoradas.isEmpty)

    let terceiraExecucao = GoogleCalendarViewModel(defaults: defaults)
    terceiraExecucao.aplicar(eventos: [evento], biblioteca: nil, agora: agora)
    #expect(terceiraExecucao.reunioesPendentes.map(\.id) == ["planejamento"])
    terceiraExecucao.ignorarPendente(pendente)
    terceiraExecucao.apagarPendenteDefinitivamente(pendente)

    let quartaExecucao = GoogleCalendarViewModel(defaults: defaults)
    quartaExecucao.aplicar(eventos: [evento], biblioteca: nil, agora: agora)
    #expect(quartaExecucao.reunioesPendentes.isEmpty)
    #expect(quartaExecucao.reunioesIgnoradas.isEmpty)
}

@MainActor
@Test("Conversão preserva duração e notas e respeita processamento manual")
func conversaoDeReuniaoPreservaCaptura() async throws {
    let suite = "ConversaoCalendarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }

    let armazenamento = Armazenamento(raiz: raiz)
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString,
            emMemoria: true
        )
    )
    let biblioteca = Biblioteca(
        armazenamento: armazenamento,
        repositorio: repositorio,
        espaco: EspacoID()
    )
    biblioteca.processamentoAutomatico = false

    let agora = Date()
    let evento = eventoCalendar(
        id: "retrospectiva",
        data: agora.addingTimeInterval(1_800),
        descricao: "Pauta trazida do evento"
    )
    let google = GoogleCalendarViewModel(defaults: defaults)
    google.aplicar(eventos: [evento], biblioteca: biblioteca, agora: agora)
    let pendente = try #require(google.reunioesPendentes.first)

    let pastaRelativa = Armazenamento.caminhoRelativo(id: UUID())
    let audio = armazenamento.resolver(relativo: pastaRelativa)
        .appendingPathComponent(Armazenamento.Nome.microfone)
    try FileManager.default.createDirectory(
        at: audio.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("audio-de-teste".utf8).write(to: audio)
    let nota = NotaDaConversa(texto: "Decisão anotada ao vivo", start: 12)

    let arquivo = try #require(
        await google.importarAudioParaReuniao(
            pendente,
            audioURL: audio,
            biblioteca: biblioteca,
            duracao: 73,
            notas: [nota]
        )
    )

    #expect(arquivo.duracao == 73)
    #expect(arquivo.notas.map(\.texto) == ["Pauta trazida do evento", "Decisão anotada ao vivo"])
    #expect(arquivo.notas.last?.start == 12)
    guard case .prontoParaTranscrever = biblioteca.estado(de: arquivo) else {
        Issue.record("Processamento automático desligado ainda enfileirou a reunião")
        return
    }

    let relancado = GoogleCalendarViewModel(defaults: defaults)
    relancado.aplicar(eventos: [evento], biblioteca: biblioteca, agora: agora)
    #expect(relancado.reunioesPendentes.isEmpty)
}

@MainActor
@Test("Falha ao salvar reunião remove a pasta de áudio copiada")
func falhaDePersistenciaFazRollbackDaMidia() async throws {
    struct FalhaEsperada: Error {}

    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: raiz) }
    let armazenamento = Armazenamento(raiz: raiz)
    let repositorio = SwiftDataRepository(
        modelContainer: try SwiftDataRepository.containerLocal(
            nome: UUID().uuidString,
            emMemoria: true
        )
    )
    let biblioteca = Biblioteca(
        armazenamento: armazenamento,
        repositorio: repositorio,
        espaco: EspacoID(),
        salvarArquivo: { _ in throw FalhaEsperada() }
    )
    let origem = raiz.appendingPathComponent("origem.m4a")
    try Data("audio".utf8).write(to: origem)
    let pendente = ReuniaoPendenteCalendar(
        id: "falha",
        titulo: "Falha",
        dataHora: Date(),
        participantes: ["ana@example.com"],
        descricao: nil,
        idExterno: "google-calendar-api:falha"
    )

    let resultado = await biblioteca.criarArquivoDeReuniaoPendente(
        pendente,
        audioURL: origem,
        duracao: 15
    )

    #expect(resultado == nil)
    let pastaDeGravacoes = armazenamento.raiz.appendingPathComponent(
        Armazenamento.pastaGravacoes,
        isDirectory: true
    )
    let pastas = try FileManager.default.contentsOfDirectory(
        at: pastaDeGravacoes,
        includingPropertiesForKeys: nil
    )
    #expect(pastas.isEmpty)
}

@Suite("Transporte do Google Calendar")
struct TransporteGoogleCalendarTests {
    @Test("Lista todas as páginas dentro da mesma janela de 24 horas")
    func paginacao() async throws {
        let agora = try #require(ReuniaoExterna.parseDateTime("2026-08-27T12:00:00Z"))
        let transporte = TransporteCalendarFake(respostas: [
            """
            {"items":[{"id":"um","summary":"Um","eventType":"default","start":{"dateTime":"2026-08-27T13:00:00Z"},"attendees":[{"email":"um@example.com"}]}],"nextPageToken":"pagina-2"}
            """,
            """
            {"items":[{"id":"dois","summary":"Dois","eventType":"default","start":{"dateTime":"2026-08-27T14:00:00Z"},"attendees":[{"displayName":"Dois"}]}]}
            """,
        ])
        let fonte = FonteGoogleCalendarAPI(
            agora: { agora },
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { _ in "token-fake" }
        )

        let eventos = try await fonte.listarEventos()
        let urls = await transporte.urlsRecebidas()

        #expect(eventos.map(\.id) == ["um", "dois"])
        #expect(urls.count == 2)
        #expect(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pageToken" }) == nil)
        #expect(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pageToken" })?.value == "pagina-2")

        let componentes = try #require(URLComponents(url: urls[0], resolvingAgainstBaseURL: false))
        let timeMin = try #require(componentes.queryItems?.first { $0.name == "timeMin" }?.value)
        let timeMax = try #require(componentes.queryItems?.first { $0.name == "timeMax" }?.value)
        let inicio = try #require(ReuniaoExterna.parseDateTime(timeMin))
        let fim = try #require(ReuniaoExterna.parseDateTime(timeMax))
        #expect(fim.timeIntervalSince(inicio) == 24 * 3_600)
    }

    @Test("Evento com data inválida fica de fora sem esconder os outros (IN-05)")
    func dataInvalidaNaoDerrubaALista() async throws {
        let transporte = TransporteCalendarFake(respostas: [
            """
            {"items":[
              {"id":"quebrada","eventType":"default","start":{"dateTime":"nao-e-data"},"attendees":[{"email":"ana@example.com"}]},
              {"id":"boa","summary":"Boa","eventType":"default","start":{"dateTime":"2026-08-27T13:00:00Z"},"attendees":[{"email":"bia@example.com"}]}
            ]}
            """,
        ])
        let fonte = FonteGoogleCalendarAPI(
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { _ in "token-fake" }
        )

        let eventos = try await fonte.listarEventos()

        // A data ruim nunca vira "agora": o evento some da lista, só ele.
        #expect(eventos.map(\.id) == ["boa"])
    }

    @Test("Data inválida no detalhe de um evento continua sendo erro observável")
    func dataInvalidaNoDetalhe() async throws {
        let transporte = TransporteCalendarFake(respostas: [
            """
            {"id":"quebrada","eventType":"default","start":{"dateTime":"nao-e-data"}}
            """,
        ])
        let fonte = FonteGoogleCalendarAPI(
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { _ in "token-fake" }
        )

        do {
            _ = try await fonte.obterEventoDetalhado(id: "quebrada")
            Issue.record("A API aceitou uma data inválida")
        } catch let erro as FonteGoogleCalendarErro {
            guard case .dataInvalida("quebrada") = erro else {
                Issue.record("Erro inesperado: \(erro)")
                return
            }
        }
    }

    @Test("401 renova o token à força e repete o pedido uma vez (IN-03)")
    func naoAutorizadoRenovaERepete() async throws {
        let transporte = TransporteCalendarFake(
            respostas: ["{}", #"{"email":"ana@example.com"}"#],
            status: [401, 200]
        )
        let pedidos = PedidosDeToken()
        let fonte = FonteGoogleCalendarAPI(
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { forcar in
                await pedidos.registrar(forcar)
                return forcar ? "token-novo" : "token-velho"
            }
        )

        let conta = try await fonte.conta()

        #expect(conta.email == "ana@example.com")
        #expect(await pedidos.todos == [false, true])
        #expect(await transporte.autorizacoesRecebidas() == ["Bearer token-velho", "Bearer token-novo"])
    }

    @Test("Um segundo 401 não entra em laço")
    func naoAutorizadoDuasVezesFalha() async throws {
        let transporte = TransporteCalendarFake(respostas: ["{}", "{}"], status: [401, 401])
        let fonte = FonteGoogleCalendarAPI(
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { _ in "token" }
        )

        await #expect(throws: FonteGoogleCalendarErro.self) {
            _ = try await fonte.conta()
        }
        #expect(await transporte.urlsRecebidas().count == 2)
    }
}

private func eventoCalendar(
    id: String,
    data: Date,
    descricao: String? = nil
) -> FonteGoogleCalendarAPI.EventoCalendarSimples {
    FonteGoogleCalendarAPI.EventoCalendarSimples(
        id: id,
        titulo: "Reunião \(id)",
        dataHora: data,
        participantes: [ParticipanteDaReuniao(email: "ana@example.com")],
        descricao: descricao
    )
}

private actor PedidosDeToken {
    private(set) var todos: [Bool] = []
    func registrar(_ forcar: Bool) { todos.append(forcar) }
}

private actor TransporteCalendarFake {
    private let respostas: [Data]
    private let status: [Int]
    private var indice = 0
    private var urls: [URL] = []
    private var autorizacoes: [String] = []

    init(respostas: [String], status: [Int] = []) {
        self.respostas = respostas.map { Data($0.utf8) }
        self.status = status
    }

    func enviar(_ pedido: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(pedido.url)
        guard indice < respostas.count else {
            throw URLError(.badServerResponse)
        }
        urls.append(url)
        autorizacoes.append(pedido.value(forHTTPHeaderField: "Authorization") ?? "")
        let dados = respostas[indice]
        let codigo = indice < status.count ? status[indice] : 200
        indice += 1
        let resposta = try #require(
            HTTPURLResponse(url: url, statusCode: codigo, httpVersion: nil, headerFields: nil)
        )
        return (dados, resposta)
    }

    func urlsRecebidas() -> [URL] { urls }
    func autorizacoesRecebidas() -> [String] { autorizacoes }
}

// MARK: - Granola

@Test("Transcrição do Granola é dividida por fala, com falante e ordem (IN-04)")
func transcricaoDoGranolaViraFalas() throws {
    let texto = """
    Me: Bom dia, vamos começar pela agenda. Them: Claro, pode ser.
    Me: Primeiro ponto é o prazo.
    Them: Sexta-feira funciona para todos?
    """

    let segmentos = FonteGranola.segmentosDeTranscricao(texto)

    #expect(segmentos.map(\.falante) == [Speaker.eu, Speaker.interlocutor, Speaker.eu, Speaker.interlocutor])
    #expect(segmentos.map(\.texto) == [
        "Bom dia, vamos começar pela agenda.",
        "Claro, pode ser.",
        "Primeiro ponto é o prazo.",
        "Sexta-feira funciona para todos?",
    ])
    // Tempos estimados, crescentes e sem sobreposição: é o que mantém a
    // ordem ao recarregar e dá duração à conversa.
    let inicios = segmentos.compactMap(\.inicio)
    #expect(inicios == inicios.sorted())
    #expect(Set(inicios).count == segmentos.count)
    for (anterior, seguinte) in zip(segmentos, segmentos.dropFirst()) {
        #expect(try #require(anterior.fim) <= (try #require(seguinte.inicio)))
    }
    #expect(try #require(segmentos.last?.fim) > 0)
}

@Test("Transcrição do Granola sem rótulos continua sendo uma fala só, sem falante")
func transcricaoDoGranolaSemRotulos() {
    let segmentos = FonteGranola.segmentosDeTranscricao("Apenas um texto corrido, sem viradas.")

    #expect(segmentos.count == 1)
    #expect(segmentos.first?.falante == nil)
    #expect(segmentos.first?.texto == "Apenas um texto corrido, sem viradas.")
    #expect(FonteGranola.segmentosDeTranscricao("   ").isEmpty)
}
