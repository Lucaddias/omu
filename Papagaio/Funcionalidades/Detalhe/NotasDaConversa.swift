import PapagaioCore
import SwiftUI

/// Notas como uma linha do tempo, e não como um bloco de texto.
///
/// Antes existiam dois modelos mentais para a mesma coisa: durante a gravação a
/// nota era um item carimbado no tempo; depois virava um bloco único, com os
/// marcadores relegados a uma lista embaixo. Quem aprendia um encontrava o
/// outro ao voltar na conversa — e "crítica" marcava o bloco inteiro, nunca o
/// pedaço que importava.
///
/// Agora existe uma unidade só: a nota. Toda nota tem instante, texto e um
/// sinalizador de crítica. Marcador é a nota que nasceu sem texto.
struct PainelDeNotasDaConversa: View {
    @Binding var notas: [NotaDaConversa]
    let estadoDeSalvamento: String
    let duracao: TimeInterval
    /// Lido só na hora de criar a nota: como valor, o cronômetro redesenharia a
    /// lista várias vezes por segundo.
    let instanteAtual: () -> TimeInterval
    let ditado: DitadoDeNota
    let aoTocar: (NotaDaConversa) -> Void
    let aoSalvar: () -> Void
    let aoAlternarDitado: () -> Void

    @State private var filtro: FiltroDeNotas = .todas
    @State private var rascunho = ""
    @FocusState private var escrevendo: Bool
    /// Qual nota está aberta para edição.
    ///
    /// `@State`, e não `@FocusState`: foco só existe quando há um campo na
    /// tela para recebê-lo, e o campo desta nota só aparece **porque** ela está
    /// em edição. Guardando isso em `@FocusState`, o clique no lápis pedia
    /// foco para um campo que ainda não existia, o SwiftUI descartava o pedido
    /// e nada acontecia. O foco do teclado é assunto separado, resolvido dentro
    /// da própria linha.
    @State private var notaEmEdicao: UUID?

    /// Etiquetas saem do próprio texto, por `#`.
    ///
    /// Sem campo novo no modelo: nada de migração de banco, e a pessoa escreve
    /// a etiqueta no fluxo em vez de parar para abrir um seletor. É como
    /// funciona em quase toda ferramenta de nota.
    private var etiquetas: [String] {
        let todas = notas.flatMap { Self.etiquetas(em: $0.texto) }
        return Array(Set(todas)).sorted()
    }

    private var notasVisiveis: [NotaDaConversa] {
        let ordenadas = notas.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }

        switch filtro {
        case .todas: return ordenadas
        case let .etiqueta(nome):
            return ordenadas.filter { Self.etiquetas(em: $0.texto).contains(nome) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            campoDeEscrita

            if ditado.ocupado || !ditado.textoParcial.isEmpty {
                previaDoDitado
            }

            if !etiquetas.isEmpty {
                filtros
            }

            if notasVisiveis.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "note.text",
                    titulo: notas.isEmpty ? "Nenhuma nota ainda".localized : "Nada com esse filtro".localized,
                    mensagem: notas.isEmpty
                        ? "Escreva no campo acima e pressione Enter. O instante do áudio fica guardado junto.".localized
                        : "Troque o filtro para ver as outras notas.".localized
                )
                // Menor que antes: o bloco de escrita já ocupa a parte de cima,
                // e um vazio de 200pt embaixo dele fazia a tela parecer mais
                // vazia do que está.
                .frame(maxWidth: .infinity, minHeight: 140)
                .cartaoPapagaio()
            } else {
                LazyVStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                    ForEach(notasVisiveis) { nota in
                        LinhaDeNotaDaConversa(
                            nota: vinculo(para: nota),
                            emEdicao: $notaEmEdicao,
                            aoTocar: { aoTocar(nota) },
                            aoRemover: { remover(nota) },
                            aoSalvar: aoSalvar
                        )
                    }
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sem título nem parágrafo de abertura: a aba já se chama "Notas" e o
    /// texto de instruções custava duas linhas e meia de altura antes da
    /// primeira nota. Ele continua atrás do "?", para quem chega agora.
    private var botaoDeAjuda: some View {
        BotaoDeAjudaPapagaio(
            texto: "Cada nota fica presa a um instante. Clique no tempo para ouvir o trecho, e use #etiquetas para agrupar depois.".localized,
            ajuda: "Como funcionam as notas".localized,
            largura: 300
        )
    }

    /// Um campo só, que salva no Enter.
    ///
    /// Antes eram três botões — nova nota, marcar instante, ditar — e a nota
    /// nascia vazia esperando alguém digitar dentro dela, na lista. Dois passos
    /// para uma ideia que dura três segundos numa conversa ao vivo.
    ///
    /// Agora é o inverso: o campo está sempre pronto, e o Enter fecha a nota
    /// com o instante em que ela foi escrita. Marcador vira o caso em que se
    /// aperta Enter com o campo vazio — mesma tecla, sem botão próprio.
    private var campoDeEscrita: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                // O instante fica à vista enquanto se escreve: é o que
                // diferencia esta nota de qualquer bloco de texto.
                Text(instanteAtual().comoCronometro)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .frame(width: 52, alignment: .leading)
                    .padding(.top, 2)

                // Bloco de escrita, não campo de uma linha.
                //
                // Numa conversa a pessoa anota pouco e em rajadas: fica
                // ouvindo, e de vez em quando registra o que importa. Um campo
                // rasteiro parece formulário e convida a frases curtas; um
                // bloco alto parece papel, e é para onde o olho volta entre
                // uma anotação e outra. Ele também absorve o parágrafo inteiro
                // sem rolar, no caso em que a ideia vem completa.
                TextField("Escreva uma nota e pressione Enter…".localized, text: $rascunho, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PapagaioTema.Tipo.corpo)
                    .lineLimit(4...14)
                    .frame(minHeight: 96, alignment: .topLeading)
                    .focused($escrevendo)
                    .onSubmit { salvarRascunho() }

                Button {
                    aoAlternarDitado()
                } label: {
                    Image(systemName: simboloDoDitado)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            ditado.ocupado ? PapagaioTema.perigo : PapagaioTema.destaqueEscuro
                        )
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(rotuloDoDitado)
                .disabled(ditado.estado == .transcrevendo)
            }
            .padding(PapagaioTema.Espaco.medio)
            .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(
                        escrevendo ? PapagaioTema.destaque.opacity(0.58) : PapagaioTema.borda,
                        lineWidth: 1
                    )
            }

            HStack(spacing: PapagaioTema.Espaco.curto) {
                if case let .falhou(motivo) = ditado.estado {
                    Label(motivo, systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.perigo)
                        .lineLimit(2)
                } else {
                    Text("Enter salva · Enter vazio marca o instante".localized)
                        .font(.caption)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer()

                Label(
                    estadoDeSalvamento.localized,
                    systemImage: estadoDeSalvamento == "Salvo" ? "checkmark.circle" : "clock"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)

                botaoDeAjuda
            }
        }
    }

    /// Filtrar é o que dá consequência à marcação: uma etiqueta que não muda
    /// nada depois não é usada duas vezes.
    private var filtros: some View {
        LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.curto, espacoVertical: PapagaioTema.Espaco.curto) {
            chipDeFiltro("Todas".localized, ativo: filtro == .todas) { filtro = .todas }

            ForEach(etiquetas, id: \.self) { nome in
                chipDeFiltro("#\(nome)", ativo: filtro == .etiqueta(nome)) {
                    filtro = .etiqueta(nome)
                }
            }
        }
    }

    private func chipDeFiltro(
        _ texto: String,
        ativo: Bool,
        cor: Color = PapagaioTema.destaqueEscuro,
        acao: @escaping () -> Void
    ) -> some View {
        Button(action: acao) {
            Text(texto)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ativo ? PapagaioTema.textoSobrePrimario : cor)
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, PapagaioTema.Espaco.medio)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(ativo ? cor : cor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var previaDoDitado: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
            Image(systemName: ditado.gravando ? "waveform" : "hourglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(ditado.gravando ? "Ouvindo…".localized : "Refinando com o modelo local…".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Text(ditado.textoParcial.isEmpty ? "Fale — o texto aparece aqui.".localized : ditado.textoParcial)
                    .font(.body)
                    .foregroundStyle(PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.destaqueSuave.opacity(0.45), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
    }

    private var rotuloDoDitado: String {
        switch ditado.estado {
        case .gravando: "Parar e transcrever".localized
        case .transcrevendo: "Transcrevendo…".localized
        default: "Ditar nota".localized
        }
    }

    private var simboloDoDitado: String {
        switch ditado.estado {
        case .gravando: "stop.circle.fill"
        case .transcrevendo: "hourglass"
        default: "mic"
        }
    }

    /// Vínculo por identidade, e não por índice: a lista se reordena por tempo
    /// a cada digitação, e um índice fixo passaria a apontar para outra nota.
    private func vinculo(para nota: NotaDaConversa) -> Binding<NotaDaConversa> {
        Binding(
            get: { notas.first { $0.id == nota.id } ?? nota },
            set: { nova in
                guard let indice = notas.firstIndex(where: { $0.id == nota.id }) else { return }
                notas[indice] = nova
            }
        )
    }

    /// Fecha a nota com o instante em que ela foi escrita.
    ///
    /// Campo vazio vira marcador: é o gesto de "guarda este ponto, volto
    /// depois", e não faz sentido obrigar a inventar texto para isso.
    private func salvarRascunho() {
        let texto = rascunho.trimmingCharacters(in: .whitespacesAndNewlines)
        let instante = min(max(0, instanteAtual()), max(duracao, 0))

        notas.append(
            NotaDaConversa(
                texto: texto,
                start: instante,
                critica: false,
                tipo: texto.isEmpty ? .marcador : .nota
            )
        )
        rascunho = ""
        filtro = .todas
        aoSalvar()
        // O foco fica no campo: numa conversa ao vivo vem outra nota logo em
        // seguida, e tirar a mão do teclado custa a frase seguinte.
        escrevendo = true
    }

    private func remover(_ nota: NotaDaConversa) {
        notas.removeAll { $0.id == nota.id }
        aoSalvar()
    }

    static func etiquetas(em texto: String) -> [String] {
        texto
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { String($0.dropFirst()).trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
    }

    enum FiltroDeNotas: Equatable {
        case todas
        case etiqueta(String)
    }
}

/// Uma nota: tempo à esquerda, texto no meio, ações à direita.
private struct LinhaDeNotaDaConversa: View {
    @Binding var nota: NotaDaConversa
    @Binding var emEdicao: UUID?
    let aoTocar: () -> Void
    let aoRemover: () -> Void
    let aoSalvar: () -> Void

    /// Foco do teclado, local à linha: o campo já existe quando isto é ligado.
    @FocusState private var digitando: Bool

    private var editando: Bool { emEdicao == nota.id }

    /// Fora de edição o texto é renderizado — negrito fica negrito, link fica
    /// clicável. Markdown cru na tela era o pior dos dois mundos: a pessoa
    /// escrevia marcação e continuava lendo marcação.
    private var textoRenderizado: AttributedString {
        (try? AttributedString(
            markdown: nota.texto,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(nota.texto)
    }

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
            // Tempo e play na mesma linha, e não empilhados: em coluna eles
            // criavam duas alturas de texto num cartão que muitas vezes tem uma
            // linha só, e o cartão inteiro crescia para acomodá-los.
            Button(action: aoTocar) {
                HStack(spacing: PapagaioTema.Espaco.minimo) {
                    Text(nota.start.comoRelogio)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "play.circle.fill")
                        .font(.callout)
                }
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 74, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ouvir a partir de %@".localized(nota.start.comoRelogio))

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                if editando {
                    // Campo que cresce com o texto: a área enorme em branco de
                    // antes intimidava e não sugeria nada.
                    TextField("O que aconteceu aqui? Use #etiqueta para agrupar".localized, text: $nota.texto, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .lineLimit(1...12)
                        .focused($digitando)
                        .onChange(of: nota.texto) { _, _ in aoSalvar() }
                        .onSubmit { emEdicao = nil }
                        // O campo acabou de nascer; agora sim dá para focá-lo.
                        .onAppear { digitando = true }
                } else if nota.texto.isEmpty {
                    // Marcador: ponto guardado sem texto. Antes ele caía no
                    // ramo de edição e virava um campo vazio — um cartão alto,
                    // mudo, que parecia defeito.
                    Label("Marcador".localized, systemImage: "bookmark.fill")
                        .font(.system(size: 15).italic())
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { emEdicao = nota.id }
                } else {
                    Text(textoRenderizado)
                        .font(.system(size: 16))
                        .foregroundStyle(PapagaioTema.texto)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { emEdicao = nota.id }
                }

                let etiquetas = PainelDeNotasDaConversa.etiquetas(em: nota.texto)
                if !etiquetas.isEmpty, !editando {
                    LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.minimo, espacoVertical: PapagaioTema.Espaco.minimo) {
                        ForEach(etiquetas, id: \.self) { nome in
                            Text("#\(nome)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PapagaioTema.destaqueEscuro)
                                .padding(.horizontal, PapagaioTema.Espaco.curto)
                                .padding(.vertical, 2)
                                .background(PapagaioTema.destaqueSuave, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Sem o marcador de "crítica": era um segundo eixo de organização
            // convivendo com as `#etiquetas`, que fazem o mesmo trabalho e são
            // escritas no fluxo. Quem precisa destacar escreve `#urgente`.
            //
            // Editar e apagar: as duas ações que uma nota salva precisa ter, e
            // só elas.
            // Lado a lado, não empilhados, e com alvo de 28pt.
            //
            // Empilhados eles esticavam o cartão de uma nota curta para caber
            // dois ícones em coluna. E o alvo antes era o desenho do glifo,
            // uns 12pt — abaixo do mínimo confortável para clicar.
            HStack(spacing: PapagaioTema.Espaco.minimo) {
                Button {
                    emEdicao = editando ? nil : nota.id
                } label: {
                    Image(systemName: editando ? "checkmark" : "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            editando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
                        )
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(editando ? "Concluir edição".localized : "Editar nota".localized)

                Button(action: aoRemover) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Apagar nota".localized)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(PapagaioTema.destaque)
                .frame(width: 4)
                .padding(.vertical, PapagaioTema.Espaco.medio)
        }
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(editando ? PapagaioTema.destaque : PapagaioTema.borda.opacity(0.72), lineWidth: editando ? 1.4 : 1)
        }
    }
}
