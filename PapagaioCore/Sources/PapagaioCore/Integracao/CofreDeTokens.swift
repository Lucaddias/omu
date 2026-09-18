import Foundation
import Security

/// Guarda segredos (token de acesso, refresh, registro do cliente) no
/// Keychain — o único lugar do macOS onde credenciais sobrevivem a
/// reinicializações sem ficarem em texto puro no disco.
public struct CofreDeTokens: Sendable {
    public let servico: String

    public init(servico: String) {
        self.servico = servico
    }

    public func salvar(_ dados: Data, conta: String) throws {
        let atributos: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: conta,
        ]
        SecItemDelete(atributos as CFDictionary)
        var novo = atributos
        novo[kSecValueData as String] = dados
        novo[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(novo as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ErroDoCofre.falha(status: status)
        }
    }

    public func carregar(conta: String) -> Data? {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: conta,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultado: CFTypeRef?
        let status = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard status == errSecSuccess, let dados = resultado as? Data else {
            return nil
        }
        return dados
    }

    /// Quais destas contas têm item guardado — sem ler o segredo.
    ///
    /// Pede só atributos, nunca `kSecReturnData`: o macOS só pede a senha do
    /// Keychain quando precisa decifrar o valor. Uma checagem de "tem
    /// credencial?" no launch não deve disparar prompt nenhum.
    public func contasExistentes(entre contas: Set<String>) -> Set<String> {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var resultado: CFTypeRef?
        let status = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard status == errSecSuccess,
              let itens = resultado as? [[String: Any]]
        else { return [] }
        let existentes = itens.compactMap { $0[kSecAttrAccount as String] as? String }
        return contas.intersection(existentes)
    }

    public func apagar(conta: String) {
        let atributos: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: conta,
        ]
        SecItemDelete(atributos as CFDictionary)
    }
}

public enum ErroDoCofre: LocalizedError, Equatable {
    case falha(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .falha(status):
            "Não foi possível guardar a credencial no Keychain (OSStatus \(status))."
        }
    }
}

/// Quem apresenta o navegador de autorização ao usuário.
///
/// O app usa `ASWebAuthenticationSession`; a CLI de avaliação usa um
/// prompt (URL impressa + código colado). Só o fluxo de autorização difere —
/// DCR, PKCE e troca de token são os mesmos.
public protocol ApresentadorDeAutorizacaoOAuth: Sendable {
    /// Abre a URL de autorização e devolve o código de autorização
    /// (`authorization_code`) ou lança `ErroOAuth.autorizacaoNegada`.
    func autorizar(url: URL) async throws -> String
}