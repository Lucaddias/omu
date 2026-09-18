import SwiftUI

/// O painel que fica por cima de tudo enquanto a gravação corre.
///
/// **Por que não é um widget de WidgetKit.** Widget no macOS não aceita
/// digitação: desde o macOS 14 ele tem botões e toggles por `AppIntent`, mas
/// não existe campo de texto, e anotar durante a conversa é o motivo principal
/// deste painel existir. Widget também atualiza por timeline, em intervalos que
/// o sistema decide — um cronômetro de segundos nunca ficaria certo. E não há
/// Live Activity no Mac.
///
/// O que resolve é uma janela pequena e flutuante do próprio app, que é como
/// gravadores de áudio profissionais fazem: sempre visível, sobre qualquer
/// programa, e com o teclado funcionando.
///
/// **Três tamanhos**, escolhidos pela largura real do painel, porque quem
/// arrasta o canto está dizendo de quanto precisa:
///
/// - **Mínimo** (abaixo de 300pt): ponto, cronômetro e três botões. É a barra
///   de transporte, para quem só quer não perder a gravação de vista.
/// - **Padrão** (300 a 440pt): acrescenta o campo de nota com o instante atual.
/// - **Amplo** (acima de 440pt): acrescenta a lista das notas já registradas,
///   para conferir o que foi anotado sem voltar ao app.
///
/// Em tela pequena o painel não muda de regra — ele começa no tamanho padrão,
/// que cabe em 340×190pt, menos de um oitavo de um MacBook Air de 13". Quem
/// precisar de mais espaço encolhe para o mínimo, que ocupa uma faixa de 44pt
/// de altura e pode ficar num canto sem cobrir nada.
struct PainelFlutuanteDeGravacao: View {
    @Bindable var gravador: GravadorViewModel
    let aoAbrirNoApp: () -> Void
    /// Encolhe o painel até o tamanho mínimo, ou devolve pro tamanho de
    /// antes — o mesmo botão faz as duas coisas, dependendo do tamanho atual
    /// (ver `botaoDeTamanho`). Só a própria pessoa aciona isso, pelo botão;
    /// nada acontece sozinho por causa de arrasto.
    let aoAlternarTamanho: () -> Void

    @State private var largura: CGFloat = 0
    @FocusState private var focoNaNota: Bool

    private var exibindoNota: Bool { largura >= 300 }
    private var exibindoLista: Bool { largura >= 440 }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            transporte

            if exibindoNota {
                campoDeNota
            }

            if exibindoLista, !gravador.notasDaGravacao.isEmpty {
                Divider()
                listaDeNotas
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PapagaioTema.fundo)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { largura = $0 }
        .animation(.snappy(duration: 0.2), value: exibindoNota)
        .animation(.snappy(duration: 0.2), value: exibindoLista)
    }

    // MARK: - Transporte

    private var transporte: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            // O ponto pisca só gravando: parado, ele viraria enfeite e a pessoa
            // deixaria de notar a diferença entre gravando e pausado.
            Circle()
                .fill(gravador.pausado ? PapagaioTema.aviso : PapagaioTema.perigo)
                .frame(width: 9, height: 9)
                .opacity(gravador.pausado ? 1 : 0.35)
                .animation(
                    gravador.pausado
                        ? .default
                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: gravador.pausado
                )

            Text(gravador.tempoDeGravacao.comoCronometro)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PapagaioTema.texto)

            Spacer(minLength: PapagaioTema.Espaco.curto)

            BotaoDoSelo(
                simbolo: gravador.pausado ? "play.fill" : "pause.fill",
                ajuda: gravador.pausado ? "Continuar".localized : "Pausar".localized
            ) {
                Task {
                    if gravador.pausado {
                        await gravador.continuar()
                    } else {
                        await gravador.pausar()
                    }
                }
            }

            BotaoDoSelo(simbolo: "stop.fill", ajuda: "Finalizar gravação".localized) {
                Task { await gravador.alternarGravacao() }
            }

            BotaoDoSelo(simbolo: "xmark", ajuda: "Cancelar gravação".localized, perigo: true) {
                Task { await gravador.cancelar() }
            }

            if exibindoNota {
                // Só aparece com espaço de sobra: no mínimo, mais um botão
                // aqui voltava a apertar tudo perto do cronômetro.
                BotaoDoSelo(simbolo: "arrow.up.left.square", ajuda: "Abrir no app".localized) {
                    aoAbrirNoApp()
                }
                BotaoDoSelo(simbolo: "pip.enter", ajuda: "Minimizar".localized) {
                    aoAlternarTamanho()
                }
            } else {
                // No mínimo, um botão só faz o trabalho dos dois de cima:
                // volta pro tamanho de antes, de onde dá pra abrir a nota e
                // (se precisar) voltar ao app pelo mesmo caminho de sempre.
                BotaoDoSelo(simbolo: "arrow.up.left.and.arrow.down.right", ajuda: "Restaurar tamanho".localized) {
                    aoAlternarTamanho()
                }
            }
        }
    }

    // MARK: - Nota

    /// Mesmo fluxo das outras duas telas: escreve e aperta Enter.
    ///
    /// Antes havia aqui um caminho próprio — "Crítica", "Marcar instante" e
    /// "Salvar nota" como botões — enquanto a tela de gravação e a aba Notas já
    /// usavam só o Enter. Três lugares para a mesma tarefa, com três gestos
    /// diferentes, é o tipo de inconsistência que a pessoa paga reaprendendo.
    private var campoDeNota: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                Text(gravador.tempoDeGravacao.comoCronometro)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .padding(.top, 3)

                TextField("Escreva e pressione Enter…".localized, text: $gravador.rascunhoDaNota, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focoNaNota)
                    .onSubmit { salvarNota() }
            }
            .padding(PapagaioTema.Espaco.curto)
            .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(
                        focoNaNota ? PapagaioTema.destaque.opacity(0.58) : PapagaioTema.borda,
                        lineWidth: 1
                    )
            }

            Text("Enter salva · Enter vazio marca o instante".localized)
                .font(.caption2)
                .foregroundStyle(PapagaioTema.textoSecundario)
        }
    }

    private func salvarNota() {
        if gravador.rascunhoDaNota.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gravador.inserirMarcador()
        } else {
            gravador.adicionarNota()
        }
        focoNaNota = true
    }

    // MARK: - Notas registradas

    private var listaDeNotas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                // Mais recentes em cima: durante a gravação, o que interessa é
                // conferir o que acabou de ser anotado.
                ForEach(gravador.notasDaGravacao.reversed()) { nota in
                    HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.curto) {
                        Text(nota.start.comoCronometro)
                            .font(.caption.monospaced())
                            .foregroundStyle(PapagaioTema.textoSecundario)

                        Text(nota.texto.isEmpty ? "Marcador".localized : nota.texto)
                            .font(.caption)
                            .foregroundStyle(
                                nota.texto.isEmpty
                                    ? PapagaioTema.textoSecundario
                                    : PapagaioTema.texto
                            )
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        Button {
                            gravador.removerNota(nota)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                                .foregroundStyle(PapagaioTema.textoSecundario)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Apagar nota".localized)

                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }
}
