import SwiftUI

struct CartaoDeTarefaGeral: View {
    let tarefa: TarefaGeral
    let aoEditar: () -> Void
    let aoAlternarConclusao: () -> Void
    let aoExcluir: () -> Void
    /// Independente da coluna estar oculta ou não — a pessoa pode querer
    /// tirar de vista uma tarefa específica mesmo dentro de uma coluna que
    /// continua visível. Só aparece de novo com "Mostrar tarefas ocultas"
    /// nos filtros do quadro, meio opaca pra ficar claro que está oculta.
    let oculta: Bool
    let aoOcultar: () -> Void

    private var concluida: Bool { tarefa.tarefa.status == .concluida }

    /// Altura reservada pro bloco título + nome da conversa (2 linhas + 1
    /// linha, ver `.lineLimit` abaixo) — é isto que já deixa todo cartão do
    /// mesmo tamanho, encolhendo ou não o título de verdade. Uma altura
    /// fixa por fora do cartão inteiro (como havia antes) virava sobra vazia
    /// embaixo da prioridade/data em todo cartão com título de uma linha só
    /// — a "brecha" que a pessoa via entre o rodapé e a borda do cartão.
    private static let alturaDoBlocoDeTitulo: CGFloat = 56

    /// A cor da tarja lateral segue o status, não a prioridade — a mesma cor
    /// da coluna em que o cartão está (amarelo, laranja ou verde), para o
    /// cartão continuar dizendo "onde ele está" mesmo fora do quadro
    /// (arrastado, numa busca, etc.). A prioridade continua no selo, que é o
    /// lugar certo pra esse dado.
    ///
    /// Atrasada é exceção: o cartão vive na coluna "Atrasada" (ver
    /// `TarefasView.tarefasAtrasadas`), não na de "Não iniciado"/"Em
    /// andamento" — mas o `status` gravado nele continua sendo um desses
    /// dois, e a tarja seguindo o status literal mostrava amarelo/laranja
    /// dentro da própria coluna vermelha. Vermelho aqui também, coerente com
    /// onde o cartão está de verdade.
    private var corDeStatus: Color {
        atrasada ? PapagaioTema.perigo : tarefa.tarefa.status.cor
    }

    /// Comparando dia com dia, não hora com hora: uma tarefa com prazo hoje
    /// às 23h não devia contar como atrasada às 9h da manhã do próprio dia —
    /// só quando o dia do prazo já ficou pra trás de verdade.
    private var atrasada: Bool {
        guard let prazo = tarefa.tarefa.prazo, !concluida, !tarefa.tarefa.atrasoFoiReconhecido else { return false }
        return Calendar.current.startOfDay(for: prazo) < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            // `.lineLimit` de volta: deixar o texto quebrar livremente fazia
            // cada cartão crescer para uma altura diferente conforme o
            // tamanho do título e do nome da conversa — no quadro lado a
            // lado, isso ficava desalinhado e parecia quebrado. Duas linhas
            // pro título e uma pro nome da conversa dão espaço pra maioria
            // dos casos sem esticar o cartão; o que não couber corta com
            // "...", troca aceitável por todos os cartões terem o mesmo
            // tamanho.
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                // Recuo à direita só na primeira linha do título: o menu
                // "..." virou um overlay no canto do cartão (ver abaixo),
                // em vez de ocupar sua própria fileira em cima — isso é o
                // que devolve o espaço que sobrava vazio no topo. Sem este
                // recuo, uma primeira linha comprida passaria por baixo do
                // botão.
                // `.minimumScaleFactor` antes de recorrer às reticências:
                // um título que quase cabe encolhe um pouco a fonte em vez
                // de cortar — só quando nem encolhido cabe é que aparece o
                // "...".
                Text(tarefa.tarefa.titulo)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(concluida ? PapagaioTema.textoSecundario : PapagaioTema.texto)
                    .strikethrough(concluida, color: PapagaioTema.textoSecundario)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .padding(.trailing, 34)

                Text(tarefa.conversa.titulo)
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
            }
            .frame(minHeight: Self.alturaDoBlocoDeTitulo, alignment: .top)

            // Responsável e status voltaram — mesma informação que já
            // existia na linha de tabela de antes desta sessão, só que
            // faltava nos cartões. Duas colunas, mesmo componente
            // `ColunaDaTarefa` da aba Tarefas de cada conversa.
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.largo) {
                ColunaDaTarefa(rotulo: "Responsável".localized) {
                    responsavelDaTarefa
                }
                ColunaDaTarefa(rotulo: "Status".localized) {
                    seloDeStatus
                }
            }

            // Prioridade e data por último, no rodapé — mesma linha, um de
            // cada lado, como já era.
            HStack {
                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Text("Prioridade:".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                    SeloDePrioridade(prioridade: tarefa.tarefa.prioridade)
                }

                Spacer(minLength: PapagaioTema.Espaco.medio)

                Label(rotuloDoPrazo, systemImage: concluida ? "checkmark.circle" : "calendar")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(corDoPrazo)
            }
        }
        // Recuo extra à esquerda: a tarja de cor mora encostada na borda do
        // cartão, e sem este respiro o texto ficaria colado nela.
        .padding(.leading, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.curto)
        .padding([.top, .trailing, .bottom], PapagaioTema.Espaco.largo)
        // Só `minHeight`, sem `maxHeight`: o bloco de título já reserva uma
        // altura fixa pra si mesmo (ver `alturaDoBlocoDeTitulo`), então o
        // cartão inteiro já sai do mesmo tamanho na prática — sem precisar
        // de uma altura fixa por fora que sobrava vazia embaixo da
        // prioridade/data em cartões de título curto, e que cortava (via
        // `.clipShape` abaixo) um título de duas linhas mais a Ata mais
        // comprida do que o previsto.
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        // Mesmo raio de todo cartão do app — o de "controle" (8pt, botão e
        // campo) fazia este cartão parecer um componente pequeno, não a
        // mesma superfície do cartão de conversa ao lado dele na Biblioteca.
        .cartaoPapagaio()
        .overlay(alignment: .topTrailing) {
            // Ele saiu de dentro do `VStack` (onde ocupava uma fileira só
            // pra si, empurrando todo o resto do cartão pra baixo) e virou
            // um overlay solto no canto — o mesmo espaço que ele ocupava
            // sozinho antes de mais nada agora é o próprio respiro do
            // título com o topo do cartão.
            Menu {
                Button("Editar".localized, systemImage: "pencil", action: aoEditar)
                Button(oculta ? "Mostrar".localized : "Ocultar".localized, systemImage: oculta ? "eye" : "eye.slash", action: aoOcultar)
                // "Marcar concluída" saiu daqui: com três colunas agora, o
                // gesto que muda o status é arrastar o cartão até a que
                // representa o novo estado — este atalho pulava direto
                // para Concluída, sem passar por Em andamento.
                Button("Excluir".localized, systemImage: "trash", role: .destructive, action: aoExcluir)
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
            // A cor da coluna virou tarja: antes só o selo de prioridade
            // dizia algo colorido, e as três colunas do quadro ficavam
            // visualmente idênticas — só o rótulo de texto separava uma da
            // outra.
            Rectangle()
                .fill(corDeStatus)
                .frame(width: 4)
        }
        // Depois da tarja, e não antes: é o `.clipShape` no fim da cadeia
        // que arredonda a pontinha dela junto com o resto do cartão — antes
        // dele, a tarja é um retângulo reto que escapava dos cantos.
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        .shadow(color: PapagaioTema.destaque.opacity(0.08), radius: 10, y: 6)
        // Só aparece opaca de novo se "Mostrar tarefas ocultas" também
        // estiver ligado (senão nem chega a renderizar) — aqui é só o
        // sinal visual de que esta em particular está marcada como oculta.
        .opacity(oculta ? 0.5 : 1)
    }

    /// Mesmo tratamento de `LinhaDeTarefaDaConversa.responsavelDaTarefa`:
    /// avatar com iniciais e nome, ou o aviso de "sem responsável".
    private var responsavelDaTarefa: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            if let responsavel = tarefa.tarefa.responsavelValido {
                AvatarDePessoa(nome: responsavel, diametro: 26)

                Text(responsavel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 26, height: 26)

                Text("Sem responsável".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    /// "Atrasada" no lugar do status literal quando o prazo já passou — mesmo
    /// tratamento de `LinhaDeTarefaDaConversa.seloDeStatus`.
    private var seloDeStatus: some View {
        Group {
            if atrasada {
                Text("Atrasada".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.perigo)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.perigo.opacity(0.12), in: Capsule())
            } else {
                SeloDeStatusDaTarefa(status: tarefa.tarefa.status)
            }
        }
    }

    private var rotuloDoPrazo: String {
        guard let prazo = tarefa.tarefa.prazo else { return "Sem deadline".localized }
        if Calendar.current.isDateInToday(prazo) { return "Hoje".localized }
        if Calendar.current.isDateInTomorrow(prazo) { return "Amanhã".localized }
        return prazo.formatted(.dateTime.day().month().year())
    }

    private var corDoPrazo: Color {
        guard let prazo = tarefa.tarefa.prazo, !concluida else { return PapagaioTema.textoSecundario }
        if prazo <= Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date() {
            return PapagaioTema.perigo
        }
        return PapagaioTema.textoSecundario
    }
}
