import SwiftUI

/// Mesmo cartão-pastilha de `CartaoFiltroDeConversaTarefa`, adaptado para a
/// tela agregada de Mídias — a fileira de "Todas as conversas" no topo,
/// clicável para filtrar a grade por uma ou mais conversas.
struct CartaoFiltroDeConversaMidia: View {
    let conversa: MidiasDaConversaGeral
    let selecionado: Bool
    let acao: () -> Void

    /// Mesma cor do cartão desta conversa na Biblioteca — ver o mesmo
    /// raciocínio em `CartaoFiltroDeConversaTarefa.corDeIdentidade`.
    private var corDeIdentidade: Color {
        let id = conversa.arquivo.id
        if let pasta = PreferenciasVisuaisDoArquivo.pasta(id) {
            return AparenciaDasPastas.corResolvida(de: pasta).acentoSobreSuperficie
        }
        if AparenciaDoCartao.semCor(id) {
            return PapagaioTema.destaqueEscuro
        }
        if let escolhida = AparenciaDoCartao.cor(id) {
            return escolhida.acentoSobreSuperficie
        }
        return PapagaioTema.destaqueEscuro
    }

    private var tamanhoTotal: Int64 {
        conversa.anexos.reduce(0) { $0 + $1.tamanho }
    }

    var body: some View {
        Button(action: acao) {
            HStack(spacing: PapagaioTema.Espaco.medio) {
                Image(systemName: simbolo)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(corDeIdentidade)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(conversa.titulo)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(selecionado ? corDeIdentidade : PapagaioTema.texto)

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                        Label(
                            "\(conversa.anexos.count) \(conversa.anexos.count == 1 ? "Arquivo".localized : "Arquivos".localized)",
                            systemImage: "photo.on.rectangle"
                        )
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: true, vertical: false)
                        Label(formatoDeBytes(tamanhoTotal), systemImage: "externaldrive")
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .padding(.leading, PapagaioTema.Espaco.curto)
            .frame(minWidth: 254, maxWidth: 254, minHeight: 82, alignment: .leading)
            .background(selecionado ? PapagaioTema.destaqueSuave.opacity(0.82) : PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle().fill(corDeIdentidade).frame(width: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(selecionado ? PapagaioTema.destaque : PapagaioTema.borda, lineWidth: selecionado ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selecionado ? "Desmarcar %@".localized(conversa.titulo) : "Marcar %@".localized(conversa.titulo))
    }

    private var simbolo: String {
        selecionado ? "bubble.left.and.text.bubble.right.fill" : "bubble.left"
    }
}
