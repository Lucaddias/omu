import SwiftUI

struct SeletorDeContextoDaConta: View {
    let contexto: ContextoDaConta
    let equipeAtiva: EquipeDisponivel?
    /// Todas as equipes da pessoa — uma linha para cada, não só a ativa.
    /// Com só uma linha genérica "Equipe" (o que havia antes), quem tinha
    /// várias não tinha como trocar por aqui: precisava ir em "Gerenciar
    /// equipe" só para escolher outra. Criar continua sendo coisa de lá —
    /// aqui é só trocar entre as que já existem.
    let equipes: [EquipeDisponivel]
    let aoUsarPerfil: () -> Void
    let aoUsarEquipe: (EquipeDisponivel) -> Void
    /// Um `Menu` nativo do SwiftUI renderiza os itens como `NSMenuItem` de
    /// verdade — sem jeito de colorir o fundo ou destacar qual equipe está
    /// selecionada, só o texto puro. E abrir a lista "inline" (empurrando o
    /// resto do menu pra baixo) duplicava a equipe ativa na tela: uma vez na
    /// linha resumo, outra dentro da lista. Por isso a lista vira um
    /// popover flutuante — como o seletor do Codex — que abre por cima sem
    /// mexer no resto do menu, e a linha resumo some enquanto ele está
    /// aberto.
    @State private var mostrandoEquipes = false

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text("Pessoal".localized)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(PapagaioTema.textoSecundario)

            BotaoDeContextoDaConta(
                titulo: "Perfil pessoal".localized,
                subtitulo: "Conta pessoal".localized,
                simbolo: "person.crop.circle",
                selecionado: contexto == .perfil,
                acao: aoUsarPerfil
            )

            if !equipes.isEmpty {
                Text("Equipe".localized)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .padding(.top, PapagaioTema.Espaco.curto)

                linhaDeEquipeAtiva
            }
        }
        .frame(width: 260, alignment: .leading)
    }

    /// A linha que fica sempre visível: nome da equipe ativa e um "v" que
    /// abre o popover flutuante com a lista completa.
    private var linhaDeEquipeAtiva: some View {
        Button {
            mostrandoEquipes = true
        } label: {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Image(systemName: "person.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(contexto == .equipe ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(equipeAtiva?.nome ?? "Selecionar equipe".localized)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let ativa = equipeAtiva {
                        let membrosTexto = ativa.quantidadeDeMembros == 1 ? "1 membro".localized : "%d membros".localized(ativa.quantidadeDeMembros)
                        Text("\(ativa.papel.localized) • \(membrosTexto)")
                            .font(.caption)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.body.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
            .padding(PapagaioTema.Espaco.curto)
            .background(
                contexto == .equipe ? PapagaioTema.destaqueSuave.opacity(0.7) : Color.clear,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $mostrandoEquipes, arrowEdge: .bottom) {
            listaFlutuanteDeEquipes
        }
    }

    /// Até `maximoVisivel` equipes cabem sem rolagem — acima disso, uma
    /// altura travada com `ScrollView` mantém o popover num tamanho
    /// razoável em vez de crescer com a lista inteira.
    private static let maximoVisivel = 5
    private static let alturaDeCadaLinha: CGFloat = 56
    private static let alturaDaRolagem = alturaDeCadaLinha * CGFloat(maximoVisivel)

    private var listaFlutuanteDeEquipes: some View {
        Group {
            if equipes.count <= Self.maximoVisivel {
                conteudoDaLista
            } else {
                ScrollView {
                    conteudoDaLista
                }
                .frame(maxHeight: Self.alturaDaRolagem)
            }
        }
        .frame(width: 260)
        .padding(PapagaioTema.Espaco.curto)
    }

    private var conteudoDaLista: some View {
        VStack(spacing: PapagaioTema.Espaco.minimo) {
            ForEach(equipes) { equipe in
                let membrosTexto = equipe.quantidadeDeMembros == 1 ? "1 membro".localized : "%d membros".localized(equipe.quantidadeDeMembros)
                BotaoDeContextoDaConta(
                    titulo: equipe.nome,
                    subtitulo: "\(equipe.papel.localized) • \(membrosTexto)",
                    simbolo: "person.3",
                    selecionado: contexto == .equipe && equipe.id == equipeAtiva?.id,
                    acao: {
                        aoUsarEquipe(equipe)
                        mostrandoEquipes = false
                    }
                )
            }
        }
    }
}

struct BotaoDeContextoDaConta: View {
    let titulo: String
    let subtitulo: String
    let simbolo: String
    let selecionado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Image(systemName: simbolo)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selecionado ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(titulo.localized)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitulo.localized)
                        .font(.caption)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer()
            }
            .padding(PapagaioTema.Espaco.curto)
            .background(
                selecionado ? PapagaioTema.destaqueSuave.opacity(0.7) : Color.clear,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
