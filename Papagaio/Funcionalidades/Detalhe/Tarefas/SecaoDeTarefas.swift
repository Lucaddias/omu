import SwiftUI

/// Uma seção do quadro de tarefas de uma conversa — mesmo desenho da coluna
/// do Painel de Tarefas geral (`ColunaDeTarefasGerais`), incluindo a tag do
/// cabeçalho com contagem e o botão de olho pra recolher a lista de
/// cartões sem perder o alvo de soltura.
struct SecaoDeTarefas: View {
    let titulo: String
    let cor: Color
    let tarefas: [TarefaDaConversa]
    let destino: DestinoDeTarefa
    let aoAlternarConclusao: (TarefaDaConversa) -> Void
    let aoEditar: (TarefaDaConversa) -> Void
    let aoMover: (UUID, DestinoDeTarefa) -> Void
    /// Quais tarefas (pelo `uuidString`) a pessoa escondeu individualmente
    /// — independente da seção estar oculta ou não. Ver `CartaoDeTarefaGeral`
    /// e `TarefasOcultasStore` no Painel de Tarefas geral.
    let tarefasOcultas: Set<String>
    let aoOcultarTarefa: (TarefaDaConversa) -> Void
    /// Se a lista de cartões desta seção está recolhida. A tag do
    /// cabeçalho continua sempre visível (com a contagem) — só o conteúdo
    /// abaixo dela some.
    let oculta: Bool
    let aoAlternarOcultar: () -> Void
    @State private var recebendoDrop = false

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Circle()
                    .fill(cor)
                    .frame(width: 10, height: 10)

                Text(titulo)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(PapagaioTema.texto)

                Text("\(tarefas.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 26, height: 26)
                    .background(PapagaioTema.superficieSuave, in: Circle())

                if !oculta {
                    Text("Arraste tarefas para cá".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer(minLength: PapagaioTema.Espaco.curto)

                Button(action: aoAlternarOcultar) {
                    Image(systemName: oculta ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(oculta ? "Mostrar seção %@".localized(titulo) : "Ocultar seção %@".localized(titulo))
            }
            .padding(.leading, PapagaioTema.Espaco.curto)

            if oculta {
                // Recolhida, mas continua soltável: mesma faixa fina do
                // Painel de Tarefas geral, coerente com o `.dropDestination`
                // que envolve a seção inteira (ver o fim do arquivo).
                Text("Seção recolhida — pode soltar aqui.".localized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        recebendoDrop ? cor.opacity(0.12) : PapagaioTema.superficie.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    )
            } else {
                VStack(spacing: PapagaioTema.Espaco.curto) {
                    if tarefas.isEmpty {
                        Text("Solte uma tarefa aqui para mudar para %@.".localized(titulo.lowercased()))
                            .font(.callout)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background(PapagaioTema.superficie.opacity(0.45), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                    }

                    ForEach(tarefas) { tarefa in
                        LinhaDeTarefaDaConversa(
                            tarefa: tarefa,
                            aoAlternarConclusao: { aoAlternarConclusao(tarefa) },
                            aoEditar: { aoEditar(tarefa) },
                            oculta: tarefasOcultas.contains(tarefa.id.uuidString),
                            aoOcultar: { aoOcultarTarefa(tarefa) }
                        )
                        .draggable(tarefa.id.uuidString)
                    }
                }
            }
        }
        // Padding fixo: alternar 0/10 no `isTargeted` remedia a coluna inteira a
        // cada entrada e saída do cursor, e era isso que travava o arrasto.
        .padding(10)
        .background(
            recebendoDrop ? cor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
        )
        .dropDestination(for: String.self) { ids, _ in
            guard let idTexto = ids.first,
                  let id = UUID(uuidString: idTexto)
            else { return false }
            aoMover(id, destino)
            return true
        } isTargeted: { ativo in
            recebendoDrop = ativo
        }
    }
}
