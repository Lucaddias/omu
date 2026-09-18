import AppKit
import SwiftUI

struct AvatarDaContaNaBarra: View {
    let url: URL?
    let simbolo: String
    let conectado: Bool

    private var imagem: NSImage? {
        guard let url else { return nil }
        let acessou = url.startAccessingSecurityScopedResource()
        defer {
            if acessou { url.stopAccessingSecurityScopedResource() }
        }
        return NSImage(contentsOf: url)
    }

    /// Glifo sem anel próprio: o container já recorta em círculo + stroke
    /// (abaixo), e `person.crop.circle*` desenhava um segundo anel dentro do
    /// primeiro. O caminho com foto não é tocado.
    private var simboloSemAnelProprio: String {
        simbolo.contains("crop.circle") ? "person.fill" : simbolo
    }

    var body: some View {
        ZStack {
            if let imagem {
                Image(nsImage: imagem)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: simboloSemAnelProprio)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(conectado ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .frame(width: PapagaioTema.Altura.compacta, height: PapagaioTema.Altura.compacta)
            }
        }
        .frame(width: PapagaioTema.Altura.compacta, height: PapagaioTema.Altura.compacta)
        .background(.regularMaterial, in: Circle())
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(PapagaioTema.borda.opacity(0.8), lineWidth: 1)
        }
    }
}

struct BotaoDeIconeDaBarra: View {
    let simbolo: String
    let legenda: String
    @Binding var legendaAtiva: LegendaDaBarra?
    let selecionado: Bool
    var mostraIndicador = false
    @State private var pairando = false

    var body: some View {
        GeometryReader { geometria in
            ZStack(alignment: .topTrailing) {
                Image(systemName: simbolo)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selecionado || pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .frame(width: PapagaioTema.Altura.compacta, height: PapagaioTema.Altura.compacta)
                    .background(fundo, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(selecionado ? PapagaioTema.destaque.opacity(0.58) : PapagaioTema.borda.opacity(pairando ? 1 : 0.76), lineWidth: 1)
                    }
                    .contentShape(Circle())

                if mostraIndicador {
                    Circle()
                        .fill(PapagaioTema.destaque)
                        .frame(width: 8, height: 8)
                        .offset(x: -5, y: 5)
                }
            }
            .onHover { ativo in
                pairando = ativo
                if ativo {
                    let area = geometria.frame(in: .global)
                    legendaAtiva = LegendaDaBarra(texto: legenda, x: area.midX, baseDoIcone: area.maxY)
                } else if legendaAtiva?.texto == legenda {
                    legendaAtiva = nil
                }
            }
        }
        .frame(width: PapagaioTema.Altura.compacta, height: PapagaioTema.Altura.compacta)
        .zIndex(pairando ? 10 : 0)
        .animation(.easeOut(duration: 0.14), value: pairando)
        .animation(.easeOut(duration: 0.14), value: selecionado)
    }

    private var fundo: Color {
        if selecionado { return PapagaioTema.destaqueSuave.opacity(0.76) }
        if pairando { return PapagaioTema.destaqueSuave.opacity(0.46) }
        return PapagaioTema.superficie
    }
}

struct BotaoDeAtalhoDaBarra: View {
    let simbolo: String
    let legenda: String
    @Binding var legendaAtiva: LegendaDaBarra?
    let selecionado: Bool
    @State private var pairando = false

    var body: some View {
        GeometryReader { geometria in
            Image(systemName: simbolo)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selecionado || pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                .frame(width: 36, height: PapagaioTema.Altura.compacta)
                .background(fundo, in: Capsule())
                .contentShape(Rectangle())
                .onHover { ativo in
                    pairando = ativo
                    if ativo {
                        let area = geometria.frame(in: .global)
                        legendaAtiva = LegendaDaBarra(texto: legenda, x: area.midX, baseDoIcone: area.maxY)
                    } else if legendaAtiva?.texto == legenda {
                        legendaAtiva = nil
                    }
                }
        }
            .frame(width: 36, height: PapagaioTema.Altura.compacta)
            .onHover { ativo in
                if !ativo, legendaAtiva?.texto == legenda {
                    legendaAtiva = nil
                }
            }
            .zIndex(pairando ? 10 : 0)
            .animation(.easeOut(duration: 0.14), value: pairando)
            .animation(.easeOut(duration: 0.14), value: selecionado)
    }

    private var fundo: Color {
        if selecionado { return PapagaioTema.destaqueSuave.opacity(0.72) }
        if pairando { return PapagaioTema.destaqueSuave.opacity(0.42) }
        return .clear
    }
}

/// Botão pequeno para dentro do selo de gravação.
///
/// Menor que o `BotaoCircularPapagaio` de propósito: ele convive com texto numa
/// cápsula de 36pt de altura, e o botão padrão ocuparia a cápsula inteira.
struct BotaoDoSelo: View {
    let simbolo: String
    let ajuda: String
    var perigo = false
    let acao: () -> Void

    @State private var pairando = false

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(cor)
                .frame(width: 24, height: 24)
                .background(
                    pairando ? PapagaioTema.superficieSuave : .clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(ajuda.localized)
        .accessibilityLabel(ajuda.localized)
        .onHover { pairando = $0 }
        .animation(.easeOut(duration: 0.12), value: pairando)
    }

    private var cor: Color {
        if perigo { return PapagaioTema.perigo }
        return pairando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
    }
}
