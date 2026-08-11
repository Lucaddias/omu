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
                    Text(anexo.tipoVisual)
                        .font(.callout.weight(.semibold))
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

        let tamanho = CGSize(width: 680, height: 380)
        let escala = NSScreen.main?.backingScaleFactor ?? 2
        let requisicao = QLThumbnailGenerator.Request(
            fileAt: anexo.url,
            size: tamanho,
            scale: escala,
            representationTypes: .thumbnail
        )

        do {
            let representacao = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: requisicao)
            await MainActor.run {
                miniatura = representacao.nsImage
            }
        } catch {
            if anexo.tipoVisual == "Imagem" {
                await MainActor.run {
                    miniatura = NSImage(contentsOf: anexo.url)
                }
            }
        }
    }
}

struct PreviaDeAudio: View {
    var body: some View {
        HStack(alignment: .center, spacing: PapagaioTema.Espaco.minimo) {
            ForEach(0..<28, id: \.self) { indice in
                Capsule()
                    .fill(PapagaioTema.destaque)
                    .frame(width: 4, height: altura(para: indice))
                    .opacity(indice.isMultiple(of: 3) ? 0.9 : 0.55)
            }
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
