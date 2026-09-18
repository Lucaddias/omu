import AppKit
import SwiftUI

extension Notification.Name {
    static let aparenciaDoAppMudou = Notification.Name("aparenciaDoAppMudou")
}

/// Ponte SwiftUI -> AppKit para tema.
///
/// `.preferredColorScheme(nil)` sozinho não força a `NSWindow` a reconsultar
/// `NSApp.effectiveAppearance` na hora — ela só recalcula em resign/become key.
/// Por isso a troca para "Sistema" parecia presa até clicar fora e voltar.
/// Aqui setamos `window.appearance = nil` explicitamente e invalidamos o desenho.
@MainActor
enum SincroniaDeAparencia {
    static func aplicar(_ aparencia: AparenciaDoApp) {
        let ns = aparencia.nsAppearance // nil em .sistema = reconsulta o sistema
        for window in NSApp.windows {
            // Não forçar aparência em painéis de sistema (open/save).
            if window is NSOpenPanel || window is NSSavePanel { continue }
            window.appearance = ns
            window.viewsNeedDisplay = true
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
            window.displayIfNeeded()
        }
        NotificationCenter.default.post(name: .aparenciaDoAppMudou, object: aparencia)
    }
}
