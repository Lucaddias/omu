import SwiftUI

struct NovaTarefaDaConversaSheet: View {
    enum Modo {
        case criacao
        case edicao

        var titulo: String {
            switch self {
            case .criacao: "Nova tarefa".localized
            case .edicao: "Editar tarefa".localized
            }
        }

        var botao: String {
            switch self {
            case .criacao: "Adicionar tarefa".localized
            case .edicao: "Salvar alterações".localized
            }
        }

        var simbolo: String {
            switch self {
            case .criacao: "list.clipboard"
            case .edicao: "pencil"
            }
        }
    }

    let modo: Modo
    @Binding var titulo: String
    @Binding var responsavel: String
    @Binding var prioridade: PrioridadeDaTarefa
    @Binding var status: StatusDaTarefa
    @Binding var prazo: Date
    let responsaveisDisponiveis: [ResponsavelDaTarefa]
    let aoCancelar: () -> Void
    let aoAdicionar: () -> Void
    /// Só existe no modo edição — não faz sentido "excluir" uma tarefa que
    /// ainda nem foi criada. `nil` no modo criação (ver o call site) some
    /// com o botão por completo, em vez de deixá-lo desabilitado.
    var aoExcluir: (() -> Void)? = nil
    @State private var confirmandoExclusao = false

    private var podeAdicionar: Bool {
        !titulo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var prazoEstaPerto: Bool {
        let calendario = Calendar.current
        let hoje = calendario.startOfDay(for: Date())
        let diaDoPrazo = calendario.startOfDay(for: prazo)
        let dias = calendario.dateComponents([.day], from: hoje, to: diaDoPrazo).day ?? Int.max
        return dias <= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Image(systemName: modo.simbolo)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .frame(width: 44, height: 44)
                    .background(PapagaioTema.destaqueSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(modo.titulo)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PapagaioTema.texto)

                    Text("Defina título, responsável, prioridade e deadline antes de salvar.".localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Título".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                TextField("Ex.: Revisar pontos da entrevista".localized, text: $titulo)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, PapagaioTema.Espaco.medio)
                    .frame(height: PapagaioTema.Altura.padrao)
                    .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                            .stroke(PapagaioTema.borda, lineWidth: 1)
                    }
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Responsável".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                VStack(spacing: PapagaioTema.Espaco.curto) {
                    Menu {
                        Button("Sem responsável".localized) {
                            responsavel = ""
                        }

                        ForEach(responsaveisDisponiveis) { pessoa in
                            Button {
                                responsavel = pessoa.rotulo
                            } label: {
                                Text(pessoa.rotulo)
                            }
                        }
                    } label: {
                        HStack(spacing: PapagaioTema.Espaco.curto) {
                            Image(systemName: "person.crop.circle")
                            Text(responsavel.isEmpty ? "Escolher participante".localized : responsavel)
                                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .frame(height: PapagaioTema.Altura.padrao)
                        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                                .stroke(PapagaioTema.borda, lineWidth: 1)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)

                    TextField("Ou digite nome, e-mail ou login".localized, text: $responsavel)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .frame(height: PapagaioTema.Altura.padrao)
                        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                                .stroke(PapagaioTema.borda, lineWidth: 1)
                        }
                }
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Prioridade".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                ControleSegmentadoPapagaio(
                    opcoes: PrioridadeDaTarefa.allCases,
                    selecionado: $prioridade,
                    titulo: { $0.titulo },
                    simbolo: { _ in nil }
                )
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Deadline".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                CampoDeDataPapagaio(data: $prazo, rotuloAcessivel: "Data de entrega".localized)

                if prazoEstaPerto && status != .concluida {
                    Label("Deadline perto: a tarefa será marcada como prioridade alta.".localized, systemImage: "bell.badge")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.perigo)
                }
            }

            HStack(spacing: PapagaioTema.Espaco.medio) {
                if let aoExcluir {
                    Button("Excluir".localized, systemImage: "trash", role: .destructive) {
                        confirmandoExclusao = true
                    }
                    .buttonStyle(BotaoDeContornoDestrutivoPapagaio())
                    .confirmationDialog(
                        "Excluir esta tarefa?".localized,
                        isPresented: $confirmandoExclusao,
                        titleVisibility: .visible
                    ) {
                        Button("Excluir".localized, role: .destructive, action: aoExcluir)
                        Button("Cancelar".localized, role: .cancel) {}
                    } message: {
                        Text("Ela vai para a lixeira, de onde dá para restaurar depois.".localized)
                    }
                }

                Button("Cancelar".localized, action: aoCancelar)
                    .buttonStyle(BotaoDeContornoPapagaio())

                Spacer()

                Button(modo.botao, systemImage: modo == .criacao ? "plus" : "checkmark") {
                    aoAdicionar()
                }
                .buttonStyle(BotaoPrincipalPapagaio())
                .disabled(!podeAdicionar)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(minWidth: 340, idealWidth: 500, maxWidth: 520, alignment: .leading)
        .background(PapagaioTema.fundo)
    }
}

/// Mesmo contorno de `BotaoDeContornoPapagaio`, só que vermelho — para a
/// única ação destrutiva que aparece solta (fora de um menu) neste
/// formulário. Um `role: .destructive` sozinho não tinge nada de vermelho
/// quando o `ButtonStyle` é customizado (o estilo de contorno padrão do app
/// define sua própria cor de texto por cima), então este estilo existe só
/// para não perder esse sinal visual aqui.
private struct BotaoDeContornoDestrutivoPapagaio: ButtonStyle {
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(habilitado ? PapagaioTema.perigo : PapagaioTema.textoSecundario)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .frame(minHeight: PapagaioTema.Altura.destaque)
            .background(PapagaioTema.superficie, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PapagaioTema.perigo.opacity(habilitado ? 0.6 : 0.3), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
