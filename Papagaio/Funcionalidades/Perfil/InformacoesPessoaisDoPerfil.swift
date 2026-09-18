import SwiftUI

struct InformacoesPessoaisDoPerfil: View {
    @Binding var nome: String
    @Binding var email: String
    let aoSalvar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            TituloDeSecaoDoPerfil(simbolo: "person", titulo: "Informações Pessoais".localized)

            SeparadorPapagaio()

            // TODO(validacao-produto): o nome aparece 2x — em destaque no
            // cartão acima (display) e neste campo (editor do mesmo valor).
            // Mínimo sem re-layout: o campo deixa claro que edita o nome
            // exibido. Falta validar a solução final (edição inline no cartão
            // e remoção deste campo, ou remoção do nome do cartão).
            CampoDoPerfil(titulo: "Nome de exibição".localized, texto: $nome, placeholder: "Seu nome".localized)
            Text("É o nome exibido no cartão acima.".localized)
                .font(.caption)
                .foregroundStyle(PapagaioTema.textoSecundario)
            CampoDoPerfil(titulo: "Email Primário".localized, texto: $email, placeholder: "seu@email.com")

            Button("Salvar alterações".localized, systemImage: "checkmark") {
                aoSalvar()
            }
            .buttonStyle(BotaoDeContornoPapagaio())
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }
}
