import SwiftUI

struct CartaoDeAnexoDeMidia: View {
    let anexo: AnexoDeMidiaDaConversa
    let aoAbrir: () -> Void
    let aoRemover: () -> Void
    /// Só usado pela tela agregada de Mídias (todas as conversas juntas) —
    /// `nil` na aba "Mídia" de dentro de uma conversa, onde repetir o nome
    /// dela em cada cartão seria repetir o título da própria página (mesmo
    /// raciocínio de `CartaoDeTarefaDaConversa` para tarefas).
    var origem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            Button(action: aoAbrir) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                    PreviaDoAnexoDeMidia(anexo: anexo)
                        .frame(maxWidth: .infinity)

                    // Sem `.lineLimit`: o nome do arquivo é o que a
                    // pessoa deu a ele (ou o nome original do Finder) —
                    // sem tamanho garantido, cortar com "..." escondia
                    // justamente o que identifica o anexo. `minHeight`
                    // aqui é só o piso de duas linhas; o cartão em volta
                    // não tem mais `maxHeight` (ver abaixo), então um
                    // nome maior estica o cartão em vez de ser cortado.
                    Text(anexo.nome)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .frame(minHeight: 44, alignment: .topLeading)

                    if let origem {
                        Text(origem)
                            .font(.callout)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .help("Mostrar %@ no Finder".localized(anexo.nome))

            // Fora do botão: dentro dele, passar o mouse por cima dos selos
            // (só informativos, não abrem nada) mostrava a mesma dica
            // "Mostrar no Finder" bem em cima deles, tampando o texto que a
            // pessoa estava tentando ler — o selo de tamanho ("4,1 MB")
            // sumia atrás da bolha da dica.
            HStack(spacing: PapagaioTema.Espaco.minimo) {
                SeloDeMidia(texto: anexo.tipoVisual.localized, simbolo: anexo.simbolo)
                SeloDeMidia(texto: anexo.extensaoVisual, simbolo: "doc.text")
                SeloDeMidia(texto: formatoDeBytes(anexo.tamanho), simbolo: "externaldrive")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Text(anexo.data.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Spacer()

                Button("Remover".localized, systemImage: "trash", role: .destructive, action: aoRemover)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.perigo)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        // Só `minHeight`: a maioria dos cartões continua nos mesmos 318pt de
        // sempre, mas um nome de arquivo comprido (sem `.lineLimit` agora)
        // pode precisar de mais — sem `maxHeight`, ele estica em vez de
        // cortar por cima do texto.
        .frame(maxWidth: .infinity, minHeight: 318, alignment: .topLeading)
        .cartaoPapagaio()
    }
}
