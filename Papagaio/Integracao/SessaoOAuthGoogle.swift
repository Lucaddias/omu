import CryptoKit
import Foundation
import os
import PapagaioCore
import AppKit

enum ErroOAuthGoogle: LocalizedError, Equatable {
    case credenciaisNaoConfiguradas
    case autorizacaoNegada
    case semCodigoDeAutorizacao
    case respostaInvalida
    case servidor(mensagem: String)
    case semRefreshToken
    case navegadorNaoAbriu
    case tempoEsgotado
    case servidorLocalFalhou(String)
    case estadoAusente
    case estadoInvalido

    var errorDescription: String? {
        switch self {
        case .credenciaisNaoConfiguradas:
            return "Client ID do Google não configurado. Configure-o no arquivo local do projeto.".localized
        case .autorizacaoNegada:
            return "Autorização cancelada ou recusada no navegador.".localized
        case .semCodigoDeAutorizacao:
            return "O navegador voltou sem o código de autorização. Tente de novo.".localized
        case .respostaInvalida:
            return "O servidor do Google respondeu de forma inesperada.".localized
        case let .servidor(mensagem):
            return "O servidor respondeu: %@.".localized(mensagem)
        case .semRefreshToken:
            return "A sessão expirou e não há refresh token. Conecte de novo.".localized
        case .navegadorNaoAbriu:
            return "O navegador não abriu — confira se o Ōmu pode abrir janelas e tente de novo.".localized
        case .tempoEsgotado:
            return "Tempo esgotado esperando sua autorização — volte ao navegador e tente de novo.".localized
        case let .servidorLocalFalhou(msg):
            return "Falha ao iniciar servidor local para OAuth: %@".localized(msg)
        case .estadoAusente, .estadoInvalido:
            return "O retorno de autorização não corresponde à conexão iniciada. Tente conectar novamente.".localized
        }
    }
}

protocol CofreDeTokensOAuthGoogle: Sendable {
    func salvar(_ dados: Data, conta: String) throws
    func carregar(conta: String) -> Data?
    func apagar(conta: String)
}

extension CofreDeTokens: CofreDeTokensOAuthGoogle {}

enum CredenciaisGoogle {
    static var clienteID: String {
        if let valor = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
           !valor.isEmpty {
            return valor
        }
        return ""
    }

    static var estaConfigurado: Bool {
        !clienteID.isEmpty
    }
}

final class SessaoOAuthGoogle: Sendable {
    private let cofre: any CofreDeTokensOAuthGoogle
    private let sessao = URLSession(configuration: .ephemeral)
    private let registro = Logger(subsystem: "Papagaio", category: "GoogleCalendar")

    private let autorizacaoEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private let revogacaoEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private let userinfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    private let escopos = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email"

    init(
        cofre: any CofreDeTokensOAuthGoogle
    ) {
        self.cofre = cofre
    }

    func tokenDeAcesso(forcandoRenovacao forcar: Bool) async throws -> String {
        guard CredenciaisGoogle.estaConfigurado else {
            throw ErroOAuthGoogle.credenciaisNaoConfiguradas
        }

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

    func sair() async {
        if let refresh = cofre.carregar(conta: "refresh_token")
            .map({ String(data: $0, encoding: .utf8) ?? "" }),
           !refresh.isEmpty {
            try? await revogar(refresh)
        }
        registro.info("Sessão Google encerrada — credenciais apagadas do Keychain")
        cofre.apagar(conta: "access_token")
        cofre.apagar(conta: "access_token_expires")
        cofre.apagar(conta: "refresh_token")
        cofre.apagar(conta: "pkce")
    }

    private func fluxoDeAutorizacao() async throws -> String {
        let estado = UUID().uuidString
        let (servidor, redirectURI) = try await iniciarServidorLocal(estadoEsperado: estado)

        let url: URL
        do {
            url = try prepararAutorizacao(redirectURI: redirectURI, estado: estado)
        } catch {
            await servidor.parar()
            throw error
        }

        guard NSWorkspace.shared.open(url) else {
            cofre.apagar(conta: "pkce")
            await servidor.parar()
            throw ErroOAuthGoogle.navegadorNaoAbriu
        }

        let codigo: String
        do {
            codigo = try await aguardarCodigo(no: servidor, tempoLimite: .seconds(180))
        } catch {
            cofre.apagar(conta: "pkce")
            throw error
        }

        guard !codigo.isEmpty else {
            cofre.apagar(conta: "pkce")
            throw ErroOAuthGoogle.semCodigoDeAutorizacao
        }

        registro.info("Autorização recebida; iniciando troca segura do código")
        let credenciais = try await trocarCodigo(codigo, redirectURI: redirectURI)
        return credenciais.accessToken
    }

    func aguardarCodigo(
        no servidor: ServidorOAuthLocal,
        tempoLimite: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await servidor.aguardarCodigo()
            }
            group.addTask {
                try await Task.sleep(for: tempoLimite)
                throw ErroOAuthGoogle.tempoEsgotado
            }
            do {
                guard let resultado = try await group.next() else {
                    throw ErroOAuthGoogle.tempoEsgotado
                }
                group.cancelAll()
                await servidor.parar()
                return resultado
            } catch {
                group.cancelAll()
                await servidor.parar()
                throw error
            }
        }
    }

    private func iniciarServidorLocal(
        estadoEsperado: String
    ) async throws -> (ServidorOAuthLocal, redirectURI: String) {
        let servidor = ServidorOAuthLocal(estadoEsperado: estadoEsperado)
        let porta = try await servidor.iniciar()
        let redirectURI = "http://127.0.0.1:\(porta)/oauth/callback"
        return (servidor, redirectURI)
    }

    func prepararAutorizacao(redirectURI: String, estado: String) throws -> URL {
        let par = gerarAtributoPKCE()
        try cofre.salvar(Data(par.verificador.utf8), conta: "pkce")

        var componentes = URLComponents(url: autorizacaoEndpoint, resolvingAgainstBaseURL: false)!
        let itens = [
            URLQueryItem(name: "client_id", value: CredenciaisGoogle.clienteID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: par.desafio),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: estado),
            URLQueryItem(name: "scope", value: escopos),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "none"),
        ]
        componentes.queryItems = itens
        guard let url = componentes.url else {
            cofre.apagar(conta: "pkce")
            throw ErroOAuthGoogle.respostaInvalida
        }
        registro.info("URL de autorização Google preparada")
        return url
    }

    private func trocarCodigo(_ codigo: String, redirectURI: String) async throws -> CredenciaisDeToken {
        let verificador = cofre.carregar(conta: "pkce")
            .map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        cofre.apagar(conta: "pkce")
        guard !verificador.isEmpty else {
            throw ErroOAuthGoogle.respostaInvalida
        }

        let corpo: [String: Any] = [
            "grant_type": "authorization_code",
            "code": codigo,
            "redirect_uri": redirectURI,
            "code_verifier": verificador,
            "client_id": CredenciaisGoogle.clienteID,
        ]

        var pedido = URLRequest(url: tokenEndpoint)
        pedido.timeoutInterval = 15
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.httpBody = try JSONSerialization.data(withJSONObject: corpo)

        registro.info("Trocando código de autorização por token (Google)")
        return try await responderComToken(pedido)
    }

    private func trocarRefreshToken(_ refresh: String) async throws -> CredenciaisDeToken {
        let corpo: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": CredenciaisGoogle.clienteID,
        ]

        var pedido = URLRequest(url: tokenEndpoint)
        pedido.timeoutInterval = 15
        pedido.httpMethod = "POST"
        pedido.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pedido.httpBody = try JSONSerialization.data(withJSONObject: corpo)

        registro.info("Renovando token com refresh token (Google)")
        return try await responderComToken(pedido)
    }

    private func revogar(_ token: String) async throws {
        var pedido = URLRequest(url: revogacaoEndpoint)
        pedido.timeoutInterval = 15
        pedido.httpMethod = "POST"
        pedido.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var corpo = URLComponents()
        corpo.queryItems = [URLQueryItem(name: "token", value: token)]
        pedido.httpBody = corpo.query?.data(using: .utf8)
        _ = try? await sessao.data(for: pedido)
    }

    private func responderComToken(_ pedido: URLRequest) async throws -> CredenciaisDeToken {
        let (dados, resposta) = try await sessao.data(for: pedido)
        guard let http = resposta as? HTTPURLResponse else {
            throw ErroOAuthGoogle.respostaInvalida
        }
        let json = try corpoJSON(dados)
        if let erro = json["error"] as? String {
            let descricao = json["error_description"] as? String ?? erro
            if http.statusCode == 400 && erro == "invalid_grant" {
                registro.info("Refresh token inválido/expirado — fluxo completo na próxima")
                cofre.apagar(conta: "refresh_token")
            }
            throw ErroOAuthGoogle.servidor(mensagem: descricao)
        }
        guard let acesso = json["access_token"] as? String else {
            throw ErroOAuthGoogle.respostaInvalida
        }
        let expiraEm = json["expires_in"] as? TimeInterval ?? 3600
        let credenciais = CredenciaisDeToken(
            accessToken: acesso,
            refreshToken: json["refresh_token"] as? String,
            expiraEm: Date().addingTimeInterval(expiraEm)
        )
        registro.info("Token Google obtido (expira em \(Int(expiraEm))s)")
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

    private func corpoJSON(_ dados: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            throw ErroOAuthGoogle.respostaInvalida
        }
        return json
    }

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

    func obterInfoConta(accessToken: String) async throws -> (email: String, nome: String?) {
        var pedido = URLRequest(url: userinfoEndpoint)
        pedido.timeoutInterval = 15
        pedido.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (dados, _) = try await sessao.data(for: pedido)
        let json = try corpoJSON(dados)
        let email = (json["email"] as? String) ?? ""
        let nome = json["name"] as? String
        return (email, nome)
    }
}

actor ServidorOAuthLocal {
    private static let filaDeSocket = DispatchQueue(
        label: "papagaio.oauth.google.loopback",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let estadoEsperado: String
    private var listener: FileHandle?
    private var conexao = ConexaoOAuthLocal()

    init(estadoEsperado: String) {
        self.estadoEsperado = estadoEsperado
    }

    func iniciar() async throws -> Int {
        parar()
        conexao = ConexaoOAuthLocal()
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw ErroOAuthGoogle.servidorLocalFalhou("socket falhou")
        }

        var opt = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socket)
            throw ErroOAuthGoogle.servidorLocalFalhou("bind falhou")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsockResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &len)
            }
        }
        guard getsockResult == 0 else {
            close(socket)
            throw ErroOAuthGoogle.servidorLocalFalhou("getsockname falhou")
        }

        let porta = Int(UInt16(addr.sin_port).byteSwapped)

        guard listen(socket, 1) == 0 else {
            close(socket)
            throw ErroOAuthGoogle.servidorLocalFalhou("listen falhou")
        }

        self.listener = FileHandle(fileDescriptor: socket, closeOnDealloc: true)

        return porta
    }

    func aguardarCodigo() async throws -> String {
        guard let listener else {
            throw ErroOAuthGoogle.servidorLocalFalhou("servidor não iniciado")
        }
        let conexao = self.conexao
        let estadoEsperado = self.estadoEsperado

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuacao in
                Self.filaDeSocket.async {
                    do {
                        let codigo = try Self.receberCallback(
                            no: listener.fileDescriptor,
                            conexao: conexao,
                            estadoEsperado: estadoEsperado
                        )
                        continuacao.resume(returning: codigo)
                    } catch {
                        continuacao.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            conexao.cancelar()
            Darwin.shutdown(listener.fileDescriptor, SHUT_RDWR)
        }
    }

    func parar() {
        conexao.cancelar()
        if let descritor = listener?.fileDescriptor, descritor >= 0 {
            Darwin.shutdown(descritor, SHUT_RDWR)
        }
        // O worker retém o FileHandle até sair do accept. Fechá-lo aqui
        // permitiria que o sistema reutilizasse o descritor antes do worker.
        listener = nil
    }

    nonisolated static func extrairCodigo(
        da requisicao: String,
        estadoEsperado: String
    ) throws -> String {
        guard let primeiraLinha = requisicao.split(separator: "\n").first,
              primeiraLinha.hasPrefix("GET ") || primeiraLinha.hasPrefix("POST ")
        else { throw ErroOAuthGoogle.respostaInvalida }
        let partes = primeiraLinha.split(separator: " ")
        guard partes.count >= 2 else { throw ErroOAuthGoogle.respostaInvalida }
        let caminho = String(partes[1])
        guard let urlComponents = URLComponents(string: caminho),
              urlComponents.path == "/oauth/callback"
        else { throw ErroOAuthGoogle.respostaInvalida }

        let itens = urlComponents.queryItems ?? []
        guard let estado = itens.first(where: { $0.name == "state" })?.value,
              !estado.isEmpty
        else { throw ErroOAuthGoogle.estadoAusente }
        guard estado == estadoEsperado else {
            throw ErroOAuthGoogle.estadoInvalido
        }
        if itens.contains(where: { $0.name == "error" }) {
            throw ErroOAuthGoogle.autorizacaoNegada
        }
        guard let code = itens.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else { throw ErroOAuthGoogle.semCodigoDeAutorizacao }
        return code
    }

    nonisolated private static func receberCallback(
        no socket: Int32,
        conexao: ConexaoOAuthLocal,
        estadoEsperado: String
    ) throws -> String {
        var endereco = sockaddr_in()
        var tamanho = socklen_t(MemoryLayout<sockaddr_in>.size)
        let cliente = withUnsafeMutablePointer(to: &endereco) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(socket, $0, &tamanho)
            }
        }
        guard cliente >= 0 else {
            throw CancellationError()
        }
        guard conexao.registrar(cliente) else {
            Darwin.close(cliente)
            throw CancellationError()
        }
        defer { conexao.fechar() }
        var semSIGPIPE = 1
        setsockopt(
            cliente,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &semSIGPIPE,
            socklen_t(MemoryLayout<Int>.size)
        )

        var dados = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        // TCP pode dividir a primeira linha em vários pacotes. O limite
        // restringe memória; cancelar fecha também a conexão já aceita.
        while dados.count < 8_192 && dados.range(of: Data("\r\n\r\n".utf8)) == nil {
            let quantidade = Darwin.read(cliente, &buffer, min(buffer.count, 8_192 - dados.count))
            if conexao.cancelada { throw CancellationError() }
            guard quantidade > 0 else { throw ErroOAuthGoogle.respostaInvalida }
            dados.append(contentsOf: buffer.prefix(quantidade))
        }
        guard dados.range(of: Data("\r\n\r\n".utf8)) != nil,
              let requisicao = String(data: dados, encoding: .utf8) else {
            try? enviarResposta(status: "400 Bad Request", no: cliente)
            throw ErroOAuthGoogle.respostaInvalida
        }

        do {
            let codigo = try extrairCodigo(
                da: requisicao,
                estadoEsperado: estadoEsperado
            )
            try enviarResposta(status: "200 OK", no: cliente)
            return codigo
        } catch {
            try? enviarResposta(status: "400 Bad Request", no: cliente)
            throw error
        }
    }

    nonisolated private static func enviarResposta(
        status: String,
        no socket: Int32
    ) throws {
        let sucesso = status.hasPrefix("200")
        let titulo = sucesso ? "Autorização concluída".localized : "Autorização recusada".localized
        let mensagem = sucesso
            ? "Pode fechar esta janela e voltar ao Ōmu.".localized
            : "Volte ao Ōmu e tente novamente.".localized
        let corpo = "<html><body><h1>\(titulo)</h1><p>\(mensagem)</p></body></html>"
        let corpoData = Data(corpo.utf8)
        var resposta = Data("HTTP/1.1 \(status)\r\n".utf8)
        resposta.append(Data("Content-Type: text/html; charset=utf-8\r\n".utf8))
        resposta.append(Data("Connection: close\r\n".utf8))
        resposta.append(Data("Content-Length: \(corpoData.count)\r\n\r\n".utf8))
        resposta.append(corpoData)

        try resposta.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var enviados = 0
            while enviados < resposta.count {
                let quantidade = Darwin.write(
                    socket,
                    base.advanced(by: enviados),
                    resposta.count - enviados
                )
                guard quantidade > 0 else {
                    throw ErroOAuthGoogle.servidorLocalFalhou("resposta HTTP falhou")
                }
                enviados += quantidade
            }
        }
    }
}

/// A posse do socket aceito cruza a fila bloqueante e o cancelamento Swift.
/// Shutdown desbloqueia read; só o worker fecha, sob a mesma trava, evitando
/// fechar um descritor que o sistema já tenha reutilizado.
private final class ConexaoOAuthLocal: @unchecked Sendable {
    private let trava = NSLock()
    private var cliente: Int32?
    private var foiCancelada = false

    var cancelada: Bool { trava.withLock { foiCancelada } }

    func registrar(_ descritor: Int32) -> Bool {
        trava.withLock {
            guard !foiCancelada else { return false }
            cliente = descritor
            return true
        }
    }

    func cancelar() {
        trava.withLock {
            foiCancelada = true
            if let cliente { Darwin.shutdown(cliente, SHUT_RDWR) }
        }
    }

    func fechar() {
        trava.withLock {
            if let cliente {
                Darwin.shutdown(cliente, SHUT_RDWR)
                Darwin.close(cliente)
                self.cliente = nil
            }
        }
    }
}

private struct CredenciaisDeToken {
    let accessToken: String
    let refreshToken: String?
    let expiraEm: Date
}

private struct TokenGuardado {
    let valor: String
    let expiraEm: Date
}
