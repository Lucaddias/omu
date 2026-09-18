import SwiftUI

/// Escolhe o que os cartões da biblioteca mostram.
///
/// Chega pelos três pontinhos de um cartão, porque é ali que a pessoa está
/// olhando quando pensa "não preciso ver isto" — e não numa tela de ajustes,
/// onde ela teria de imaginar o cartão de memória. O que ela muda, porém, vale
/// para a grade inteira: ver o efeito no cartão que a levou até aqui é o que
/// deixa isso claro sem precisar de explicação.
struct PersonalizacaoDoCartao: View {
    @Binding var campos: CamposDoCartao
    let aoFechar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Personalizar cartões".localized)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Escolha o que aparece nos cartões da biblioteca. Vale para todos.".localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer()

                BotaoCircularPapagaio(
                    simbolo: "xmark",
                    ajuda: "Fechar".localized,
                    destaque: true,
                    acao: aoFechar
                )
            }
            .padding(PapagaioTema.Espaco.secao)

            SeparadorPapagaio()

            ScrollView {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                    ListaDeCamposDoCartao(campos: $campos)

                    // O exemplo fecha o ciclo: aqui a grade fica atrás da
                    // folha, então nem sempre dá para ver o efeito no cartão
                    // real enquanto se mexe nos interruptores.
                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                        Text("Exemplo".localized)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .textCase(.uppercase)

                        PreviaDoCartaoDeConversa(campos: campos)
                    }
                }
                .padding(PapagaioTema.Espaco.secao)
            }
            .scrollBounceBehavior(.basedOnSize)

            SeparadorPapagaio()

            HStack {
                // Sem confirmação: nada aqui é destrutivo, e voltar ao padrão é
                // um clique de desfazer para quem desligou demais e se perdeu.
                Button("Restaurar padrão".localized) {
                    withAnimation(.snappy(duration: 0.22)) { campos = .padrao }
                }
                .buttonStyle(BotaoDeContornoPapagaio())

                Spacer()

                Button("Concluir".localized, action: aoFechar)
                    .buttonStyle(BotaoPrincipalPapagaio())
            }
            .padding(PapagaioTema.Espaco.secao)
        }
        .frame(width: 460, height: 560)
        .background(PapagaioTema.fundo)
    }

}
