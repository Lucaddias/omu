import AppKit
import SwiftUI

struct PerfilPessoalView: View {
    @Bindable var perfil: PerfilViewModel
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let aoSelecionarEquipe: (EquipeDisponivel) -> Void
    let aoAdicionarEquipe: (String) -> Void
    let aoEntrarComCodigo: (String) -> Void
    let aoSair: () -> Void
    let aoExcluirConta: () async throws -> Void
    @State private var nome: String = ""
    @State private var email: String = ""
    @State private var mostrandoAvisoDeSenha = false
    @State private var mostrandoConfirmacaoDeExclusao = false
    @State private var excluindoConta = false
    @State private var erroDeExclusao: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                Text("Meu Perfil".localized)
                    .font(PapagaioTema.Tipo.tituloDePagina)
                    .foregroundStyle(PapagaioTema.texto)

                CartaoDeIdentidadeDoPerfil(
                    nome: nome,
                    email: email,
                    avatarURL: perfil.avatarURL,
                    aoEditarAvatar: escolherAvatar
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: PapagaioTema.Espaco.secao) {
                        InformacoesPessoaisDoPerfil(
                            nome: $nome,
                            email: $email,
                            aoSalvar: salvarDados
                        )
                        .frame(maxWidth: .infinity)

                        EquipesDoPerfil(
                            equipeAtiva: equipeAtiva,
                            equipes: equipes,
                            aoSelecionar: aoSelecionarEquipe,
                            aoAdicionarEquipe: aoAdicionarEquipe,
                            aoEntrarComCodigo: aoEntrarComCodigo
                        )
                        .frame(width: 330)
                    }

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                        InformacoesPessoaisDoPerfil(
                            nome: $nome,
                            email: $email,
                            aoSalvar: salvarDados
                        )

                        EquipesDoPerfil(
                            equipeAtiva: equipeAtiva,
                            equipes: equipes,
                            aoSelecionar: aoSelecionarEquipe,
                            aoAdicionarEquipe: aoAdicionarEquipe,
                            aoEntrarComCodigo: aoEntrarComCodigo
                        )
                    }
                }

                SegurancaDoPerfil(
                    aoAlterarSenha: { mostrandoAvisoDeSenha = true },
                    aoSair: aoSair,
                    aoExcluirConta: { mostrandoConfirmacaoDeExclusao = true },
                    excluindoConta: excluindoConta
                )
                .frame(maxWidth: 690)
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
        }
        .background(PapagaioTema.fundo)
        .onAppear {
            nome = perfil.nome
            email = perfil.email
        }
        // O onAppear sozinho deixa os campos velhos quando o perfil muda com
        // a tela já montada (troca de conta, fim do sign-in): os campos
        // seguem o modelo enquanto a view existe.
        .onChange(of: perfil.nome) { _, novo in nome = novo }
        .onChange(of: perfil.email) { _, novo in email = novo }
        .alert("Login com Apple".localized, isPresented: $mostrandoAvisoDeSenha) {
            Button("OK".localized, role: .cancel) {}
        } message: {
            Text("A senha é gerenciada pelo seu ID Apple. Para alterar, use os ajustes da sua conta Apple.".localized)
        }
        .alert("Excluir perfil deste Mac?".localized, isPresented: $mostrandoConfirmacaoDeExclusao) {
            Button("Cancelar".localized, role: .cancel) {}
            Button("Excluir perfil e dados pessoais".localized, role: .destructive) {
                Task { await excluirConta() }
            }
        } message: {
            Text("Esta ação não pode ser desfeita. Seu perfil, conversas pessoais, áudios, transcrições, notas, tarefas, vínculos de equipe e conexões com Google Calendar e Granola serão removidos deste Mac. Os dados dos espaços de equipe, as preferências do app e os compartilhamentos do iCloud serão preservados.".localized)
        }
        .alert("Não foi possível excluir a conta".localized, isPresented: Binding(
            get: { erroDeExclusao != nil },
            set: { if !$0 { erroDeExclusao = nil } }
        )) {
            Button("OK".localized, role: .cancel) { erroDeExclusao = nil }
        } message: {
            Text(erroDeExclusao ?? "")
        }
    }

    private func salvarDados() {
        perfil.salvarDados(nome: nome, email: email)
        nome = perfil.nome
        email = perfil.email
    }

    private func escolherAvatar() {
        let painel = NSOpenPanel()
        painel.allowedContentTypes = [.image]
        painel.allowsMultipleSelection = false
        painel.canChooseDirectories = false
        painel.canChooseFiles = true
        painel.title = "Escolher foto do perfil".localized
        // `begin` no lugar de `runModal`: o painel deixa de travar a main
        // enquanto a pessoa navega.
        painel.begin { resposta in
            guard resposta == .OK, let url = painel.url else { return }
            Task { @MainActor in
                perfil.escolherAvatar(url)
            }
        }
    }

    private func excluirConta() async {
        excluindoConta = true
        defer { excluindoConta = false }

        do {
            try await aoExcluirConta()
        } catch {
            erroDeExclusao = error.localizedDescription
        }
    }
}
