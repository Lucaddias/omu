import SwiftUI

struct CartaoDeIdentidadeDoPerfil: View {
    let nome: String
    let email: String
    let avatarURL: URL?
    let aoEditarAvatar: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PapagaioTema.Espaco.pagina) {
                conteudo
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                conteudo
            }
        }
        .padding(.horizontal, PapagaioTema.Espaco.secao)
        .padding(.vertical, PapagaioTema.Espaco.secao)
        .frame(maxWidth: 990, minHeight: 220, alignment: .leading)
        .cartaoPapagaio()
    }

    private var conteudo: some View {
        Group {
            ZStack(alignment: .bottomTrailing) {
                AvatarDoPerfil(url: avatarURL, tamanho: 132)

                Button(action: aoEditarAvatar) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PapagaioTema.textoSobrePrimario)
                        .frame(width: 36, height: 36)
                        .background(PapagaioTema.preenchimentoPrimario, in: Circle())
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .help("Trocar foto do perfil".localized)
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(nome.isEmpty ? "Meu Perfil".localized : nome)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)

                Text(email.isEmpty ? "email@exemplo.com" : email)
                    .font(.title3)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
