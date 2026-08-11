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
    @FocusState private var notaEmFoco: UUID?

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
        case .criticas: return ordenadas.filter(\.critica)
        case let .etiqueta(nome):
            return ordenadas.filter { Self.etiquetas(em: $0.texto).contains(nome) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            acoes

            if ditado.ocupado || !ditado.textoParcial.isEmpty {
                previaDoDitado
            }

            if !etiquetas.isEmpty || notas.contains(where: \.critica) {
                filtros
            }

            if notasVisiveis.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "note.text",
                    titulo: notas.isEmpty ? "Nenhuma nota ainda" : "Nada com esse filtro",
                    mensagem: notas.isEmpty
                        ? "Crie uma nota com ⌘N, marque um instante com ⌘K, ou dite falando."
                        : "Troque o filtro para ver as outras notas."
                )
                .frame(maxWidth: .infinity, minHeight: 200)
                .cartaoPapagaio()
            } else {
                LazyVStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                    ForEach(notasVisiveis) { nota in
                        LinhaDeNotaDaConversa(
                            nota: vinculo(para: nota),
                            emFoco: $notaEmFoco,
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
            texto: "Cada nota fica presa a um instante. Clique no tempo para ouvir o trecho, e use #etiquetas para agrupar depois.",
            ajuda: "Como funcionam as notas",
            largura: 300
        )
    }

    private var acoes: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Button {
                criarNota()
            } label: {
                Label("Nova nota", systemImage: "square.and.pencil")
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .keyboardShortcut("n", modifiers: [.command])

            Button {
                criarNota(marcador: true)
            } label: {
                Label("Marcar instante", systemImage: "bookmark")
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .keyboardShortcut("k", modifiers: [.command])

            Button {
                aoAlternarDitado()
            } label: {
                Label(rotuloDoDitado, systemImage: simboloDoDitado)
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .disabled(ditado.estado == .transcrevendo)

            Spacer(minLength: 12)

            if case let .falhou(motivo) = ditado.estado {
                Label(motivo, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapagaioTema.perigo)
                    .lineLimit(2)
            } else {
                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Text("⌘N nota · ⌘K marcador")
                    botaoDeAjuda
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .padding(.leading, PapagaioTema.Espaco.medio)
                .padding(.trailing, PapagaioTema.Espaco.minimo)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(PapagaioTema.superficieSuave, in: Capsule())
            }

            // O aviso de salvamento vem para cá junto com o resto: era a
            // única coisa que o cabeçalho ainda carregava.
            Label(
                estadoDeSalvamento,
                systemImage: estadoDeSalvamento == "Salvo" ? "checkmark.circle" : "clock"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario)
        }
    }

    /// Filtrar é o que dá consequência à marcação: uma etiqueta que não muda
    /// nada depois não é usada duas vezes.
    private var filtros: some View {
        LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.curto, espacoVertical: PapagaioTema.Espaco.curto) {
            chipDeFiltro("Todas", ativo: filtro == .todas) { filtro = .todas }

            if notas.contains(where: \.critica) {
                chipDeFiltro("Críticas", ativo: filtro == .criticas, cor: PapagaioTema.perigo) {
                    filtro = .criticas
                }
            }

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
                Text(ditado.gravando ? "Ouvindo…" : "Refinando com o modelo local…")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Text(ditado.textoParcial.isEmpty ? "Fale — o texto aparece aqui." : ditado.textoParcial)
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
        case .gravando: "Parar e transcrever"
        case .transcrevendo: "Transcrevendo…"
        default: "Ditar nota"
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

    private func criarNota(marcador: Bool = false) {
        let instante = min(max(0, instanteAtual()), max(duracao, 0))
        let nova = NotaDaConversa(
            texto: "",
            start: instante,
            critica: false,
            tipo: marcador ? .marcador : .nota
        )
        notas.append(nova)
        filtro = .todas
        aoSalvar()
        if !marcador { notaEmFoco = nova.id }
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
        case criticas
        case etiqueta(String)
    }
}

/// Uma nota: tempo à esquerda, texto no meio, ações à direita.
private struct LinhaDeNotaDaConversa: View {
    @Binding var nota: NotaDaConversa
    @FocusState.Binding var emFoco: UUID?
    let aoTocar: () -> Void
    let aoRemover: () -> Void
    let aoSalvar: () -> Void

    private var editando: Bool { emFoco == nota.id }

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
            Button(action: aoTocar) {
                VStack(spacing: 2) {
                    Text(nota.start.comoRelogio)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "play.circle")
                        .font(.caption)
                }
                .foregroundStyle(nota.critica ? PapagaioTema.perigo : PapagaioTema.destaqueEscuro)
                .frame(width: 54)
            }
            .buttonStyle(.plain)
            .help("Ouvir a partir de \(nota.start.comoRelogio)")

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                if editando || nota.texto.isEmpty {
                    // Campo que cresce com o texto: a área enorme em branco de
                    // antes intimidava e não sugeria nada.
                    TextField("O que aconteceu aqui? Use #etiqueta para agrupar", text: $nota.texto, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .lineLimit(1...12)
                        .focused($emFoco, equals: nota.id)
                        .onChange(of: nota.texto) { _, _ in aoSalvar() }
                } else {
                    Text(textoRenderizado)
                        .font(.system(size: 16))
                        .foregroundStyle(PapagaioTema.texto)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { emFoco = nota.id }
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

            VStack(spacing: PapagaioTema.Espaco.curto) {
                Button {
                    nota.critica.toggle()
                    aoSalvar()
                } label: {
                    Image(systemName: nota.critica ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(nota.critica ? PapagaioTema.perigo : PapagaioTema.textoSecundario)
                }
                .buttonStyle(.plain)
                .help(nota.critica ? "Desmarcar como crítica" : "Marcar como crítica")

                Button(action: aoRemover) {
                    Image(systemName: "trash")
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
                .buttonStyle(.plain)
                .help("Apagar nota")
            }
            .font(.callout)
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(nota.critica ? PapagaioTema.perigo : PapagaioTema.destaque)
                .frame(width: 4)
                .padding(.vertical, PapagaioTema.Espaco.medio)
        }
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(editando ? PapagaioTema.destaque : PapagaioTema.borda.opacity(0.72), lineWidth: editando ? 1.4 : 1)
        }
    }
}
