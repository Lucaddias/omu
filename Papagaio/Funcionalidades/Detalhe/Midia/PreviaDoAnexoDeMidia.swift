import AppKit
import QuickLookThumbnailing
import SwiftUI

struct PreviaDoAnexoDeMidia: View {
    let anexo: AnexoDeMidiaDaConversa
    @State private var miniatura: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .fill(PapagaioTema.superficieSuave)

            if let miniatura {
                Image(nsImage: miniatura)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if anexo.tipoVisual == "Áudio" {
                PreviaDeAudio()
                    .padding(PapagaioTema.Espaco.largo)
            } else {
                VStack(spacing: PapagaioTema.Espaco.curto) {
                    Image(systemName: anexo.simbolo)
                        .font(.system(size: 34, weight: .semibold))
                    Text(anexo.tipoVisual.localized)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(PapagaioTema.destaqueEscuro)
            }

            // Os selos de tipo e extensão saíram daqui: a mesma informação
            // já aparece logo abaixo, na linha de etiquetas do cartão. Sobre a
            // prévia, eles cobriam justamente o que a prévia existe para
            // mostrar.
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda.opacity(0.72), lineWidth: 1)
        }
        .task(id: anexo.url) {
            await carregarMiniatura()
        }
    }

    private func carregarMiniatura() async {
        guard anexo.tipoVisual != "Áudio" else { return }

        // Imagem: carrega o arquivo direto, sem depender do serviço do
        // QuickLook (`quicklookd`, um processo à parte). Antes disso, um
        // print colado (sem vir de um arquivo do Finder, escrito na hora a
        // partir dos bytes arrastados) só mostrava a foto de verdade se o
        // QuickLook chegasse a **falhar** — se ele simplesmente demorasse ou
        // devolvesse algo genérico sem lançar erro, o cartão ficava com o
        // ícone de "Imagem" em vez da própria captura. Indo direto, a prévia
        // de qualquer imagem é sempre o conteúdo de verdade.
        if anexo.tipoVisual == "Imagem" {
            if let imagem = NSImage(contentsOf: anexo.url) {
                await MainActor.run { miniatura = imagem }
            }
            return
        }

        let tamanho = CGSize(width: 680, height: 380)
        let escala = NSScreen.main?.backingScaleFactor ?? 2
        let requisicao = QLThumbnailGenerator.Request(
            fileAt: anexo.url,
            size: tamanho,
            scale: escala,
            representationTypes: .thumbnail
        )

        if let representacao = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: requisicao) {
            await MainActor.run { miniatura = representacao.nsImage }
        }
    }
}

struct PreviaDeAudio: View {
    private static let larguraDaBarra: CGFloat = 4

    var body: some View {
        GeometryReader { geometria in
            // Número de barras fixo (28) e sem `GeometryReader`, a fileira
            // tinha largura própria (28 × 4pt + os respiros entre elas) que
            // não ligava para o quanto o cartão media de verdade — num
            // cartão estreito (janela pequena, uma coluna só na grade) as
            // barras das pontas ficavam cortadas pela borda arredondada do
            // cartão, à esquerda e à direita. Calculando quantas barras
            // cabem na largura medida (`geometria.size.width`), a fileira
            // nunca é mais larga que a própria prévia — encolhe ou cresce
            // junto com o cartão, e nunca corta nada.
            let espaco = PapagaioTema.Espaco.minimo
            let quantidade = max(6, Int((geometria.size.width + espaco) / (Self.larguraDaBarra + espaco)))

            HStack(alignment: .center, spacing: espaco) {
                ForEach(0..<quantidade, id: \.self) { indice in
                    Capsule()
                        .fill(PapagaioTema.destaque)
                        .frame(width: Self.larguraDaBarra, height: altura(para: indice))
                        .opacity(indice.isMultiple(of: 3) ? 0.9 : 0.55)
                }
            }
            .frame(width: geometria.size.width, height: geometria.size.height, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PapagaioTema.destaqueSuave.opacity(0.52), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .padding(PapagaioTema.Espaco.medio)
                .background(PapagaioTema.superficie.opacity(0.86), in: Circle())
        }
    }

    private func altura(para indice: Int) -> CGFloat {
        let padrao: [CGFloat] = [18, 32, 48, 28, 62, 38, 54, 24]
        return padrao[indice % padrao.count]
    }
}
