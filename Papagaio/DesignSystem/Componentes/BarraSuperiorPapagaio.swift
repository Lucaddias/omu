import SwiftUI

struct BarraSuperiorPapagaioView: View {
    @Binding var consulta: String
    @Binding var legendaAtiva: LegendaDaBarra?
    @State private var exibindoMenuDePerfil = false
    @State private var exibindoNotificacoes = false
    @State private var larguraDaBarra: CGFloat = 0
    let exibindoBotaoVoltar: Bool
    let bibliotecaSelecionada: Bool
    let tarefasSelecionada: Bool
    let midiasSelecionada: Bool
    let configuracoesSelecionada: Bool
    let lixeiraSelecionada: Bool
    let perfilConectado: Bool
    let perfilVerificando: Bool
    let avatarURL: URL?
    let contextoDaConta: ContextoDaConta
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let gravando: Bool
    let processandoBiblioteca: Bool
    let quantidadeDeAvisos: Int
    let notificacoes: [NotificacaoDoApp]
    let aoEntrar: () -> Void
    let aoSair: () -> Void
    let aoMarcarNotificacoesComoLidas: () -> Void
    let aoLimparNotificacoes: () -> Void
    let aoVoltar: () -> Void
    let aoAbrirBiblioteca: () -> Void
    let aoAbrirTarefas: () -> Void
    let aoAbrirMidias: () -> Void
    let aoAbrirConfiguracoes: () -> Void
    let aoAbrirLixeira: () -> Void
    let aoUsarPerfil: () -> Void
    let aoUsarEquipe: (EquipeDisponivel) -> Void
    let aoGerenciarPerfil: () -> Void
    let aoGerenciarEquipe: () -> Void

    /// A barra era um `ScrollView` horizontal com `minWidth: 760`. Abaixo disso
    /// ela não encolhia: rolava, e o botão de conta — único acesso a perfil,
    /// equipe e sair — saía da tela sem nenhum indício de que ainda estava lá.
    ///
    /// Agora ela se resolve sozinha em três estágios: completa; sem o rótulo da
    /// conta; e, no mais apertado, com os dois grupos de ícones fundidos num
    /// menu "⋯". Nenhuma ação fica inalcançável em nenhuma largura.
    /// Fora da gravação, e fora de Configurações — ali não há nada para a
    /// busca filtrar, é uma tela de preferências, não uma lista. O painel de
    /// tarefas continua incluído: já filtra pelo termo digitado (nome da
    /// conversa e nome da tarefa), então esconder a busca ali só escondia
    /// uma funcionalidade que já existia.
    private var exibindoBusca: Bool { !gravando && !configuracoesSelecionada }

    /// Os atalhos não seguem a busca: em Configurações eles eram escondidos
    /// junto com o campo, e a tela ficava sem nenhum caminho de volta para a
    /// Biblioteca. Só a gravação os esconde.
    private var exibindoAtalhos: Bool { !gravando }

    /// "Buscar conversas…" não servia em nenhuma das outras duas telas com
    /// busca: no painel de tarefas o termo casa o nome da tarefa, e na
    /// lixeira ele também alcança mídia e tarefas apagadas — dizer só
    /// "conversas" ali prometia menos do que a busca de fato cobre.
    private var placeholderDeBusca: String {
        if tarefasSelecionada { return "Buscar tarefas…".localized }
        if midiasSelecionada { return "Buscar mídias…".localized }
        if lixeiraSelecionada { return "Buscar na lixeira…".localized }
        return "Buscar conversas…".localized
    }

    /// Só centraliza quando sobra largura para os três blocos conviverem: a
    /// busca no meio, o voltar à esquerda e conta mais ações à direita.
    private var exibindoBuscaCentralizada: Bool {
        exibindoAtalhos && larguraDaBarra >= 1_040
    }

    var body: some View {
        // A busca fica no centro da **janela**, não no meio do que sobra entre
        // os dois grupos. Num `HStack` com espaçadores ela pousaria à esquerda
        // do centro, porque o grupo da conta é bem mais largo que o do voltar.
        // Daí a sobreposição centralizada por cima da linha.
        HStack(spacing: PapagaioTema.Espaco.medio) {
            if exibindoBotaoVoltar || gravando {
                BotaoCircularPapagaio(
                    simbolo: "chevron.backward",
                    ajuda: "Voltar para a biblioteca".localized,
                    legendaAtiva: $legendaAtiva,
                    acao: aoVoltar
                )
            }

            // Sem espaço para centralizar, busca e atalhos voltam para a linha,
            // logo depois do voltar, e encolhem junto com ela.
            if exibindoAtalhos, !exibindoBuscaCentralizada {
                if exibindoBusca { campoDeBusca }
                atalhos
            }

            Spacer(minLength: PapagaioTema.Espaco.curto)

            // Degradação em três estágios. Depender do tamanho mínimo da janela
            // não funcionou — `windowResizability(.contentMinSize)` não segurou
            // o `minWidth` através do `NavigationStack`, e a janela continuava
            // encolhendo até a barra transbordar pelos dois lados. Aqui a barra
            // se resolve sozinha em qualquer largura.
            if !gravando {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PapagaioTema.Espaco.medio) {
                        grupoDeAcoes
                        botaoDePerfil(comRotulo: true)
                    }

                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        grupoDeAcoes
                        botaoDePerfil(comRotulo: false)
                    }

                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        menuDeAcoesCompacto
                        botaoDePerfil(comRotulo: false)
                    }
                }
            }
        }
        // Gravando, a barra some inteira e sobra só o botão de voltar: buscar
        // ou trocar de seção no meio de uma captura só tira a pessoa da tela
        // em que ela está trabalhando.
        // A busca centralizada é uma sobreposição, e sobreposição não empurra
        // ninguém: em janela estreita ela passava por cima dos botões da
        // direita. Por isso a largura decide o layout — centralizada quando há
        // espaço, dentro da linha quando não há.
        .overlay {
            if exibindoBuscaCentralizada {
                HStack(spacing: PapagaioTema.Espaco.medio) {
                    if exibindoBusca { campoDeBusca }
                    atalhos
                }
                .fixedSize()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larguraDaBarra = $0 }
        // A barra segue a mesma coluna das páginas: margem igual **e** o mesmo
        // teto de largura. Só igualar o padding não bastava — as páginas usam
        // `larguraDeConteudoPapagaio`, que centraliza o conteúdo numa coluna
        // limitada, então em tela larga o título começava bem depois da busca.
        // A ordem importa: primeiro a coluna, depois a margem — igual às
        // páginas, que fazem `larguraDeConteudoPapagaio()` e só então o
        // `padding`. Invertido, a margem entra **dentro** da coluna e soma
        // 24pt, jogando a busca para a direita do título em tela larga.
        .padding(.vertical, PapagaioTema.Espaco.curto)
        .larguraDeConteudoPapagaio()
        .padding(.horizontal, PapagaioTema.espacamentoDePagina)
        // Sem linha divisória: a régua horizontal separava a barra da página
        // como se fossem duas superfícies, e são a mesma. Os próprios botões
        // já têm contorno, então a hierarquia não depende dela.
        .background(PapagaioTema.fundo)
    }

    private var grupoDeAcoes: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Button {
                exibindoNotificacoes = true
                aoMarcarNotificacoesComoLidas()
            } label: {
                BotaoDeIconeDaBarra(
                    simbolo: "bell",
                    legenda: "Notificações".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: exibindoNotificacoes,
                    mostraIndicador: quantidadeDeAvisos > 0
                )
            }
            .buttonStyle(.plain)
            .help("Notificações".localized)
            .popover(isPresented: $exibindoNotificacoes, arrowEdge: .top) {
                ListaDeNotificacoesDoApp(
                    notificacoes: notificacoes,
                    processandoBiblioteca: processandoBiblioteca,
                    gravando: gravando,
                    aoLimpar: aoLimparNotificacoes
                )
            }

            Button(action: aoAbrirLixeira) {
                BotaoDeIconeDaBarra(
                    simbolo: "trash",
                    legenda: "Lixeira".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: lixeiraSelecionada
                )
            }
            .buttonStyle(.plain)
            .help("Lixeira".localized)

            Button(action: aoAbrirConfiguracoes) {
                BotaoDeIconeDaBarra(
                    simbolo: "gearshape",
                    legenda: "Configurações".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: configuracoesSelecionada
                )
            }
            .buttonStyle(.plain)
            .help("Configurações".localized)
        }
        // Sem cápsula em volta: eram dois contornos concêntricos para a mesma
        // coisa. Cada ícone já se anuncia como botão pelo próprio círculo, e
        // agrupá-los de novo só engrossava a moldura.
        .frame(height: PapagaioTema.Altura.padrao)
        .fixedSize()
    }

    /// Estágio final da barra: um menu só com tudo o que os dois grupos de
    /// ícones ofereciam. Nada fica inacessível quando a janela aperta.
    private var menuDeAcoesCompacto: some View {
        Menu {
            Button("Biblioteca de conversas".localized, systemImage: "folder", action: aoAbrirBiblioteca)
            Button("Tarefas".localized, systemImage: "list.clipboard", action: aoAbrirTarefas)
            Button("Mídias".localized, systemImage: "photo.on.rectangle", action: aoAbrirMidias)

            Divider()

            Button(action: {
                exibindoNotificacoes = true
                aoMarcarNotificacoesComoLidas()
            }) {
                Label(
                    quantidadeDeAvisos > 0 ? "Notificações (%d)".localized(quantidadeDeAvisos) : "Notificações".localized,
                    systemImage: "bell"
                )
            }
            Button("Lixeira".localized, systemImage: "trash", action: aoAbrirLixeira)
            Button("Configurações".localized, systemImage: "gearshape", action: aoAbrirConfiguracoes)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: PapagaioTema.Altura.padrao, height: PapagaioTema.Altura.padrao)
                .background(PapagaioTema.superficie, in: Circle())
                .overlay {
                    Circle().stroke(PapagaioTema.borda.opacity(0.82), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if quantidadeDeAvisos > 0 {
                        Circle()
                            .fill(PapagaioTema.destaque)
                            .frame(width: 8, height: 8)
                    }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mais ações".localized)
        .accessibilityLabel("Mais ações".localized)
        .popover(isPresented: $exibindoNotificacoes, arrowEdge: .top) {
            ListaDeNotificacoesDoApp(
                notificacoes: notificacoes,
                processandoBiblioteca: processandoBiblioteca,
                gravando: gravando,
                aoLimpar: aoLimparNotificacoes
            )
        }
    }

    private func botaoDePerfil(comRotulo: Bool) -> some View {
        Button {
            exibindoMenuDePerfil = true
        } label: {
            conteudoDoBotaoDePerfil(comRotulo: comRotulo)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(perfilConectado ? tituloDaContaAtiva : "Perfil".localized)
        .accessibilityLabel(perfilConectado ? "Conta ativa: %@".localized(tituloDaContaAtiva) : "Perfil".localized)
        .popover(isPresented: $exibindoMenuDePerfil, arrowEdge: .top) {
            menuDePerfil
        }
    }

    private func conteudoDoBotaoDePerfil(comRotulo: Bool) -> some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            AvatarDaContaNaBarra(
                url: contextoDaConta == .perfil ? avatarURL : nil,
                simbolo: contextoDaConta.simbolo,
                conectado: perfilConectado
            )

            if comRotulo {
                Text(tituloDaContaAtiva)
                    .font(PapagaioTema.Tipo.apoio.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.72))
            }
        }
        .padding(.leading, PapagaioTema.Espaco.minimo)
        .padding(.trailing, comRotulo ? PapagaioTema.Espaco.medio : PapagaioTema.Espaco.minimo)
        .frame(height: PapagaioTema.Altura.padrao)
        .background(PapagaioTema.superficie, in: Capsule())
        .overlay {
            Capsule()
                .stroke(PapagaioTema.borda.opacity(0.82), lineWidth: 1)
        }
    }

    private var menuDePerfil: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            if perfilConectado {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Conta ativa".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                    Text(tituloDaContaAtiva)
                        .font(.headline)
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                SeletorDeContextoDaConta(
                    contexto: contextoDaConta,
                    equipeAtiva: equipeAtiva,
                    equipes: equipes,
                    aoUsarPerfil: {
                        exibindoMenuDePerfil = false
                        aoUsarPerfil()
                    },
                    aoUsarEquipe: { equipe in
                        exibindoMenuDePerfil = false
                        aoUsarEquipe(equipe)
                    }
                )

                Divider()

                Button("Gerenciar perfil".localized, systemImage: "person.crop.circle") {
                    exibindoMenuDePerfil = false
                    aoGerenciarPerfil()
                }

                Button("Gerenciar equipe".localized, systemImage: "person.3.sequence") {
                    exibindoMenuDePerfil = false
                    aoGerenciarEquipe()
                }

                Button("Sair".localized, role: .destructive) {
                    exibindoMenuDePerfil = false
                    aoSair()
                }
            } else {
                Button("Entrar com Apple".localized) {
                    exibindoMenuDePerfil = false
                    aoEntrar()
                }
                .disabled(perfilVerificando)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(width: 280, alignment: .leading)
    }

    private var campoDeBusca: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PapagaioTema.textoSecundario)
            // O placeholder muda com a tela: "conversas" não dizia nada de
            // útil no painel de tarefas, onde o termo casa é o nome da
            // tarefa (ou da conversa que a gerou) — nem na lixeira, onde a
            // busca também alcança mídia e tarefas apagadas, não só
            // conversas.
            TextField(placeholderDeBusca, text: $consulta)
                .textFieldStyle(.plain)
                .foregroundStyle(PapagaioTema.texto)
                .accessibilityLabel(placeholderDeBusca)
        }
        // Único elemento elástico da barra: cresce até 620 e cede até 100.
        // Sem `layoutPriority` — ele deve ser servido depois dos grupos de
        // ícones, que são `fixedSize` e não têm como encolher em troca.
        .frame(minWidth: 100, idealWidth: 520, maxWidth: 620)
        // Cápsula, como os atalhos e o botão de perfil ao lado —
        // `molduraDeControlePapagaio()` desenha um retângulo de cantos só
        // discretamente arredondados (o raio padrão de qualquer controle do
        // app), e aqui ela ficava a única peça quadrada no meio de tudo o
        // mais redondo da barra.
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .frame(height: PapagaioTema.Altura.padrao)
        .background(PapagaioTema.superficie, in: Capsule())
        .overlay {
            Capsule().stroke(PapagaioTema.borda, lineWidth: 1)
        }
    }

    private var atalhos: some View {
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            Button(action: aoAbrirBiblioteca) {
                BotaoDeAtalhoDaBarra(
                    simbolo: "folder",
                    legenda: "Biblioteca de conversas".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: bibliotecaSelecionada
                )
            }
            .buttonStyle(.plain)
            .help("Biblioteca de conversas".localized)
            .accessibilityLabel("Biblioteca de conversas".localized)

            Button(action: aoAbrirTarefas) {
                BotaoDeAtalhoDaBarra(
                    simbolo: "list.clipboard",
                    legenda: "Tarefas".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: tarefasSelecionada
                )
            }
            .buttonStyle(.plain)
            .help("Tarefas".localized)
            .accessibilityLabel("Tarefas".localized)

            Button(action: aoAbrirMidias) {
                BotaoDeAtalhoDaBarra(
                    simbolo: "photo.on.rectangle",
                    legenda: "Mídias".localized,
                    legendaAtiva: $legendaAtiva,
                    selecionado: midiasSelecionada
                )
            }
            .buttonStyle(.plain)
            .help("Mídias".localized)
            .accessibilityLabel("Mídias".localized)
        }
        .padding(.horizontal, PapagaioTema.Espaco.minimo)
        .frame(height: PapagaioTema.Altura.padrao)
        // Cápsula, como o campo de busca e o botão de perfil ao lado — não
        // um retângulo de cantos arredondados. Era o único componente
        // quadrado no meio de tudo o mais redondo da barra.
        .background(PapagaioTema.superficie, in: Capsule())
        .overlay {
            Capsule().stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .fixedSize()
    }

    private var tituloDaContaAtiva: String {
        contextoDaConta == .perfil ? "Perfil pessoal".localized : (equipeAtiva?.nome ?? "Nenhuma equipe ainda".localized)
    }
}
