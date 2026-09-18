import SwiftUI

struct SeloDeTipoDoArquivo: View {
    let texto: String

    var body: some View {
        Text(texto.localized)
            .font(.caption.weight(.bold))
            .foregroundStyle(PapagaioTema.texto)
            .lineLimit(1)
                    .minimumScaleFactor(0.82)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(PapagaioTema.superficie.opacity(0.88), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PapagaioTema.borda.opacity(0.7), lineWidth: 1)
            }
    }
}

struct SeloDeMidia: View {
    let texto: String
    let simbolo: String

    var body: some View {
        Label(texto.localized, systemImage: simbolo)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario)
            .lineLimit(1)
                    .minimumScaleFactor(0.82)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(PapagaioTema.superficieSuave, in: Capsule())
    }
}

func formatoDeBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 KB" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
