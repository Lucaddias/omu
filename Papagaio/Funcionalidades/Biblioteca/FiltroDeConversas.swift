import SwiftUI

enum FiltroDaBiblioteca: String, CaseIterable, Identifiable {
    case todas = "Todas"
    case pastas = "Pastas"

    var id: Self { self }

    var simbolo: String {
        switch self {
        case .todas: "tray.full"
        case .pastas: "folder"
        }
    }
}

struct FiltroDeConversas: View {
    @Binding var selecionado: FiltroDaBiblioteca
    @Binding var pastaSelecionada: String?
    @Binding var atalhoSelecionado: AtalhoDaBiblioteca?
    let aoLimparAtalhoVisual: () -> Void

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            ForEach(FiltroDaBiblioteca.allCases) { filtro in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selecionado = filtro
                        pastaSelecionada = nil
                        atalhoSelecionado = nil
                        aoLimparAtalhoVisual()
                    }
                } label: {
                    PastilhaDeFiltro(filtro: filtro, selecionada: selecionado == filtro)
                }
                .buttonStyle(.plain)
                .help(filtro.rawValue)
                .accessibilityLabel("Mostrar \(filtro.rawValue.localizedLowercase)")
            }
        }
    }
}

/// O filtro era texto solto: só o glifo e as letras respondiam ao clique, e o
/// espaço entre eles não. Como pastilha, a área clicável é o retângulo inteiro
/// — e o estado selecionado deixa de depender só da cor da fonte, que some em
/// tela clara.
private struct PastilhaDeFiltro: View {
    let filtro: FiltroDaBiblioteca
    let selecionada: Bool
    @State private var pairando = false

    var body: some View {
        Label(filtro.rawValue, systemImage: filtro.simbolo)
            .font(.callout.weight(.semibold))
            .foregroundStyle(corDoTexto)
            .padding(.horizontal, PapagaioTema.Espaco.medio)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(fundo, in: Capsule())
            .overlay {
                Capsule().stroke(
                    selecionada
                        ? PapagaioTema.destaque.opacity(0.58)
                        : PapagaioTema.borda.opacity(pairando ? 1 : 0.76),
                    lineWidth: 1
                )
            }
            // Sem isto, o clique continuaria valendo só sobre o desenho: a
            // forma define a área de toque, e é ela que faz a pastilha ser um
            // botão de verdade.
            .contentShape(Capsule())
            .onHover { pairando = $0 }
            .animation(.easeOut(duration: 0.14), value: pairando)
            .animation(.easeOut(duration: 0.14), value: selecionada)
    }

    private var corDoTexto: Color {
        selecionada || pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
    }

    private var fundo: Color {
        if selecionada { return PapagaioTema.destaque.opacity(0.14) }
        return pairando ? PapagaioTema.superficie : .clear
    }
}
