import PapagaioCore
import SwiftUI

struct TarefasView: View {
    let biblioteca: Biblioteca?
    let consulta: String
    @State private var conversasSelecionadas: Set<ArquivoID> = []
    @State private var versaoDasTarefas = 0
    @State private var prioridadeSelecionada: PrioridadeDaTarefa?
    @State private var ordenacao: OrdenacaoDoPainelDeTarefas = .deadline
    @State private var filtroDeDeadline: FiltroDeDeadlineTarefa = .todas
    @State private var exibindoEditor = false
    @State private var tarefaEmEdicao: TarefaGeral?
    @State private var conversaDoEditor: ArquivoID?
    @State private var tituloDoEditor = ""
    @State private var responsavelDoEditor = ""
    @State private var prioridadeDoEditor: PrioridadeDaTarefa = .media
    @State private var statusDoEditor: StatusDaTarefa = .emAndamento
    @State private var prazoDoEditor = Date()
    @State private var larguraDoQuadro: CGFloat?

    private var conversas: [Arquivo] {
        biblioteca?.arquivos.sorted { $0.criadoEm > $1.criadoEm } ?? []
    }

    private var tarefasPorConversa: [TarefasDaConversaGeral] {
        _ = versaoDasTarefas
        return conversas.compactMap { arquivo -> TarefasDaConversaGeral? in
            let tarefas = TarefasGeraisStore.carregar(arquivo)
                .sorted(by: ordenarPorDeadline)
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
        return filtradasPorSelecao.compactMap { conversa in
            let tarefas = conversa.tarefas.filter {
                conversa.titulo.localizedCaseInsensitiveContains(termo)
                    || $0.titulo.localizedCaseInsensitiveContains(termo)
                    || $0.origem.localizedCaseInsensitiveContains(termo)
                    || ($0.responsavel?.localizedCaseInsensitiveContains(termo) ?? false)
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

        return filtradas.sorted { primeira, segunda in
            switch ordenacao {
            case .deadline:
                return ordenarPorDeadline(primeira.tarefa, segunda.tarefa)
            case .prioridade:
                let prioridadeA = prioridadeOrdenacao(primeira.tarefa.prioridade)
                let prioridadeB = prioridadeOrdenacao(segunda.tarefa.prioridade)
                if prioridadeA != prioridadeB { return prioridadeA < prioridadeB }
                return ordenarPorDeadline(primeira.tarefa, segunda.tarefa)
            }
        }
    }

    private var tarefasDePrioridadeAlta: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.prioridade == .alta && $0.tarefa.status != .concluida }
    }

    private var tarefasEmAndamento: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status == .emAndamento && $0.tarefa.prioridade != .alta }
    }

    private var tarefasConcluidas: [TarefaGeral] {
        tarefasVisiveis.filter { $0.tarefa.status == .concluida }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    Text("Painel de Tarefas")
                        .font(PapagaioTema.Tipo.tituloDePagina)
                        .foregroundStyle(PapagaioTema.texto)

                    Text("Gerencie as ações geradas a partir das suas conversas.")
                        .font(.title3)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                if tarefasPorConversa.isEmpty {
                    CartaoDeEstadoVazio(
                        simbolo: "list.clipboard",
                        titulo: "Nenhuma tarefa ainda",
                        mensagem: "Quando uma conversa tiver próximos passos ou tarefas criadas, elas ficarão reunidas nesta página."
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .cartaoPapagaio()
                } else {
                    seletorDeConversas
                    kanbanDeTarefas
                }
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
        }
        .background(PapagaioTema.fundo)
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
            .help("Adicionar tarefa")
            .disabled(conversas.isEmpty)
        }
        .sheet(isPresented: $exibindoEditor) {
            EditorDeTarefaGeralSheet(
                modo: tarefaEmEdicao == nil ? .criacao : .edicao,
                conversas: conversas,
                conversaSelecionada: $conversaDoEditor,
                titulo: $tituloDoEditor,
                responsavel: $responsavelDoEditor,
                prioridade: $prioridadeDoEditor,
                status: $statusDoEditor,
                prazo: $prazoDoEditor,
                aoCancelar: { exibindoEditor = false },
                aoSalvar: salvarTarefaDoEditor
            )
        }
    }

    private var seletorDeConversas: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Todas as conversas")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                if !conversasSelecionadas.isEmpty {
                    Button("Limpar seleção") {
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
                HStack(spacing: PapagaioTema.Espaco.medio) {
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
            HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
                Label(tituloDoKanban, systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PapagaioTema.texto)

                Text("\(tarefasVisiveis.count) \(tarefasVisiveis.count == 1 ? "Tarefa" : "Tarefas")")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .padding(.horizontal, PapagaioTema.Espaco.medio)
                    .padding(.vertical, PapagaioTema.Espaco.minimo)
                    .background(PapagaioTema.superficieSuave, in: Capsule())

                Spacer()

                Menu {
                    Button("Todas") { prioridadeSelecionada = nil }
                    ForEach(PrioridadeDaTarefa.allCases, id: \.self) { prioridade in
                        Button(prioridade.rawValue) { prioridadeSelecionada = prioridade }
                    }
                } label: {
                    Label(prioridadeSelecionada?.rawValue ?? "Prioridade", systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: prioridadeSelecionada != nil))

                Menu {
                    Button("Todas") { filtroDeDeadline = .todas }
                    Divider()
                    ForEach(FiltroDeDeadlineTarefa.allCases.filter { $0 != .todas }, id: \.self) { filtro in
                        Button(filtro.titulo) { filtroDeDeadline = filtro }
                    }
                } label: {
                    Label(filtroDeDeadline.titulo, systemImage: filtroDeDeadline.simbolo)
                }
                .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: filtroDeDeadline != .todas))

            }

            if tarefasVisiveis.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "magnifyingglass",
                    titulo: "Nenhuma tarefa encontrada",
                    mensagem: "Tente limpar a seleção ou buscar por outra conversa."
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                .cartaoPapagaio()
            } else {
                // `AnyLayout` decidido pela largura medida, e não `ViewThatFits`:
                // o quadro tem de empilhar quando a *janela* aperta, nunca por
                // causa do texto que está dentro dele. Ver `cabeEmColunas`.
                let arranjo = cabeEmColunas
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: PapagaioTema.Espaco.largo))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: PapagaioTema.Espaco.largo))

                arranjo {
                    coluna(titulo: "Prioridade alta", cor: PapagaioTema.perigo, tarefas: tarefasDePrioridadeAlta)
                    coluna(titulo: "Em andamento", cor: PapagaioTema.destaque, tarefas: tarefasEmAndamento)
                    coluna(titulo: "Concluídas", cor: PapagaioTema.textoSecundario, tarefas: tarefasConcluidas)
                }
            }
        }
        // Medido no bloco inteiro, que ocupa a mesma largura nos dois arranjos.
        // Medir o próprio quadro faria a escolha depender do que ela produziu.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larguraDoQuadro = $0 }
    }

    /// Largura mínima em que um cartão de tarefa ainda se lê: abaixo disso o
    /// título quebra em quatro linhas e a data desgruda do responsável.
    private static let larguraMinimaDaColuna: CGFloat = 280

    /// As três colunas lado a lado só quando a janela realmente as comporta.
    ///
    /// Isto era um `ViewThatFits`, que escolhe pelo tamanho *ideal* do conteúdo
    /// — e o ideal de um texto é a linha inteira sem quebrar. Bastava uma tarefa
    /// de título longo mudar de coluna para o total estourar e o quadro inteiro
    /// desabar numa coluna só, sem a janela ter mudado de tamanho. Era esse o
    /// "bug ao concluir": concluir movia um cartão comprido para as Concluídas.
    private var cabeEmColunas: Bool {
        // Antes da primeira medida, assume que cabe: a janela padrão comporta.
        guard let larguraDoQuadro else { return true }
        return larguraDoQuadro >= Self.larguraMinimaDaColuna * 3 + PapagaioTema.Espaco.largo * 2
    }

    private var tituloDoKanban: String {
        if conversasSelecionadas.count == 1,
           let selecionada = conversasVisiveis.first {
            return selecionada.titulo
        }
        return conversasSelecionadas.isEmpty ? "Todas as tarefas" : "\(conversasSelecionadas.count) conversas selecionadas"
    }

    private func coluna(titulo: String, cor: Color, tarefas: [TarefaGeral]) -> some View {
        ColunaDeTarefasGerais(
            titulo: titulo,
            cor: cor,
            tarefas: tarefas,
            aoEditar: abrirEdicao,
            aoAlternarConclusao: alternarConclusao,
            aoExcluir: excluirTarefa,
            aoMover: moverTarefa
        )
            .frame(maxWidth: .infinity, alignment: .top)
    }

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
        tarefaEmEdicao = nil
        conversaDoEditor = conversasSelecionadas.first ?? conversas.first?.id
        tituloDoEditor = ""
        responsavelDoEditor = ""
        prioridadeDoEditor = .media
        statusDoEditor = .emAndamento
        prazoDoEditor = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        exibindoEditor = true
    }

    private func abrirEdicao(_ tarefa: TarefaGeral) {
        tarefaEmEdicao = tarefa
        conversaDoEditor = tarefa.conversa.id
        tituloDoEditor = tarefa.tarefa.titulo
        responsavelDoEditor = tarefa.tarefa.responsavel ?? ""
        prioridadeDoEditor = tarefa.tarefa.prioridade
        statusDoEditor = tarefa.tarefa.status
        prazoDoEditor = tarefa.tarefa.prazo ?? Date()
        exibindoEditor = true
    }

    private func salvarTarefaDoEditor() {
        guard let conversaID = conversaDoEditor,
              let arquivo = conversas.first(where: { $0.id == conversaID })
        else { return }

        let titulo = tituloDoEditor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titulo.isEmpty else { return }

        var tarefas = TarefasGeraisStore.carregar(arquivo)
        let tarefaAtualizada = TarefaDaConversa(
            id: tarefaEmEdicao?.tarefa.id ?? UUID(),
            titulo: titulo,
            origem: arquivo.resumo?.titulo ?? arquivo.titulo,
            prioridade: prioridadeDoEditor,
            status: statusDoEditor,
            responsavel: responsavelDoEditor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : responsavelDoEditor,
            prazo: prazoDoEditor
        )

        if let tarefaEmEdicao,
           let indice = tarefas.firstIndex(where: { $0.id == tarefaEmEdicao.tarefa.id }) {
            tarefas[indice] = tarefaAtualizada
        } else {
            tarefas.append(tarefaAtualizada)
        }

        TarefasGeraisStore.salvar(tarefas, para: conversaID)
        versaoDasTarefas += 1
        exibindoEditor = false
    }

    private func alternarConclusao(_ tarefa: TarefaGeral) {
        atualizar(tarefa) { editada in
            editada.status = editada.status == .concluida ? .emAndamento : .concluida
        }
    }

    private func moverTarefa(_ id: String, para destino: DestinoDeTarefa) {
        guard let tarefa = tarefasVisiveis.first(where: { $0.id == id }) else { return }
        atualizar(tarefa) { editada in
            editada.status = destino.status
            if let prioridade = destino.prioridade {
                editada.prioridade = prioridade
            }
        }
    }

    private func excluirTarefa(_ tarefa: TarefaGeral) {
        guard let arquivo = conversas.first(where: { $0.id == tarefa.conversa.id }) else { return }
        let tarefas = TarefasGeraisStore.carregar(arquivo).filter { $0.id != tarefa.tarefa.id }
        TarefasGeraisStore.salvar(tarefas, para: tarefa.conversa.id)
        LixeiraDeTarefas.mover(
            tarefa.tarefa,
            arquivoID: tarefa.conversa.id,
            conversaTitulo: tarefa.conversa.titulo
        )
        versaoDasTarefas += 1
    }

    private func atualizar(_ tarefa: TarefaGeral, alteracao: (inout TarefaDaConversa) -> Void) {
        guard let arquivo = conversas.first(where: { $0.id == tarefa.conversa.id }) else { return }
        var tarefas = TarefasGeraisStore.carregar(arquivo)
        guard let indice = tarefas.firstIndex(where: { $0.id == tarefa.tarefa.id }) else { return }
        alteracao(&tarefas[indice])
        TarefasGeraisStore.salvar(tarefas, para: tarefa.conversa.id)
        versaoDasTarefas += 1
    }

    private func ordenarPorDeadline(_ primeira: TarefaDaConversa, _ segunda: TarefaDaConversa) -> Bool {
        switch (primeira.prazo, segunda.prazo) {
        case let (a?, b?):
            if a != b { return a < b }
            if primeira.prioridade != segunda.prioridade {
                return prioridadeOrdenacao(primeira.prioridade) < prioridadeOrdenacao(segunda.prioridade)
            }
            return primeira.titulo.localizedCaseInsensitiveCompare(segunda.titulo) == .orderedAscending
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return primeira.titulo.localizedCaseInsensitiveCompare(segunda.titulo) == .orderedAscending
        }
    }

    private func prioridadeOrdenacao(_ prioridade: PrioridadeDaTarefa) -> Int {
        switch prioridade {
        case .alta: 0
        case .media: 1
        case .baixa: 2
        }
    }
}
