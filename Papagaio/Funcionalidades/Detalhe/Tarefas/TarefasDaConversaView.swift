import SwiftUI

struct TarefasDaConversaView: View {
    let tarefas: [TarefaDaConversa]
    /// Sugestões da IA ainda não revisadas — não fazem parte de `tarefas`
    /// (que já vem só com as aceitas) e ganham uma seção própria acima do
    /// quadro, ver `secaoDeSugestoes`.
    let sugestoes: [TarefaDaConversa]
    @Binding var filtro: FiltroDeTarefas
    let aoAdicionar: () -> Void
    let aoAlternarConclusao: (TarefaDaConversa) -> Void
    let aoEditar: (TarefaDaConversa) -> Void
    let aoMover: (UUID, DestinoDeTarefa) -> Void
    let aoAceitarSugestao: (TarefaDaConversa) -> Void
    let aoEditarSugestao: (TarefaDaConversa) -> Void
    let aoRejeitarSugestao: (TarefaDaConversa) -> Void

    /// Botão de olho por seção, herdado do Painel de Tarefas geral.
    @AppStorage("ocultarSecaoNaoIniciado") private var ocultarSecaoNaoIniciado = false
    @AppStorage("ocultarSecaoEmAndamento") private var ocultarSecaoEmAndamento = false
    @AppStorage("ocultarSecaoConcluidas") private var ocultarSecaoConcluidas = false
    @AppStorage("ocultarSecaoAtrasada") private var ocultarSecaoAtrasada = false
    @State private var tarefasOcultas: Set<String> = TarefasOcultasStore.carregar()
    /// Sem isto ligado, uma tarefa oculta some do quadro por completo — não
    /// dava pra saber que existia, nem pra desmarcá-la de volta. Mesmo par
    /// do Painel de Tarefas geral (ver `TarefasView`).
    @AppStorage("mostrarTarefasOcultasDaConversa") private var mostrarTarefasOcultas = false

    private var tarefasFiltradas: [TarefaDaConversa] {
        switch filtro {
        case .tudo:
            tarefas
        case .naoIniciado:
            tarefas.filter { $0.status == .naoIniciado && !atrasada($0) }
        case .emAndamento:
            tarefas.filter { $0.status == .emAndamento && !atrasada($0) }
        case .concluidas:
            tarefas.filter { $0.status == .concluida }
        case .atrasadas:
            tarefas.filter { $0.status != .concluida && atrasada($0) }
        }
    }

    private var tarefasVisiveis: [TarefaDaConversa] {
        mostrarTarefasOcultas
            ? tarefasFiltradas
            : tarefasFiltradas.filter { !tarefasOcultas.contains($0.id.uuidString) }
    }

    private var tarefasOcultasNestaConversa: Int {
        tarefas.lazy.filter { tarefasOcultas.contains($0.id.uuidString) }.count
    }

    private var naoIniciadas: [TarefaDaConversa] {
        tarefasVisiveis.filter { $0.status == .naoIniciado && !atrasada($0) }
    }

    private var emAndamento: [TarefaDaConversa] {
        tarefasVisiveis.filter { $0.status == .emAndamento && !atrasada($0) }
    }

    private var concluidas: [TarefaDaConversa] {
        tarefasVisiveis.filter { $0.status == .concluida }
    }

    /// Recorte, não status: reúne "Não iniciado" e "Em andamento" com prazo
    /// vencido, tirando as duas de onde estariam normalmente — mesma
    /// lógica de `TarefasView.tarefasAtrasadas`.
    private var atrasadas: [TarefaDaConversa] {
        tarefasVisiveis.filter { $0.status != .concluida && atrasada($0) }
    }

    /// Dia contra dia, não hora contra hora — mesmo critério de
    /// `CartaoDeTarefaGeral.atrasada`. Já reconhecida (a pessoa arrastou
    /// pra uma coluna de status manualmente) nunca conta como atrasada,
    /// mesmo com o prazo ainda vencido — ver `TarefaDaConversa.atrasoReconhecido`.
    private func atrasada(_ tarefa: TarefaDaConversa) -> Bool {
        guard let prazo = tarefa.prazo, tarefa.status != .concluida, !tarefa.atrasoFoiReconhecido else { return false }
        return Calendar.current.startOfDay(for: prazo) < Calendar.current.startOfDay(for: Date())
    }

    private func alternarOcultarTarefa(_ tarefa: TarefaDaConversa) {
        let chave = tarefa.id.uuidString
        if tarefasOcultas.contains(chave) {
            tarefasOcultas.remove(chave)
        } else {
            tarefasOcultas.insert(chave)
        }
        TarefasOcultasStore.salvar(tarefasOcultas)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            if !sugestoes.isEmpty {
                SecaoDeSugestoesDeTarefa(
                    sugestoes: sugestoes,
                    aoAceitar: aoAceitarSugestao,
                    aoEditar: aoEditarSugestao,
                    aoRejeitar: aoRejeitarSugestao
                )
            }

            HStack(alignment: .center, spacing: PapagaioTema.Espaco.medio) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PapagaioTema.Espaco.curto) {
                    ForEach(FiltroDeTarefas.allCases) { opcao in
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                filtro = opcao
                            }
                        } label: {
                            Text(opcao.titulo)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(filtro == opcao ? PapagaioTema.textoSobrePrimario : PapagaioTema.textoSecundario)
                                .padding(.horizontal, PapagaioTema.Espaco.largo)
                                .frame(height: PapagaioTema.Altura.padrao)
                                .background(
                                    filtro == opcao ? PapagaioTema.preenchimentoPrimario : PapagaioTema.superficie,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(filtro == opcao ? Color.clear : PapagaioTema.borda, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // O conteúdo das tags tem largura intrínseca. Sem limitar o
                // viewport, ele tomava o espaço do botão de criar e a última
                // tag acabava cortada, em vez de poder ser rolada.
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

                if tarefasOcultasNestaConversa > 0 {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            mostrarTarefasOcultas.toggle()
                        }
                    } label: {
                        Label(
                            mostrarTarefasOcultas ? "\(tarefasOcultasNestaConversa) \("ocultas".localized)" : "Ocultas".localized,
                            systemImage: mostrarTarefasOcultas ? "eye" : "eye.slash"
                        )
                    }
                    .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: mostrarTarefasOcultas))
                    .help(mostrarTarefasOcultas ? "Esconder de novo as tarefas ocultas".localized : "Mostrar as tarefas ocultas".localized)
                    .layoutPriority(1)
                }

                Button(action: aoAdicionar) {
                    Image(systemName: "plus")
                        // Altura.destaque (44) é a medida do sistema para ação
                        // principal/alvo mínimo — o 48 de antes vivia fora da
                        // escala que o próprio botão deveria exemplificar.
                        .font(.title2.weight(.medium))
                        .foregroundStyle(PapagaioTema.textoSobrePrimario)
                        .frame(width: PapagaioTema.Altura.destaque, height: PapagaioTema.Altura.destaque)
                        .background(PapagaioTema.preenchimentoPrimario, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Adicionar tarefa".localized)
                .accessibilityLabel("Adicionar tarefa".localized)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if tarefasVisiveis.isEmpty && sugestoes.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "list.clipboard",
                    titulo: "Nenhuma tarefa aqui".localized,
                    mensagem: "Use o botão de adicionar para criar uma tarefa nesta conversa.".localized
                )
                .frame(minHeight: 280)
                .cartaoPapagaio()
            } else {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                    secoesVisiveis
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var secoesVisiveis: some View {
        switch filtro {
        case .tudo:
            secaoNaoIniciado(tarefas: naoIniciadas)
            secaoEmAndamento(tarefas: emAndamento)
            secaoConcluidas(tarefas: concluidas)
            // Por último, logo abaixo de "Concluídas".
            secaoAtrasada(tarefas: atrasadas)
        case .naoIniciado:
            secaoNaoIniciado(tarefas: tarefasVisiveis)
        case .emAndamento:
            secaoEmAndamento(tarefas: tarefasVisiveis)
        case .concluidas:
            secaoConcluidas(tarefas: tarefasVisiveis)
        case .atrasadas:
            secaoAtrasada(tarefas: tarefasVisiveis)
        }
    }

    private func secaoNaoIniciado(tarefas: [TarefaDaConversa]) -> some View {
        SecaoDeTarefas(
            titulo: "Não iniciado".localized,
            cor: PapagaioTema.aviso,
            tarefas: tarefas,
            destino: .naoIniciado,
            aoAlternarConclusao: aoAlternarConclusao,
            aoEditar: aoEditar,
            aoMover: aoMover,
            tarefasOcultas: tarefasOcultas,
            aoOcultarTarefa: alternarOcultarTarefa,
            oculta: ocultarSecaoNaoIniciado,
            aoAlternarOcultar: { withAnimation(.snappy(duration: 0.18)) { ocultarSecaoNaoIniciado.toggle() } }
        )
    }

    private func secaoEmAndamento(tarefas: [TarefaDaConversa]) -> some View {
        SecaoDeTarefas(
            titulo: "Em andamento".localized,
            cor: PapagaioTema.destaque,
            tarefas: tarefas,
            destino: .emAndamento,
            aoAlternarConclusao: aoAlternarConclusao,
            aoEditar: aoEditar,
            aoMover: aoMover,
            tarefasOcultas: tarefasOcultas,
            aoOcultarTarefa: alternarOcultarTarefa,
            oculta: ocultarSecaoEmAndamento,
            aoAlternarOcultar: { withAnimation(.snappy(duration: 0.18)) { ocultarSecaoEmAndamento.toggle() } }
        )
    }

    private func secaoConcluidas(tarefas: [TarefaDaConversa]) -> some View {
        SecaoDeTarefas(
            titulo: "Concluídas".localized,
            cor: PapagaioTema.sucesso,
            tarefas: tarefas,
            destino: .concluida,
            aoAlternarConclusao: aoAlternarConclusao,
            aoEditar: aoEditar,
            aoMover: aoMover,
            tarefasOcultas: tarefasOcultas,
            aoOcultarTarefa: alternarOcultarTarefa,
            oculta: ocultarSecaoConcluidas,
            aoAlternarOcultar: { withAnimation(.snappy(duration: 0.18)) { ocultarSecaoConcluidas.toggle() } }
        )
    }

    /// Destino "Não iniciado", igual à coluna "Atrasada" do Painel de
    /// Tarefas geral: se o prazo continuar vencido, o recorte pega a tarefa
    /// de volta pra cá no próximo recálculo; senão ela só vira "Não
    /// iniciado" mesmo.
    private func secaoAtrasada(tarefas: [TarefaDaConversa]) -> some View {
        SecaoDeTarefas(
            titulo: "Atrasada".localized,
            cor: PapagaioTema.perigo,
            tarefas: tarefas,
            destino: .naoIniciado,
            aoAlternarConclusao: aoAlternarConclusao,
            aoEditar: aoEditar,
            aoMover: aoMover,
            tarefasOcultas: tarefasOcultas,
            aoOcultarTarefa: alternarOcultarTarefa,
            oculta: ocultarSecaoAtrasada,
            aoAlternarOcultar: { withAnimation(.snappy(duration: 0.18)) { ocultarSecaoAtrasada.toggle() } }
        )
    }
}
