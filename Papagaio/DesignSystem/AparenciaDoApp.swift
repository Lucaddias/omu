import AppKit
import SwiftUI

/// Tema escolhido pelo usuário em Configurações.
///
/// As cores do `PapagaioTema` já sabem se desenhar clara ou escura; o que faltava
/// era decidir **qual** aparência vale. `sistema` deixa o Mac mandar, mas quem
/// prefere um tema fixo não deveria ter de trocar o ajuste do sistema inteiro só
/// por causa deste app.
enum AparenciaDoApp: String, CaseIterable, Identifiable {
    case sistema
    case claro
    case escuro

    var id: Self { self }

    var titulo: String {
        switch self {
        case .sistema: "Sistema".localized
        case .claro: "Claro".localized
        case .escuro: "Escuro".localized
        }
    }

    var simbolo: String {
        switch self {
        case .sistema: "circle.lefthalf.filled"
        case .claro: "sun.max"
        case .escuro: "moon"
        }
    }

    var descricao: String {
        switch self {
        case .sistema: "Acompanha o ajuste de aparência do seu Mac.".localized
        case .claro: "Mantém o app claro, mesmo com o Mac no escuro.".localized
        case .escuro: "Mantém o app escuro, mesmo com o Mac no claro.".localized
        }
    }

    /// `nil` em `sistema`: sem esquema preferido, o SwiftUI herda a aparência da
    /// janela — que é justamente o comportamento de acompanhar o sistema.
    var esquemaPreferido: ColorScheme? {
        switch self {
        case .sistema: nil
        case .claro: .light
        case .escuro: .dark
        }
    }

    /// A mesma escolha, só que para janelas feitas em AppKit puro (o painel
    /// flutuante de gravação, por exemplo).
    ///
    /// `.preferredColorScheme` só afeta o ambiente do SwiftUI — quem decide a
    /// aparência de verdade de uma janela (e das cores dinâmicas do
    /// `PapagaioTema`, que resolvem contra a `NSAppearance` da janela, não
    /// contra o `colorScheme` do SwiftUI) é a própria `NSWindow`/`NSPanel`.
    /// Uma janela hospedada fora da hierarquia do `ContentView` — como o
    /// painel flutuante, que vive no seu próprio `NSHostingView` — nunca
    /// herda o `.preferredColorScheme` da janela principal, e sem isto ela
    /// seguia a aparência real do Mac mesmo com o app forçado no escuro.
    var nsAppearance: NSAppearance? {
        switch self {
        case .sistema: nil
        case .claro: NSAppearance(named: .aqua)
        case .escuro: NSAppearance(named: .darkAqua)
        }
    }
}
