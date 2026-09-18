import PapagaioCore
import AppKit
import SwiftUI

struct TarefasView: View {
    let biblioteca: Biblioteca?
    let consulta: String
    @State private var conversasSelecionadas: Set<ArquivoID> = []
    @State private var painelDeTarefas = TarefasDoPainelViewModel()
    @State private var prioridadeSelecionada: PrioridadeDaTarefa?
    @State private var ordenacao: OrdenacaoDoPainelDeTarefas = .deadline
    @State private var filtroDeDeadline: FiltroDeDeadlineTarefa = .todas
    @State private var exibindoEditor = false
    @State private var tarefaEmEdicao: TarefaGeral?
    @State private var conversaDoEditor: ArquivoID?
    @State private var tituloDoEditor = ""
    @State private var descricaoDoEditor = ""
    @State private var responsavelDoEditor = ""
    @State private var prioridadeDoEditor: PrioridadeDaTarefa = .media
    @State private var statusDoEditor: StatusDaTarefa = .naoIniciado
    @State private var prazoDoEditor = Date()
    @State private var larguraDoQuadro: CGFloat?
    /// Cada coluna tem seu próprio botão de olho, na própria tag do
    /// cabeçalho — persistido por coluna, pra quem prefere o quadro sem
    /// uma delas não decidir de novo toda vez que abre o app.
    @AppStorage("ocultarColunaNaoIniciado") private var ocultarColunaNaoIniciado = false
    @AppStorage("ocultarColunaEmAndamento") private var ocultarColunaEmAndamento = false
    @AppStorage("ocultarColunaConcluidas") private var ocultarColunaConcluidas = false
    @AppStorage("ocultarColunaAtrasada") private var ocultarColunaAtrasada = false
    @State private var scrollViewDoKanban: NSScrollView?
    /// Altura real do cabeçalho (título + cards de conversa), para a zona de
    /// rolagem automática do arraste nunca cobrir nada clicável ali em cima.
    @State private var alturaDoCabecalho: CGFloat = 0
    /// Altura do cabeçalho do próprio quadro (título "Todas as tarefas" +
    /// filtros de prioridade/data). Ficava de fora da conta acima — a zona
    /// de rolagem começava exatamente onde o quadro começa, cobrindo esses
    /// filtros (principalmente quando o cabeçalho quebra em duas linhas em
    /// telas estreitas) e os botões paravam de responder a clique.
    @State private var alturaDoCabecalhoDoKanban: CGFloat = 0
    /// Tarefas escondidas uma a uma (pelo `id` composto de `TarefaGeral`),
    /// independente de status ou coluna — ver `TarefasOcultasStore`.
    @State private var tarefasOcultas: Set<String> = TarefasOcultasStore.carregar()
    /// Sem isto ligado, uma tarefa oculta simplesmente não aparece em canto
    /// nenhum do quadro — não dava pra saber que existia, nem pra
    /// desmarcá-la de volta.
    @AppStorage("mostrarTarefasOcultas") private var mostrarTarefasOcultas = false

    private var conversas: [Arquivo] {
        biblioteca?.arquivos.sorted { $0.entradaNaBiblioteca > $1.entradaNaBiblioteca } ?? []
    }

    private var tarefasPorConversa: [TarefasDaConversaGeral] {
        conversas.compactMap { arquivo -> TarefasDaConversaGeral? in
            let tarefas = painelDeTarefas.tarefas(de: arquivo)
                .filter { !$0.pendenteDeRevisao }
                .sorted(by: OrdenacaoDeTarefas.porDeadline)
            guard !tarefas.isEmpty else { return nil }
            return TarefasDaConversaGeral(
                arquivo: arquivo,
                titulo: arquivo.resumo?.titulo ?? arquivo.titulo,
                tarefas: tarefas
            )
        }
    }

    private var conversasVisiveis: [TarefasDaConversaGeral] {
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = tarefasPorConversa
        let filtradasPorSelecao: [TarefasDaConversaGeral]
        if conversasSelecionadas.isEmpty {
            filtradasPorSelecao = base
        } else {
            filtradasPorSelecao = base.filter { conversasSelecionadas.contains($0.id) }
        }

        guard !termo.isEmpty else { return filtradasPorSelecao }
        // A mesma lógica da busca na Biblioteca: título, descrição, data e
        // duração da conversa, além do que já era buscado na própria tarefa
        // (título, origem, responsável) e, agora, o prazo e a descrição dela.
        return filtradasPorSelecao.compactMap { conversa in
            let dataDaConversa = DataDigitada.texto(de: conversa.arquivo.criadoEm)
            let duracaoDaConversa = conversa.arquivo.duracao.comoDuracaoPorExtenso
            let tarefas = conversa.tarefas.filter {
                conversa.titulo.casaComBusca(termo)
                    || dataDaConversa.casaComBusca(termo)
                    || duracaoDaConversa.casaComBusca(termo)
                    || $0.titulo.casaComBusca(termo)
                    || $0.origem.casaComBusca(termo)
                    || ($0.responsavel?.casaComBusca(termo) ?? false)
                    || ($0.descricao?.casaComBusca(termo) ?? false)
                    || ($0.prazo.map { DataDigitada.texto(de: $0).casaComBusca(termo) } ?? false)
            }
            guard !tarefas.isEmpty else { return nil }
            return TarefasDaConversaGeral(
                arquivo: conversa.arquivo,
                titulo: conversa.titulo,
                tarefas: tarefas
            )
        }
    }

    private var tarefasVisiveis: [TarefaGeral] {
        let tarefas = conversasVisiveis.flatMap { conversa in
            conversa.tarefas.map {
                TarefaGeral(conversa: conversa, tarefa: $0)
            }
        }

        let porPrioridade = prioridadeSelecionada.map { prioridade in
            tarefas.filter { $0.tarefa.prioridade == prioridade }
        } ?? tarefas

        let filtradas = porPrioridade.filter { tarefa in
            filtroDeDeadline.inclui(tarefa.tarefa.prazo)
        }

        // Tarefa oculta some do quadro por completo a não ser que "Mostrar
        // tarefas ocultas" esteja ligado — aí ela continua aparecendo (só
        // meio apagada, ver `CartaoDeTarefaGeral`), pra dar pra desmarcá-la.
        let semOcultas = mostrarTarefasOcultas
            ? filtradas
            : filtradas.filter { !tarefasOcultas.contains($0.id) }

        return semOcultas.sorted { primeira, segunda in
            switch ordenacao {
            case .deadline:
                return OrdenacaoDeTarefas.porDeadline(primeira.tarefa, segunda.tarefa)
            case .prioridade:
                return OrdenacaoDeTarefas.porPrioridade(primeira.tarefa, segunda.tarefa)
            }
        }
    }

    /// Onde toda tarefa nova começa. Prioridade é etiqueta, não filtro desta
    /// coluna — uma tarefa de prioridade Alta que ninguém começou ainda mora
    /// aqui, não numa coluna própria. Atrasada também não: uma "Não
    /// iniciado" com prazo vencido sai daqui e vai pra lá (ver
    /// `tarefasAtrasadas`), sem isso ela apareceria duas vezes no quadro.
    /// Isso vale sempre, mesmo com a coluna "Atrasada" recolhida
    /// (`ocultarColunaAtrasada`): recolher só esconde a lista de cartões
    /// dela — a tag do cabeçalho continua contando essas tarefas — então
    /// elas continuam pertencendo a ela, não voltam pra cá.
    private var tarefasNaoIniciadas: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status == .naoIniciado && !atrasada($0) }
    }

    private var tarefasEmAndamento: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status == .emAndamento && !atrasada($0) }
    }

    private var tarefasConcluidas: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status == .concluida }
    }

    /// Recorte, não status: reúne "Não iniciado" e "Em andamento" com prazo
    /// já vencido, tirando as duas de onde estariam normalmente — em vez de
    /// aparecer em dois lugares, a tarefa muda de coluna assim que atrasa.
    /// Concluída nunca entra aqui, mesmo com prazo vencido: o que já foi
    /// feito não está mais "atrasado" pra ninguém decidir.
    private var tarefasAtrasadas: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status != .concluida && atrasada($0) }
    }

    /// Dia contra dia, não hora contra hora — mesmo critério dos selos nos
    /// cartões (`CartaoDeTarefaGeral.atrasada`), pra bater com o que a
    /// pessoa já vê ali. Já reconhecida (ver `TarefaDaConversa.atrasoReconhecido`)
    /// nunca conta como atrasada, mesmo com o prazo ainda vencido — foi a
    /// própria pessoa quem escolheu onde a tarefa fica ao arrastá-la.
    private func atrasada(_ tarefa: TarefaGeral) -> Bool {
        guard let prazo = tarefa.tarefa.prazo,
              tarefa.tarefa.status != .concluida,
              !tarefa.tarefa.atrasoFoiReconhecido
        else { return false }
        return Calendar.current.startOfDay(for: prazo) < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                    // Medido, e não estimado: um número fixo (88pt) cobria o
                    // cabeçalho num teste e sobrava por cima dos cards de
                    // "Todas as conversas" no seguinte — o cabeçalho muda de
                    // altura com o conteúdo (com ou sem os cards de
                    // conversa, com ou sem quebra de linha no título). Com a
                    // altura real medida aqui, a zona de rolagem começa
                    // sempre depois do que há para clicar, não importa a
                    // altura.
                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                        cabecalhoDoPainel

                        if !tarefasPorConversa.isEmpty {
                            seletorDeConversas
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alturaDoCabecalho = $0 }

                    if tarefasPorConversa.isEmpty {
                        CartaoDeEstadoVazio(
                            simbolo: "list.clipboard",
                            titulo: "Nenhuma tarefa ainda".localized,
                            mensagem: "Quando uma conversa tiver próximos passos ou tarefas criadas, elas ficarão reunidas nesta página.".localized
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .cartaoPapagaio()
                    } else {
                        kanbanDeTarefas
                    }
                }
                .larguraDeConteudoPapagaio()
                .padding(.horizontal, PapagaioTema.espacamentoDePagina)
                .padding(.vertical, PapagaioTema.espacamentoDePagina)
                // O botão flutuante não pode cobrir o último card. Esta área
                // também deixa uma faixa livre para levar o cursor até a
                // borda e acionar a rolagem durante o arraste.
                .padding(.bottom, 82)
            }
            .background(LeitorDeScrollView { scrollViewDoKanban = $0 })
            .overlay(alignment: .top) {
                // Uma lista em colunas também pode ficar maior que a janela.
                // Arrastar para o topo precisa acompanhar o card em qualquer
                // largura, não apenas no Kanban vertical.
                //
                // Com recuo do topo, medido de verdade: sem ele, esta zona
                // (mesmo invisível) cobria o cabeçalho da página inteiro —
                // botão "i", cards de "Todas as conversas" e tudo — e essas
                // áreas paravam de responder a clique, roubadas por esta
                // camada por cima delas. O recuo deixa tudo isso livre e
                // ainda sobra zona suficiente perto do topo do quadro pra
                // rolagem durante o arraste continuar funcionando.
                // Faixa bem fina (16pt) e com uma folga extra generosa
                // (`Self.margemDeSegurancaDaZona`) além da tag da coluna:
                // essa mesma faixa já tinha comido o clique do menu "..."
                // no canto do primeiro cartão de cada coluna umas duas
                // vezes — a conta de quanto a tag mede é sensível demais a
                // qualquer mudança de layout ao redor pra confiar só nela.
                // Prefere sobrar folga (a rolagem automática só começa um
                // pouco mais tarde) a faltar um pixel e roubar outro clique.
                ZonaDeRolagemDuranteArrasto(scrollView: scrollViewDoKanban, direcao: .cima, altura: 16)
                    .padding(.top, PapagaioTema.espacamentoDePagina + alturaDoCabecalho + PapagaioTema.Espaco.pagina + alturaDoCabecalhoDoKanban + PapagaioTema.Espaco.largo + Self.alturaDaTagDaColuna + Self.margemDeSegurancaDaZona)
            }
            .overlay(alignment: .bottom) {
                ZonaDeRolagemDuranteArrasto(scrollView: scrollViewDoKanban, direcao: .baixo)
        }
        .background(PapagaioTema.fundo)
        .task {
            painelDeTarefas.recarregar(conversas: conversas)
        }
        .onChange(of: biblioteca?.arquivos) { _, _ in
            painelDeTarefas.recarregar(conversas: conversas)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: abrirCriacaoDeTarefa) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(PapagaioTema.textoSobrePrimario)
                    .frame(width: 58, height: 58)
                    .background(PapagaioTema.preenchimentoPrimario, in: Circle())
                    .shadow(color: PapagaioTema.destaque.opacity(0.28), radius: 18, y: 10)
            }
            .buttonStyle(.plain)
            .padding(PapagaioTema.Espaco.pagina)
            .help("Adicionar tarefa".localized)
            .disabled(conversas.isEmpty)
        }
        .sheet(isPresented: $exibindoEditor) {
            EditorDeTarefaGeralSheet(
                modo: tarefaEmEdicao == nil ? .criacao : .edicao,
                conversas: conversas,
                conversaSelecionada: $conversaDoEditor,
                titulo: $tituloDoEditor,
                descricao: $descricaoDoEditor,
                responsavel: $responsavelDoEditor,
                prioridade: $prioridadeDoEditor,
                status: $statusDoEditor,
                prazo: $prazoDoEditor,
                aoCancelar: { exibindoEditor = false },
                aoSalvar: salvarTarefaDoEditor
            )
        }
    }

    /// O título dentro de um cartão próprio — mesmo tratamento do cabeçalho
    /// da Biblioteca, que também vive separado da grade abaixo dele.
    private var cabecalhoDoPainel: some View {
        // O "i" no lugar do subtítulo fixo — mesmo tratamento que a
        // Biblioteca já usa: a explicação aparece ao passar o mouse, e não
        // ocupa uma linha inteira que só se lê uma vez.
        HStack(alignment: .center, spacing: PapagaioTema.Espaco.curto) {
            Text("Painel de Tarefas".localized)
                .font(PapagaioTema.Tipo.tituloDePagina)
                .foregroundStyle(PapagaioTema.texto)

            // Nudge de +3pt: mesmo com `alignment: .center`, o círculo do
            // "i" ficava visivelmente acima do centro óptico da letra bold
            // de 30pt (ver o mesmo ajuste e comentário em
            // `BibliotecaHomeView.cabecalhoDaBiblioteca`).
            BotaoDeAjudaPapagaio(
                texto: "Gerencie as tarefas geradas a partir das suas conversas.".localized,
                ajuda: "Sobre o painel de tarefas".localized,
                largura: 280
            )
            .offset(y: 3)

            Spacer(minLength: 0)
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var seletorDeConversas: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Todas as conversas".localized)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                // Mesmo tratamento da contagem na tag de cada coluna do
                // quadro logo abaixo — uma pastilha ao lado do rótulo, não
                // outro texto solto competindo com ele.
                Text("\(tarefasPorConversa.count) \(tarefasPorConversa.count == 1 ? "Conversa".localized : "Conversas".localized)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .padding(.vertical, PapagaioTema.Espaco.minimo)
                    .background(PapagaioTema.superficieSuave, in: Capsule())

                if !conversasSelecionadas.isEmpty {
                    Button("Limpar seleção".localized) {
                        withAnimation(.snappy(duration: 0.18)) {
                            conversasSelecionadas.removeAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                // `.top`, e não o padrão `.center`: os cartões não têm mais
                // altura fixa (um título comprido agora estica em vez de
                // truncar), e centralizados um cartão mais alto deixava os
                // vizinhos baixos flutuando no meio da fileira.
                HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                    ForEach(tarefasPorConversa) { conversa in
                        CartaoFiltroDeConversaTarefa(
                            conversa: conversa,
                            selecionado: conversasSelecionadas.contains(conversa.id),
                            vencimento: vencimentoMaisProximo(conversa.tarefas)
                        ) {
                            alternarSelecao(conversa.id)
                        }
                    }
                }
                .padding(.vertical, PapagaioTema.Espaco.minimo)
            }
            .desvanecerNasBordasHorizontais()
        }
    }

    private var kanbanDeTarefas: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            cabecalhoDoKanban
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alturaDoCabecalhoDoKanban = $0 }

            if tarefasVisiveis.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "magnifyingglass",
                    titulo: "Nenhuma tarefa encontrada".localized,
                    mensagem: "Tente limpar a seleção ou buscar por outra conversa.".localized
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                .cartaoPapagaio()
            } else {
                // `AnyLayout` decidido pela largura medida, e não `ViewThatFits`:
                // o quadro tem de empilhar quando a *janela* aperta, nunca por
                // causa do texto que está dentro dele. Ver `cabeEmColunas`.
                let arranjo = cabeEmColunas
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: PapagaioTema.Espaco.largo))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: PapagaioTema.Espaco.medio))

                arranjo {
                    coluna(
                        titulo: "Não iniciado".localized,
                        cor: StatusDaTarefa.naoIniciado.cor,
                        tarefas: tarefasNaoIniciadas,
                        destino: .naoIniciado,
                        oculta: $ocultarColunaNaoIniciado
                    )
                    coluna(
                        titulo: "Em andamento".localized,
                        cor: StatusDaTarefa.emAndamento.cor,
                        tarefas: tarefasEmAndamento,
                        destino: .emAndamento,
                        oculta: $ocultarColunaEmAndamento
                    )
                    coluna(
                        titulo: "Concluídas".localized,
                        cor: StatusDaTarefa.concluida.cor,
                        tarefas: tarefasConcluidas,
                        destino: .concluida,
                        oculta: $ocultarColunaConcluidas
                    )
                    // Última, depois de "Concluídas". Aceita soltura como
                    // as outras — vai para "Não iniciado" (ver `destino`);
                    // se o prazo dela já estiver vencido, o recorte
                    // `tarefasAtrasadas` pega essa tarefa de volta pra cá no
                    // próximo recálculo, então soltar aqui uma tarefa sem
                    // prazo vencido só move ela pra "Não iniciado" mesmo —
                    // igual arrastar pra lá diretamente.
                    coluna(
                        titulo: "Atrasada".localized,
                        cor: PapagaioTema.perigo,
                        tarefas: tarefasAtrasadas,
                        destino: .naoIniciado,
                        oculta: $ocultarColunaAtrasada
                    )
                }
            }
        }
        // Medido no bloco inteiro, que ocupa a mesma largura nos dois arranjos.
        // Medir o próprio quadro faria a escolha depender do que ela produziu.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larguraDoQuadro = $0 }
    }

    @ViewBuilder
    private var cabecalhoDoKanban: some View {
        if cabeCabecalhoEmUmaLinha {
            HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
                resumoDoKanban
                Spacer(minLength: PapagaioTema.Espaco.medio)
                filtrosDoKanban
            }
        } else {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                resumoDoKanban
                ScrollView(.horizontal, showsIndicators: false) {
                    filtrosDoKanban
                        .padding(.vertical, PapagaioTema.Espaco.minimo)
                }
            }
        }
    }

    private var resumoDoKanban: some View {
        HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
            // Sem limite de linha, e sem truncar: o título vem do nome da
            // conversa (ou de "N conversas selecionadas"), tamanho fora do
            // controle da tela — cortar com "..." escondia informação que a
            // pessoa clicou justamente para ver. `layoutPriority` continua
            // garantindo que ele ganha espaço dos filtros antes de quebrar
            // linha à toa.
            Label(tituloDoKanban, systemImage: "list.clipboard")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(PapagaioTema.texto)
                .layoutPriority(1)

            Text("\(tarefasVisiveis.count) \(tarefasVisiveis.count == 1 ? "Tarefa".localized : "Tarefas".localized)")
                .font(.callout.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .padding(.horizontal, PapagaioTema.Espaco.medio)
                .padding(.vertical, PapagaioTema.Espaco.minimo)
                .background(PapagaioTema.superficieSuave, in: Capsule())
                .fixedSize()
        }
    }

    private var filtrosDoKanban: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Menu {
                Button("Todas".localized) { prioridadeSelecionada = nil }
                ForEach(PrioridadeDaTarefa.allCases, id: \.self) { prioridade in
                    Button(prioridade.titulo) { prioridadeSelecionada = prioridade }
                }
            } label: {
                Label(prioridadeSelecionada?.titulo ?? "Prioridade".localized, systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: prioridadeSelecionada != nil))

            Menu {
                Button("Todas".localized) { filtroDeDeadline = .todas }
                Divider()
                ForEach(FiltroDeDeadlineTarefa.allCases.filter { $0 != .todas }, id: \.self) { filtro in
                    Button(filtro.titulo) { filtroDeDeadline = filtro }
                }
            } label: {
                Label(filtroDeDeadline.titulo, systemImage: filtroDeDeadline.simbolo)
            }
            .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: filtroDeDeadline != .todas))
            // O botão de ocultar coluna saiu daqui: cada coluna tem o seu
            // próprio, na própria tag do cabeçalho (ver `ColunaDeTarefasGerais`).

            if !tarefasOcultas.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        mostrarTarefasOcultas.toggle()
                    }
                } label: {
                    Label(
                        mostrarTarefasOcultas ? "\(tarefasOcultas.count) \("ocultas".localized)" : "Ocultas".localized,
                        systemImage: mostrarTarefasOcultas ? "eye" : "eye.slash"
                    )
                }
                .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: mostrarTarefasOcultas))
                .help(mostrarTarefasOcultas ? "Esconder de novo as tarefas ocultas".localized : "Mostrar as tarefas ocultas".localized)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Largura mínima em que um cartão de tarefa ainda se lê: abaixo disso o
    /// título quebra em quatro linhas e a data desgruda do responsável.
    private static let larguraMinimaDaColuna: CGFloat = 280

    /// Altura da tag do cabeçalho de cada coluna (ver `ColunaDeTarefasGerais`,
    /// `minHeight: 30`) somada ao respiro vertical da coluna acima dela
    /// (`.padding(.vertical, 10)`). A zona invisível de rolagem automática
    /// durante o arraste começa só depois disso — sem essa folga ela cobria
    /// bem a faixa onde vive o botão de olho de cada tag, e o clique nele
    /// não chegava a lugar nenhum.
    private static let alturaDaTagDaColuna: CGFloat = 46

    /// Folga extra por cima da conta acima — essa conta já errou o
    /// suficiente pra roubar o clique do menu "..." no canto do primeiro
    /// cartão de cada coluna mais de uma vez. Em vez de tentar acertar o
    /// pixel exato de novo, essa margem generosa garante que a zona
    /// termine bem antes do primeiro cartão começar, ao custo de a rolagem
    /// automática só entrar em ação um pouco mais tarde durante o arraste.
    private static let margemDeSegurancaDaZona: CGFloat = 40

    /// As quatro colunas lado a lado só quando a janela realmente as comporta.
    ///
    /// Isto era um `ViewThatFits`, que escolhe pelo tamanho *ideal* do conteúdo
    /// — e o ideal de um texto é a linha inteira sem quebrar. Bastava uma tarefa
    /// de título longo mudar de coluna para o total estourar e o quadro inteiro
    /// desabar numa coluna só, sem a janela ter mudado de tamanho. Era esse o
    /// "bug ao concluir": concluir movia um cartão comprido para as Concluídas.
    private var cabeEmColunas: Bool {
        // Antes da primeira medida, assume que cabe: a janela padrão comporta.
        guard let larguraDoQuadro else { return true }
        // Sempre 4: as quatro tags do cabeçalho ficam na fileira mesmo com
        // a lista de cartões de alguma coluna recolhida (ver `oculta` em
        // `ColunaDeTarefasGerais`) — só a altura muda, não a largura.
        let numeroDeColunas: CGFloat = 4
        return larguraDoQuadro >= Self.larguraMinimaDaColuna * numeroDeColunas + PapagaioTema.Espaco.largo * (numeroDeColunas - 1)
    }

    /// Abaixo desta largura, título e filtros recebem linhas separadas. Assim
    /// o texto nunca é espremido entre os dois menus.
    private var cabeCabecalhoEmUmaLinha: Bool {
        guard let larguraDoQuadro else { return true }
        return larguraDoQuadro >= 960
    }

    private var tituloDoKanban: String {
        if conversasSelecionadas.count == 1,
           let selecionada = conversasVisiveis.first {
            return selecionada.titulo
        }
        return conversasSelecionadas.isEmpty ? "Todas as tarefas".localized : "\(conversasSelecionadas.count) \("conversas selecionadas".localized)"
    }

    private func coluna(
        titulo: String,
        cor: Color,
        tarefas: [TarefaGeral],
        destino: DestinoDeTarefa,
        permiteSoltar: Bool = true,
        oculta: Binding<Bool>
    ) -> some View {
        ColunaDeTarefasGerais(
            titulo: titulo,
            cor: cor,
            tarefas: tarefas,
            destino: destino,
            aoEditar: abrirEdicao,
            aoAlternarConclusao: alternarConclusao,
            aoExcluir: excluirTarefa,
            aoMover: moverTarefa,
            tarefasOcultas: tarefasOcultas,
            aoOcultarTarefa: alternarOcultarTarefa,
            compacto: !cabeEmColunas,
            permiteSoltar: permiteSoltar,
            oculta: oculta.wrappedValue,
            aoAlternarOcultar: {
                withAnimation(.snappy(duration: 0.18)) {
                    oculta.wrappedValue.toggle()
                }
            }
        )
            .frame(maxWidth: .infinity, alignment: .top)
            .id("kanban-\(titulo)")
    }

}

/// Borda de rolagem contínua: ela avança pequenos passos, em vez de saltar
/// direto para outra coluna, preservando o controle durante o arrasto.
struct ZonaDeRolagemDuranteArrasto: View {
    enum Direcao { case cima, baixo }

    let scrollView: NSScrollView?
    let direcao: Direcao
    /// Altura da faixa invisível. 128 (o padrão) cobre uma área generosa
    /// antes da borda física da janela — mas essa mesma área invisível
    /// também intercepta clique e o início de um arraste em qualquer coisa
    /// por baixo dela (foi o que quebrou os botões de filtro e o olho de
    /// cada coluna antes). No topo, essa faixa começa logo abaixo dos
    /// cabeçalhos e filtros — encostando já na primeira fileira de
    /// cartões — então ali ela precisa ser bem mais fina, senão captura o
    /// clique que deveria iniciar o arraste do próprio cartão.
    var altura: CGFloat = 128
    @State private var tarefaDeRolagem: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(height: altura)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { _, _ in false } isTargeted: { ativo in
                tarefaDeRolagem?.cancel()
                guard ativo else { return }

                tarefaDeRolagem = Task { @MainActor in
                    // Um pequeno atraso evita disparos acidentais. Depois a
                    // lista se move em passos curtos enquanto o card estiver
                    // na borda, como a rolagem nativa de uma lista.
                    try? await Task.sleep(for: .milliseconds(120))
                    while !Task.isCancelled {
                        guard let scrollView else { return }
                        rolar(scrollView)
                        try? await Task.sleep(for: .milliseconds(110))
                    }
                }
            }
            .onDisappear { tarefaDeRolagem?.cancel() }
    }

    @MainActor
    private func rolar(_ scrollView: NSScrollView) {
        let areaVisivel = scrollView.contentView.bounds
        let alturaDoDocumento = scrollView.documentView?.bounds.height ?? areaVisivel.height
        let limite = max(0, alturaDoDocumento - areaVisivel.height)
        // Devagar o bastante para escolher o destino; contínuo o bastante
        // para a página acompanhar o cartão arrastado.
        let delta: CGFloat = direcao == .cima ? -18 : 18
        let proximaPosicao = min(max(0, areaVisivel.origin.y + delta), limite)
        scrollView.contentView.scroll(to: NSPoint(x: areaVisivel.origin.x, y: proximaPosicao))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

struct LeitorDeScrollView: NSViewRepresentable {
    let aoEncontrar: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { procurarScrollView(aPartirDe: view) }
        // Em algumas composições de ScrollView o `background` entra na
        // hierarquia um ciclo depois. Repetir uma vez evita que o leitor fique
        // com `nil` e o auto-scroll simplesmente não tenha alvo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            procurarScrollView(aPartirDe: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { procurarScrollView(aPartirDe: nsView) }
    }

    private func procurarScrollView(aPartirDe view: NSView) {
        var ancestral: NSView? = view
        while let atual = ancestral {
            if let scrollView = atual as? NSScrollView {
                aoEncontrar(scrollView)
                return
            }
            ancestral = atual.superview
        }
    }
}

extension TarefasView {
    private func alternarSelecao(_ id: ArquivoID) {
        withAnimation(.snappy(duration: 0.18)) {
            if conversasSelecionadas.contains(id) {
                conversasSelecionadas.remove(id)
            } else {
                conversasSelecionadas.insert(id)
            }
        }
    }

    private func vencimentoMaisProximo(_ tarefas: [TarefaDaConversa]) -> Date? {
        tarefas
            .filter { $0.status != .concluida }
            .compactMap(\.prazo)
            .min()
    }

    private func abrirCriacaoDeTarefa() {
        // Fecha antes de reabrir (ver comentário em `abrirEdicao`): garante
        // que o `.sheet(isPresented:)` sempre veja uma transição de verdade
        // de fechado pra aberto, mesmo se já houvesse um editor na tela.
        exibindoEditor = false
        DispatchQueue.main.async {
            tarefaEmEdicao = nil
            conversaDoEditor = conversasSelecionadas.first ?? conversas.first?.id
            tituloDoEditor = ""
            descricaoDoEditor = ""
            responsavelDoEditor = ""
            prioridadeDoEditor = .media
            statusDoEditor = .naoIniciado
            prazoDoEditor = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            exibindoEditor = true
        }
    }

    private func abrirEdicao(_ tarefa: TarefaGeral) {
        // `.sheet(isPresented:)` só reavalia o conteúdo (e o `modo` calculado
        // ali dentro) numa transição de `false` para `true`. Setando
        // `tarefaEmEdicao` e `exibindoEditor = true` no mesmo instante em que
        // `exibindoEditor` já podia estar `true` (editor anterior ainda
        // fechando), a apresentação virava um "true para true" que o SwiftUI
        // não conta como reabertura — o conteúdo antigo (modo "Nova tarefa")
        // ficava na tela, só os campos (ligados por `@Binding`, sempre ao
        // vivo) é que mostravam os dados certos. Fechando primeiro e
        // reabrindo no próximo ciclo, a transição é sempre genuína.
        exibindoEditor = false
        DispatchQueue.main.async {
            tarefaEmEdicao = tarefa
            conversaDoEditor = tarefa.conversa.id
            tituloDoEditor = tarefa.tarefa.titulo
            descricaoDoEditor = tarefa.tarefa.descricao ?? ""
            responsavelDoEditor = tarefa.tarefa.responsavelValido ?? ""
            prioridadeDoEditor = tarefa.tarefa.prioridade
            statusDoEditor = tarefa.tarefa.status
            prazoDoEditor = tarefa.tarefa.prazo ?? Date()
            exibindoEditor = true
        }
    }

    private func salvarTarefaDoEditor() {
        guard let conversaID = conversaDoEditor,
              let arquivo = conversas.first(where: { $0.id == conversaID })
        else { return }

        let titulo = tituloDoEditor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titulo.isEmpty else { return }

        let descricao = descricaoDoEditor.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prazo trocado à mão no formulário: o reconhecimento de atraso de
        // um prazo anterior não vale mais pra este novo prazo — se o novo
        // também já estiver vencido, a tarefa deve voltar a contar como
        // "Atrasada" normalmente, não continuar "perdoada" por causa de um
        // arraste antigo com outra data.
        let prazoMudou = tarefaEmEdicao?.tarefa.prazo != prazoDoEditor
        let tarefaAtualizada = TarefaDaConversa(
            id: tarefaEmEdicao?.tarefa.id ?? UUID(),
            titulo: titulo,
            origem: arquivo.resumo?.titulo ?? arquivo.titulo,
            prioridade: prioridadeDoEditor,
            status: statusDoEditor,
            responsavel: responsavelDoEditor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : responsavelDoEditor,
            prazo: prazoDoEditor,
            descricao: descricao.isEmpty ? nil : descricao,
            prioridadeDefinidaManualmente: true,
            atrasoReconhecido: prazoMudou ? nil : tarefaEmEdicao?.tarefa.atrasoReconhecido
        )

        painelDeTarefas.salvar(tarefaAtualizada, em: arquivo, substituindo: tarefaEmEdicao != nil)
        exibindoEditor = false
    }

    private func alternarConclusao(_ tarefa: TarefaGeral) {
        painelDeTarefas.alternarConclusao(tarefa.tarefa.id, em: tarefa.conversa.arquivo)
    }

    private func alternarOcultarTarefa(_ tarefa: TarefaGeral) {
        if tarefasOcultas.contains(tarefa.id) {
            tarefasOcultas.remove(tarefa.id)
        } else {
            tarefasOcultas.insert(tarefa.id)
        }
        TarefasOcultasStore.salvar(tarefasOcultas)
    }

    private func moverTarefa(_ id: String, para destino: DestinoDeTarefa) {
        guard let tarefa = tarefasVisiveis.first(where: { $0.id == id }) else { return }
        var transacao = Transaction()
        transacao.disablesAnimations = true
        withTransaction(transacao) {
            painelDeTarefas.mover(tarefa.tarefa.id, para: destino, em: tarefa.conversa.arquivo)
        }
    }

    private func excluirTarefa(_ tarefa: TarefaGeral) {
        painelDeTarefas.excluir(
            tarefa.tarefa,
            em: tarefa.conversa.arquivo,
            conversaTitulo: tarefa.conversa.titulo
        )
    }
}
