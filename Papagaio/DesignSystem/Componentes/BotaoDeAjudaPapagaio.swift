import SwiftUI

/// O "i" que explica uma tela, com o texto aparecendo **ao passar o mouse**.
///
/// Ajuda escondida atrás de um clique é ajuda que ninguém encontra: quem não
/// sabe o que a tela faz também não sabe que aquele ícone responde. Passar o
/// mouse é gratuito, e é assim que a pessoa descobre sem se comprometer.
///
/// O texto é um `popover`, e não uma sobreposição. Sobreposição é desenhada na
/// camada do próprio filho: passava por baixo do cartão seguinte da página, e
/// `zIndex` não resolvia — ele só ordena irmãos do mesmo contêiner, e o cartão
/// é irmão da linha inteira, não do ícone. O popover vive numa janela própria,
/// acima de tudo e sem recorte.
///
/// Ele abre para baixo (`arrowEdge: .bottom`), portanto não cobre o ícone e o
/// ponteiro continua "em cima" — sem isso o `onHover` viraria falso ao abrir e
/// o balão entraria em pisca-pisca.
struct BotaoDeAjudaPapagaio: View {
    let texto: String
    var ajuda: String = "Sobre esta tela"
    /// Largura da caixa de texto. Frases curtas pedem menos.
    var largura: CGFloat = 300

    @State private var pairando = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(
                pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
            )
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { pairando = $0 }
            .popover(isPresented: $pairando, arrowEdge: .bottom) {
                Text(texto)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: largura, alignment: .leading)
                    .padding(PapagaioTema.Espaco.largo)
            }
            .accessibilityLabel(ajuda)
            .accessibilityHint(texto)
            .help(texto)
    }
}
