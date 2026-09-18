import SwiftUI

/// O anexo removido, no lugar onde estava, apagado e com as duas saídas.
///
/// Some da grade seria mais limpo e muito pior: para desfazer um clique errado
/// a pessoa teria de sair da conversa e procurar a lixeira do app. E o
/// arrependimento acontece aqui, dois segundos depois do clique.
///
/// A escolha é deliberadamente assimétrica. **Restaurar** é a ação provável e
/// reversível, então tem destaque. **Apagar de vez** é rara e definitiva, então
/// fica discreta e ainda pede confirmação — a diferença entre as duas está no
/// peso visual, não num alerta que interrompe toda vez.
struct CartaoDeMidiaRemovida: View {
    let item: MidiaNaLixeira
    let aoRestaurar: () -> Void
    let aoApagarDeVez: () -> Void

    @State private var confirmandoExclusao = false

    private var simbolo: String {
        switch item.tipo {
        case "Imagem": "photo"
        case "Vídeo": "film"
        case "PDF": "doc.richtext"
        case "Áudio": "waveform"
        default: "doc"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            ZStack {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .fill(PapagaioTema.superficieSuave)

                VStack(spacing: PapagaioTema.Espaco.curto) {
                    Image(systemName: "trash")
                        .font(.system(size: 22, weight: .medium))
                    Text("Removido".localized)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(PapagaioTema.textoSecundario)
            }
            // Prévia mais baixa que a do cartão normal: aqui não há o que
            // mostrar, e o espaço vale mais para as duas ações caberem dentro
            // dos mesmos 318pt de altura da fileira.
            .frame(maxWidth: .infinity)
            .frame(height: 118)

            // Sem `.lineLimit` — mesmo ajuste de `CartaoDeAnexoDeMidia`: o
            // nome do arquivo não tem tamanho garantido.
            Text(item.nome)
                .font(.headline.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                // Riscado: diz "isto saiu" sem precisar de mais uma palavra.
                .strikethrough(true, color: PapagaioTema.textoSecundario.opacity(0.6))

            HStack(spacing: PapagaioTema.Espaco.curto) {
                SeloDeMidia(texto: item.tipo.localized, simbolo: simbolo)
                SeloDeMidia(texto: formatoDeBytes(item.tamanho), simbolo: "externaldrive")
            }

            Spacer(minLength: 0)

            // Mesmo rodapé do cartão normal: uma linha, ação à esquerda e
            // destrutiva à direita, na mesma altura. Empilhados e
            // centralizados, os dois botões flutuavam no meio do vazio e não
            // conversavam com o resto da grade.
            HStack {
                Button(action: aoRestaurar) {
                    Label("Restaurar".localized, systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(BotaoDeContornoPapagaio())

                Spacer()

                Button("Apagar de vez".localized, systemImage: "trash") {
                    confirmandoExclusao = true
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.plain)
                .foregroundStyle(PapagaioTema.perigo)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        // Só `minHeight` — mesmo ajuste de `CartaoDeAnexoDeMidia`: sem
        // `maxHeight`, um nome comprido estica o cartão em vez de cortar.
        .frame(maxWidth: .infinity, minHeight: 318, alignment: .topLeading)
        .background(
            PapagaioTema.superficie.opacity(0.35),
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(
                    PapagaioTema.borda.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        }
        .confirmationDialog(
            "Apagar %@ definitivamente?".localized(item.nome),
            isPresented: $confirmandoExclusao,
            titleVisibility: .visible
        ) {
            Button("Apagar definitivamente".localized, role: .destructive, action: aoApagarDeVez)
            Button("Cancelar".localized, role: .cancel) {}
        } message: {
            Text("O arquivo sai do seu Mac e não poderá ser recuperado.".localized)
        }
    }

    private func formatoDeBytes(_ bytes: Int64) -> String {
        let formatador = ByteCountFormatter()
        formatador.countStyle = .file
        return formatador.string(fromByteCount: bytes)
    }
}
