import Foundation
import Testing
@testable import Papagaio

@Test("Callback Google aceita código somente com o state esperado")
func callbackGoogleValido() throws {
    let requisicao = "GET /oauth/callback?code=codigo-curto&state=estado-certo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

    let codigo = try ServidorOAuthLocal.extrairCodigo(
        da: requisicao,
        estadoEsperado: "estado-certo"
    )

    #expect(codigo == "codigo-curto")
}

@Test("Callback Google rejeita state ausente")
func callbackGoogleSemState() {
    let requisicao = "GET /oauth/callback?code=codigo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

    do {
        _ = try ServidorOAuthLocal.extrairCodigo(
            da: requisicao,
            estadoEsperado: "estado-certo"
        )
        Issue.record("Callback sem state foi aceito")
    } catch {
        #expect(error as? ErroOAuthGoogle == .estadoAusente)
    }
}

@Test("Callback Google rejeita state divergente")
func callbackGoogleComStateDivergente() {
    let requisicao = "GET /oauth/callback?code=codigo&state=outro HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

    do {
        _ = try ServidorOAuthLocal.extrairCodigo(
            da: requisicao,
            estadoEsperado: "estado-certo"
        )
        Issue.record("Callback com state divergente foi aceito")
    } catch {
        #expect(error as? ErroOAuthGoogle == .estadoInvalido)
    }
}

@Test("Cancelar a espera fecha o servidor local e desbloqueia o callback")
func servidorOAuthGooglePodeSerCancelado() async throws {
    let servidor = ServidorOAuthLocal(estadoEsperado: "estado")
    _ = try await servidor.iniciar()
    let espera = Task {
        try await servidor.aguardarCodigo()
    }

    try await Task.sleep(for: .milliseconds(50))
    espera.cancel()

    do {
        _ = try await espera.value
        Issue.record("A espera continuou ativa depois do cancelamento")
    } catch {
        #expect(error is CancellationError)
    }
    await servidor.parar()
}

@Test("Timeout do OAuth encerra o servidor sem bloquear o actor")
func timeoutDoOAuthGoogleEncerraEspera() async throws {
    let cofre = CofreOAuthGoogleEmMemoria()
    let sessao = SessaoOAuthGoogle(cofre: cofre)
    let servidor = ServidorOAuthLocal(estadoEsperado: "estado")
    _ = try await servidor.iniciar()

    do {
        _ = try await sessao.aguardarCodigo(
            no: servidor,
            tempoLimite: .milliseconds(50)
        )
        Issue.record("O servidor não respeitou o timeout")
    } catch {
        #expect(error as? ErroOAuthGoogle == .tempoEsgotado)
    }
}

@Test("Falha ao persistir PKCE interrompe a autorização com mensagem localizável")
func falhaAoSalvarPKCEEhPropagada() {
    let cofre = CofreOAuthGoogleEmMemoria(falharAoSalvar: true)
    let sessao = SessaoOAuthGoogle(cofre: cofre)

    do {
        _ = try sessao.prepararAutorizacao(
            redirectURI: "http://127.0.0.1:1234/oauth/callback",
            estado: "estado"
        )
        Issue.record("A autorização prosseguiu sem persistir o verificador PKCE")
    } catch {
        #expect(error.localizedDescription == FalhaDoCofreFake().localizedDescription)
    }
}

@Test("Logout Google apaga token, validade, refresh e PKCE")
func logoutGoogleApagaTodasAsChaves() async throws {
    let cofre = CofreOAuthGoogleEmMemoria()
    try cofre.salvar(Data("acesso".utf8), conta: "access_token")
    try cofre.salvar(Data("validade".utf8), conta: "access_token_expires")
    try cofre.salvar(Data("verificador".utf8), conta: "pkce")
    let sessao = SessaoOAuthGoogle(cofre: cofre)

    await sessao.sair()

    #expect(cofre.contasPersistidas.isEmpty)
}

@Test("URL de autorização usa PKCE e state sem incorporar Client Secret")
func autorizacaoGoogleEhClientePublico() throws {
    let cofre = CofreOAuthGoogleEmMemoria()
    let sessao = SessaoOAuthGoogle(cofre: cofre)
    let url = try sessao.prepararAutorizacao(
        redirectURI: "http://127.0.0.1:1234/oauth/callback",
        estado: "estado-unico"
    )
    let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    #expect(itens.first(where: { $0.name == "state" })?.value == "estado-unico")
    #expect(itens.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    #expect(!itens.contains(where: { $0.name == "client_secret" }))
    #expect(cofre.carregar(conta: "pkce")?.isEmpty == false)
    let chaveLegada = ["GOOGLE", "CLIENT", "SECRET"].joined(separator: "_")
    #expect(Bundle.main.object(forInfoDictionaryKey: chaveLegada) == nil)
}

private struct FalhaDoCofreFake: LocalizedError {
    var errorDescription: String? {
        "Não foi possível guardar a credencial de segurança local."
    }
}

private final class CofreOAuthGoogleEmMemoria: CofreDeTokensOAuthGoogle, @unchecked Sendable {
    private let trava = NSLock()
    private var dados: [String: Data] = [:]
    private let falharAoSalvar: Bool

    init(falharAoSalvar: Bool = false) {
        self.falharAoSalvar = falharAoSalvar
    }

    var contasPersistidas: Set<String> {
        trava.withLock { Set(dados.keys) }
    }

    func salvar(_ dados: Data, conta: String) throws {
        if falharAoSalvar { throw FalhaDoCofreFake() }
        trava.withLock {
            self.dados[conta] = dados
        }
    }

    func carregar(conta: String) -> Data? {
        trava.withLock { dados[conta] }
    }

    func apagar(conta: String) {
        _ = trava.withLock {
            dados.removeValue(forKey: conta)
        }
    }
}

@Test("Cancelar OAuth também desbloqueia cliente conectado que não envia cabeçalho")
func cancelarOAuthComClienteSilencioso() async throws {
    let servidor = ServidorOAuthLocal(estadoEsperado: "estado")
    let porta = try await servidor.iniciar()
    let cliente = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard cliente >= 0 else { throw ErroOAuthGoogle.respostaInvalida }
    defer { Darwin.close(cliente) }
    var endereco = sockaddr_in()
    endereco.sin_family = sa_family_t(AF_INET)
    endereco.sin_addr.s_addr = inet_addr("127.0.0.1")
    endereco.sin_port = UInt16(porta).bigEndian
    let conectado = withUnsafePointer(to: &endereco) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(cliente, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(conectado == 0)
    let espera = Task { try await servidor.aguardarCodigo() }
    try await Task.sleep(for: .milliseconds(50))
    espera.cancel()
    do {
        _ = try await espera.value
        Issue.record("Callback silencioso não respeitou cancelamento")
    } catch { #expect(error is CancellationError) }
    await servidor.parar()
}
