import PapagaioCore
import SwiftUI

/// Uma pasta apagada, no mesmo formato dos outros itens da lixeira.
///
/// A descrição insiste num ponto que o resto da tela pode sugerir errado: aqui
/// não há arquivo nenhum guardado. Pasta é rótulo, as conversas continuam na
/// biblioteca, e restaurar apenas recoloca o rótulo em quem o tinha.
struct CartaoDePastaNaLixeira: View {
    let item: PastaNaLixeira
    /// As conversas que foram para a lixeira junto com a pasta, na ordem em
    /// que estavam nela.
    let conversas: [Arquivo]
    let aoRestaurar: () -> Void
    let aoRestaurarConversa: (Arquivo) -> Void
    let aoApagarDefinitivamente: () -> Void

    private var prazoDeExclusao: String {
        guard let limite = Calendar.current.date(byAdding: .day, value: 30, to: item.apagadaEm) else {
            return "Exclui em 30 dias".localized
        }
        let dias = Calendar.current.dateComponents([.day], from: Date(), to: limite).day ?? 0
        if dias <= 0 { return "Exclui hoje".localized }
        if dias == 1 { return "Exclui em 1 dia".localized }
        return String(format: "Exclui em %d dias".localized, dias)
    }

    private var quantidade: String {
        item.conversas.count == 1 ? "1 conversa".localized : String(format: "%d conversas".localized, item.conversas.count)
    }

    private var dataCurta: String {
        return item.apagadaEm
            .formatted(.dateTime.locale(LocalizacaoDoApp.localeAtual).day().month(.abbreviated))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Label("PASTA".localized, systemImage: "folder.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSobrePrimario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, PapagaioTema.Espaco.medio)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.preenchimentoPrimario, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

                Spacer(minLength: 8)

                HStack(spacing: PapagaioTema.Espaco.largo) {
                    Button(action: aoRestaurar) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .help("Restaurar pasta".localized)
                    .accessibilityLabel(String(format: "Restaurar a pasta %@".localized, item.nome))

                    Button(role: .destructive, action: aoApagarDefinitivamente) {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.perigo)
                    .help("Apagar definitivamente".localized)
                    .accessibilityLabel(String(format: "Apagar definitivamente a pasta %@".localized, item.nome))
                }
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                // Sem `.lineLimit` no nome — mesmo ajuste de `CartaoDaLixeira`:
                // nome de pasta é dado real, sem tamanho garantido.
                Text(item.nome)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.68))
                    .strikethrough(true, color: PapagaioTema.textoSecundario.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    item.conversas.isEmpty
                        ? "A pasta estava vazia. Restaure para tê-la de volta com a cor e a imagem que tinha.".localized
                        : "Restaure a pasta inteira, com a cor e a imagem que tinha, ou traga de volta só uma conversa.".localized
                )
                .font(.body)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            // A lista existe para dar a escolha por arquivo. Sem ela, restaurar
            // seria tudo ou nada — e quem apagou uma pasta de doze conversas
            // muitas vezes quer só uma de volta.
            if !conversas.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(conversas) { arquivo in
                            // Sem `.lineLimit`: um título comprido só deixa
                            // esta linha da lista mais alta — a `ScrollView`
                            // em volta já rola verticalmente de qualquer
                            // jeito, então não precisa cortar com "...".
                            HStack(spacing: PapagaioTema.Espaco.curto) {
                                Text(arquivo.resumo?.titulo ?? arquivo.titulo)
                                    .font(.callout)
                                    .foregroundStyle(PapagaioTema.textoSecundario)

                                Spacer(minLength: PapagaioTema.Espaco.curto)

                                Button("Restaurar".localized) { aoRestaurarConversa(arquivo) }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                            }
                            .padding(.vertical, PapagaioTema.Espaco.curto)

                            if arquivo.id != conversas.last?.id {
                                SeparadorPapagaio()
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 120)
            }

            Spacer(minLength: 0)

            SeparadorPapagaio()

            HStack(spacing: PapagaioTema.Espaco.largo) {
                Label(dataCurta, systemImage: "calendar")
                Label(quantidade, systemImage: "doc.text")

                Spacer(minLength: 8)

                Text(prazoDeExclusao)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(PapagaioTema.perigo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.62))
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
        .cartaoPapagaio()
        .accessibilityElement(children: .contain)
    }
}
