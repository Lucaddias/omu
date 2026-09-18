import AppKit
import SwiftUI

extension Notification.Name {
    static let abrirGravacaoNoApp = Notification.Name("abrirGravacaoNoApp")
}

/// Escolhe o host antes de construir qualquer estado ou cena de produção.
@main
enum InicializacaoDoPapagaio {
    @MainActor
    static func main() {
        if PoliticaDeInicializacaoExterna().permiteServicosExternos {
            PapagaioApp.main()
        } else {
            HostDeTestesDoPapagaio.main()
        }
    }
}

private struct HostDeTestesDoPapagaio: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}

struct PapagaioApp: App {
    @NSApplicationDelegateAdaptor(DelegadoDeConvitesCloudKit.self) private var delegadoDeConvites

    /// A gravação nasce aqui, e não dentro da `ContentView`, para que o item da
    /// barra de menus observe o mesmo objeto que a janela — sem isso seriam
    /// duas gravações independentes, cada uma com seu cronômetro.
    @State private var gravador = GravadorViewModel()

    /// O painel flutuante que acompanha a gravação fora da janela do app.
    @State private var painelFlutuante = JanelaFlutuanteDeGravacao()
    /// Ligado por padrão: gravar com o app atrás de outro programa é o caso
    /// comum aqui, e é justamente quando não há como pausar nem anotar.
    @AppStorage("painelFlutuanteDuranteGravacao") private var painelHabilitado = true

    init() {
        // Modo de diagnóstico do R-11: roda a matriz de configurações do tap
        // dentro deste bundle (que tem a permissão de TCC) e encerra.
        if DiagnosticoTap.pedido {
            DiagnosticoTap.executar()
            exit(0)
        }

        // Também antes das views: campos de cartão criados nesta versão nascem
        // ligados para quem já tinha personalizado a grade.
        CamposDoCartao.ligarCamposNovos()

        // Idem: tarefas gravadas antes de "Não iniciado" existir nasceram
        // marcadas "Em andamento" pelo único padrão que havia então. Sem esta
        // migração, o painel de tarefas mostraria como "em progresso" um monte
        // de tarefa que ninguém tinha nem aberto ainda.
        MigracaoDeStatusDeTarefas.executarUmaVez()
    }

    var body: some Scene {
        WindowGroup("") {
            ContentView(gravador: gravador)
                // O painel aparece e some junto com a gravação. Fica fora da
                // `ContentView` para não depender da janela principal estar
                // visível — ela pode estar minimizada, que é o caso de uso.
                .onChange(of: gravador.gravando) { _, gravando in
                    if gravando, painelHabilitado {
                        painelFlutuante.exibir(gravador: gravador) {
                            // "Abrir no app" precisa fazer mais que ativar:
                            // a principal pode estar minimizada, em outro
                            // Space ou em outra tela (Tarefas/Mídias/Config).
                            // Sem desminimizar + ordenar à frente + navegar
                            // à captura, o clique parecia não fazer nada.
                            NSApp.activate(ignoringOtherApps: true)
                            for window in NSApp.windows {
                                if let painel = window as? NSPanel, painel.level == .floating { continue }
                                if window.isMiniaturized { window.deminiaturize(nil) }
                                window.makeKeyAndOrderFront(nil)
                            }
                            NotificationCenter.default.post(name: .abrirGravacaoNoApp, object: nil)
                        }
                    } else {
                        painelFlutuante.esconder(origem: gravador.origemDoPainelNaTela)
                    }
                }
        }
        .defaultSize(width: 1_000, height: 700)
        // Barra de título transparente pela janela inteira, e não só pela
        // toolbar. `toolbarBackground(.hidden:)` vale para a toolbar da
        // janela; em tela cheia o macOS troca a barra de título por outra,
        // que aquele modificador não alcança — e a tira cinza voltava.
        .windowStyle(.hiddenTitleBar)
        // Sem isto o `minWidth` da `ContentView` é só uma sugestão: a janela
        // continua arrastável abaixo dele e o conteúdo transborda em vez de
        // parar de encolher.
        .windowResizability(.contentMinSize)

        // Único sinal de que o microfone está ligado quando o app está atrás de
        // outra janela ou minimizado. Some quando não há gravação — item de
        // menu permanente vira ruído.
        MenuBarExtra(isInserted: .constant(gravador.gravando)) {
            Text(gravador.pausado ? "Gravação pausada".localized : "Gravando agora".localized)
            Text(gravador.tempoDeGravacao.comoCronometro)

            Divider()

            Button(gravador.pausado ? "Continuar".localized : "Pausar".localized) {
                Task {
                    if gravador.pausado {
                        await gravador.continuar()
                    } else {
                        await gravador.pausar()
                    }
                }
            }

            Button("Finalizar gravação".localized) {
                Task { await gravador.alternarGravacao() }
            }

            Button("Cancelar gravação".localized) {
                Task { await gravador.cancelar() }
            }
        } label: {
            // Ponto vermelho com o cronômetro: legível de canto de tela, sem
            // depender de o app estar visível.
            Label(
                gravador.tempoDeGravacao.comoCronometro,
                systemImage: gravador.pausado ? "pause.circle.fill" : "record.circle"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
