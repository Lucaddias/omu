import SwiftUI

enum AtalhoDaBiblioteca: String, Identifiable {
    case recentes = "Recentes"
    case favoritos = "Favoritos"

    var id: Self { self }
}

struct AtalhosDaBiblioteca: View {
    @Binding var selecionado: AtalhoDaBiblioteca?
    let aoSelecionarRecentes: () -> Void
    let aoSelecionarFavoritos: () -> Void
    var compacto = false
    /// Só o glifo — ver o mesmo parâmetro em `FiltroDeConversas`. O nome
    /// continua no `.help()` de cada botão, como tooltip.
    var somenteIcone = false

    var body: some View {
        HStack(spacing: compacto ? PapagaioTema.Espaco.curto : PapagaioTema.Espaco.largo) {
            Button(action: aoSelecionarRecentes) {
                BotaoTextualDeAtalhoDaBiblioteca(
                    titulo: "Recentes".localized,
                    simbolo: "clock.arrow.circlepath",
                    selecionado: selecionado == .recentes,
                    compacto: compacto,
                    somenteIcone: somenteIcone
                )
            }
            .buttonStyle(.plain)
            .help("Recentes".localized)

            Button(action: aoSelecionarFavoritos) {
                BotaoTextualDeAtalhoDaBiblioteca(
                    titulo: "Favoritos".localized,
                    simbolo: selecionado == .favoritos ? "star.fill" : "star",
                    selecionado: selecionado == .favoritos,
                    compacto: compacto,
                    somenteIcone: somenteIcone
                )
            }
            .buttonStyle(.plain)
            .help("Favoritos".localized)
        }
        .accessibilityLabel("Atalhos da biblioteca".localized)
    }
}

struct BotaoTextualDeAtalhoDaBiblioteca: View {
    let titulo: String
    let simbolo: String
    let selecionado: Bool
    var compacto = false
    var somenteIcone = false
    @State private var pairando = false

    /// Calculado antes da cadeia de modificadores — ver o mesmo ajuste em
    /// `PastilhaDeFiltro`: ternários aninhados direto num argumento de
    /// `.frame(minWidth:height:)` faziam o compilador perder a inferência de
    /// tipo ("Cannot infer contextual base").
    private var alturaDoBotao: CGFloat { compacto ? 36 : PapagaioTema.Altura.padrao }
    private var larguraMinima: CGFloat { somenteIcone ? alturaDoBotao : 0 }
    private var paddingHorizontal: CGFloat {
        if somenteIcone || compacto { return PapagaioTema.Espaco.curto }
        return PapagaioTema.Espaco.largo
    }

    var body: some View {
        conteudo
            .font((compacto ? Font.caption : Font.callout).weight(.semibold))
            .foregroundStyle(selecionado || pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
            .padding(.horizontal, paddingHorizontal)
            // Não existe `.frame(minWidth:height:)` — só `.frame(width:height:)`
            // (tamanho fixo) ou a família `minWidth`/`minHeight`/`maxHeight`
            // (flexível). Juntar `minWidth` com `height` sozinho parecia
            // válido lendo o código, mas o compilador via um argumento
            // "extra" que não bate com nenhum dos dois overloads.
            .frame(minWidth: larguraMinima, minHeight: alturaDoBotao, maxHeight: alturaDoBotao)
            .background(fundo, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(selecionado ? PapagaioTema.destaque.opacity(0.54) : PapagaioTema.borda.opacity(pairando ? 1 : 0.86), lineWidth: 1)
            }
            // Mesmo motivo do `.fixedSize()` em `PastilhaDeFiltro`: sem ele o
            // texto comprimia numa janela estreita e quebrava com hífen
            // ("Re-c...", "Fa-v..."). Numa janela apertada demais mesmo para
            // isso, `somenteIcone` some com o rótulo em vez de comprimi-lo.
            .fixedSize()
            .contentShape(Capsule())
            .onHover { pairando = $0 }
            .animation(.easeOut(duration: 0.14), value: pairando)
            .animation(.easeOut(duration: 0.14), value: selecionado)
    }

    /// Ícone sozinho no modo compacto — o nome continua acessível pelo
    /// `.help()` de cada `Button` em `AtalhosDaBiblioteca`.
    @ViewBuilder
    private var conteudo: some View {
        if somenteIcone {
            Image(systemName: simbolo)
        } else {
            Label(titulo, systemImage: simbolo)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var fundo: Color {
        if selecionado { return PapagaioTema.destaqueSuave.opacity(0.76) }
        if pairando { return PapagaioTema.destaqueSuave.opacity(0.42) }
        return PapagaioTema.superficie
    }
}
