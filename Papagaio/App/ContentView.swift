import AppKit
import PapagaioCore
import SwiftUI
import UniformTypeIdentifiers

/// Coordenador da interface inicial.
///
/// Mantém a identidade dos view models e as integrações de sistema (navegação,
/// importação e Sign in with Apple). A composição visual vive em componentes
/// menores para que o redesign não altere o ciclo de vida do áudio.
struct ContentView: View {
    /// A gravação é criada no `App` e passada para cá: o item da barra de menus
    /// precisa observar exatamente o mesmo objeto que a janela.
    let modelo: GravadorViewModel

    init(gravador: GravadorViewModel) {
        modelo = gravador
    }

    @State private var biblioteca: Biblioteca?
    @State private var modelos: ModelosViewModel?
    @State private var perfil = PerfilViewModel()
    @State private var notificacoes = NotificacoesViewModel()
    @State private var equipes = EquipesDoUsuario.carregar()
    @State private var falhaDeAbertura: String?
    @State private var mostrandoImportador = false
    @State private var arquivoParaConfigurar: Arquivo?
    @State private var arquivosAguardandoFicha: Set<ArquivoID> = []
    @State private var tituloDaFicha = ""
    @State private var entrevistadoDaFicha = ""
    @State private var emailDoEntrevistadoDaFicha = ""
    @State private var entrevistadoresDaFicha = ""
    @State private var emailDosEntrevistadoresDaFicha = ""
    @State private var descricaoDaFicha = ""
    @State private var formatoDaFicha = ""
    @State private var participantesDaFicha = "1"
    @State private var dataDaFicha = Date()
    @State private var duracaoDaFicha = ""
    @State private var consulta = ""
    @State private var legendaDaBarra: LegendaDaBarra?
    @State private var secaoDaBiblioteca: SecaoDaBiblioteca = .todos
    @State private var telaSelecionada: TelaPrincipal = .biblioteca
    /// Foco na tela de captura. Sair dela não interrompe a gravação — some o
    /// painel e aparece o selo "Gravando", que traz de volta.
    @State private var focoNaGravacao = false
    /// Pilha de conversas abertas, para a barra saber que há uma na frente.
    @State private var conversaAberta: [UUID] = []
    @State private var pastaDaBibliotecaSelecionada: String?
    @AppStorage("processamentoAutomatico") private var processamentoAutomatico = true
    @AppStorage("contextoDaConta") private var contextoDaContaRaw = ContextoDaConta.perfil.rawValue
    @AppStorage("equipeAtiva") private var equipeAtivaID = ""
    @AppStorage("aparenciaDoApp") private var aparenciaRaw = AparenciaDoApp.sistema.rawValue

    private var aparencia: Binding<AparenciaDoApp> {
        Binding(
            get: { AparenciaDoApp(rawValue: aparenciaRaw) ?? .sistema },
            set: { aparenciaRaw = $0.rawValue }
        )
    }

    private var contextoDaConta: ContextoDaConta {
        get { ContextoDaConta(rawValue: contextoDaContaRaw) ?? .perfil }
        nonmutating set { contextoDaContaRaw = newValue.rawValue }
    }

    /// `nil` enquanto a pessoa não tiver criado nenhuma equipe.
    private var equipeAtiva: EquipeDisponivel? {
        equipes.first { $0.id == equipeAtivaID } ?? equipes.first
    }

    private var responsaveisDaEquipeAtiva: [ResponsavelDaTarefa] {
        guard let equipeAtiva else { return [] }
        return MembrosDasEquipes.carregar(equipeID: equipeAtiva.id).map {
            ResponsavelDaTarefa(nome: $0.nome, email: $0.email)
        }
    }

    var body: some View {
        NavigationStack(path: $conversaAberta) {
            VStack(spacing: 0) {
                BarraSuperiorPapagaioView(
                    consulta: $consulta,
                    legendaAtiva: $legendaDaBarra,
                    exibindoBotaoVoltar: !naTelaInicial,
                    bibliotecaSelecionada: telaSelecionada == .biblioteca && secaoDaBiblioteca != .lixeira,
                    tarefasSelecionada: telaSelecionada == .tarefas,
                    configuracoesSelecionada: telaSelecionada == .configuracoes,
                    lixeiraSelecionada: telaSelecionada == .biblioteca && secaoDaBiblioteca == .lixeira,
                    perfilConectado: perfil.conectado,
                    perfilVerificando: perfil.verificando,
                    avatarURL: perfil.avatarURL,
                    contextoDaConta: contextoDaConta,
                    equipeAtiva: equipeAtiva,
                    gravando: modelo.gravando && focoNaGravacao,
                    processandoBiblioteca: biblioteca?.processando ?? false,
                    quantidadeDeAvisos: notificacoes.naoLidas,
                    notificacoes: notificacoes.itens,
                    aoEntrar: perfil.entrar,
                    aoSair: sairDoPerfil,
                    aoMarcarNotificacoesComoLidas: notificacoes.marcarComoLidas,
                    aoLimparNotificacoes: notificacoes.limpar,
                    aoVoltar: voltar,
                    aoAbrirBiblioteca: voltarParaBiblioteca,
                    aoAbrirTarefas: abrirTarefas,
                    aoAbrirConfiguracoes: { telaSelecionada = .configuracoes },
                    aoAbrirLixeira: abrirLixeira,
                    aoUsarPerfil: selecionarPerfilPessoal,
                    aoUsarEquipe: selecionarEquipe,
                    aoGerenciarPerfil: abrirPerfil,
                    aoGerenciarEquipe: abrirEquipe
                )

                if let falhaDeAbertura {
                    Label(falhaDeAbertura, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.perigo)
                        .padding(PapagaioTema.Espaco.largo)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PapagaioTema.perigo.opacity(0.08))
                }

                switch telaSelecionada {
                case .biblioteca:
                    BibliotecaHomeView(
                        gravador: modelo,
                        biblioteca: biblioteca,
                        modelos: modelos,
                        consulta: $consulta,
                        secaoSelecionada: $secaoDaBiblioteca,
                        pastaSelecionada: $pastaDaBibliotecaSelecionada,
                        mostrandoImportador: $mostrandoImportador,
                        processamentoAutomatico: processamentoAutomatico,
                        aoAlternarGravacao: {
                            await modelo.alternarGravacao()
                            withAnimation(.snappy(duration: 0.18)) {
                                focoNaGravacao = modelo.gravando
                            }
                        },
                        aoPausarGravacao: { await modelo.pausar() },
                        aoContinuarGravacao: { await modelo.continuar() },
                        aoCancelarGravacao: {
                            await modelo.cancelar()
                            focoNaGravacao = false
                        },
                        aoEscolherPastaDeModelos: escolherPastaDeModelos,
                        aoUsarPastaDoApp: usarPastaDoApp,
                        aoSoltarArquivos: importarArrastados,
                        focoNaGravacao: $focoNaGravacao
                    )
                case .tarefas:
                    TarefasView(
                        biblioteca: biblioteca,
                        consulta: consulta
                    )
                case .configuracoes:
                    ConfiguracoesView(
                        processamentoAutomatico: $processamentoAutomatico,
                        aparencia: aparencia
                    )
                case .perfil:
                    PerfilPessoalView(
                        perfil: perfil,
                        equipeAtiva: equipeAtiva,
                        equipes: equipes,
                        aoSelecionarEquipe: usarEquipe,
                        aoAdicionarEquipe: adicionarEquipe,
                        aoSair: sairDoPerfil
                    )
                case .equipe:
                    GestaoDeEquipeView(
                        equipeAtiva: equipeAtiva,
                        equipes: equipes,
                        aoSelecionarEquipe: usarEquipe,
                        aoAtualizarQuantidadeDeMembros: atualizarQuantidadeDeMembros
                    )
                }
            }
            .background(PapagaioTema.fundo.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) {
                // Sem padding: a legenda se ancora na base do próprio ícone,
                // então a folga vive dentro de LegendaGlobalDaBarra.
                LegendaGlobalDaBarra(texto: legendaDaBarra)
            }
            .overlay(alignment: .bottomTrailing) {
                seloDeGravacaoEmAndamento
            }
            .navigationDestination(for: UUID.self) { id in
                if let biblioteca, let arquivo = biblioteca.arquivo(id: id) {
                    ArquivoDetalheView(
                        arquivo: arquivo,
                        audio: biblioteca.audio(de: arquivo),
                        audioSecundario: biblioteca.audioSecundario(de: arquivo),
                        estado: biblioteca.estado(de: arquivo),
                        processando: biblioteca.estaProcessando(arquivo),
                        naFila: biblioteca.estaNaFila(arquivo),
                        responsaveisDisponiveis: responsaveisDaEquipeAtiva,
                        aoTranscrever: { biblioteca.enfileirarProcessamento(arquivo) },
                        aoAtualizarNotas: { notas in
                            await biblioteca.atualizarNotas(notas, de: arquivo)
                        },
                        aoNotificarTarefa: { titulo, mensagem in
                            notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: .aviso)
                        },
                        aoAtualizarMetadados: { titulo, data, duracao in
                            Task { await biblioteca.atualizarMetadados(arquivo, titulo: titulo, criadoEm: data, duracao: duracao) }
                        },
                        aoAtualizarTranscricao: { trechos in
                            await biblioteca.atualizarTrechos(trechos, de: arquivo)
                        },
                        aoDitar: { url in try await biblioteca.transcreverDitado(url) },
                        // A conversa substitui a raiz do `NavigationStack`, e
                        // com ela some a barra do app. Ajustes e lixeira
                        // viajam junto para não ficarem inalcançáveis aqui.
                        aoAbrirConfiguracoes: {
                            conversaAberta.removeAll()
                            telaSelecionada = .configuracoes
                        }
                    )
                }
            }
        }
        // Piso de conforto, não de correção: quem garante que nada transborda é
        // a própria barra superior, que colapsa em estágios. Este mínimo só
        // evita abrir a janela num tamanho em que a grade de cartões fica com
        // uma coluna só. Note que `windowResizability(.contentMinSize)` não
        // propaga isto de forma confiável através do `NavigationStack` — por
        // isso nenhum layout depende deste número.
        .frame(minWidth: 460, minHeight: 520)
        // `nil` em "Sistema": sem esquema preferido a janela herda a aparência
        // do Mac. Nos outros dois casos isto fixa a aparência da janela, e as
        // cores dinâmicas do tema resolvem em cima dela.
        .preferredColorScheme(aparencia.wrappedValue.esquemaPreferido)
        .task {
            notificacoes.preparar()
            perfil.iniciar()
            await abrir()
        }
        .onChange(of: processamentoAutomatico) { _, novoValor in
            biblioteca?.processamentoAutomatico = novoValor
        }
        .fileImporter(
            isPresented: $mostrandoImportador,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav]
        ) { resultado in
            guard case let .success(url) = resultado,
                  url.startAccessingSecurityScopedResource()
            else { return }
            Task {
                defer { url.stopAccessingSecurityScopedResource() }
                await modelo.importar(url)
            }
        }
        .sheet(isPresented: Binding(
            get: { arquivoParaConfigurar != nil },
            set: { if !$0 { arquivoParaConfigurar = nil } }
        )) {
            EditorDeInformacoesDoCard(
                modo: .nova,
                titulo: $tituloDaFicha,
                entrevistado: $entrevistadoDaFicha,
                emailDoEntrevistado: $emailDoEntrevistadoDaFicha,
                entrevistadores: $entrevistadoresDaFicha,
                emailDosEntrevistadores: $emailDosEntrevistadoresDaFicha,
                descricao: $descricaoDaFicha,
                formato: $formatoDaFicha,
                participantes: $participantesDaFicha,
                data: $dataDaFicha,
                duracao: $duracaoDaFicha,
                aoCancelar: { arquivoParaConfigurar = nil },
                aoSalvar: salvarFichaDaEntrevista
            )
        }
        .alert("Não foi possível entrar", isPresented: Binding(
            get: { perfil.erro != nil },
            set: { if !$0 { perfil.dispensarErro() } }
        )) {
            Button("OK", role: .cancel) { perfil.dispensarErro() }
        } message: {
            Text(perfil.erro ?? "")
        }
    }

    private func abrir() async {
        guard biblioteca == nil else { return }
        do {
            let nova = try Biblioteca()
            nova.processamentoAutomatico = processamentoAutomatico
            nova.aoNotificar = { titulo, mensagem, tipo in
                notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: tipo)
            }
            nova.aoConcluirProcessamento = { arquivo in
                guard arquivosAguardandoFicha.contains(arquivo.id) else { return }
                arquivosAguardandoFicha.remove(arquivo.id)
                abrirFichaDaEntrevista(para: arquivo)
            }
            biblioteca = nova

            let gerenciador = ModelosViewModel(
                pastaDoContainer: nova.armazenamento.pastaDeModelos
            )
            gerenciador.verificar()
            nova.pastaDeModelos = gerenciador.pasta
            modelos = gerenciador

            // A gravação entrega o áudio; a biblioteca salva e processa. Esta
            // ligação permanece na raiz para não desaparecer ao redesenhar uma
            // subview de biblioteca.
            modelo.aoProduzirAudio = { titulo, pasta, duracao, notas in
                if let arquivo = await nova.registrar(
                    titulo: titulo,
                    pastaRelativa: pasta,
                    duracao: duracao,
                    notas: notas
                ) {
                    if let pastaDaBibliotecaSelecionada {
                        PreferenciasVisuaisDoArquivo.definirPasta(
                            pastaDaBibliotecaSelecionada,
                            para: arquivo.id
                        )
                    }
                    if nova.processamentoAutomatico {
                        arquivosAguardandoFicha.insert(arquivo.id)
                    } else {
                        abrirFichaDaEntrevista(para: arquivo)
                    }
                }
            }
            await nova.preparar()
        } catch {
            falhaDeAbertura = "Não foi possível abrir a biblioteca: \(error)"
        }
    }

    private func abrirFichaDaEntrevista(para arquivo: Arquivo) {
        let metadados = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
        arquivoParaConfigurar = arquivo
        tituloDaFicha = arquivo.resumo?.titulo ?? arquivo.titulo
        entrevistadoDaFicha = metadados.entrevistado
        emailDoEntrevistadoDaFicha = metadados.emailDoEntrevistado
        entrevistadoresDaFicha = metadados.entrevistadores
        emailDosEntrevistadoresDaFicha = metadados.emailDosEntrevistadores
        descricaoDaFicha = metadados.descricao
        formatoDaFicha = metadados.formato
        participantesDaFicha = "\(max(1, metadados.participantes ?? 1))"
        dataDaFicha = arquivo.criadoEm
        duracaoDaFicha = arquivo.duracao.comoDuracaoPorExtenso
    }

    private func salvarFichaDaEntrevista() {
        guard let arquivo = arquivoParaConfigurar,
              let biblioteca
        else { return }

        let tituloLimpo = tituloDaFicha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty else { return }

        // Participantes deixou de ser um campo digitável na ficha: sai da soma
        // dos nomes que a pessoa acabou de preencher. Ler do estado antigo
        // deixava sempre "1", independente de quantos nomes havia.
        let quantidade = max(
            1,
            nomesInformados(entrevistadoDaFicha) + nomesInformados(entrevistadoresDaFicha)
        )
        let metadados = MetadadosVisuaisDoArquivo(
            entrevistado: entrevistadoDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDoEntrevistado: emailDoEntrevistadoDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            entrevistadores: entrevistadoresDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDosEntrevistadores: emailDosEntrevistadoresDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            descricao: descricaoDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            formato: formatoDaFicha.trimmingCharacters(in: .whitespacesAndNewlines),
            participantes: quantidade
        )
        PreferenciasVisuaisDoArquivo.definirMetadados(metadados, para: arquivo.id)

        // A duração não é editável na ficha: continua sendo a do próprio áudio.
        let duracao = arquivo.duracao
        Task {
            await biblioteca.atualizarMetadados(arquivo, titulo: tituloLimpo, criadoEm: dataDaFicha, duracao: duracao)
            await MainActor.run {
                arquivoParaConfigurar = nil
            }
        }
    }

    private func nomesInformados(_ texto: String) -> Int {
        texto
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    /// Importa arquivos soltos do Finder.
    ///
    /// Vindo do `.dropDestination`, a URL **não** é security-scoped como a do
    /// `.fileImporter`: o próprio arraste é a autorização do usuário, e chamar
    /// `startAccessingSecurityScopedResource` aqui devolveria `false` e
    /// abortaria a importação de um arquivo perfeitamente acessível.
    private func importarArrastados(_ urls: [URL]) {
        let audios = urls.filter { Self.extensoesDeAudio.contains($0.pathExtension.lowercased()) }
        guard !audios.isEmpty else { return }
        // Mesmo caminho do `.fileImporter`: quem importa é o gravador, que já
        // sabe avisar sobre canal único e devolver o arquivo para a biblioteca.
        Task {
            for url in audios {
                await modelo.importar(url)
            }
        }
    }

    private static let extensoesDeAudio: Set<String> = [
        "m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov",
    ]

    private func abrirLixeira() {
        telaSelecionada = .biblioteca
        secaoDaBiblioteca = .lixeira
    }

    private func abrirTarefas() {
        telaSelecionada = .tarefas
        secaoDaBiblioteca = .todos
    }

    private func abrirPerfil() {
        telaSelecionada = .perfil
        secaoDaBiblioteca = .todos
    }

    private func abrirEquipe() {
        telaSelecionada = .equipe
        secaoDaBiblioteca = .todos
    }

    private func selecionarPerfilPessoal() {
        contextoDaConta = .perfil
    }

    /// Entra no contexto de equipe mesmo sem equipe alguma — é lá que mora o
    /// estado vazio que convida a criar a primeira.
    private func selecionarEquipe() {
        contextoDaConta = .equipe
        if let equipeAtiva { equipeAtivaID = equipeAtiva.id }
    }

    private func usarEquipe(_ equipe: EquipeDisponivel) {
        contextoDaConta = .equipe
        equipeAtivaID = equipe.id
    }

    private func adicionarEquipe(nome: String) {
        let nomeLimpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nomeLimpo.isEmpty else { return }

        let base = nomeLimpo
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: " ", with: "-")

        let nova = EquipeDisponivel(
            id: "\(base)-\(UUID().uuidString.prefix(6))",
            nome: nomeLimpo,
            papel: "Administrador",
            quantidadeDeMembros: 1
        )
        equipes.append(nova)
        EquipesDoUsuario.salvar(equipes)
        usarEquipe(nova)
    }

    private func atualizarQuantidadeDeMembros(equipeID: String, quantidade: Int) {
        guard let indice = equipes.firstIndex(where: { $0.id == equipeID }) else { return }
        equipes[indice].quantidadeDeMembros = quantidade
        EquipesDoUsuario.salvar(equipes)
    }

    private func sairDoPerfil() {
        perfil.sair()
        contextoDaConta = .perfil
        voltarParaBiblioteca()
    }

    /// A raiz do app: biblioteca, em "Todas", sem conversa aberta e fora da
    /// captura. Em qualquer outro lugar o chevron aparece.
    private var naTelaInicial: Bool {
        conversaAberta.isEmpty
            && !focoNaGravacao
            && telaSelecionada == .biblioteca
            && secaoDaBiblioteca == .todos
    }

    /// Um passo por vez, e sempre em direção à tela inicial: fecha a conversa,
    /// sai da captura, volta para a biblioteca. Antes, de Equipe o botão ia
    /// para Perfil — hierarquia que fazia o mesmo botão significar coisas
    /// diferentes conforme a tela.
    private func voltar() {
        if !conversaAberta.isEmpty {
            conversaAberta.removeLast()
            return
        }
        if focoNaGravacao {
            withAnimation(.snappy(duration: 0.18)) { focoNaGravacao = false }
            return
        }
        voltarParaBiblioteca()
    }

    /// Selo que segue a pessoa por todas as telas enquanto a gravação continua
    /// rodando fora da tela de captura. Sem ele, sair da captura escondia a
    /// gravação inteira e o microfone seguia ligado sem sinal na janela.
    @ViewBuilder
    private var seloDeGravacaoEmAndamento: some View {
        if modelo.gravando && !focoNaGravacao {
            Button {
                telaSelecionada = .biblioteca
                secaoDaBiblioteca = .todos
                withAnimation(.snappy(duration: 0.18)) { focoNaGravacao = true }
            } label: {
                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Circle()
                        .fill(modelo.pausado ? PapagaioTema.aviso : PapagaioTema.perigo)
                        .frame(width: 9, height: 9)

                    Text(modelo.pausado ? "Pausado" : "Gravando")
                        .font(.callout.weight(.semibold))

                    Text(modelo.tempoDeGravacao.comoCronometro)
                        .font(.system(.callout, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundStyle(PapagaioTema.texto)
                .padding(.horizontal, PapagaioTema.Espaco.largo)
                .frame(height: PapagaioTema.Altura.padrao)
                .background(PapagaioTema.superficie, in: Capsule())
                .overlay { Capsule().stroke(PapagaioTema.borda, lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .help("Voltar para a gravação em andamento")
            .padding(PapagaioTema.Espaco.secao)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func voltarParaBiblioteca() {
        telaSelecionada = .biblioteca
        secaoDaBiblioteca = .todos
    }

    /// Toda mudança de origem dos pesos passa por aqui. Antes, voltar para a
    /// pasta do app deixava a `Biblioteca` apontando para a pasta externa.
    private func escolherPastaDeModelos(_ url: URL) {
        modelos?.escolher(url)
        sincronizarPastaDeModelos()
    }

    private func usarPastaDoApp() {
        modelos?.usarOContainer()
        sincronizarPastaDeModelos()
    }

    private func sincronizarPastaDeModelos() {
        guard let modelos else { return }
        biblioteca?.pastaDeModelos = modelos.pasta
    }
}

#Preview {
    ContentView(gravador: GravadorViewModel())
}
