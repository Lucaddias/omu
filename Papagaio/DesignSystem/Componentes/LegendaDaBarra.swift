import SwiftUI

struct LegendaGlobalDaBarra: View {
    let texto: LegendaDaBarra?

    /// Altura medida da cápsula, para ancorar a borda superior dela — e não o
    /// centro, que é o que `position` posiciona — logo abaixo do ícone.
    @State private var altura: CGFloat = 0

    /// Respiro entre a base do ícone e o topo da legenda.
    private static let folga = PapagaioTema.Espaco.curto

    var body: some View {
        GeometryReader { geometria in
            // O botão informa sua posição em coordenadas globais; este overlay
            // desenha nas suas próprias. Sem converter, a legenda ficava presa
            // ao topo do overlay (que começa no topo da barra) e caía em cima
            // do ícone.
            let area = geometria.frame(in: .global)

            Group {
                if let texto {
                    Text(texto.texto.localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, PapagaioTema.Espaco.curto)
                        .padding(.vertical, PapagaioTema.Espaco.minimo)
                        .background(PapagaioTema.superficie, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(PapagaioTema.borda.opacity(0.92), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altura = $0 }
                        .position(
                            x: posicaoLimitada(texto.x - area.minX, largura: geometria.size.width),
                            y: texto.baseDoIcone - area.minY + Self.folga + altura / 2
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.12), value: texto)
        .allowsHitTesting(false)
        .zIndex(100)
    }

    private func posicaoLimitada(_ x: CGFloat, largura: CGFloat) -> CGFloat {
        min(max(x, 80), max(80, largura - 80))
    }
}

struct LegendaDaBarra: Equatable {
    let texto: String
    /// Centro horizontal do ícone, em coordenadas globais.
    let x: CGFloat
    /// Borda inferior do ícone, em coordenadas globais.
    let baseDoIcone: CGFloat
}
