import SwiftUI

struct EquipesDoPerfil: View {
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let aoSelecionar: (EquipeDisponivel) -> Void
    let aoAdicionarEquipe: (String) -> Void
    let aoEntrarComCodigo: (String) -> Void
    @State private var mostrandoNovaEquipe = false
    @State private var nomeDaNovaEquipe = ""
    @State private var mostrandoEntrada = false
    @State private var codigoDaEquipe = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            HStack {
                Text("Equipes".localized)
                    .font(.title3)
                    .foregroundStyle(PapagaioTema.texto)

                Spacer()

                Button {
                    mostrandoNovaEquipe = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .background(PapagaioTema.destaqueSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                .help("Adicionar nova equipe".localized)

                Button("Entrar com código".localized, systemImage: "number") {
                    mostrandoEntrada = true
                }
                .buttonStyle(BotaoDeContornoPapagaio())
            }

            SeparadorPapagaio()

            if equipes.isEmpty {
                Text("Você ainda não tem equipes. Use o + para criar a primeira ou entre com um código.".localized)
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                ForEach(equipes) { equipe in
                    Button {
                        aoSelecionar(equipe)
                    } label: {
                        HStack(spacing: PapagaioTema.Espaco.medio) {
                            Image(systemName: equipe.id == equipeAtiva?.id ? "checkmark.circle.fill" : "person.3")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(equipe.id == equipeAtiva?.id ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                                Text(equipe.nome)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(PapagaioTema.texto)
                                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                                Text("\(equipe.papel.localized) • \(equipe.resumoDeMembros.localized)")
                                    .font(.caption)
                                    .foregroundStyle(PapagaioTema.textoSecundario)
                                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            }

                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(PapagaioTema.Espaco.curto)
                    .background(
                        equipe.id == equipeAtiva?.id ? PapagaioTema.destaqueSuave.opacity(0.58) : Color.clear,
                        in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    )
                }
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, minHeight: 226, alignment: .topLeading)
        .cartaoPapagaio()
        .alert("Nova equipe".localized, isPresented: $mostrandoNovaEquipe) {
            TextField("Nome da equipe".localized, text: $nomeDaNovaEquipe)
            Button("Cancelar".localized, role: .cancel) {
                nomeDaNovaEquipe = ""
            }
            Button("Adicionar".localized) {
                adicionarEquipe()
            }
            .disabled(nomeDaNovaEquipe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Crie uma equipe para vincular ao seu perfil.".localized)
        }
        .alert("Entrar em uma equipe".localized, isPresented: $mostrandoEntrada) {
            TextField("Código da equipe".localized, text: $codigoDaEquipe)
            Button("Cancelar".localized, role: .cancel) { codigoDaEquipe = "" }
            Button("Entrar".localized) {
                aoEntrarComCodigo(codigoDaEquipe)
                codigoDaEquipe = ""
            }
            .disabled(codigoDaEquipe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Peça o código ao administrador da equipe.".localized)
        }
    }

    private func adicionarEquipe() {
        let nome = nomeDaNovaEquipe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nome.isEmpty else { return }
        aoAdicionarEquipe(nome)
        nomeDaNovaEquipe = ""
    }
}

#Preview("Equipes no perfil") {
    EquipesDoPerfil(
        equipeAtiva: .init(id: "produto", nome: "Produto", papel: "Administrador", quantidadeDeMembros: 4, codigoDeEntrada: "A7K2M9"),
        equipes: [
            .init(id: "produto", nome: "Produto", papel: "Administrador", quantidadeDeMembros: 4, codigoDeEntrada: "A7K2M9"),
            .init(id: "pesquisa", nome: "Pesquisa", papel: "Membro", quantidadeDeMembros: 8, codigoDeEntrada: "B4N8Q2")
        ],
        aoSelecionar: { _ in },
        aoAdicionarEquipe: { _ in },
        aoEntrarComCodigo: { _ in }
    )
    .padding()
    .background(PapagaioTema.fundo)
    .frame(width: 420)
}
