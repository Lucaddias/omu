import SwiftUI

struct LinhaDeTarefaDaConversa: View {
    let tarefa: TarefaDaConversa
    let aoAlternarConclusao: () -> Void
    let aoEditar: () -> Void
    /// Escondida uma a uma, independente da seção — ver `SecaoDeTarefas` e
    /// `TarefasOcultasStore`.
    let oculta: Bool
    let aoOcultar: () -> Void

    /// Largura medida da própria linha — e não mais `ViewThatFits` decidindo
    /// sozinho entre `conteudoHorizontal` e `conteudoCompacto`.
    ///
    /// `tituloDaTarefa` tem `maxWidth: .infinity` (precisa, para esticar
    /// quando sobra espaço) — e é exatamente isso que confundia o
    /// `ViewThatFits`: pedido para testar se `conteudoHorizontal` cabe, ele
    /// media o texto do título sem quebrar linha, não no mínimo de 160pt que
    /// a `.frame` permite. Um título comprido ("Configurar o fluxo de
    /// compilação...") fazia essa largura "ideal" estourar qualquer janela,
    /// e a linha caía pro layout empilhado mesmo numa tela bem larga — com
    /// as duas linhas vizinhas (títulos mais curtos) continuando na
    /// horizontal ao lado dela. Resultado: uma linha bem mais alta que as
    /// outras, sem motivo real de espaço.
    @State private var larguraDaLinha: CGFloat?

    private var concluida: Bool { tarefa.status == .concluida }
    private var dataDoPrazo: String {
        tarefa.prazo?.formatted(.dateTime.day().month().year()) ?? "Sem deadline".localized
    }

    /// Comparando dia com dia, não hora com hora — mesmo critério de
    /// `CartaoDeTarefaGeral.atrasada`. Sem seção própria (ver o motivo em
    /// `TarefasDaConversaView`), mas continua marcada aqui na própria
    /// linha, na coluna que normalmente mostra o status.
    private var atrasada: Bool {
        guard let prazo = tarefa.prazo, !concluida, !tarefa.atrasoFoiReconhecido else { return false }
        return Calendar.current.startOfDay(for: prazo) < Calendar.current.startOfDay(for: Date())
    }

    /// Soma dos mínimos de `conteudoHorizontal`: botão (22) + título (160) +
    /// 4 separadores (1pt cada) + 4 colunas de metadado (96+130+96+104) +
    /// botão de ocultar (34) + botão de editar (34) + os espaços
    /// `Espaco.medio`/`Espaco.minimo` entre os itens vizinhos. Abaixo disso,
    /// `conteudoHorizontal` de verdade não cabe — não é só o título
    /// encolhendo, é tudo espremido.
    private static let larguraMinimaHorizontal: CGFloat = 830

    var body: some View {
        Group {
            if let larguraDaLinha, larguraDaLinha < Self.larguraMinimaHorizontal {
                conteudoCompacto
            } else {
                conteudoHorizontal
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larguraDaLinha = $0 }
        .padding(.horizontal, PapagaioTema.Espaco.largo)
        .padding(.vertical, PapagaioTema.Espaco.medio)
        .frame(minHeight: 86)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .opacity(oculta ? 0.5 : 1)
    }

    private var conteudoHorizontal: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            botaoConclusao

            tituloDaTarefa
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

            SeparadorDaLinhaDeTarefa()
            ColunaDaTarefa(rotulo: "Prioridade".localized) {
                SeloDePrioridade(prioridade: tarefa.prioridade)
            }
            .frame(minWidth: 96, idealWidth: 128, maxWidth: 150, alignment: .leading)

            SeparadorDaLinhaDeTarefa()
            ColunaDaTarefa(rotulo: "Responsável".localized) {
                responsavelDaTarefa
            }
            .frame(minWidth: 130, idealWidth: 190, maxWidth: 220, alignment: .leading)

            SeparadorDaLinhaDeTarefa()
            ColunaDaTarefa(rotulo: "Status".localized) {
                seloDeStatus
            }
            .frame(minWidth: 96, idealWidth: 124, maxWidth: 150, alignment: .leading)

            SeparadorDaLinhaDeTarefa()
            ColunaDaTarefa(rotulo: "Data".localized) {
                Label(dataDoPrazo, systemImage: concluida ? "checkmark.circle" : "calendar")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(concluida ? PapagaioTema.sucesso : PapagaioTema.perigo)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(minWidth: 104, idealWidth: 136, maxWidth: 160, alignment: .leading)

            acoes
        }
    }

    private var conteudoCompacto: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                botaoConclusao
                tituloDaTarefa
                Spacer()
                acoes
            }

            Divider()
                .background(PapagaioTema.borda)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 135), spacing: PapagaioTema.Espaco.medio, alignment: .leading)],
                alignment: .leading,
                spacing: PapagaioTema.Espaco.medio
            ) {
                ColunaDaTarefa(rotulo: "Prioridade".localized) {
                    SeloDePrioridade(prioridade: tarefa.prioridade)
                }
                ColunaDaTarefa(rotulo: "Responsável".localized) {
                    responsavelDaTarefa
                }
                ColunaDaTarefa(rotulo: "Status".localized) {
                    seloDeStatus
                }
                ColunaDaTarefa(rotulo: "Data".localized) {
                    Label(dataDoPrazo, systemImage: concluida ? "checkmark.circle" : "calendar")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(concluida ? PapagaioTema.sucesso : PapagaioTema.perigo)
                        .monospacedDigit()
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                }
            }
        }
    }

    /// "Atrasada" no lugar do status literal quando o prazo já passou — a
    /// pessoa continua sabendo que a tarefa está "Não iniciado" ou "Em
    /// andamento" por baixo (é isso que muda ao arrastar entre seções),
    /// mas o que precisa saltar aos olhos aqui é que ela está vencida.
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
                SeloDeStatusDaTarefa(status: tarefa.status)
            }
        }
    }

    private var botaoConclusao: some View {
        Button(action: aoAlternarConclusao) {
            Image(systemName: concluida ? "checkmark.square.fill" : "square")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(concluida ? PapagaioTema.sucesso : PapagaioTema.textoSecundario)
        }
        .buttonStyle(.plain)
        .help(concluida ? "Marcar como em andamento".localized : "Concluir".localized)
    }

    private var acoes: some View {
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            botaoOcultar
            botaoEditar
        }
    }

    private var botaoOcultar: some View {
        Button(action: aoOcultar) {
            Image(systemName: oculta ? "eye.slash" : "eye")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(oculta ? "Mostrar tarefa".localized : "Ocultar tarefa".localized)
    }

    private var botaoEditar: some View {
        Button(action: aoEditar) {
            Image(systemName: "pencil")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Editar tarefa".localized)
    }

    private var tituloDaTarefa: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text(tarefa.titulo)
                .font(.headline.weight(.semibold))
                .foregroundStyle(concluida ? PapagaioTema.textoSecundario : PapagaioTema.texto)
                .strikethrough(concluida, color: PapagaioTema.textoSecundario)
                .lineLimit(2)

            Text(tarefa.origem)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
        }
    }

    private var responsavelDaTarefa: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            if let responsavel = tarefa.responsavelValido {
                AvatarDePessoa(nome: responsavel, diametro: 30)

                Text(responsavel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 30, height: 30)

                Text("Sem responsável".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }
}

struct ColunaDaTarefa<Conteudo: View>: View {
    let rotulo: String
    let conteudo: Conteudo

    init(rotulo: String, @ViewBuilder conteudo: () -> Conteudo) {
        self.rotulo = rotulo
        self.conteudo = conteudo()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text(rotulo)
                .font(.caption2.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .textCase(.uppercase)
            conteudo
        }
    }
}

struct SeparadorDaLinhaDeTarefa: View {
    var body: some View {
        Rectangle()
            .fill(PapagaioTema.borda.opacity(0.85))
            .frame(width: 1, height: 44)
    }
}
