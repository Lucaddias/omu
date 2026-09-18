import AppKit
import Foundation

/// Acrescenta "Salvar em…" ao painel de compartilhamento do macOS.
///
/// O painel do sistema lista apps e serviços — Mail, Mensagens, AirDrop — mas
/// não oferece gravar num diretório. Como o `NSSharingServicePicker` aceita
/// serviços próprios, entra aqui um que abre o painel de salvar. Assim
/// "compartilhar" e "salvar no disco" ficam no mesmo lugar, que é onde a
/// pessoa procura.
final class OpcoesDeCompartilhamento: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let arquivos: [URL]
    private weak var servicoSalvar: NSSharingService?

    init(arquivos: [URL]) {
        self.arquivos = arquivos
    }

    func sharingServicePicker(
        _ picker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices propostos: [NSSharingService]
    ) -> [NSSharingService] {
        guard let primeiro = arquivos.first else { return propostos }

        let icone = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage()
        let arquivosParaLimpar = arquivos
        let salvar = NSSharingService(title: "Salvar em…", image: icone, alternateImage: nil) {
            Task { @MainActor in
                let painel = NSSavePanel()
                painel.nameFieldStringValue = primeiro.lastPathComponent
                painel.canCreateDirectories = true
                guard painel.runModal() == .OK, let destino = painel.url else {
                    arquivosParaLimpar.forEach(DossieDaConversa.descartarArquivoTemporario)
                    return
                }

                // Um dossiê pode conter horas de áudio. A cópia síncrona na
                // main congelava toda a janela até o arquivo terminar.
                Task.detached {
                    defer { arquivosParaLimpar.forEach(DossieDaConversa.descartarArquivoTemporario) }
                    let acesso = destino.startAccessingSecurityScopedResource()
                    defer { if acesso { destino.stopAccessingSecurityScopedResource() } }
                    do {
                        if FileManager.default.fileExists(atPath: destino.path) {
                            try FileManager.default.removeItem(at: destino)
                        }
                        try FileManager.default.copyItem(at: primeiro, to: destino)
                    } catch {
                        await MainActor.run {
                            let alerta = NSAlert()
                            alerta.messageText = "Não foi possível salvar".localized
                            alerta.informativeText = error.localizedDescription
                            alerta.alertStyle = .warning
                            alerta.runModal()
                        }
                    }
                }
            }
        }
        servicoSalvar = salvar

        return [salvar] + propostos
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        sharingService === servicoSalvar ? nil : self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        if service == nil { descartarTemporarios() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        descartarTemporarios()
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        descartarTemporarios()
    }

    private func descartarTemporarios() {
        arquivos.forEach(DossieDaConversa.descartarArquivoTemporario)
    }
}
