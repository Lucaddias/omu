import SwiftUI

struct CabecalhoDePagina<Acoes: View>: View {
    let titulo: String
    let subtitulo: String?
    @ViewBuilder let acoes: () -> Acoes

    init(
        titulo: String,
        subtitulo: String? = nil,
        @ViewBuilder acoes: @escaping () -> Acoes = { EmptyView() }
    ) {
        self.titulo = titulo
        self.subtitulo = subtitulo
        self.acoes = acoes
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.largo) {
                texto
                Spacer(minLength: 16)
                acoes()
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                texto
                acoes()
            }
        }
    }

    private var texto: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text(titulo.localized)
                .font(PapagaioTema.Tipo.tituloDePagina)
                .foregroundStyle(PapagaioTema.texto)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            if let subtitulo {
                Text(subtitulo.localized)
                    .font(.title3)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CartaoDeEstadoVazio: View {
    let simbolo: String
    let titulo: String
    let mensagem: String

    var body: some View {
        VStack(spacing: PapagaioTema.Espaco.medio) {
            Image(systemName: simbolo)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 64, height: 64)
                .background(PapagaioTema.destaqueSuave, in: Circle())
            Text(titulo.localized)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PapagaioTema.texto)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(mensagem.localized)
                .multilineTextAlignment(.center)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(maxWidth: 420)
                .minimumScaleFactor(0.85)
        }
        .padding(PapagaioTema.Espaco.pagina)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct SeparadorPapagaio: View {
    var body: some View {
        Rectangle()
            .fill(PapagaioTema.borda.opacity(0.75))
            .frame(height: 1)
    }
}
