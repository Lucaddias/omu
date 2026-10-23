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
    /// Segura o encerramento enquanto uma gravação é finalizada.
    ///
    /// A conversa só é registrada quando a gravação para. ⌘Q, "Encerrar" no
    /// Dock ou o logout no meio de uma reunião matavam o processo com o áudio
    /// no disco e nenhum registro apontando para ele.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EncerramentoDoApp.haGravacaoEmCurso else { return .terminateNow }
        Task { @MainActor in
            await EncerramentoDoApp.finalizarGravacao()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

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
                let servico = ServicoDeEquipesCloudKit()
                let equipe = try await servico.aceitar(metadados)
                let incluida = await MainActor.run { EquipesDoUsuario.incluirOuAtualizar(equipe) }
                guard incluida else {
                    await servico.abandonarZonaCompartilhada(de: equipe)
                    throw ErroDeEquipeCloudKit.conviteConflitaComEquipeLocal
                }
                await MainActor.run {
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
