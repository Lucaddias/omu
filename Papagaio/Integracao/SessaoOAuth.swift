import CryptoKit
import Foundation
import os
import PapagaioCore

/// Erros do fluxo OAuth de uma fonte externa (Granola hoje).
enum ErroOAuth: LocalizedError, Equatable {
    /// A pessoa fechou o navegador ou recusou a autorização.
    case autorizacaoNegada
    /// Autorizou, mas a URL de retorno não trouxe `code`.
    case semCodigoDeAutorizacao
    /// A rota de registro dinâmico de cliente não respondeu como esperado.
    case registroFalhou
    /// O servidor de autorização respondeu algo que não é JSON esperado.
    case respostaInvalida
    /// O servidor de token respondeu com erro de protocolo.
    case servidor(mensagem: String)
    /// Refresh sem refresh token disponível no Keychain.
    case semRefreshToken
    /// O navegador padrão não abriu a URL de autorização.
    case navegadorNaoAbriu
    /// A autorização ficou quieta por tempo demais.
    case tempoEsgotado

    var errorDescription: String? {
        switch self {
        case .autorizacaoNegada:
            "Autorização cancelada ou recusada no navegador.".localized
        case .semCodigoDeAutorizacao:
            "O navegador voltou sem o código de autorização. Tente de novo.".localized
        case .registroFalhou:
            "Não foi possível registrar o Ōmu no servidor do Granola.".localized
        case .respostaInvalida:
            "O servidor de autorização respondeu de forma inesperada.".localized
        case let .servidor(mensagem):
            "O servidor respondeu: %@.".localized(mensagem)
        case .semRefreshToken:
            "A sessão expirou e o Ōmu não tem como renová-la. Conecte de novo.".localized
        case .navegadorNaoAbriu:
            "O navegador não abriu — confira se o Ōmu pode abrir janelas e tente de novo.".localized
        case .tempoEsgotado:
            "Tempo esgotado esperando sua autorização — volte ao navegador e tente de novo.".localized
        }
    }
}

/// Sessão OAuth 2.0 de um servidor MCP remoto (Streamable HTTP).
///
/// Faz o caminho inteiro que um cliente MCP de terceiros precisaria:
/// DCR (RFC 7591) registra um cliente novo no `register`, PKCE (S256) protege
/// o `authorization_code`, e o navegador padrão do sistema (scheme
/// `papagaio://` no Info.plist) apresenta a autorização.
///
/// As credenciais vivem no Keychain via `CofreDeTokens`: sobrevivem a
/// reinicializações e nunca ficam em texto puro no disco. O `GranolaViewModel`
/// guarda esta sessão e expõe só `tokenDeAcesso(forcandoRenovacao:)` para o
/// `ClienteMCP`.
final class SessaoOAuth: Sendable {
    private let servidorMCP: URL
    private let cofre: CofreDeTokens
    private let apresentador: ApresentadorDeAutorizacaoOAuth
    private let sessao = URLSession(configuration: .ephemeral)
    private let registro = Logger(subsystem: "Papagaio", category: "Granola")

    init(
        servidorMCP: URL,
        cofre: CofreDeTokens,
        apresentador: ApresentadorDeAutorizacaoOAuth
    ) {
        self.servidorMCP = servidorMCP
        self.cofre = cofre
        self.apresentador = apresentador
    }

    // MARK: - Token

    /// O `access_token` atual, renovando quando necessário. Se não houver
    /// nenhum (primeira conexão), dispara o fluxo de autorização no navegador.
    func tokenDeAcesso(forcandoRenovacao forcar: Bool) async throws -> String {
        let guardado = carregarToken()
        if !forcar,
           let guardado,
           guardado.expiraEm > Date().addingTimeInterval(60) {
            return guardado.valor
        }

        if let refresh = cofre.carregar(conta: "refresh_token")
            .map({ String(data: $0, encoding: .utf8) ?? "" }),
           !refresh.isEmpty {
            return try await trocarRefreshToken(refresh).accessToken
        }

        if let guardado, guardado.expiraEm > Date() {
            return guardado.valor
        }

        return try await fluxoDeAutorizacao()
    }

    /// Apaga as credenciais locais e tenta revogar o token no servidor.
    func sair() async {
        if let refresh = cofre.carregar(conta: "refresh_token")
            .map({ String(data: $0, encoding: .utf8) ?? "" }),
           !refresh.isEmpty {
            try? await revogar(refresh)
        }
        registro.info("Sessão encerrada — credenciais apagadas do Keychain")
        cofre.apagar(conta: "access_token")
        cofre.apagar(conta: "access_token_expires")
        cofre.apagar(conta: "refresh_token")
        cofre.apagar(conta: "client")
        cofre.apagar(conta: "pkce")
    }

    // MARK: - Metadados do servidor

    /// Metadados do `oauth-authorization-server`: rota de registro e endpoints
    /// de autorização/token/revogação. Cai nos padrões do MCP quando o servidor
    /// não publica `.well-known`.
    private func metadados() async throws -> MetadadosDoServidor {
        let base = baseDoServidor()
        var configuracao = MetadadosDoServidor(
            registracao: base.appendingPathComponent("register"),
            autorizacao: base.appendingPathComponent("authorize"),
            token: base.appendingPathComponent("token"),
            revogacao: base.appendingPathComponent("revoke")
        )

        let descubravel = base.appendingPathComponent(".well-known/oauth-authorization-server")
        guard let (dados, resposta) = try? await sessao.data(for: pedido(descubravel)),
              let http = resposta as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
        else { return configuracao }

        if let rota = json["registration_endpoint"] as? String, let url = URL(string: rota) {
            configuracao.registracao = url
        }
        if let rota = json["authorization_endpoint"] as? String, let url = URL(string: rota) {
            configuracao.autorizacao = url
        }
        if let rota = json["token_endpoint"] as? String, let url = URL(string: rota) {
            configuracao.token = url
        }
        if let rota = json["revocation_endpoint"] as? String, let url = URL(string: rota) {
            configuracao.revogacao = url
        }
        configuracao.escoposApresentados = json["scopes_supported"] as? [String]
        registro.info(
            "Metadados OAuth: registro=\(configuracao.registracao, privacy: .public) autorização=\(configuracao.autorizacao, privacy: .public) token=\(configuracao.token, privacy: .public)"
        )
        return configuracao
    }

    /// `https://mcp.granola.ai/mcp` vira `https://mcp.granola.ai` — os
    /// endpoints OAuth vivem na raiz, não sob o caminho do MCP.
    private func baseDoServidor() -> URL {
        var componentes = URLComponents(url: servidorMCP, resolvingAgainstBaseURL: false)!
        componentes.path = ""
        componentes.query = nil
        componentes.fragment = nil
        return componentes.url ?? servidorMCP
    }

    private func corpoJSON(_ dados: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            throw ErroOAuth.respostaInvalida
        }
        return json
    }

    /// Pedidos curtos: um servidor de autorização precisa responder em
    /// segundos, não minutos — tempo alto esconde travadas como "aguardando"
    /// silencioso na interface.
    private func pedido(_ url: URL) -> URLRequest {
        var pedido = URLRequest(url: url)
        pedido.timeoutInterval = 15
        return pedido
    }

    // MARK: - DCR + fluxo de autorização

    private func fluxoDeAutorizacao() async throws -> String {
        let metadados = try await metadados()
        let cliente = try await registrar(metadados: metadados)

        let url = urlDeAutorizacao(cliente: cliente, metadados: metadados)
        let codigo = try await apresentador.autorizar(url: url)
        guard !codigo.isEmpty else { throw ErroOAuth.semCodigoDeAutorizacao }

        let credenciais = try await trocarCodigo(codigo, cliente: cliente, metadados: metadados)
        return credenciais.accessToken
    }

    /// DCR (RFC 7591): o Ōmu se registra como cliente novo na primeira
    /// conexão. O registro é guardado — sem ele o refresh não funciona depois.
    private func registrar(metadados: MetadadosDoServidor) async throws -> ClienteRegistrado {
        if let guardado: ClienteRegistrado = cofre.carregar(conta: "client")
            .flatMap({ try? JSONDecoder().decode(ClienteRegistrado.self, from: $0) }) {
            return guardado
        }

        let parametros: [String: Any] = [
            "client_name": "Ōmu",
            "redirect_uris": ["papagaio://oauth/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var pedido = pedido(metadados.registracao)
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.httpBody = try JSONSerialization.data(withJSONObject: parametros)

        let (dados, resposta) = try await sessao.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            registro.fault(
                "Registro de cliente falhou — status \(String(describing: (resposta as? HTTPURLResponse)?.statusCode))"
            )
            throw ErroOAuth.registroFalhou
        }

        let json = try corpoJSON(dados)
        guard let idCliente = json["client_id"] as? String, !idCliente.isEmpty else {
            throw ErroOAuth.registroFalhou
        }
        let cliente = ClienteRegistrado(
            id: idCliente,
            segredo: json["client_secret"] as? String,
            metodoDeAutenticacao: (json["token_endpoint_auth_method"] as? String) ?? "none"
        )
        if let dados = try? JSONEncoder().encode(cliente) {
            try? cofre.salvar(dados, conta: "client")
        }
        registro.info("Cliente OAuth registrado")
        return cliente
    }

    private func urlDeAutorizacao(cliente: ClienteRegistrado, metadados: MetadadosDoServidor) -> URL {
        let par = gerarAtributoPKCE()
        try? cofre.salvar(Data(par.verificador.utf8), conta: "pkce")

        var componentes = URLComponents(url: metadados.autorizacao, resolvingAgainstBaseURL: false)!
        var itens = [
            URLQueryItem(name: "client_id", value: cliente.id),
            URLQueryItem(name: "redirect_uri", value: "papagaio://oauth/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: par.desafio),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]
        if let escopos = metadados.escoposApresentados, !escopos.isEmpty {
            itens.append(URLQueryItem(name: "scope", value: escopos.joined(separator: " ")))
        }
        componentes.queryItems = itens
        registro.info("URL de autorização preparada")
        return componentes.url!
    }

    private func trocarCodigo(
        _ codigo: String,
        cliente: ClienteRegistrado,
        metadados: MetadadosDoServidor
    ) async throws -> CredenciaisDeToken {
        let verificador = cofre.carregar(conta: "pkce")
            .map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        cofre.apagar(conta: "pkce")

        var corpo: [String: Any] = [
            "grant_type": "authorization_code",
            "code": codigo,
            "redirect_uri": "papagaio://oauth/callback",
            "code_verifier": verificador,
        ]
        var pedido = pedido(metadados.token)
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if cliente.metodoDeAutenticacao == "client_secret_basic", let segredo = cliente.segredo {
            let base = "\(cliente.id):\(segredo)".data(using: .utf8)!.base64EncodedString()
            pedido.setValue("Basic \(base)", forHTTPHeaderField: "Authorization")
        } else {
            corpo["client_id"] = cliente.id
        }
        pedido.httpBody = try JSONSerialization.data(withJSONObject: corpo)

        registro.info("Trocando código de autorização por token")
        return try await responderComToken(pedido)
    }

    private func trocarRefreshToken(_ refresh: String) async throws -> CredenciaisDeToken {
        guard let cliente: ClienteRegistrado = cofre.carregar(conta: "client")
            .flatMap({ try? JSONDecoder().decode(ClienteRegistrado.self, from: $0) })
        else { throw ErroOAuth.semRefreshToken }

        var corpo: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ]
        var pedido = pedido((try await metadados()).token)
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if cliente.metodoDeAutenticacao == "client_secret_basic", let segredo = cliente.segredo {
            let base = "\(cliente.id):\(segredo)".data(using: .utf8)!.base64EncodedString()
            pedido.setValue("Basic \(base)", forHTTPHeaderField: "Authorization")
        } else {
            corpo["client_id"] = cliente.id
        }
        pedido.httpBody = try JSONSerialization.data(withJSONObject: corpo)

        registro.info("Renovando token com refresh token")
        let credenciais = try await responderComToken(pedido)
        return credenciais
    }

    private func revogar(_ token: String) async throws {
        let cliente: ClienteRegistrado? = cofre.carregar(conta: "client")
            .flatMap { try? JSONDecoder().decode(ClienteRegistrado.self, from: $0) }
        let metadados = try await metadados()
        var pedido = pedido(metadados.revogacao)
        pedido.httpMethod = "POST"
        pedido.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let cliente {
            let base = "\(cliente.id):\(cliente.segredo ?? "")".data(using: .utf8)!.base64EncodedString()
            pedido.setValue("Basic \(base)", forHTTPHeaderField: "Authorization")
        }
        var corpo = URLComponents()
        corpo.queryItems = [URLQueryItem(name: "token", value: token)]
        pedido.httpBody = corpo.query?.data(using: .utf8)
        _ = try? await sessao.data(for: pedido)
    }

    private func responderComToken(_ pedido: URLRequest) async throws -> CredenciaisDeToken {
        let (dados, _) = try await sessao.data(for: pedido)
        let json = try corpoJSON(dados)
        if let erro = json["error"] as? String {
            let descricao = json["error_description"] as? String ?? erro
            throw ErroOAuth.servidor(mensagem: descricao)
        }
        guard let acesso = json["access_token"] as? String else {
            throw ErroOAuth.respostaInvalida
        }
        let expiraEm = json["expires_in"] as? TimeInterval ?? 3600
        let credenciais = CredenciaisDeToken(
            accessToken: acesso,
            refreshToken: json["refresh_token"] as? String,
            expiraEm: Date().addingTimeInterval(expiraEm)
        )
        registro.info("Token obtido (expira em \(Int(expiraEm))s)")
        guardar(credenciais)
        return credenciais
    }

    private func guardar(_ credenciais: CredenciaisDeToken) {
        try? cofre.salvar(Data(credenciais.accessToken.utf8), conta: "access_token")
        if let refresh = credenciais.refreshToken {
            try? cofre.salvar(Data(refresh.utf8), conta: "refresh_token")
        }
        try? cofre.salvar(String(credenciais.expiraEm.timeIntervalSince1970).data(using: .utf8)!, conta: "access_token_expires")
    }

    private func carregarToken() -> TokenGuardado? {
        guard let valor = cofre.carregar(conta: "access_token")
            .map({ String(data: $0, encoding: .utf8) ?? "" }),
              !valor.isEmpty
        else { return nil }
        let expiraEm = cofre.carregar(conta: "access_token_expires")
            .flatMap { dados in TimeInterval(String(data: dados, encoding: .utf8) ?? "") }
            .map(Date.init(timeIntervalSince1970:)) ?? Date.distantFuture
        return TokenGuardado(valor: valor, expiraEm: expiraEm)
    }

    /// PKCE S256: verificador aleatório de 96 caracteres URL-safe, desafio é o
    /// hash SHA-256 base64url.
    private func gerarAtributoPKCE() -> (verificador: String, desafio: String) {
        let alfabeto = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let verificador = String((0..<96).map { _ in alfabeto.randomElement()! })
        let hash = Data(SHA256.hash(data: Data(verificador.utf8)))
        let desafio = hash.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verificador, desafio)
    }
}

// MARK: - Tipos internos

/// Registro do cliente depois do DCR.
private struct ClienteRegistrado: Codable {
    let id: String
    let segredo: String?
    let metodoDeAutenticacao: String
}

/// Resultado de uma troca de código/refresh.
private struct CredenciaisDeToken {
    let accessToken: String
    let refreshToken: String?
    let expiraEm: Date
}

/// Token guardado no Keychain.
private struct TokenGuardado {
    let valor: String
    let expiraEm: Date
}

/// Endpoints descobertos do servidor de autorização.
private struct MetadadosDoServidor {
    var registracao: URL
    var autorizacao: URL
    var token: URL
    var revogacao: URL
    /// Escopos que o servidor anuncia; vazio manda a URL sem `scope`.
    var escoposApresentados: [String]?
}
