import SwiftUI

@main
struct PapagaioApp: App {
    /// A gravação nasce aqui, e não dentro da `ContentView`, para que o item da
    /// barra de menus observe o mesmo objeto que a janela — sem isso seriam
    /// duas gravações independentes, cada uma com seu cronômetro.
    @State private var gravador = GravadorViewModel()

    init() {
        // Modo de diagnóstico do R-11: roda a matriz de configurações do tap
        // dentro deste bundle (que tem a permissão de TCC) e encerra.
        if DiagnosticoTap.pedido {
            DiagnosticoTap.executar()
            exit(0)
        }

        // Antes de qualquer view ler UserDefaults: instalações antigas têm as
        // equipes e as pessoas de exemplo gravadas no disco.
        LimpezaDeDadosFabricados.executarUmaVez()
    }

    var body: some Scene {
        WindowGroup("") {
            ContentView(gravador: gravador)
        }
        .defaultSize(width: 1_000, height: 700)
        // Sem isto o `minWidth` da `ContentView` é só uma sugestão: a janela
        // continua arrastável abaixo dele e o conteúdo transborda em vez de
        // parar de encolher.
        .windowResizability(.contentMinSize)

        // Único sinal de que o microfone está ligado quando o app está atrás de
        // outra janela ou minimizado. Some quando não há gravação — item de
        // menu permanente vira ruído.
        MenuBarExtra(isInserted: .constant(gravador.gravando)) {
            Text(gravador.pausado ? "Gravação pausada" : "Gravando agora")
            Text(gravador.tempoDeGravacao.comoCronometro)

            Divider()

            Button(gravador.pausado ? "Continuar" : "Pausar") {
                Task {
                    if gravador.pausado {
                        await gravador.continuar()
                    } else {
                        await gravador.pausar()
                    }
                }
            }

            Button("Finalizar gravação") {
                Task { await gravador.alternarGravacao() }
            }

            Button("Cancelar gravação") {
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
