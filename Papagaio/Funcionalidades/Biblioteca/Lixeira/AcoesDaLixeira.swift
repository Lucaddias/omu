import SwiftUI

struct AcoesDaLixeira: View {
    let temArquivos: Bool
    let aoRestaurarTudo: () -> Void
    let aoEsvaziar: () -> Void
    /// Esconde o texto dos dois botões, deixando só o glifo — o nome
    /// continua acessível pelo `.help()` de cada um, como tooltip, e para
    /// VoiceOver via `.labelStyle(.iconOnly)`, que não apaga o rótulo, só
    /// não desenha o texto. Usado quando a janela não tem espaço para os
    /// dois botões por extenso ao lado do título "Lixeira"; ver
    /// `BibliotecaHomeView.cabecalhoDaLixeira`.
    var somenteIcone = false

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.largo) {
            Button("Restaurar Tudo".localized, systemImage: "arrow.counterclockwise", action: aoRestaurarTudo)
                .aplicarSomenteIcone(somenteIcone)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .buttonStyle(BotaoDeContornoPapagaio())
                .disabled(!temArquivos)
                .help("Restaurar todos os arquivos da lixeira".localized)

            Button("Esvaziar Lixeira".localized, systemImage: "trash.square", role: .destructive, action: aoEsvaziar)
                .aplicarSomenteIcone(somenteIcone)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .font(.body.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSobrePrimario)
                .padding(.horizontal, somenteIcone ? PapagaioTema.Espaco.medio : PapagaioTema.Espaco.largo)
                .frame(minWidth: somenteIcone ? PapagaioTema.Altura.destaque : 0, minHeight: PapagaioTema.Altura.destaque)
                .background(PapagaioTema.preenchimentoPrimario, in: Capsule())
                .buttonStyle(.plain)
                .disabled(!temArquivos)
                .opacity(temArquivos ? 1 : 0.45)
                .help("Apagar definitivamente todos os arquivos da lixeira".localized)
        }
    }
}

private extension View {
    /// `.labelStyle(somenteIcone ? .iconOnly : .automatic)` não compila: os
    /// dois lados do ternário são tipos concretos diferentes
    /// (`IconOnlyLabelStyle` e `DefaultLabelStyle`), e o Swift exige que as
    /// duas pontas de um `?:` sejam do mesmo tipo. O `@ViewBuilder` aqui
    /// resolve isso do mesmo jeito que um `if`/`else` normal num `body`:
    /// cada ramo aplica o próprio modificador (ou nenhum), sem precisar
    /// unificar os dois estilos num tipo só.
    @ViewBuilder
    func aplicarSomenteIcone(_ ativo: Bool) -> some View {
        if ativo {
            labelStyle(.iconOnly)
        } else {
            self
        }
    }
}
