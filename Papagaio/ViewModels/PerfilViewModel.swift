import AppKit
import AuthenticationServices
import Foundation
import Observation
import Security

/// Identidade opcional do perfil local.
///
/// O identificador do Sign in with Apple serve apenas ao perfil deste app;
/// arquivos, gravações e notas permanecem locais neste lançamento.
@MainActor
@Observable
final class PerfilViewModel: NSObject {
    private enum Chave {
        static let servico = "com.papagaio.Papagaio.perfil"
        static let conta = "apple-user-identifier"
        static let nome = "perfil.nome"
        static let email = "perfil.email"
        static let avatar = "perfil.avatar"
    }

    private(set) var identificador: String?
    // Vazio até a pessoa preencher ou entrar com a Apple. A UI já trata ausência.
    var nome = ""
    var email = ""
    var avatarURL: URL?
    private(set) var verificando = false
    private(set) var erro: String?
    private var observadorDeRevogacao: NSObjectProtocol?

    var conectado: Bool { identificador != nil }

    override init() {
        super.init()
        carregarPerfilLocal()
        observadorDeRevogacao = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.removerCredencial() }
        }
    }

    isolated deinit {
        if let observadorDeRevogacao {
            NotificationCenter.default.removeObserver(observadorDeRevogacao)
        }
    }

    /// Restaura a sessão local e confirma seu estado com a Apple.
    func iniciar() {
        guard let id = lerDoKeychain() else { return }
        identificador = id
        verificarEstadoDaCredencial(id)
    }

    func entrar() {
        erro = nil
        let requisicao = ASAuthorizationAppleIDProvider().createRequest()
        requisicao.requestedScopes = [.fullName, .email]

        let controlador = ASAuthorizationController(authorizationRequests: [requisicao])
        controlador.delegate = self
        controlador.presentationContextProvider = self
        controlador.performRequests()
    }

    func sair() {
        // Sair só remove o perfil deste app. Não revoga o consentimento na Apple.
        removerCredencial()
    }

    /// Limpa o perfil e a sessão que pertencem a esta instalação do app.
    /// A revogação do consentimento do Sign in with Apple é administrada pela
    /// Apple; aqui removemos a conta local e seus dados no dispositivo.
    func excluirDadosDaConta() {
        removerDoKeychain()
        UserDefaults.standard.removeObject(forKey: Chave.nome)
        UserDefaults.standard.removeObject(forKey: Chave.email)
        UserDefaults.standard.removeObject(forKey: Chave.avatar)
        identificador = nil
        nome = ""
        email = ""
        avatarURL = nil
        erro = nil
    }

    func salvarDados(nome: String, email: String) {
        let nomeLimpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailLimpo = email.trimmingCharacters(in: .whitespacesAndNewlines)

        self.nome = nomeLimpo.isEmpty ? self.nome : nomeLimpo
        self.email = emailLimpo.isEmpty ? self.email : emailLimpo
        UserDefaults.standard.set(self.nome, forKey: Chave.nome)
        UserDefaults.standard.set(self.email, forKey: Chave.email)
    }

    func escolherAvatar(_ url: URL) {
        do {
            let dados = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(dados, forKey: Chave.avatar)
            avatarURL = resolverBookmarkDeAvatar()
        } catch {
            avatarURL = url
            self.erro = "Não foi possível guardar a foto do perfil: %@".localized(error.localizedDescription)
        }
    }

    func dispensarErro() {
        erro = nil
    }

    private func verificarEstadoDaCredencial(_ id: String) {
        verificando = true
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { [weak self] estado, erro in
            Task { @MainActor in
                guard let self else { return }
                self.verificando = false
                switch estado {
                case .authorized:
                    break
                case .revoked, .notFound, .transferred:
                    self.removerCredencial()
                @unknown default:
                    self.erro = erro?.localizedDescription ?? "Não foi possível validar a credencial da Apple.".localized
                }
            }
        }
    }

    private func salvarNoKeychain(_ id: String) throws {
        removerDoKeychain()
        let consulta: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Chave.servico,
            kSecAttrAccount: Chave.conta,
            kSecValueData: Data(id.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(consulta as CFDictionary, nil)
        guard status == errSecSuccess else { throw ErroKeychain(status: status) }
    }

    private func lerDoKeychain() -> String? {
        let consulta: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Chave.servico,
            kSecAttrAccount: Chave.conta,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var resultado: CFTypeRef?
        let status = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard status == errSecSuccess, let dados = resultado as? Data else { return nil }
        return String(data: dados, encoding: .utf8)
    }

    private func removerCredencial() {
        removerDoKeychain()
        identificador = nil
    }

    private func carregarPerfilLocal() {
        if let nomeSalvo = UserDefaults.standard.string(forKey: Chave.nome), !nomeSalvo.isEmpty {
            nome = nomeSalvo
        }
        if let emailSalvo = UserDefaults.standard.string(forKey: Chave.email), !emailSalvo.isEmpty {
            email = emailSalvo
        }
        avatarURL = resolverBookmarkDeAvatar()
    }

    private func resolverBookmarkDeAvatar() -> URL? {
        guard let dados = UserDefaults.standard.data(forKey: Chave.avatar) else { return nil }
        var obsoleto = false
        return try? URL(
            resolvingBookmarkData: dados,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &obsoleto
        )
    }

    private func removerDoKeychain() {
        let consulta: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Chave.servico,
            kSecAttrAccount: Chave.conta,
        ]
        SecItemDelete(consulta as CFDictionary)
    }

    private struct ErroKeychain: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Erro do Keychain (%d).".localized(Int(status))
        }
    }
}

extension PerfilViewModel: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credencial = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        let id = credencial.user
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.salvarNoKeychain(id)
                self.identificador = id
                let nome = [credencial.fullName?.givenName, credencial.fullName?.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                self.salvarDados(
                    nome: nome.isEmpty ? self.nome : nome,
                    email: credencial.email ?? self.email
                )
            } catch {
                self.erro = "Não foi possível guardar sua sessão: %@".localized(error.localizedDescription)
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let codigo = (error as? ASAuthorizationError)?.code
        Task { @MainActor [weak self] in
            // Cancelar o painel não é um erro de produto.
            if codigo != .canceled { self?.erro = error.localizedDescription }
        }
    }
}

extension PerfilViewModel: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // O AuthenticationServices solicita a âncora durante a apresentação
        // do painel. A exigência do protocolo ainda é nonisolated, embora
        // AppKit so permita consultar janelas na main actor.
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        }
    }
}
