import SwiftUI

struct ControleSegmentadoPapagaio<Opcao: Hashable>: View {
    let opcoes: [Opcao]
    @Binding var selecionado: Opcao
    let titulo: (Opcao) -> String
    let simbolo: (Opcao) -> String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                botoes
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                botoes
            }
        }
    }

    private var botoes: some View {
        Group {
            ForEach(opcoes, id: \.self) { opcao in
                botao(opcao)
            }
        }
    }

    private func botao(_ opcao: Opcao) -> some View {
        let ativo = opcao == selecionado

        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                selecionado = opcao
            }
        } label: {
            HStack(spacing: PapagaioTema.Espaco.minimo) {
                if let simbolo = simbolo(opcao) {
                    Image(systemName: simbolo)
                }
                Text(titulo(opcao).localized)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(ativo ? PapagaioTema.textoSobrePrimario : PapagaioTema.textoSecundario)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: PapagaioTema.Altura.padrao)
            .background(ativo ? PapagaioTema.preenchimentoPrimario : PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(ativo ? Color.clear : PapagaioTema.borda, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
