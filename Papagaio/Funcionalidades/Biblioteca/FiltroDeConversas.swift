import SwiftUI

enum FiltroDaBiblioteca: String, CaseIterable, Identifiable {
    case todas = "Todas"
    case pastas = "Pastas"

    var id: Self { self }

    var titulo: String {
        rawValue.localized
    }

    var simbolo: String {
        switch self {
        case .todas: "tray.full"
        case .pastas: "folder"
        }
    }
}

struct FiltroDeConversas: View {
    @Binding var selecionado: FiltroDaBiblioteca
    @Binding var pastaSelecionada: String?
    @Binding var atalhoSelecionado: AtalhoDaBiblioteca?
    let aoLimparAtalhoVisual: () -> Void
    var compacto = false
    /// Só o glifo, sem o texto — a pastilha vira um botão redondo pequeno, e
    /// o nome do filtro passa a viver só no `.help()` (tooltip ao passar o
    /// mouse). Usado quando nem o texto compacto cabe na janela; ver
    /// `BibliotecaHomeView.filtrosEPastas`.
    var somenteIcone = false

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            ForEach(FiltroDaBiblioteca.allCases) { filtro in
                // Sem `Button`, e com `onTapGesture` na pastilha.
                //
                // Um `Button` decide sozinho onde termina o alvo, a partir do
                // que o rótulo desenha — e foi essa decisão implícita que
                // deixou "Todas" respondendo só sobre o texto, porque a
                // pastilha não selecionada não desenha fundo nenhum. O
                // `onTapGesture` não tem essa liberdade: ele vale exatamente na
                // forma declarada logo antes dele, e essa forma é o retângulo
                // inteiro da pastilha.
                PastilhaDeFiltro(
                    filtro: filtro,
                    selecionada: selecionado == filtro,
                    compacto: compacto,
                    somenteIcone: somenteIcone
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.18)) {
                        selecionado = filtro
                        pastaSelecionada = nil
                        atalhoSelecionado = nil
                        aoLimparAtalhoVisual()
                    }
                }
                .help(filtro.titulo)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Mostrar %@".localized(filtro.titulo.localizedLowercase))
                .accessibilityAddTraits(selecionado == filtro ? [.isSelected] : [])
            }
        }
    }
}

/// O filtro era texto solto: só o glifo e as letras respondiam ao clique, e o
/// espaço entre eles não. Como pastilha, a área clicável é o retângulo inteiro
/// — e o estado selecionado deixa de depender só da cor da fonte, que some em
/// tela clara.
private struct PastilhaDeFiltro: View {
    let filtro: FiltroDaBiblioteca
    let selecionada: Bool
    let compacto: Bool
    var somenteIcone: Bool = false
    @State private var pairando = false

    /// Calculado antes da cadeia de modificadores, e não com ternários
    /// aninhados dentro dela: o compilador do Swift se perde tentando
    /// inferir o tipo de `.frame(minWidth:height:)` com dois `?:` dentro do
    /// mesmo argumento — "Cannot infer contextual base" era exatamente esse
    /// sintoma, não um erro de lógica.
    private var alturaDaPastilha: CGFloat { compacto ? 36 : PapagaioTema.Altura.compacta }
    private var larguraMinima: CGFloat { somenteIcone ? alturaDaPastilha : 0 }
    private var paddingHorizontal: CGFloat {
        if somenteIcone || compacto { return PapagaioTema.Espaco.curto }
        return PapagaioTema.Espaco.medio
    }

    var body: some View {
        conteudo
            .font((compacto ? Font.caption : Font.callout).weight(.semibold))
            .foregroundStyle(corDoTexto)
            .padding(.horizontal, paddingHorizontal)
            // Não existe `.frame(minWidth:height:)` — mesmo ajuste feito em
            // `AtalhosDaBiblioteca.BotaoTextualDeAtalhoDaBiblioteca`.
            .frame(minWidth: larguraMinima, minHeight: alturaDaPastilha, maxHeight: alturaDaPastilha)
            .background(fundo, in: Capsule())
            .overlay {
                Capsule().stroke(
                    selecionada
                        ? PapagaioTema.destaque.opacity(0.58)
                        : PapagaioTema.borda.opacity(pairando ? 1 : 0.76),
                    lineWidth: 1
                )
            }
            // Sem `.fixedSize()`, numa janela estreita o SwiftUI comprimia o
            // rótulo abaixo da largura natural dele — "Todas" virava "To...",
            // "Favoritos" virava "Fa-v..." quebrado ao meio com hífen. Com
            // isto o texto nunca encolhe; quem cede espaço numa janela
            // estreita é o rótulo inteiro sumindo (`somenteIcone`), decidido
            // por `BibliotecaHomeView.filtrosEPastas`.
            .fixedSize()
            // A forma de clique é o retângulo inteiro da pastilha.
            //
            // Sem ela, o alvo era só o que está **desenhado** — e a pastilha
            // não selecionada tem fundo `Color.clear`, que o SwiftUI não
            // considera desenhado. Sobravam as letras e o glifo. Como a
            // pastilha selecionada tem fundo com cor, ela funcionava inteira:
            // por isso "Pastas" respondia enquanto se estava em Pastas, e
            // "Todas" só respondia se o clique caísse exatamente sobre o texto.
            // O sintoma trocava de lado junto com a seleção, o que fazia
            // parecer que só um dos dois botões estava quebrado.
            .contentShape(Rectangle())
            .onHover { pairando = $0 }
            .animation(.easeOut(duration: 0.14), value: pairando)
            .animation(.easeOut(duration: 0.14), value: selecionada)
    }

    /// Ícone sozinho no modo compacto — o nome do filtro continua acessível
    /// pelo `.help(filtro.rawValue)` aplicado em `FiltroDeConversas`, que
    /// vira o tooltip ao passar o mouse.
    @ViewBuilder
    private var conteudo: some View {
        if somenteIcone {
            Image(systemName: filtro.simbolo)
        } else {
            Label(filtro.titulo, systemImage: filtro.simbolo)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var corDoTexto: Color {
        selecionada || pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
    }

    private var fundo: Color {
        if selecionada { return PapagaioTema.destaque.opacity(0.14) }
        // `superficie` com opacidade quase nula, e não `.clear`: visualmente é
        // a mesma coisa, mas é uma cor desenhada — e cor desenhada recebe
        // clique. Sozinha já resolveria; com o `contentShape` acima, é a
        // segunda trava contra o mesmo problema voltar.
        return pairando ? PapagaioTema.superficie : PapagaioTema.superficie.opacity(0.001)
    }
}
