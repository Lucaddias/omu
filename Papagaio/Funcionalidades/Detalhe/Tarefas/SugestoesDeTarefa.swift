import SwiftUI

/// Uma tarefa que a IA extraiu da transcrição, ainda não revisada — não
/// entra em nenhum Kanban até a pessoa decidir. Sem coluna de status, sem
/// arrastar: só três ações diretas, porque revisar dez sugestões arrastando
/// cada uma para "Não iniciado" seria mais trabalho do que a IA economizou.
struct LinhaDeSugestaoDeTarefa: View {
    let tarefa: TarefaDaConversa
    let aoAceitar: () -> Void
    let aoEditar: () -> Void
    let aoRejeitar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(tarefa.titulo)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(2)

                // Sem selo de prioridade aqui: é sugestão, ainda não é
                // tarefa de verdade, e prioridade é decisão de quem aceita —
                // não da IA que extraiu o texto da transcrição. Quem quiser
                // definir uma antes de aceitar, edita (botão de lápis).
                if let responsavel = tarefa.responsavelValido {
                    Text(responsavel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: PapagaioTema.Espaco.curto) {
                botao(simbolo: "xmark", ajuda: "Descartar sugestão".localized, cor: PapagaioTema.perigo, acao: aoRejeitar)
                botao(simbolo: "pencil", ajuda: "Editar antes de aceitar".localized, cor: PapagaioTema.textoSecundario, acao: aoEditar)
                botao(simbolo: "checkmark", ajuda: "Aceitar e mandar para o quadro".localized, cor: PapagaioTema.sucesso, preenchido: true, acao: aoAceitar)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .background(PapagaioTema.destaqueSuave.opacity(0.4), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.destaque.opacity(0.3), lineWidth: 1)
        }
    }

    private func botao(simbolo: String, ajuda: String, cor: Color, preenchido: Bool = false, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(preenchido ? PapagaioTema.textoSobrePrimario : cor)
                .frame(width: 30, height: 30)
                .background(preenchido ? cor : cor.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(ajuda)
        .accessibilityLabel(ajuda)
    }
}

/// A seção que agrupa as sugestões pendentes da conversa, no topo da aba
/// Tarefas — antes de qualquer coluna do quadro, porque revisar essas
/// sugestões é o que decide o que vai existir nele.
struct SecaoDeSugestoesDeTarefa: View {
    let sugestoes: [TarefaDaConversa]
    let aoAceitar: (TarefaDaConversa) -> Void
    let aoEditar: (TarefaDaConversa) -> Void
    let aoRejeitar: (TarefaDaConversa) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Text("Sugestões da conversa".localized)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(PapagaioTema.texto)

                Text("\(sugestoes.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 26, height: 26)
                    .background(PapagaioTema.superficieSuave, in: Circle())
            }
            .padding(.leading, PapagaioTema.Espaco.curto)

            Text("Identificadas automaticamente na transcrição. Aceite para mandar para o quadro de tarefas, edite antes de aceitar ou descarte.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .padding(.leading, PapagaioTema.Espaco.curto)

            VStack(spacing: PapagaioTema.Espaco.curto) {
                ForEach(sugestoes) { tarefa in
                    LinhaDeSugestaoDeTarefa(
                        tarefa: tarefa,
                        aoAceitar: { aoAceitar(tarefa) },
                        aoEditar: { aoEditar(tarefa) },
                        aoRejeitar: { aoRejeitar(tarefa) }
                    )
                }
            }
        }
    }
}
