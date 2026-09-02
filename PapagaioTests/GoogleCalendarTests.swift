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

    @Test("Data inválida produz erro observável em vez de usar o horário atual")
    func dataInvalida() async throws {
        let transporte = TransporteCalendarFake(respostas: [
            """
            {"items":[{"id":"quebrada","eventType":"default","start":{"dateTime":"nao-e-data"},"attendees":[{"email":"ana@example.com"}]}]}
            """,
        ])
        let fonte = FonteGoogleCalendarAPI(
            transportar: { pedido in try await transporte.enviar(pedido) },
            obterToken: { _ in "token-fake" }
        )

        do {
            _ = try await fonte.listarEventos()
            Issue.record("A API aceitou uma data inválida")
        } catch let erro as FonteGoogleCalendarErro {
            guard case .dataInvalida("quebrada") = erro else {
                Issue.record("Erro inesperado: \(erro)")
                return
            }
        }
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
        participantes: [ParticipanteDaReuniao(legado: "ana@example.com")],
        descricao: descricao
    )
}

private actor TransporteCalendarFake {
    private let respostas: [Data]
    private var indice = 0
    private var urls: [URL] = []

    init(respostas: [String]) {
        self.respostas = respostas.map { Data($0.utf8) }
    }

    func enviar(_ pedido: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(pedido.url)
        guard indice < respostas.count else {
            throw URLError(.badServerResponse)
        }
        urls.append(url)
        let dados = respostas[indice]
        indice += 1
        let resposta = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        return (dados, resposta)
    }

    func urlsRecebidas() -> [URL] { urls }
}
