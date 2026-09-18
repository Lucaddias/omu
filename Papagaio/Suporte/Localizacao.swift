import Foundation
import SwiftUI

/// Gerenciador central de localização e regionalização baseado no sistema oficial da Apple (Localizable.xcstrings).
public enum LocalizacaoDoApp: Sendable {
    /// Locale que o macOS atribuiu ao app. Ele acompanha a escolha de idioma
    /// do sistema (ou o idioma específico do app em Ajustes do Sistema).
    public static var localeAtual: Locale { .autoupdatingCurrent }

    /// Retorna a tradução do catálogo oficial compilado da Apple (Localizable.xcstrings).
    public static func texto(_ chave: String) -> String {
        NSLocalizedString(chave, tableName: nil, bundle: .main, value: chave, comment: "")
    }
}

public extension String {
    /// Versão regionalizada da string para a interface do app utilizando o catálogo oficial da Apple.
    var localized: String {
        LocalizacaoDoApp.texto(self)
    }

    /// Versão regionalizada formatada com argumentos utilizando o catálogo oficial da Apple.
    func localized(_ args: CVarArg...) -> String {
        let formato = LocalizacaoDoApp.texto(self)
        return String(format: formato, locale: LocalizacaoDoApp.localeAtual, arguments: args)
    }
}
