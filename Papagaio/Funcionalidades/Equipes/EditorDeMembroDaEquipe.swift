import SwiftUI

struct EditorDeMembroDaEquipe: View {
    let titulo: String
    @State var membro: MembroDaEquipe
    let aoCancelar: () -> Void
    let aoSalvar: (MembroDaEquipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            HStack {
                Text(titulo)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(PapagaioTema.texto)
                Spacer()
                Button(action: aoCancelar) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            CampoDoPerfil(titulo: "Nome", texto: $membro.nome, placeholder: "Nome completo")
            CampoDoPerfil(titulo: "Email", texto: $membro.email, placeholder: "email@empresa.com")

            if titulo == "Convidar membro" {
                Text("Use o e-mail associado ao Apple Account da pessoa. O convite será enviado pelo iCloud.")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }

            CampoDoPerfil(titulo: "Cargo", texto: $membro.cargo, placeholder: "Ex.: Pesquisador, Designer, Transcritor")

            Picker("Status", selection: $membro.status) {
                ForEach(StatusDaEquipe.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: aoCancelar)
                    .buttonStyle(BotaoDeContornoPapagaio())
                Button(titulo == "Convidar membro" ? "Enviar convite" : "Salvar", systemImage: "checkmark") {
                    aoSalvar(membro)
                }
                .buttonStyle(BotaoPrincipalPapagaio())
                .disabled(membro.nome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || membro.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 460)
        .background(PapagaioTema.fundo)
    }
}
