import SwiftUI

struct GestaoDeEquipeView: View {
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let aoSelecionarEquipe: (EquipeDisponivel) -> Void
    let aoAtualizarQuantidadeDeMembros: (String, Int) -> Void
    let aoConvidarMembro: (MembroDaEquipe, EquipeDisponivel) async throws -> Void
    @State private var membros: [MembroDaEquipe] = []
    @State private var pagina = 0
    @State private var membroEditando: MembroDaEquipe?
    @State private var mostrandoAdicionar = false
    @State private var mostrandoTrocarEquipe = false
    @State private var conviteEmAndamento = false
    @State private var erroDoConvite: String?

    var body: some View {
        ScrollView {
            // Sem equipe não há membro para listar nem nome para exibir: a tela
            // inteira vira o convite para criar a primeira, no perfil.
            if equipeAtiva == nil {
                CartaoDeEstadoVazio(
                    simbolo: "person.3",
                    titulo: "Nenhuma equipe ainda",
                    mensagem: "Crie uma equipe no seu perfil para convidar pessoas e distribuir as tarefas das conversas."
                )
                .padding(.vertical, PapagaioTema.espacamentoDePagina)
            } else {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.largo) {
                            cabecalho
                        }

                        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                            cabecalho
                        }
                    }

                    TabelaDaEquipe(
                        membros: membros,
                        pagina: pagina,
                        aoEditar: { membroEditando = $0 },
                        aoRemover: remover,
                        aoAlternarPagina: alternarPagina
                    )
                }
                .larguraDeConteudoPapagaio()
                .padding(.horizontal, PapagaioTema.espacamentoDePagina)
                .padding(.vertical, PapagaioTema.espacamentoDePagina)
            }
        }
        .background(PapagaioTema.fundo)
        .onAppear {
            carregarMembrosDaEquipe()
        }
        .onChange(of: equipeAtiva?.id) { _, _ in
            carregarMembrosDaEquipe()
        }
        .sheet(isPresented: $mostrandoAdicionar) {
            EditorDeMembroDaEquipe(
                titulo: "Convidar membro",
                membro: MembroDaEquipe(nome: "", email: "", cargo: "Transcritor", status: .ativo),
                aoCancelar: { mostrandoAdicionar = false },
                aoSalvar: { novo in
                    convidar(novo)
                }
            )
        }
        .sheet(item: $membroEditando) { membro in
            EditorDeMembroDaEquipe(
                titulo: "Editar membro",
                membro: membro,
                aoCancelar: { membroEditando = nil },
                aoSalvar: { editado in
                    if let indice = membros.firstIndex(where: { $0.id == editado.id }) {
                        membros[indice] = editado
                        salvarMembrosDaEquipe()
                    }
                    membroEditando = nil
                }
            )
        }
        .sheet(isPresented: $mostrandoTrocarEquipe) {
            SeletorDeEquipeView(
                equipeAtiva: equipeAtiva,
                equipes: equipes,
                aoCancelar: { mostrandoTrocarEquipe = false },
                aoSelecionar: { equipe in
                    aoSelecionarEquipe(equipe)
                    mostrandoTrocarEquipe = false
                }
            )
        }
        .alert("Não foi possível enviar o convite", isPresented: Binding(
            get: { erroDoConvite != nil },
            set: { if !$0 { erroDoConvite = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(erroDoConvite ?? "")
        }
    }

    private var cabecalho: some View {
        Group {
                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                        Text("Equipe")
                            .font(PapagaioTema.Tipo.tituloDePagina)
                            .foregroundStyle(PapagaioTema.texto)

                        Text("Convide pessoas pelo e-mail do Apple Account para compartilhar as conversas de \(nomeDaEquipe).")
                            .font(.title3)
                            .lineSpacing(6)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                    }

                    Spacer()

                    Button("Mudar Equipe: \(nomeDaEquipe)", systemImage: "arrow.triangle.2.circlepath") {
                        mostrandoTrocarEquipe = true
                    }
                    .buttonStyle(BotaoDeContornoPapagaio())

                    Button("Convidar membro", systemImage: "person.badge.plus") {
                        mostrandoAdicionar = true
                    }
                    .buttonStyle(BotaoPrincipalPapagaio())
                    .disabled(conviteEmAndamento || equipeAtiva?.zonaCloudKit == nil)
        }
    }

    private func remover(_ membro: MembroDaEquipe) {
        guard !membro.atual else { return }
        erroDoConvite = "A remoção de participantes do iCloud ainda não foi implementada. O acesso de \(membro.nome) permanece ativo para não criar uma falsa impressão de segurança."
    }

    private func alternarPagina(_ delta: Int) {
        let ultima = max(0, (membros.count - 1) / TabelaDaEquipe.itensPorPagina)
        pagina = min(max(0, pagina + delta), ultima)
    }

    private var nomeDaEquipe: String {
        equipeAtiva?.nome ?? ""
    }

    private func carregarMembrosDaEquipe() {
        guard let equipeAtiva else {
            membros = []
            pagina = 0
            return
        }
        membros = MembrosDasEquipes.carregar(equipeID: equipeAtiva.id)
        pagina = 0
        aoAtualizarQuantidadeDeMembros(equipeAtiva.id, membros.count)
    }

    private func salvarMembrosDaEquipe() {
        guard let equipeAtiva else { return }
        MembrosDasEquipes.salvar(membros, equipeID: equipeAtiva.id)
        let ultima = max(0, (membros.count - 1) / TabelaDaEquipe.itensPorPagina)
        pagina = min(pagina, ultima)
        aoAtualizarQuantidadeDeMembros(equipeAtiva.id, membros.count)
    }

    private func convidar(_ membro: MembroDaEquipe) {
        guard let equipeAtiva else { return }
        conviteEmAndamento = true
        Task {
            defer { conviteEmAndamento = false }
            do {
                try await aoConvidarMembro(membro, equipeAtiva)
                membros.append(membro)
                salvarMembrosDaEquipe()
                mostrandoAdicionar = false
            } catch {
                erroDoConvite = error.localizedDescription
            }
        }
    }
}
