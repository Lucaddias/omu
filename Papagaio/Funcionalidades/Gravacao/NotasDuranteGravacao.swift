import PapagaioCore
import SwiftUI

/// Editor de observações da conversa enquanto o áudio ainda está sendo
/// capturado. O estado pertence ao `GravadorViewModel`, não a esta view: assim
/// o rascunho não desaparece se a hierarquia SwiftUI for recomposta.
struct PainelDeNotasDuranteGravacao: View {
    @Bindable var gravador: GravadorViewModel
    @FocusState private var editorEstaFocado: Bool
    /// Qual nota está aberta para correção. Uma por vez.
    @State private var notaEmEdicao: UUID?

    private var rascunhoVazio: Bool {
        gravador.rascunhoDaNota.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var quantidadeDeNotas: Int {
        gravador.notasDaGravacao.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            // Mesma lógica da aba Notas: um bloco de escrita com o instante à
            // vista, Enter fecha a nota, Enter vazio marca o ponto. Antes esta
            // tela tinha três botões e um editor sem tempo visível, e a mesma
            // ideia se aprendia duas vezes, de dois jeitos diferentes.
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                Text(gravador.tempoDeGravacao.comoCronometro)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .frame(width: 52, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityLabel("Tempo atual da gravação".localized)

                TextField("Escreva uma nota e pressione Enter…".localized, text: $gravador.rascunhoDaNota, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PapagaioTema.Tipo.corpo)
                    .lineLimit(4...14)
                    .frame(minHeight: 96, alignment: .topLeading)
                    .focused($editorEstaFocado)
                    .onSubmit { salvar() }
            }
            .padding(PapagaioTema.Espaco.medio)
            .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(
                        editorEstaFocado ? PapagaioTema.destaque.opacity(0.58) : PapagaioTema.borda,
                        lineWidth: 1
                    )
            }

            HStack {
                Text("Enter salva · Enter vazio marca o instante".localized)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Spacer()

                Text(quantidadeDeNotas == 1 ? "1 nota".localized : "\(quantidadeDeNotas) " + "notas".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }

            if !gravador.notasDaGravacao.isEmpty {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    // Mais recentes em cima: durante a gravação o que importa é
                    // conferir o que acabou de ser anotado.
                    ForEach(gravador.notasDaGravacao.reversed()) { nota in
                        LinhaDaNotaEmGravacao(
                            nota: nota,
                            emEdicao: $notaEmEdicao,
                            aoEditar: { texto in gravador.editarNota(nota, texto: texto) },
                            aoRemover: { gravador.removerNota(nota) }
                        )
                    }
                }
                .padding(.top, PapagaioTema.Espaco.minimo)
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
        .accessibilityElement(children: .contain)
    }

    /// Enter com texto salva a nota; Enter vazio guarda só o instante.
    private func salvar() {
        if rascunhoVazio {
            gravador.inserirMarcador()
        } else {
            gravador.adicionarNota()
        }
        // O foco volta para o campo: numa conversa ao vivo vem outra nota logo
        // em seguida, e tirar a mão do teclado custa a frase seguinte.
        editorEstaFocado = true
    }

}

private struct LinhaDaNotaEmGravacao: View {
    let nota: NotaDaConversa
    @Binding var emEdicao: UUID?
    let aoEditar: (String) -> Void
    let aoRemover: () -> Void

    @State private var rascunho = ""
    @FocusState private var focado: Bool

    private var editando: Bool { emEdicao == nota.id }

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: nota.tipo == .marcador ? "bookmark.fill" : "text.quote")
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 18)

            Text(nota.start.comoCronometro)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .monospacedDigit()

            if editando {
                // Enter confirma, como no campo de escrever: o mesmo gesto
                // fecha a nota nova e a correção.
                TextField("Corrija a nota…".localized, text: $rascunho, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($focado)
                    .onSubmit { concluir() }
            } else {
                Text(nota.texto.isEmpty ? "Marcador".localized : nota.texto)
                    .font(.callout)
                    .foregroundStyle(
                        nota.texto.isEmpty ? PapagaioTema.textoSecundario : PapagaioTema.texto
                    )
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // Corrigir na hora: anotar ao vivo produz erro de digitação e frase
            // pela metade, porque a atenção está na conversa.
            Button {
                if editando {
                    concluir()
                } else {
                    rascunho = nota.texto
                    emEdicao = nota.id
                    focado = true
                }
            } label: {
                Image(systemName: editando ? "checkmark" : "pencil")
                    .font(.caption)
                    .foregroundStyle(
                        editando ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(editando ? "Concluir edição".localized : "Editar nota".localized)

            Button(action: aoRemover) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Apagar nota".localized)
        }
        .padding(PapagaioTema.Espaco.medio)
        .background(PapagaioTema.superficieSuave.opacity(0.68), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func concluir() {
        aoEditar(rascunho)
        emEdicao = nil
    }

}
