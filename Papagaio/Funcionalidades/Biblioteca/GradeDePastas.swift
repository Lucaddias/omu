import SwiftUI

struct InformacaoDaPasta: Identifiable {
    let nome: String
    let quantidade: Int
    let duracaoTotal: TimeInterval
    let ultimoArquivo: Date?

    var id: String { nome }
}

struct GradeDePastas: View {
    let pastas: [InformacaoDaPasta]
    @Binding var selecionada: String?
    let aoCriarPasta: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            // Sem o título "Pastas": o filtro logo acima já está marcado como
            // Pastas, e repetir a palavra a 40pt de distância não informa nada.
            // O botão herda a posição dele, à esquerda, onde a leitura começa.
            HStack {
                Button("Nova pasta", systemImage: "folder.badge.plus", action: aoCriarPasta)
                    .buttonStyle(BotaoDeContornoPapagaio())

                Spacer()
            }

            if pastas.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "folder",
                    titulo: "Nenhuma pasta ainda",
                    mensagem: "Crie uma pasta para organizar conversas por projeto, cliente ou tema."
                )
                .frame(minHeight: 220)
                .cartaoPapagaio()
            } else {
                let colunas = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: PapagaioTema.Espaco.largo, alignment: .top)]

                LazyVGrid(columns: colunas, spacing: PapagaioTema.Espaco.largo) {
                    ForEach(pastas) { pasta in
                        CartaoDePasta(
                            pasta: pasta,
                            selecionado: selecionada == pasta.nome
                        ) {
                            withAnimation(.snappy(duration: 0.18)) {
                                selecionada = pasta.nome
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Pastas da biblioteca")
    }
}

struct CartaoDePasta: View {
    let pasta: InformacaoDaPasta
    let selecionado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(selecionado ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                        .frame(width: 58, height: 58)
                        .background(
                            selecionado ? PapagaioTema.destaqueSuave : PapagaioTema.superficieSuave,
                            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                        Text(pasta.nome)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PapagaioTema.texto)
                            .lineLimit(2)

                        Text("Abrir pasta")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: PapagaioTema.Espaco.medio) {
                    Label(textoDaQuantidade, systemImage: "doc.text")
                    Label(pasta.duracaoTotal.comoDuracaoPorExtenso, systemImage: "clock")

                    if let ultimoArquivo = pasta.ultimoArquivo {
                        Label(ultimoArquivo.formatted(.dateTime.day().month(.abbreviated)), systemImage: "calendar")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineLimit(1)
            }
            .padding(PapagaioTema.Espaco.largo)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                selecionado ? PapagaioTema.destaqueSuave.opacity(0.58) : PapagaioTema.superficie,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                    .stroke(selecionado ? PapagaioTema.destaque.opacity(0.55) : PapagaioTema.borda, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Abrir pasta \(pasta.nome)")
    }

    private var textoDaQuantidade: String {
        pasta.quantidade == 1 ? "1 conversa" : "\(pasta.quantidade) conversas"
    }

}
