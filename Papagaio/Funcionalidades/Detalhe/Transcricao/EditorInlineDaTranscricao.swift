import SwiftUI

/// Um editor para fala e trecho, preservando foco, atalhos e ações em ambos.
struct EditorInlineDaTranscricao: View {
    @Binding var texto: String
    let aoSalvar: () -> Void
    let aoCancelar: () -> Void
    @FocusState private var focado: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            TextEditor(text: $texto)
                .font(.body)
                .foregroundStyle(PapagaioTema.texto)
                .scrollContentBackground(.hidden)
                .textEditorStyle(.plain)
                .padding(PapagaioTema.Espaco.medio)
                .frame(minHeight: 120)
                .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        .stroke(PapagaioTema.borda, lineWidth: 1)
                }
                .focused($focado)

            HStack(spacing: PapagaioTema.Espaco.curto) {
                Spacer()
                Button("Cancelar".localized, action: aoCancelar)
                    .buttonStyle(BotaoDeContornoPapagaio())
                Button("Salvar".localized, action: aoSalvar)
                    .buttonStyle(BotaoPrincipalPapagaio())
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onAppear { focado = true }
        .onDisappear { focado = false }
    }
}
