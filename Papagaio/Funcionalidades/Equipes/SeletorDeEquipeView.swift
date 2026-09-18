import SwiftUI

struct SeletorDeEquipeView: View {
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let aoCancelar: () -> Void
    let aoSelecionar: (EquipeDisponivel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            HStack {
                Text("Mudar Equipe".localized)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(PapagaioTema.texto)

                Spacer()

                Button(action: aoCancelar) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Fechar".localized)
            }

            Text(equipes.isEmpty
                 ? "Você ainda não faz parte de nenhuma equipe.".localized
                 : "Escolha em qual equipe você quer trabalhar agora.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)

            VStack(spacing: PapagaioTema.Espaco.curto) {
                ForEach(equipes) { equipe in
                    Button {
                        aoSelecionar(equipe)
                    } label: {
                        HStack(spacing: PapagaioTema.Espaco.medio) {
                            Image(systemName: "person.3")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(PapagaioTema.destaqueEscuro)
                                .frame(width: 34, height: 34)
                                .background(PapagaioTema.destaqueSuave, in: Circle())

                            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                                Text(equipe.nome)
                                    .font(.headline)
                                    .foregroundStyle(PapagaioTema.texto)
                                Text("\(equipe.papel.localized) • \(equipe.resumoDeMembros.localized)")
                                    .font(.caption)
                                    .foregroundStyle(PapagaioTema.textoSecundario)
                            }

                            Spacer()

                            if equipe.id == equipeAtiva?.id {
                                Image(systemName: "checkmark")
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                            }
                        }
                        .padding(PapagaioTema.Espaco.medio)
                        .background(
                            equipe.id == equipeAtiva?.id ? PapagaioTema.destaqueSuave.opacity(0.62) : PapagaioTema.superficie,
                            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                                .stroke(equipe.id == equipeAtiva?.id ? PapagaioTema.destaque.opacity(0.45) : PapagaioTema.borda, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(width: 430)
        .background(PapagaioTema.fundo)
    }
}

#Preview("Seletor de equipe") {
    SeletorDeEquipeView(
        equipeAtiva: .init(id: "produto", nome: "Produto", papel: "Administrador", quantidadeDeMembros: 4),
        equipes: [
            .init(id: "produto", nome: "Produto", papel: "Administrador", quantidadeDeMembros: 4),
            .init(id: "pesquisa", nome: "Pesquisa", papel: "Membro", quantidadeDeMembros: 8)
        ],
        aoCancelar: {},
        aoSelecionar: { _ in }
    )
}
