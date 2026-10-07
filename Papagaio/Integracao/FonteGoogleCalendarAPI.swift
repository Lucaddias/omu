import Foundation
import os
import PapagaioCore

struct FonteGoogleCalendarAPI: FonteDeReunioesExternas {
    typealias Transportar = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let identificador = "google-calendar-api"
    private let obterToken: @Sendable (Bool) async throws -> String
    private let transportar: Transportar
    private let agora: @Sendable () -> Date
    private let baseURL: URL
    private let registro = Logger(subsystem: "Papagaio", category: "GoogleCalendar")

    init(
        sessao: URLSession = .shared,
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3")!,
        agora: @escaping @Sendable () -> Date = Date.init,
        transportar: Transportar? = nil,
        obterToken: @escaping @Sendable (Bool) async throws -> String
    ) {
        self.transportar = transportar ?? { pedido in
            try await sessao.data(for: pedido)
        }
        self.baseURL = baseURL
        self.agora = agora
        self.obterToken = obterToken
    }

    /// Envia com o token atual e, se o servidor responder `401` (token
    /// revogado ou vencido antes da hora local), renova à força e repete
    /// **uma** vez. Sem isso o `401` virava "respondeu algo inesperado" e se
    /// repetia até a expiração local do token.
    private func enviar(_ url: URL) async throws -> (Data, URLResponse) {
        func pedido(_ token: String) -> URLRequest {
            var pedido = URLRequest(url: url)
            pedido.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            pedido.timeoutInterval = 15
            return pedido
        }
        let primeira = try await transportar(pedido(try await obterToken(false)))
        guard (primeira.1 as? HTTPURLResponse)?.statusCode == 401 else { return primeira }
        registro.info("Google respondeu 401 — renovando o token e repetindo o pedido")
        return try await transportar(pedido(try await obterToken(true)))
    }

    func conta() async throws -> ContaExterna {
        let (dados, resposta) = try await enviar(URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FonteGoogleCalendarErro.respostaInesperada
        }
        guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let email = json["email"] as? String
        else {
            throw FonteGoogleCalendarErro.respostaInesperada
        }
        return ContaExterna(email: email, workspace: nil)
    }

    func listarReunioes() async throws -> [ReuniaoExterna] {
        let eventos = try await listarEventos()
        return eventos.map { evento in
            ReuniaoExterna(
                id: evento.id,
                titulo: evento.titulo,
                data: evento.dataHora,
                participantes: evento.participantes,
                notas: evento.descricao,
                resumo: nil,
                transcricao: nil
            )
        }
    }

    func obterReuniao(id: String, incluirTranscricao: Bool) async throws -> ReuniaoExterna {
        let (dados, resposta) = try await enviar(
            baseURL.appendingPathComponent("calendars/primary/events/\(id)")
        )
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (resposta as? HTTPURLResponse)?.statusCode == 404 {
                throw FonteGoogleCalendarErro.reuniaoNaoEncontrada(id)
            }
            throw FonteGoogleCalendarErro.respostaInesperada
        }
        guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let evento = try decodificarEvento(json, exigirParticipantes: false)
        else {
            throw FonteGoogleCalendarErro.respostaInesperada
        }
        return ReuniaoExterna(
            id: evento.id,
            titulo: evento.titulo,
            data: evento.dataHora,
            participantes: evento.participantes,
            notas: evento.descricao
        )
    }

    // MARK: - Internal

    struct EventoCalendarSimples: Equatable, Sendable {
        let id: String
        let titulo: String
        let dataHora: Date
        let participantes: [ParticipanteDaReuniao]
        let descricao: String?
    }

    func listarEventos() async throws -> [EventoCalendarSimples] {
        let agora = agora()
        let fim = agora.addingTimeInterval(24 * 3600)

        let formatador = ISO8601DateFormatter()
        formatador.formatOptions = [.withInternetDateTime]
        let timeMin = formatador.string(from: agora)
        let timeMax = formatador.string(from: fim)

        var eventos: [EventoCalendarSimples] = []
        var proximaPagina: String?
        repeat {
            var componentes = URLComponents(
                url: baseURL.appendingPathComponent("calendars/primary/events"),
                resolvingAgainstBaseURL: false
            )!
            componentes.queryItems = [
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "showDeleted", value: "false"),
            ]
            if let proximaPagina {
                componentes.queryItems?.append(
                    URLQueryItem(name: "pageToken", value: proximaPagina)
                )
            }

            let (dados, resposta) = try await enviar(componentes.url!)
            guard let http = resposta as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { throw FonteGoogleCalendarErro.respostaInesperada }
            guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any]
            else { throw FonteGoogleCalendarErro.respostaInesperada }

            let itens = json["items"] as? [[String: Any]] ?? []
            // Um evento com data ilegível fica de fora e vai para o log; ele
            // não pode esconder todos os outros compromissos do dia.
            eventos += itens.compactMap { item in
                do {
                    return try decodificarEvento(item)
                } catch {
                    registro.error("Evento do Google Calendar ignorado: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            proximaPagina = (json["nextPageToken"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            }
        } while proximaPagina != nil

        registro.info("\(eventos.count) eventos futuros (com participantes) carregados do Google Calendar")
        return eventos
    }

    // Internal method for detailed event fetch
    func obterEventoDetalhado(id: String) async throws -> EventoCalendarSimples? {
        let (dados, resposta) = try await enviar(
            baseURL.appendingPathComponent("calendars/primary/events/\(id)")
        )
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (resposta as? HTTPURLResponse)?.statusCode == 404 {
                return nil
            }
            throw FonteGoogleCalendarErro.respostaInesperada
        }
        guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            return nil
        }
        return try decodificarEvento(json, exigirParticipantes: false)
    }

    private func decodificarEvento(
        _ evento: [String: Any],
        exigirParticipantes: Bool = true
    ) throws -> EventoCalendarSimples? {
        let tipo = evento["eventType"] as? String ?? "default"
        let attendees = evento["attendees"] as? [[String: Any]]
        if exigirParticipantes {
            guard tipo == "default", attendees?.isEmpty == false else { return nil }
        }
        guard let id = evento["id"] as? String, !id.isEmpty else { return nil }

        let inicio: Date?
        if let start = evento["start"] as? [String: Any],
           let dateTime = start["dateTime"] as? String {
            inicio = ReuniaoExterna.parseDateTime(dateTime)
        } else if let start = evento["start"] as? [String: Any],
                  let date = start["date"] as? String {
            inicio = ReuniaoExterna.parseDate(date)
        } else {
            inicio = nil
        }
        guard let inicio else { throw FonteGoogleCalendarErro.dataInvalida(id) }

        let participantes = attendees?.compactMap { participante -> ParticipanteDaReuniao? in
            let email = (participante["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nome = (participante["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard email?.isEmpty == false || nome?.isEmpty == false else { return nil }
            return ParticipanteDaReuniao(
                nome: nome,
                email: email,
                isSelf: (participante["self"] as? Bool) ?? false,
                isOrganizer: (participante["organizer"] as? Bool) ?? false,
                responseStatus: participante["responseStatus"] as? String
            )
        } ?? []

        return EventoCalendarSimples(
            id: id,
            titulo: (evento["summary"] as? String) ?? "Evento sem título".localized,
            dataHora: inicio,
            participantes: participantes,
            descricao: evento["description"] as? String
        )
    }
}

enum FonteGoogleCalendarErro: LocalizedError {
    case semToken
    case respostaInesperada
    case reuniaoNaoEncontrada(String)
    case dataInvalida(String)

    var errorDescription: String? {
        switch self {
        case .semToken:
            return "Não foi possível obter token de acesso.".localized
        case .respostaInesperada:
            return "O Google Calendar respondeu algo inesperado.".localized
        case let .reuniaoNaoEncontrada(id):
            return "A reunião %@ não foi encontrada no Google Calendar.".localized(id)
        case let .dataInvalida(id):
            return "A reunião %@ tem uma data inválida no Google Calendar.".localized(id)
        }
    }
}
