import SwiftUI

/// A tarefa de uma conversa, no mesmo desenho de cartão do Painel de Tarefas
/// geral — tarja lateral com a cor do status, título no meio, prioridade e
/// data no rodapé, menu "..." no canto (ver `CartaoDeTarefaGeral`, de onde
/// todo esse desenho e os ajustes de espaço vieram).
///
/// Existe para substituir `LinhaDeTarefaDaConversa`, que era uma linha de
/// planilha: título à esquerda e depois prioridade, responsável, status e data
/// em colunas esticando para a direita. Section por section já empilhava na
/// vertical; só a tarefa dentro de cada seção ainda pensava em linha. Aqui ela
/// também não pensa mais.
///
/// Sem o nome da conversa embaixo do título — que o cartão do painel geral
/// mostra porque reúne tarefas de várias conversas ao mesmo tempo. Aqui dentro
/// de uma conversa só, repetir o nome dela em cada cartão seria repetir o
/// título da própria página.
struct CartaoDeTarefaDaConversa: View {
    let tarefa: TarefaDaConversa
    let aoAlternarConclusao: () -> Void
    let aoEditar: () -> Void
    /// Ver o mesmo par em `CartaoDeTarefaGeral`: esconder uma tarefa
    /// específica é independente da seção dela estar oculta ou não.
    let oculta: Bool
    let aoOcultar: () -> Void

    private var concluida: Bool { tarefa.status == .concluida }

    /// Mesma lógica de `CartaoDeTarefaGeral.corDeStatus`: a tarja segue o
    /// status (a cor da seção onde a tarefa está), com atrasada virando
    /// vermelha por cima disso — coerente com a seção "Atrasada" que ela
    /// ocupa nesse caso (ver `TarefasDaConversaView`).
    private var corDeStatus: Color {
        atrasada ? PapagaioTema.perigo : tarefa.status.cor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                botaoConclusao

                // `.minimumScaleFactor` antes das reticências — mesmo
                // ajuste de `CartaoDeTarefaGeral`: encolhe a fonte antes de
                // cortar o título.
                Text(tarefa.titulo)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(concluida ? PapagaioTema.textoSecundario : PapagaioTema.texto)
                    .strikethrough(concluida, color: PapagaioTema.textoSecundario)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .padding(.trailing, 34)
            }

            // Desceu do topo (ao lado do lápis) pra cá, com o rótulo
            // "Prioridade:" por extenso — sozinho, "Média"/"Alta" não dizia
            // do que o selo era. Ver o mesmo ajuste em `CartaoDeTarefaGeral`.
            // Na mesma linha da data, não numa linha só pra ela: prioridade
            // à esquerda, data à direita — as duas informações de rodapé
            // dividindo a mesma altura em vez de empilhar o cartão mais alto.
            //
            // Sem o selo "Atrasada" à parte: a tarja lateral já conta essa
            // história agora (ver `corDeStatus`), igual ao painel geral —
            // duas formas de dizer a mesma coisa competiam por atenção ali.
            HStack {
                if concluida {
                    SeloDeStatusDaTarefa(status: .concluida)
                } else {
                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        Text("Prioridade:".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapagaioTema.textoSecundario)
                        SeloDePrioridade(prioridade: tarefa.prioridade)
                    }
                }

                Spacer(minLength: PapagaioTema.Espaco.medio)

                Label(rotuloDoPrazo, systemImage: concluida ? "checkmark.circle" : "calendar")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(corDoPrazo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        // Recuo extra à esquerda: a tarja de cor mora encostada na borda do
        // cartão, e sem este respiro o texto ficaria colado nela.
        .padding(.leading, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.curto)
        .padding([.top, .trailing, .bottom], PapagaioTema.Espaco.largo)
        // Só `minHeight`, sem `maxHeight` (ver o mesmo ajuste e o motivo em
        // `CartaoDeTarefaGeral`): uma altura fixa por fora sobrava vazia
        // embaixo da prioridade/data em cartões de título curto, e cortava
        // um título de três linhas mais comprido do que o previsto.
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .cartaoPapagaio()
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Editar".localized, systemImage: "pencil", action: aoEditar)
                Button(oculta ? "Mostrar".localized : "Ocultar".localized, systemImage: oculta ? "eye" : "eye.slash", action: aoOcultar)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Ações da tarefa".localized)
            .padding(.trailing, PapagaioTema.Espaco.curto)
            .padding(.top, PapagaioTema.Espaco.curto)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(corDeStatus)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        .shadow(color: PapagaioTema.destaque.opacity(0.08), radius: 10, y: 6)
        .opacity(oculta ? 0.5 : 1)
    }

    private var botaoConclusao: some View {
        Button(action: aoAlternarConclusao) {
            Image(systemName: concluida ? "checkmark.square.fill" : "square")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(concluida ? PapagaioTema.sucesso : PapagaioTema.textoSecundario)
                .padding(.top, 1)
        }
        .buttonStyle(.plain)
        .help(concluida ? "Marcar como em andamento".localized : "Concluir".localized)
    }

    private var rotuloDoPrazo: String {
        guard let prazo = tarefa.prazo else { return "Sem deadline".localized }
        if Calendar.current.isDateInToday(prazo) { return "Hoje".localized }
        if Calendar.current.isDateInTomorrow(prazo) { return "Amanhã".localized }
        return prazo.formatted(.dateTime.day().month().year())
    }

    private var corDoPrazo: Color {
        guard let prazo = tarefa.prazo, !concluida else { return PapagaioTema.textoSecundario }
        if prazo <= Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date() {
            return PapagaioTema.perigo
        }
        return PapagaioTema.textoSecundario
    }

    /// Comparando dia com dia, não hora com hora: ver o mesmo comentário em
    /// `CartaoDeTarefaGeral`.
    private var atrasada: Bool {
        guard let prazo = tarefa.prazo, !concluida, !tarefa.atrasoFoiReconhecido else { return false }
        return Calendar.current.startOfDay(for: prazo) < Calendar.current.startOfDay(for: Date())
    }
}
