import AppKit
import CloudKit
import Foundation

extension Notification.Name {
    static let equipeCloudKitAceita = Notification.Name("equipeCloudKitAceita")
}

/// Recebe o convite aberto pelo macOS. A aceitação é feita fora da view para
/// também funcionar quando o Papagaio ainda não estava aberto.
final class DelegadoDeConvitesCloudKit: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadados: CKShare.Metadata
    ) {
        Task {
            do {
                let equipe = try await ServicoDeEquipesCloudKit().aceitar(metadados)
                await MainActor.run {
                    EquipesDoUsuario.incluirOuAtualizar(equipe)
                    NotificationCenter.default.post(name: .equipeCloudKitAceita, object: equipe)
                }
            } catch {
                // A próxima fase apresenta esse erro na interface. Aqui a
                // prioridade é nunca impedir o lançamento do app por um link
                // expirado ou por iCloud indisponível.
            }
        }
    }
}
