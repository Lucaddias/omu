import SwiftUI

struct CartaoFiltroDeConversaTarefa: View {
    let conversa: TarefasDaConversaGeral
    let selecionado: Bool
    let vencimento: Date?
    let acao: () -> Void

    /// A mesma cor do cartão desta conversa na Biblioteca — não o status das
    /// tarefas. Este cartão é um atalho para "a conversa X", e a pessoa já
    /// reconhece essa conversa pela cor dela lá; uma cor diferente aqui era
    /// a mesma conversa parecendo duas coisas em duas telas.
    ///
    /// Mesma prioridade de `CartaoDeConversa.corDaTarjaLateral`: pasta vence
    /// tudo, depois a cor escolhida à mão, e só na ausência das duas cai no
    /// acento padrão da marca.
    private var corDeIdentidade: Color {
        let id = conversa.arquivo.id
        if let pasta = PreferenciasVisuaisDoArquivo.pasta(id) {
            return AparenciaDasPastas.corResolvida(de: pasta).acentoSobreSuperficie
        }
        if AparenciaDoCartao.semCor(id) {
            return PapagaioTema.destaqueEscuro
        }
        if let escolhida = AparenciaDoCartao.cor(id) {
            return escolhida.acentoSobreSuperficie
        }
        return PapagaioTema.destaqueEscuro
    }

    var body: some View {
        Button(action: acao) {
            HStack(spacing: PapagaioTema.Espaco.medio) {
                // O ícone leva a mesma cor da tarja — os dois dizem a mesma
                // coisa, o status geral das tarefas desta conversa, e não
                // fazia sentido um estar colorido e o outro cinza. Vale
                // selecionado ou não: o acento genérico da marca não tinha
                // relação nenhuma com a identidade da própria conversa.
                Image(systemName: simbolo)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(corDeIdentidade)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    // Sem `.lineLimit`: um título de conversa comprido não
                    // pode virar "..." — ver o mesmo ajuste em
                    // `CartaoDeTarefaGeral`. O cartão cresce em altura (a
                    // largura continua fixa, é uma fileira de pastilhas do
                    // mesmo tamanho) em vez de esconder o nome.
                    Text(conversa.titulo)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(selecionado ? corDeIdentidade : PapagaioTema.texto)

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                        Label("\(conversa.tarefas.count) \(conversa.tarefas.count == 1 ? "Tarefa".localized : "Tarefas".localized)", systemImage: "list.clipboard")

                        if let vencimento {
                            Label(rotuloDoVencimento(vencimento), systemImage: "calendar")
                        } else {
                            Label("Sem data".localized, systemImage: "calendar.badge.clock")
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            // Recuo extra à esquerda para o conteúdo não encostar na tarja.
            .padding(.leading, PapagaioTema.Espaco.curto)
            // `.frame(width:minHeight:)` mistura os dois overloads de
            // `.frame` que não se misturam (o de tamanho fixo `width:height:`
            // e o flexível `minWidth:...:minHeight:...`) — daí o "extra
            // argument". `minWidth`/`maxWidth` iguais fixam a largura do
            // mesmo jeito que `width:` fixaria.
            .frame(minWidth: 254, maxWidth: 254, minHeight: 82, alignment: .leading)
            .background(selecionado ? PapagaioTema.destaqueSuave.opacity(0.82) : PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay(alignment: .leading) {
                // A tarja resume o status das tarefas desta conversa — a
                // mesma identidade que o quadro usa, só que numa pastilha.
                Rectangle().fill(corDeIdentidade).frame(width: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(selecionado ? PapagaioTema.destaque : PapagaioTema.borda, lineWidth: selecionado ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            // Sem isto, só o texto e o ícone respondiam ao clique — o vazio
            // à direita do `Spacer` (boa parte do cartão) não abria nada.
            // O cartão inteiro precisa ser o alvo, não só onde há pixel
            // desenhado.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selecionado ? "Desmarcar %@".localized(conversa.titulo) : "Marcar %@".localized(conversa.titulo))
    }

    // Balão de chat: este cartão representa a conversa (quem gerou as
    // tarefas), não as tarefas em si — esse ícone é o do quadro logo abaixo.
    private var simbolo: String {
        selecionado ? "bubble.left.and.text.bubble.right.fill" : "bubble.left"
    }

    /// Rótulo derivado: menor prazo entre as não-concluídas, não a data da
    /// conversa. "Vence" deixa isso explícito — "Hoje" sozinho parecia que
    /// mover no Kanban reescrevia a data.
    private func rotuloDoVencimento(_ data: Date) -> String {
        if Calendar.current.isDateInToday(data) { return "Vence hoje".localized }
        if Calendar.current.isDateInTomorrow(data) { return "Vence amanhã".localized }
        return data.formatted(.dateTime.day().month(.abbreviated))
    }
}
