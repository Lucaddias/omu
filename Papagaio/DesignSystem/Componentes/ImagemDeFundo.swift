import AppKit
import SwiftUI

/// Como uma imagem ocupa o espaço dela.
///
/// Os dois modos do Figma, e pelo mesmo motivo: **preencher** corta as bordas
/// para não deixar vão, e **ajustar** mostra a imagem inteira e aceita sobras.
/// Nenhum dos dois deforma — esticar para caber é a única opção que sempre
/// estraga a imagem, e por isso não existe aqui.
enum AjusteDeImagem: String, CaseIterable, Identifiable, Sendable {
    case preencher
    case ajustar

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .preencher: "Preencher".localized
        case .ajustar: "Ajustar".localized
        }
    }

    var simbolo: String {
        switch self {
        case .preencher: "arrow.up.left.and.arrow.down.right"
        case .ajustar: "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// Uma imagem de fundo que respeita o modo de ajuste escolhido.
///
/// Em "ajustar", a cor entra atrás para preencher as sobras — imagem retrato
/// numa faixa deitada deixaria duas tarjas transparentes, e transparência
/// sobre o cartão vira buraco.
struct ImagemDeFundo: View {
    let imagem: NSImage
    let ajuste: AjusteDeImagem
    let corDeFundo: Color
    /// Escurece a imagem para o texto claro por cima continuar legível.
    var comVeu = true

    var body: some View {
        ZStack {
            corDeFundo

            switch ajuste {
            case .preencher:
                Image(nsImage: imagem)
                    .resizable()
                    .scaledToFill()
            case .ajustar:
                Image(nsImage: imagem)
                    .resizable()
                    .scaledToFit()
            }

            if comVeu {
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.15)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            }
        }
        .clipped()
    }
}

/// Os dois modos lado a lado, para escolher com o olho.
struct SeletorDeAjusteDeImagem: View {
    @Binding var ajuste: AjusteDeImagem

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            ForEach(AjusteDeImagem.allCases) { opcao in
                Button {
                    ajuste = opcao
                } label: {
                    Label(opcao.titulo, systemImage: opcao.simbolo)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            ajuste == opcao ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, PapagaioTema.Espaco.curto)
                        .frame(height: PapagaioTema.Altura.compacta)
                        .background(
                            ajuste == opcao ? PapagaioTema.destaque.opacity(0.14) : .clear,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                ajuste == opcao ? PapagaioTema.destaque.opacity(0.5) : PapagaioTema.borda,
                                lineWidth: 1
                            )
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
