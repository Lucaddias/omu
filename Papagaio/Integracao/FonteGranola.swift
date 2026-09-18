import Foundation
import PapagaioCore

/// A fonte Granola por trás do protocolo `FonteDeReunioesExternas`.
///
/// Conversa com o servidor MCP do Granola (`https://mcp.granola.ai/mcp`) e
/// traduz as respostas para o formato neutro do Papagaio (`ReuniaoExterna`).
///
/// O que as ferramentas devolvem hoje:
/// - `get_account_info`: JSON (`email`, `active_workspace`).
/// - `list_meetings`: um documento `<meetings_data>` com um `<meeting>`
///   por reunião (atributos `id`, `title`, `date`; filhos `known_participants`,
///   `summary`, `notes`).
/// - `get_meetings`: o mesmo `<meetings_data>`, com a reunião completa
///   (resumo e anotações em markdown).
/// - `get_meeting_transcript`: JSON com o campo `transcript` — o texto corrido
///   da reunião, com quem falou marcado no início. Planos pagos devolvem
///   marcações por virada; sem acesso o pedido falha e a reunião entra sem
///   transcrição.
struct FonteGranola: FonteDeReunioesExternas {
    let identificador = "granola"
    let cliente: ClienteMCP

    func conta() async throws -> ContaExterna {
        let resposta = try await cliente.chamar(ferramenta: "get_account_info", argumentos: [:])
        guard let info = resposta as? [String: Any] else {
            throw FonteGranolaErro.respostaInesperada
        }
        let email = info["email"] as? String
            ?? (info["account"] as? String)
            ?? ""
        let workspaceDoDicionario = info["active_workspace"] as? [String: Any]
        let workspace = info["workspace"] as? String
            ?? (info["workspace_title"] as? String)
            ?? (workspaceDoDicionario?["title"] as? String)
            ?? ""
        return ContaExterna(email: email, workspace: workspace)
    }

    func listarReunioes() async throws -> [ReuniaoExterna] {
        let resposta = try await cliente.chamar(
            ferramenta: "list_meetings",
            argumentos: ["time_range": "last_30_days"]
        )
        return FonteGranolaXML.reunioes(em: resposta)
    }

    func obterReuniao(id: String, incluirTranscricao: Bool) async throws -> ReuniaoExterna {
        let resposta = try await cliente.chamar(
            ferramenta: "get_meetings",
            argumentos: ["meeting_ids": [id]]
        )
        let encontradas = FonteGranolaXML.reunioes(em: resposta)
        guard let reuniao = encontradas.first(where: { $0.id == id }) ?? encontradas.first else {
            throw FonteGranolaErro.reuniaoNaoEncontrada(id)
        }

        var transcricao: [SegmentoDeTranscricaoExterna]? = nil
        if incluirTranscricao {
            transcricao = try await transcricaoDaReuniao(id: id)
        }

        return ReuniaoExterna(
            id: reuniao.id,
            titulo: reuniao.titulo,
            data: reuniao.data,
            participantes: reuniao.participantes,
            notas: reuniao.notas,
            resumo: reuniao.resumo,
            transcricao: transcricao
        )
    }

    /// Transcrição separada (`get_meeting_transcript`), reservada aos planos
    /// pagos. Sem plano, o tool falha — a reunião entra com notas e resumo.
    private func transcricaoDaReuniao(id: String) async throws -> [SegmentoDeTranscricaoExterna]? {
        let resposta = try await cliente.chamar(
            ferramenta: "get_meeting_transcript",
            argumentos: ["meeting_id": id]
        )
        guard let dados = resposta as? [String: Any],
              let texto = dados["transcript"] as? String,
              !texto.isEmpty
        else { return nil }
        return FonteGranolaXML.segmentos(de: texto)
    }
}

enum FonteGranolaErro: LocalizedError {
    case respostaInesperada
    case reuniaoNaoEncontrada(String)

    var errorDescription: String? {
        switch self {
        case .respostaInesperada:
            "O Granola respondeu algo que o Ōmu não reconheceu.".localized
        case let .reuniaoNaoEncontrada(id):
            "A reunião %@ não foi encontrada no Granola.".localized(id)
        }
    }
}

/// Parser tolerante do formato real do Granola.
///
/// As ferramentas de lista/detalhe devolvem um documento de marcação própria:
///
/// ```
/// <meetings_data from="Jul 24, 2026" to="Jul 27, 2026" count="4">
/// <meeting id="..." title="..." date="Jul 27, 2026 5:12 PM GMT-3">
///   <known_participants>
///   FELIPE AZAMBUJA CARVALHO (note creator) from Poli &lt;email&gt;
///   </known_participants>
///   <summary>### ...</summary>
///   <notes>...</notes>
/// </meeting>
/// </meetings_data>
/// ```
///
/// Algumas ferramentas ainda respondem JSON (conta, transcrição); o parser
/// cobre os dois no mesmo lugar.
private enum FonteGranolaXML {
    /// Converte uma resposta em reuniões. Aceita o documento `<meetings_data>`
    /// e, como atalho, JSON nos moldes antigos (`[{...}]`, `{meetings:[...]}`).
    static func reunioes(em resposta: Any) -> [ReuniaoExterna] {
        guard let documento = resposta as? String, !documento.isEmpty else {
            return reunioesJSON(em: resposta)
        }
        let marcacoes = sentinelaDeMarcacoesReunioes.matches(in: documento, range: NSRange(documento.startIndex..., in: documento))
        return marcacoes.compactMap { marcacao in
            let atributos = atributosDo(bloco: marcacao, no: documento)
            guard let id = atributos["id"], !id.isEmpty else { return nil }
            let titulo = atributos["title"] ?? "Reunião".localized

            var participantes: [ParticipanteDaReuniao] = []
            var resumo: String?
            var notas: String?
            let filhos = sentinelaDeFilhos.matches(in: documento, range: marcacao.range(at: 2))
            for filho in filhos {
                guard filho.numberOfRanges > 2,
                      let nome = Range(filho.range(at: 1), in: documento),
                      let conteudo = Range(filho.range(at: 2), in: documento)
                else { continue }
                let texto = String(documento[conteudo]).desescaparEntidades()
                switch documento[nome] {
                case "known_participants":
                    participantes = participantesDeTexto(em: texto)
                case "summary": resumo = textoNaoLimpa(texto)
                case "notes": notas = textoNaoLimpa(texto)
                default: continue
                }
            }

            return ReuniaoExterna(
                id: id,
                titulo: titulo,
                data: FonteGranolaXML.data(do: atributos["date"]) ?? Date(),
                participantes: participantes,
                notas: notas,
                resumo: resumo
            )
        }
    }

    /// A transcrição chega como um texto corrido com rótulos ocasionais
    /// (`Me:`, `Them:`). Sem marcações de virada é um único segmento.
    static func segmentos(de texto: String) -> [SegmentoDeTranscricaoExterna] {
        let corrido = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrido.isEmpty else { return [] }
        var falante: String?
        var fala = corrido
        if let resultado = rotuloInicial.firstMatch(in: corrido, range: NSRange(corrido.startIndex..., in: corrido)),
           let marcado = Range(resultado.range(at: 0), in: corrido) {
            let rotulo = String(corrido[marcado])
                .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
            falante = FalanteExterno.rotulo(de: rotulo.lowercased())
            fala = String(corrido[marcado.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [SegmentoDeTranscricaoExterna(
            falante: falante,
            texto: fala,
            inicio: 0,
            fim: 0
        )]
    }

    // MARK: - Formato de marcação

    private static let sentinelaDeMarcacoesReunioes = try! NSRegularExpression(
        pattern: #"(?s)<meeting\s+([^>]*)>(.*?)</meeting>"#
    )
    private static let sentinelaDeAtributos = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*"([^"]*)""#
    )
    private static let sentinelaDeFilhos = try! NSRegularExpression(
        pattern: #"(?s)<(known_participants|summary|notes|transcript)>(.*?)</\1>"#
    )
    private static let rotuloInicial = try! NSRegularExpression(
        pattern: #"^\s*(Me|Them|me|them)\s*:"#
    )

    private static func atributosDo(bloco marcacao: NSTextCheckingResult, no documento: String) -> [String: String] {
        guard marcacao.numberOfRanges > 1,
              let lista = Range(marcacao.range(at: 1), in: documento)
        else { return [:] }
        let trecho = String(documento[lista])
        var atributos: [String: String] = [:]
        for match in sentinelaDeAtributos.matches(in: trecho, range: NSRange(trecho.startIndex..., in: trecho)) {
            guard match.numberOfRanges > 2,
                  let nome = Range(match.range(at: 1), in: trecho),
                  let valor = Range(match.range(at: 2), in: trecho)
            else { continue }
            atributos[String(trecho[nome])] = String(trecho[valor])
        }
        return atributos
    }

    /// Linhas de `<known_participants>`: nome + papel + `from <org> <email>`.
    private static func participantesDeTexto(em bloco: String) -> [ParticipanteDaReuniao] {
        bloco.components(separatedBy: "\n").compactMap { linha -> ParticipanteDaReuniao? in
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            guard !limpa.isEmpty else { return nil }
            var email: String?
            var nomeParte = limpa
            if let emailMatch = sentinelaDeEmail.firstMatch(in: limpa, range: NSRange(limpa.startIndex..., in: limpa)),
               emailMatch.numberOfRanges > 1,
               let conteudo = Range(emailMatch.range(at: 1), in: limpa) {
                email = String(limpa[conteudo])
                // Remove o trecho de email para extrair nome limpo
                if let rangeFull = Range(emailMatch.range(at: 0), in: limpa) {
                    nomeParte = String(limpa[..<rangeFull.lowerBound]) + String(limpa[rangeFull.upperBound...])
                }
            }
            let antesDoPapel = nomeParte
                .replacingOccurrences(of: #"\s*\(note\s*creator\).*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+from\s+.*"#, with: "", options: .regularExpression)
            let nome = antesDoPapel.trimmingCharacters(in: .whitespaces).nilIfEmpty
            if email == nil && nome == nil { return nil }
            return ParticipanteDaReuniao(nome: nome, email: email)
        }
    }

    private static func nomesDeParticipantes(em bloco: String) -> [String] {
        participantesDeTexto(em: bloco).map(\.displayNome)
    }

    private static let sentinelaDeEmail = try! NSRegularExpression(
        pattern: #"<([^<>]+@[^<>]+)>"#
    )

    /// `date="Jul 27, 2026 5:12 PM GMT-3"` — fuso pendurado no fim da string.
    private static func data(do texto: String?) -> Date? {
        guard let texto, !texto.isEmpty else { return nil }
        if let resultado = sentinelaDeFuso.firstMatch(in: texto, range: NSRange(texto.startIndex..., in: texto)),
           let encontrado = Range(resultado.range(at: 0), in: texto) {
            let trecho = String(texto[encontrado])
            let semFuso = texto
                .replacingOccurrences(of: trecho, with: "")
                .trimmingCharacters(in: .whitespaces)
            return dataFormatada(semFuso, fuso: TimeZone(secondsFromGMT: segundosDo(trecho)))
        }
        return dataFormatada(texto, fuso: nil)
    }

    private static let sentinelaDeFuso = try! NSRegularExpression(
        pattern: #"GMT[+-]\d{1,2}(?::\d{2})?"#
    )

    private static func segundosDo(_ texto: String) -> Int {
        let sinal = texto.contains("-") ? -1 : 1
        let digitos = texto.replacingOccurrences(of: "GMT+", with: "")
            .replacingOccurrences(of: "GMT-", with: "")
        let partes = digitos.split(separator: ":").compactMap { Int($0) }
        guard let horas = partes.first else { return 0 }
        let minutos = partes.count > 1 ? partes[1] : 0
        return sinal * (horas * 3600 + minutos * 60)
    }

    private static func dataFormatada(_ texto: String, fuso: TimeZone?) -> Date? {
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "en_US_POSIX")
        formatador.dateFormat = "MMM d, yyyy h:mm a"
        formatador.timeZone = fuso ?? TimeZone.current
        return formatador.date(from: texto)
    }

    private static func textoNaoLimpa(_ texto: String) -> String? {
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? nil : limpo
    }

    // MARK: - Formato antigo (JSON)

    /// O payload pode ser um array direto, `{meetings:[...]}` ou
    /// `{result:[...]}` — normaliza tudo para uma lista de dicionários.
    private static func reunioesJSON(em resposta: Any) -> [ReuniaoExterna] {
        let itens = itensJSON(em: resposta)
        return itens.compactMap { item in
            guard let id = item["id"] as? String,
                  let titulo = item["title"] as? String
            else { return nil }
            return ReuniaoExterna(
                id: id,
                titulo: titulo,
                data: FonteGranolaDicionario.data(in: item) ?? Date(),
                participantes: FonteGranolaDicionario.nomesDeParticipantes(in: item),
                notas: item["manual_notes"] as? String,
                resumo: item["gpt_summarized_notes"] as? String
                    ?? item["summary"] as? String
            )
        }
    }

    private static func itensJSON(em resposta: Any) -> [[String: Any]] {
        if let lista = resposta as? [[String: Any]] {
            return lista
        }
        guard let obj = resposta as? [String: Any] else { return [] }
        for chave in ["meetings", "results", "result", "data"] {
            if let lista = obj[chave] as? [[String: Any]] {
                return lista
            }
        }
        return [obj]
    }
}

/// Acesso tolerante a dicionários vindos do JSON do Granola (formato antigo).
private enum FonteGranolaDicionario {
    static func nomesDeParticipantes(in dicionario: [String: Any]) -> [ParticipanteDaReuniao] {
        for chave in ["attendees", "participants", "people"] {
            guard let lista = dicionario[chave] as? [Any] else { continue }
            let participantes = lista.compactMap { item -> ParticipanteDaReuniao? in
                if let texto = item as? String { return ParticipanteDaReuniao(legado: texto) }
                if let objeto = item as? [String: Any] {
                    let email = objeto["email"] as? String
                    let nome = objeto["name"] as? String
                    if (email == nil || email?.isEmpty == true) && (nome == nil || nome?.isEmpty == true) { return nil }
                    return ParticipanteDaReuniao(nome: nome, email: email)
                }
                return nil
            }
            if !participantes.isEmpty { return participantes }
        }
        return []
    }

    /// `date` ISO-8601 (com ou sem frações de segundo) ou `created_at`.
    static func data(in dicionario: [String: Any]) -> Date? {
        let comFracao = ISO8601DateFormatter()
        comFracao.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let semFracao = ISO8601DateFormatter()
        semFracao.formatOptions = [.withInternetDateTime]
        for chave in ["date", "created_at", "datetime"] {
            guard let texto = dicionario[chave] as? String else { continue }
            if let data = comFracao.date(from: texto) ?? semFracao.date(from: texto) {
                return data
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// `&lt;`, `&gt;`, `&amp;`, `&quot;` e `&#39;` de volta ao texto.
    func desescaparEntidades() -> String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}