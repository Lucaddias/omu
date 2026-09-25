import AppKit
import CloudKit
import Foundation

extension Notification.Name {
    static let equipeCloudKitAceita = Notification.Name("equipeCloudKitAceita")
    static let equipeCloudKitFalhou = Notification.Name("equipeCloudKitFalhou")
}

/// Recebe o convite aberto pelo macOS. A aceitação é feita fora da view para
/// também funcionar quando o Papagaio ainda não estava aberto.
final class DelegadoDeConvitesCloudKit: NSObject, NSApplicationDelegate {
#if OMU_PERF
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        PerfProbe.shared.aplicaçãoVaiTerminar()
    }
#endif

    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadados: CKShare.Metadata
    ) {
        guard PoliticaDeInicializacaoExterna().permiteServicosExternos else { return }
        Task {
            do {
                let equipe = try await ServicoDeEquipesCloudKit().aceitar(metadados)
                await MainActor.run {
                    EquipesDoUsuario.incluirOuAtualizar(equipe)
                    NotificationCenter.default.post(name: .equipeCloudKitAceita, object: equipe)
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .equipeCloudKitFalhou,
                        object: error.localizedDescription
                    )
                }
            }
        }
    }
}
