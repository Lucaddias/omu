import PapagaioCore
import SwiftUI

struct EditorDeTarefaGeralSheet: View {
    enum Modo {
        case criacao
        case edicao
    }

    let modo: Modo
    let conversas: [Arquivo]
    @Binding var conversaSelecionada: ArquivoID?
    @Binding var titulo: String
    @Binding var descricao: String
    @Binding var responsavel: String
    @Binding var prioridade: PrioridadeDaTarefa
    @Binding var status: StatusDaTarefa
    @Binding var prazo: Date
    let aoCancelar: () -> Void
    let aoSalvar: () -> Void

    private var conversaAtual: Arquivo? {
        guard let conversaSelecionada else { return nil }
        return conversas.first { $0.id == conversaSelecionada }
    }

    private var podeSalvar: Bool {
        conversaSelecionada != nil && !titulo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Image(systemName: modo == .criacao ? "plus.circle" : "pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .frame(width: 46, height: 46)
                    .background(PapagaioTema.destaqueSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(modo == .criacao ? "Nova tarefa".localized : "Editar tarefa".localized)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PapagaioTema.texto)
                    Text("Escolha a conversa, descreva a tarefa e defina prioridade, responsável e data limite.".localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer()
            }

            campo("Conversa".localized) {
                Menu {
                    ForEach(conversas) { conversa in
                        Button(conversa.resumo?.titulo ?? conversa.titulo) {
                            conversaSelecionada = conversa.id
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "bubble.left")
                        Text(conversaAtual.map { $0.resumo?.titulo ?? $0.titulo } ?? "Escolher conversa".localized)
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
            }

            campo("Título".localized) {
                TextField("Ex.: Revisar documentação".localized, text: $titulo)
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

            campo("Descrição".localized) {
                // Fundo e borda no próprio `TextEditor`, e não num `ZStack` ao
                // redor — mesmo padrão do editor de trecho corrigido, na tela
                // de detalhe. Com a caixa aplicada a um irmão, o recuo interno
                // que o `TextEditor` já tem por conta própria não batia com o
                // do rótulo por cima, e o cursor nascia fora da caixa.
                TextEditor(text: $descricao)
                    .font(.body)
                    .foregroundStyle(PapagaioTema.texto)
                    .scrollContentBackground(.hidden)
                    .textEditorStyle(.plain)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .padding(.vertical, PapagaioTema.Espaco.curto)
                    .frame(height: 88)
                    .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if descricao.isEmpty {
                            Text("Detalhes, contexto ou o que precisa ser feito".localized)
                                .font(.body)
                                .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.7))
                                .padding(.horizontal, PapagaioTema.Espaco.curto + 5)
                                .padding(.vertical, PapagaioTema.Espaco.curto + 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                            .stroke(PapagaioTema.borda, lineWidth: 1)
                    }
            }

            campo("Responsável".localized) {
                TextField("Nome, e-mail ou login".localized, text: $responsavel)
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

            campo("Prioridade".localized) {
                ControleSegmentadoPapagaio(
                    opcoes: PrioridadeDaTarefa.allCases,
                    selecionado: $prioridade,
                    titulo: { $0.titulo },
                    simbolo: { _ in nil }
                )
            }

            campo("Data limite".localized) {
                CampoDeDataPapagaio(data: $prazo, rotuloAcessivel: "Data limite".localized)
            }

            HStack(spacing: PapagaioTema.Espaco.medio) {
                Button("Cancelar".localized, action: aoCancelar)
                    .buttonStyle(BotaoDeContornoPapagaio())

                Spacer()

                Button(modo == .criacao ? "Adicionar tarefa".localized : "Salvar alterações".localized, systemImage: modo == .criacao ? "plus" : "checkmark") {
                    aoSalvar()
                }
                .buttonStyle(BotaoPrincipalPapagaio())
                .disabled(!podeSalvar)
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(width: 540, alignment: .leading)
        .background(PapagaioTema.fundo)
    }

    private func campo<Conteudo: View>(_ titulo: String, @ViewBuilder conteudo: () -> Conteudo) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text(titulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
            conteudo()
        }
    }
}
