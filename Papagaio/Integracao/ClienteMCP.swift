import Foundation
import os

/// Erros do transporte MCP (JSON-RPC sobre Streamable HTTP).
enum ErroMCP: LocalizedError {
    /// O servidor respondeu um erro JSON-RPC (`error.code`/`error.message`).
    case protocolo(codigo: Int, mensagem: String)
    /// Resposta fora do formato esperado (sem `result` nem `error`).
    case respostaInvalida
    /// A rede falhou.
    case rede(mensagem: String)

    var errorDescription: String? {
        switch self {
        case let .protocolo(_, mensagem):
            "O Granola respondeu: %@.".localized(mensagem)
        case .respostaInvalida:
            "O Granola respondeu de forma inesperada.".localized
        case let .rede(mensagem):
            "Sem conexão com o Granola: %@.".localized(mensagem)
        }
    }
}

/// Cliente MCP mínimo sobre Streamable HTTP (JSON-RPC 2.0).
///
/// Faz "apenas" o que o contrato do Granola pede: `initialize`, o sinal de
/// `initialized` e `tools/call`. O token é pedido a cada chamada à closure
/// fornecida (o `SessaoOAuth` renova quando expira); o servidor pode entregar
/// um id de sessão no cabeçalho `Mcp-Session-Id`, que é devolvido nas
/// chamadas seguintes.
final class ClienteMCP: @unchecked Sendable {
    private var inicializado = false
    private var inicializacao: Task<Void, Error>?
    private var idSessao: String?
    private var proximoIDInterno = 1
    private let trava = NSLock()

    /// Ids curtas e crescentes: alguns servidores rejeitam inteiros de 64
    /// bits fora do alcance de int32 com "Parse error".
    private func proximoID() -> Int {
        trava.lock(); defer { trava.unlock() }
        let atual = proximoIDInterno
        proximoIDInterno = atual >= 1_000_000_000 ? 1 : atual + 1
        return atual
    }

    let url: URL
    private let obterToken: @Sendable (Bool) async throws -> String
    private let sessao: URLSession

    init(url: URL, sessao: URLSession = .shared, token: @escaping @Sendable (Bool) async throws -> String) {
        self.url = url
        self.obterToken = token
        self.sessao = sessao
    }

    /// Chama uma ferramenta e devolve o conteúdo que o servidor mandou no
    /// `result` — tipicamente JSON dentro de `content[].text`.
    func chamar(ferramenta: String, argumentos: [String: Any]) async throws -> Any {
        try await garantirInicializacao()
        let corpo: [String: Any] = [
            "jsonrpc": "2.0",
            "id": proximoID(),
            "method": "tools/call",
            "params": [
                "name": ferramenta,
                "arguments": argumentos,
            ],
        ]
        let resposta = try await postar(corpo, contexto: "tools/call(\(ferramenta))")
        return try extrairResultado(resposta)
    }

    // MARK: - Ciclo de vida

    private func garantirInicializacao() async throws {
        let tarefa: Task<Void, Error>? = trava.withLock {
            guard !inicializado else { return nil }
            if let inicializacao { return inicializacao }
            let nova = Task { try await self.inicializar() }
            inicializacao = nova
            return nova
        }
        try await tarefa?.value
        try Task.checkCancellation()
    }

    private func inicializar() async throws {
        do {
            try await executarInicializacao()
            trava.withLock {
                inicializado = true
                inicializacao = nil
            }
        } catch {
            trava.withLock { inicializacao = nil }
            throw error
        }
    }

    private func executarInicializacao() async throws {
        let corpo: [String: Any] = [
            "jsonrpc": "2.0",
            "id": proximoID(),
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "Ōmu",
                    "version": "1.0",
                ],
            ],
        ]
        let resposta = try await postar(corpo, contexto: "initialize")
        _ = try extrairResultado(resposta)

        // Sinal de "estou pronto": notificação sem id, não espera resposta.
        let notificacao: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        _ = try await postar(notificacao, contexto: "notifications/initialized")
    }

    // MARK: - HTTP

    private func postar(_ mensagem: [String: Any], contexto: String = "postar") async throws -> [String: Any] {
        var pedido = URLRequest(url: url)
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        pedido.timeoutInterval = 60
        let token = try await obterToken(false)
        pedido.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let idSessao = trava.withLock({ idSessao }) {
            pedido.setValue(idSessao, forHTTPHeaderField: "Mcp-Session-Id")
        }
        pedido.httpBody = try JSONSerialization.data(withJSONObject: mensagem)

        let dados: Data
        do {
            let (corpo, resposta) = try await sessao.data(for: pedido)
            let status = (resposta as? HTTPURLResponse)?.statusCode
            if let http = resposta as? HTTPURLResponse {
                if let sessao = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                    trava.withLock { idSessao = sessao }
                }
            }
            // 200 para respostas; 202 é o aceite das notificações (`initialized`),
            // que vêm com corpo `null` — não há o que parsear.
            guard status == 200 || status == 202 else {
                Logger(subsystem: "Papagaio", category: "Granola").error(
                    "MCP-\(contexto, privacy: .public): status=\(status ?? 0)"
                )
                throw ErroMCP.protocolo(codigo: status ?? 0, mensagem: HTTPURLResponse.localizedString(forStatusCode: status ?? 0))
            }
            if status == 202 { return [:] }
            dados = corpo
        } catch let erro as ErroMCP {
            throw erro
        } catch {
            throw ErroMCP.rede(mensagem: error.localizedDescription)
        }

        // O servidor pode responder como SSE (event-stream) ou JSON limpo.
        // No SSE a primeira linha costuma ser `event: message` antes do
        // `data:`; em vez de exigir que o corpo comece por `data:`, todas as
        // linhas são coletadas e apenas os payloads `data:` são unidos.
        let bruto = String(data: dados, encoding: .utf8) ?? ""
        let linhas = bruto.components(separatedBy: "\n")
        let payloadsDeDados = linhas
            .filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if payloadsDeDados.isEmpty {
            guard let objeto = try Self.objetoJSON(de: dados, contexto: "resposta limpa") else {
                throw ErroMCP.respostaInvalida
            }
            return objeto
        }
        let json = payloadsDeDados.joined(separator: "\n")
        guard let objeto = try Self.objetoJSON(de: Data(json.utf8), contexto: "stream SSE") else {
            throw ErroMCP.respostaInvalida
        }
        return objeto
    }

    /// `JSONSerialization` com mensagem contextual em vez do 3840 cru do
    /// sistema quando o corpo não é JSON.
    private static func objetoJSON(de dados: Data, contexto: String) throws -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: dados) as? [String: Any]
        } catch {
            Logger(subsystem: "Papagaio", category: "Granola").error(
                "MCP: \(contexto, privacy: .public) não contém JSON válido (\(dados.count) bytes)"
            )
            throw ErroMCP.respostaInvalida
        }
    }

    private func extrairResultado(_ corpo: [String: Any]) throws -> Any {
        if let erro = corpo["error"] as? [String: Any] {
            throw ErroMCP.protocolo(
                codigo: erro["code"] as? Int ?? 0,
                mensagem: erro["message"] as? String ?? "erro desconhecido"
            )
        }
        guard let resultado = corpo["result"] else {
            throw ErroMCP.respostaInvalida
        }
        guard let resultadoJSON = resultado as? [String: Any] else {
            return resultado
        }

        // `structuredContent` é preferido quando existe; senão o texto da
        // `content[].text`, que costuma ser JSON serializado como string —
        // possivelmente precedido de um preâmbulo do servidor.
        if let estruturado = resultadoJSON["structuredContent"] {
            return estruturado
        }
        if let conteudos = resultadoJSON["content"] as? [[String: Any]] {
            for item in conteudos {
                guard (item["type"] as? String) == "text",
                      let texto = item["text"] as? String,
                      !texto.isEmpty
                else { continue }
                if let json = Self.jsonNoTexto(texto) {
                    return json
                }
                return texto
            }
        }
        return resultadoJSON
    }

    /// Tenta decodificar o texto inteiro como JSON e, se falhar, o trecho
    /// entre o primeiro `{` e o último `}` (o servidor antepõe um preâmbulo
    /// de aviso aos JSONs reais).
    private static func jsonNoTexto(_ texto: String) -> Any? {
        if let json = try? JSONSerialization.jsonObject(with: Data(texto.utf8)) {
            return json
        }
        guard let inicio = texto.firstIndex(of: "{"),
              let fim = texto.lastIndex(of: "}"),
              inicio < fim
        else { return nil }
        let trecho = texto[inicio...fim]
        return try? JSONSerialization.jsonObject(with: Data(String(trecho).utf8))
    }
}
