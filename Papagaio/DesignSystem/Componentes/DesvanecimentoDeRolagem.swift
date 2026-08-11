import SwiftUI

/// Desvanece as pontas de uma rolagem horizontal em vez de cortá-las na régua.
///
/// Sem isto o último cartão termina num corte reto na borda da página, que lê
/// como defeito de layout — e não como "tem mais coisa para o lado". O
/// gradiente diz as duas coisas ao mesmo tempo: que aquilo continua e para onde.
///
/// A faixa só existe do lado que ainda tem conteúdo escondido. Numa lista que
/// cabe inteira na tela nada desbota, e ao chegar na ponta o desvanecimento
/// daquele lado se recolhe — desbotar o que já acabou seria mentir.
private struct DesvanecimentoDeRolagemHorizontal: ViewModifier {
    /// Cor sobre a qual a rolagem está desenhada. O efeito é a página cobrindo
    /// o conteúdo, então ela precisa ser a mesma cor do fundo atrás dele.
    let fundo: Color

    /// Largura da transição. Curta o bastante para não comer um cartão inteiro.
    private static let faixa: CGFloat = 36

    @State private var bordas = BordasComConteudo(inicio: false, fim: false)

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: BordasComConteudo.self) { geometria in
                // O offset já vem com o inset aplicado, então a comparação é
                // direta. A folga de 1pt absorve o arredondamento de subpixel,
                // que senão deixava o gradiente piscando no fim da rolagem.
                let deslocamento = geometria.contentOffset.x + geometria.contentInsets.leading
                let visivel = geometria.containerSize.width
                return BordasComConteudo(
                    inicio: deslocamento > 1,
                    fim: deslocamento + visivel < geometria.contentSize.width - 1
                )
            } action: { _, novas in
                bordas = novas
            }
            // Sobreposição, e não `mask`: máscara em SwiftUI também recorta o
            // hit testing, e o cartão meio escondido na ponta deixaria de
            // aceitar clique justamente na parte que ainda dá para ver.
            .overlay {
                HStack(spacing: 0) {
                    // Largura zero em vez de troca de view: a faixa cresce e
                    // encolhe, então a animação tem o que interpolar.
                    LinearGradient(colors: [fundo, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: bordas.inicio ? Self.faixa : 0)

                    Spacer(minLength: 0)

                    LinearGradient(colors: [.clear, fundo], startPoint: .leading, endPoint: .trailing)
                        .frame(width: bordas.fim ? Self.faixa : 0)
                }
                .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.15), value: bordas)
    }

    private struct BordasComConteudo: Equatable {
        let inicio: Bool
        let fim: Bool
    }
}

extension View {
    /// Aplica o desvanecimento nas pontas de uma rolagem horizontal.
    ///
    /// Vai na `ScrollView`, não no conteúdo dela. `fundo` tem de ser a cor
    /// desenhada atrás da rolagem, ou a faixa aparece como um borrão claro.
    func desvanecerNasBordasHorizontais(fundo: Color = PapagaioTema.fundo) -> some View {
        modifier(DesvanecimentoDeRolagemHorizontal(fundo: fundo))
    }
}
