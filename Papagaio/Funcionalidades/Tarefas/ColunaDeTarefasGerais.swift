import SwiftUI

struct ColunaDeTarefasGerais: View {
    let titulo: String
    let cor: Color
    let tarefas: [TarefaGeral]
    /// Para onde uma tarefa vai ao ser solta nesta coluna.
    ///
    /// Vem de quem monta a coluna, e não adivinhado do `titulo` por texto: a
    /// adivinhação já causou uma coluna "Prioridade alta" sobrescrever a
    /// prioridade da tarefa, e um título trocado bastaria para o destino errar
    /// de novo silenciosamente.
    let destino: DestinoDeTarefa
    let aoEditar: (TarefaGeral) -> Void
    let aoAlternarConclusao: (TarefaGeral) -> Void
    let aoExcluir: (TarefaGeral) -> Void
    let aoMover: (String, DestinoDeTarefa) -> Void
    /// Quais tarefas (pelo `id` composto) a pessoa escondeu individualmente
    /// — independente da coluna estar oculta ou não.
    let tarefasOcultas: Set<String>
    let aoOcultarTarefa: (TarefaGeral) -> Void
    let compacto: Bool
    /// `false` na coluna "Atrasada": ela não é um status de verdade, é um
    /// recorte calculado (prazo vencido + não concluída) das outras colunas
    /// — soltar uma tarefa ali não teria pra qual status ir. As tarefas
    /// continuam arrastáveis pra fora dela, só não aceita soltura.
    var permiteSoltar = true
    /// Se a lista de cartões desta coluna está recolhida. A tag do
    /// cabeçalho continua sempre visível (com a contagem) — só o conteúdo
    /// abaixo dela some, para o botão de ocultar continuar acessível mesmo
    /// depois de usado.
    let oculta: Bool
    let aoAlternarOcultar: () -> Void
    @State private var recebendoDrop = false

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Circle()
                    .fill(cor)
                    .frame(width: 9, height: 9)

                Text(titulo)
                    .font(.callout.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Text("\(tarefas.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .padding(.vertical, PapagaioTema.Espaco.minimo)
                    .background(PapagaioTema.superficieSuave, in: Capsule())

                Spacer(minLength: PapagaioTema.Espaco.curto)

                Button(action: aoAlternarOcultar) {
                    Image(systemName: oculta ? "eye.slash" : "eye")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(oculta ? "Mostrar coluna %@".localized(titulo) : "Ocultar coluna %@".localized(titulo))
            }
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(PapagaioTema.superficie.opacity(0.48), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

            if oculta {
                // Recolhida, mas continua soltável: sem isto a área que
                // aceita arraste encolhia pra só a faixinha da própria tag
                // (pouco mais de 30pt) — dava pra soltar aqui, só que era
                // difícil acertar. Esta faixa mantém um alvo do tamanho de
                // sempre, coerente com o `.dropDestination` que já envolve
                // a coluna inteira (ver o fim do arquivo).
                if permiteSoltar {
                    Text("Coluna recolhida — pode soltar aqui.".localized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            recebendoDrop ? cor.opacity(0.12) : PapagaioTema.superficie.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        )
                }
            } else {
            VStack(spacing: compacto ? PapagaioTema.Espaco.curto : PapagaioTema.Espaco.medio) {
                if tarefas.isEmpty {
                    Text("Solte uma tarefa aqui.".localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(maxWidth: .infinity, minHeight: compacto ? 44 : 72)
                        .background(PapagaioTema.superficie.opacity(0.45), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                } else {
                    ForEach(tarefas) { tarefa in
                        CartaoDeTarefaGeral(
                            tarefa: tarefa,
                            aoEditar: { aoEditar(tarefa) },
                            aoAlternarConclusao: { aoAlternarConclusao(tarefa) },
                            aoExcluir: { aoExcluir(tarefa) },
                            oculta: tarefasOcultas.contains(tarefa.id),
                            aoOcultar: { aoOcultarTarefa(tarefa) }
                        )
                        .draggable(tarefa.id)
                    }
                }

                if compacto && permiteSoltar {
                    // Em modo vertical a coluna encolhe para a altura dos
                    // cards. Sem esta faixa, só alguns poucos pixels viravam
                    // destino de soltura e mover uma tarefa era impreciso.
                    // Some quando a coluna não aceita soltura (Atrasada).
                    Label("Arraste uma tarefa para cá".localized, systemImage: "arrow.down.to.line")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            recebendoDrop ? cor.opacity(0.12) : PapagaioTema.superficie.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        )
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compacto ? 0 : 320, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, minHeight: oculta ? 0 : (compacto ? 0 : 390), alignment: .top)
        // Só vertical — na horizontal, este recuo desalinhava a tarja dos
        // cartões (e o próprio cabeçalho "NÃO INICIADO") em relação a tudo
        // mais na página: "Todas as tarefas" acima, os cards de conversa,
        // a margem da própria janela. Sem ele, a borda esquerda da coluna
        // cai exatamente onde cai a de todo o resto.
        //
        // Padding vertical fixo: alternar 0/10 no `isTargeted` remedia a
        // coluna inteira a cada entrada e saída do cursor, e era isso que
        // travava o arrasto.
        .padding(.vertical, compacto ? 4 : 10)
        .contentShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .background(
            recebendoDrop ? cor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
        )
        .modifier(SoltaTarefaGeral(ativo: permiteSoltar, recebendoDrop: $recebendoDrop) { id in
            aoMover(id, destino)
        })
    }
}

/// Isola o `.dropDestination` atrás de um `if`/`else` de verdade: aplicar o
/// modificador condicionalmente com `.modifier(ativo ? ... : ...)` exige que
/// os dois ramos sejam o mesmo tipo concreto, e aqui um ramo tem
/// `.dropDestination` e o outro não — tipos diferentes. Um `ViewModifier`
/// com `@ViewBuilder` resolve isso do mesmo jeito que os outros casos
/// parecidos nesta sessão.
private struct SoltaTarefaGeral: ViewModifier {
    let ativo: Bool
    @Binding var recebendoDrop: Bool
    let aoSoltar: (String) -> Void

    func body(content: Content) -> some View {
        if ativo {
            content.dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                aoSoltar(id)
                return true
            } isTargeted: { ativo in
                recebendoDrop = ativo
            }
        } else {
            content
        }
    }
}
