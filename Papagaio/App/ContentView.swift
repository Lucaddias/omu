import AppKit
import PapagaioCore
import SwiftUI
import UniformTypeIdentifiers

/// Caixa de referência para transportar a reunião pendente do Calendar
/// entre a View e o handler `modelo.aoProduzirAudio` instalado uma vez.
final class CaixaPendente: ObservableObject {
    @Published var pendente: ReuniaoPendenteCalendar?
}

/// O formulário da ficha da entrevista num valor só. Os campos espelham os do
/// `EditorDeInformacoesDoCard`; juntá-los aqui faz abrir, salvar e resetar o
/// formulário virarem uma operação cada — antes eram dez estados soltos que
/// precisavam andar em sincronia na mão.
struct FichaDaEntrevista {
    var titulo = ""
    var entrevistado = ""
    var emailDoEntrevistado = ""
    var entrevistadores = ""
    var emailDosEntrevistadores = ""
    var descricao = ""
    var formato = ""
    var participantes = "1"
    var data = Date()
    var duracao = ""
}

/// Coordenador da interface inicial.
///
/// Mantém a identidade dos view models e as integrações de sistema (navegação,
/// importação e Sign in with Apple). A composição visual vive em componentes
/// menores para que o redesign não altere o ciclo de vida do áudio.
struct ContentView: View {
    /// A gravação é criada no `App` e passada para cá: o item da barra de menus
    /// precisa observar exatamente o mesmo objeto que a janela.
    let modelo: GravadorViewModel
    private let politicaDeInicializacaoExterna: PoliticaDeInicializacaoExterna

    init(
        gravador: GravadorViewModel,
        politicaDeInicializacaoExterna: PoliticaDeInicializacaoExterna = .init()
    ) {
        modelo = gravador
        self.politicaDeInicializacaoExterna = politicaDeInicializacaoExterna
    }

    @State private var biblioteca: Biblioteca?
    @State private var tarefaDeSelecaoDeEspaco: Task<Void, Never>?
    @State private var modelos: ModelosViewModel?
    /// A conexão com o Granola. Nasce junto com a biblioteca (`abrir`), que é
    /// quem também entrega o destino das importações.
    @State private var granola: GranolaViewModel?
    /// A conexão com o Google Calendar.
    @State private var googleCalendar: GoogleCalendarViewModel?
#if OMU_PERF
    @State private var perfil = PerfilViewModel(semPersistenciaDeConta: PerfProbe.ativada)
#else
    @State private var perfil = PerfilViewModel()
#endif
    @State private var notificacoes = NotificacoesViewModel()
    @State private var equipes = EquipesDoUsuario.carregar()
    @State private var falhaDeAbertura: String?
    @State private var mostrandoImportador = false
    @State private var arquivoParaConfigurar: Arquivo?
    @State private var arquivosAguardandoFicha: Set<ArquivoID> = []
    /// Caixa de referência para a pendente em gravação: o handler
    /// `modelo.aoProduzirAudio` é instalado uma vez e sobrevive a
    /// reconstruções da View. Um `@State` puro seria capturado com valor
    /// obsoleto; a caixa mantém a referência viva.
    @StateObject private var pendenteEmGravacao = CaixaPendente()
    /// O formulário da ficha num valor só: abrir, salvar e resetar viram uma
    /// operação cada, no lugar de dez estados soltos que precisavam andar em
    /// sincronia na mão.
    @State private var ficha = FichaDaEntrevista()
    @State private var consulta = ""
    @State private var legendaDaBarra: LegendaDaBarra?
    @State private var confirmandoCancelamentoDaGravacao = false
    /// Espaço ocupado pelo player na tela atual, anunciado por quem o desenha.
    @State private var alturaDoPlayer: CGFloat = 0
    /// Criado somente quando uma ação de equipe realmente pede CloudKit.
    /// Construir `CKContainer` junto com a view derruba o host unsigned dos
    /// testes antes mesmo de a primeira asserção executar.
    private var servicoDeEquipesCloudKit: ServicoDeEquipesCloudKit {
        ServicoDeEquipesCloudKit()
    }

    /// Dentro de uma conversa, onde a base pertence ao player.
    private var seloNoTopo: Bool { !conversaAberta.isEmpty }
    @State private var secaoDaBiblioteca: SecaoDaBiblioteca = .todos
    @State private var telaSelecionada: TelaPrincipal = .biblioteca
    /// Foco na tela de captura. Sair dela não interrompe a gravação — some o
    /// painel e aparece o selo "Gravando", que traz de volta.
    @State private var focoNaGravacao = false
    /// Pilha de conversas abertas, para a barra saber que há uma na frente.
    @State private var conversaAberta: [UUID] = []
    @State private var pastaDaBibliotecaSelecionada: String?
    @AppStorage("processamentoAutomatico") private var processamentoAutomatico = true
    @AppStorage("exibirFichaAutomaticamente") private var exibirFichaAutomaticamente = true
    @AppStorage("contextoDaConta") private var contextoDaContaRaw = ContextoDaConta.perfil.rawValue
    @AppStorage("equipeAtiva") private var equipeAtivaID = ""
    @AppStorage("aparenciaDoApp") private var aparenciaRaw = AparenciaDoApp.sistema.rawValue

#if OMU_PERF
    private var telaDaSonda: String {
        if telaSelecionada == .biblioteca, !conversaAberta.isEmpty { return "detalhe" }
        switch telaSelecionada {
        case .biblioteca: return "biblioteca"
        case .tarefas: return "tarefas"
        case .midias: return "midias"
        case .configuracoes: return "configuracoes"
        case .perfil: return "perfil"
        case .equipe: return "equipe"
        }
    }
#endif

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
                barraSuperior

                if let falhaDeAbertura {
                    mensagemDeErro(falhaDeAbertura)
                }

                conteudoDaTela
            }
            .background(PapagaioTema.fundo.ignoresSafeArea())
            // A seleção de texto **não** fica na raiz.
            //
            // `.textSelection(.enabled)` aqui vale para toda a árvore, e no
            // macOS cada `Text` selecionável monta a máquina de seleção do
            // AppKit. Numa grade de vinte cartões — cada um com título,
            // descrição, datas e nomes — e numa transcrição de milhares de
            // palavras, isso é o suficiente para a janela parar de responder.
            //
            // Ela vive onde a leitura acontece: no conteúdo da conversa, em
            // `ArquivoDetalheView`. Cartão da biblioteca não é texto para
            // copiar, é alvo de clique.
        .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) {
                // Sem padding: a legenda se ancora na base do próprio ícone,
                // então a folga vive dentro de LegendaGlobalDaBarra.
                LegendaGlobalDaBarra(texto: legendaDaBarra)
            }
            .navigationDestination(for: UUID.self) { id in
                destinoDaConversa(id)
            }
        }
#if OMU_PERF
        .overlay(alignment: .topLeading) {
            MarcadorDoPrimeiroFrame(tela: telaDaSonda)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
#endif
        // Piso de conforto, não de correção: quem garante que nada transborda é
        // a própria barra superior, que colapsa em estágios. Este mínimo só
        // evita abrir a janela num tamanho em que a grade de cartões fica com
        // uma coluna só. Note que `windowResizability(.contentMinSize)` não
        // propaga isto de forma confiável através do `NavigationStack` — por
        // isso nenhum layout depende deste número.
        // O selo fica **fora** do `NavigationStack`: dentro dele, abrir uma
        // conversa substituía a raiz e levava o selo junto — justamente quando
        // ele mais importa, que é longe da tela de captura.
        // Dentro de uma conversa o selo vai para o topo, centralizado: embaixo
        // ele disputa espaço com o player, e subir só um pouco o deixava
        // pairando no meio do caminho. Em cima há uma faixa livre entre o
        // voltar e o compartilhar, e ele não cobre nada.
        //
        // Nas outras telas fica no canto inferior direito, longe do conteúdo e
        // perto de onde a pessoa espera avisos do sistema.
        .overlay(alignment: seloNoTopo ? .top : .bottomTrailing) {
            seloDeGravacaoEmAndamento
        }
        .onPreferenceChange(AlturaDoPlayerKey.self) { altura in
            alturaDoPlayer = altura
        }
        .frame(minWidth: 460, minHeight: 520)
        // Atalhos globais da janela: ⌘R alterna a gravação e ⌘[ volta um
        // passo, de qualquer tela. São botões invisíveis de propósito —
        // existem só para o sistema rotear as teclas; as ações vivem nos
        // mesmos lugares de sempre (selo, barra superior).
        .background {
            Group {
                Button("") {
                    Task { await aoAlternarGravacao() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("", action: voltar)
                    .keyboardShortcut("[", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        // `nil` em "Sistema": sem esquema preferido a janela herda a aparência
        // do Mac. Nos outros dois casos isto fixa a aparência da janela, e as
        // cores dinâmicas do tema resolvem em cima dela.
        .preferredColorScheme(aparencia.wrappedValue.esquemaPreferido)
        .onChange(of: aparenciaRaw) { _, novoRaw in
            let nova = AparenciaDoApp(rawValue: novoRaw) ?? .sistema
            SincroniaDeAparencia.aplicar(nova)
        }
        .onAppear {
            // Relançamento com claro/escuro salvo: preferredColorScheme aplica,
            // mas window.appearance ainda é nil sem isto.
            SincroniaDeAparencia.aplicar(AparenciaDoApp(rawValue: aparenciaRaw) ?? .sistema)
        }
        .onReceive(NotificationCenter.default.publisher(for: .equipeCloudKitAceita)) { notificacao in
            guard let equipe = notificacao.object as? EquipeDisponivel else { return }
            equipes = EquipesDoUsuario.carregar()
            usarEquipe(equipe)
        }
        .onReceive(NotificationCenter.default.publisher(for: .equipeCloudKitFalhou)) { notificacao in
            guard let mensagem = notificacao.object as? String else { return }
            falhaDeAbertura = "Não foi possível aceitar o convite do iCloud: %@".localized(mensagem)
        }
        .onReceive(NotificationCenter.default.publisher(for: .abrirGravacaoNoApp)) { _ in
            voltarParaGravacao()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Quem volta ao Ōmu espera ver o que a equipe fez enquanto outro
            // app estava na frente, sem aguardar a próxima consulta periódica.
            guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
            Task { await biblioteca?.atualizarEquipeEmSegundoPlano() }
        }
        .task {
            await abrir()
            await politicaDeInicializacaoExterna.executar {
                notificacoes.preparar()
                perfil.iniciar()
                await conectarGoogleCalendarSeAutorizado()
            }
#if OMU_PERF
            if PerfProbe.ativada {
                PerfProbe.shared.iniciarCenario(
                    importar: { url in await modelo.importar(url) },
                    navegar: { tela in
                        switch tela {
                        case "biblioteca": telaSelecionada = .biblioteca
                        case "tarefas": telaSelecionada = .tarefas
                        case "midias": telaSelecionada = .midias
                        case "configuracoes": telaSelecionada = .configuracoes
                        default: break
                        }
                    },
                    buscar: { texto in
                        PerfProbe.shared.registrarBuscaSolicitada(texto)
                        consulta = texto
                    },
                    abrirDetalhe: { id in
                        conversaAberta.append(id)
                    }
                )
            }
#endif
        }
        // Retorno do navegador quando a autorização do Granola roda no
        // navegador padrão do sistema.
        .onOpenURL { url in
            _ = GerenciadorDeCallbackDeAutorizacao.compartilhado.entregar(url)
        }
        .onChange(of: processamentoAutomatico) { _, novoValor in
            biblioteca?.processamentoAutomatico = novoValor
        }
        .onChange(of: biblioteca?.arquivosComFichaPendente) { _, novoValor in
            abrirFichaPendenteSeNecessario(novoValor)
        }
        .fileImporter(
            isPresented: $mostrandoImportador,
            // Sai da mesma lista do arraste: antes o painel aceitava menos
            // formatos que o drop, e o mesmo arquivo entrava por um caminho e
            // era recusado pelo outro.
            allowedContentTypes: Self.tiposDeAudio
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
                titulo: $ficha.titulo,
                entrevistado: $ficha.entrevistado,
                emailDoEntrevistado: $ficha.emailDoEntrevistado,
                entrevistadores: $ficha.entrevistadores,
                emailDosEntrevistadores: $ficha.emailDosEntrevistadores,
                descricao: $ficha.descricao,
                formato: $ficha.formato,
                participantes: $ficha.participantes,
                data: $ficha.data,
                duracao: $ficha.duracao,
                aoCancelar: { arquivoParaConfigurar = nil },
                aoSalvar: salvarFichaDaEntrevista
            )
        }
        .alert("Não foi possível entrar".localized, isPresented: Binding(
            get: { perfil.erro != nil },
            set: { if !$0 { perfil.dispensarErro() } }
        )) {
            Button("OK".localized, role: .cancel) { perfil.dispensarErro() }
        } message: {
            Text(perfil.erro ?? "")
        }
    }

    private func mensagemDeErro(_ mensagem: String) -> some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Label(mensagem.localized, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(PapagaioTema.perigo)
                .minimumScaleFactor(0.85)

            Spacer()

            Button("Fechar".localized, systemImage: "xmark") {
                falhaDeAbertura = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(PapagaioTema.perigo)
            .help("Dispensar mensagem de erro".localized)
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.perigo.opacity(0.08))
    }

    private var barraSuperior: some View {
        BarraSuperiorPapagaioView(
            consulta: $consulta, legendaAtiva: $legendaDaBarra,
            // Sem o chevron nas telas que já têm atalho próprio na barra:
            // Tarefas, Mídias e Lixeira. Ali o botão de voltar seria um
            // segundo caminho para a Biblioteca, redundante e não obrigatório
            // como é numa conversa aberta ou na captura. Configurações mantém
            // o chevron (além dos atalhos) para garantir saída explícita.
            exibindoBotaoVoltar: !naTelaInicial
                && telaSelecionada != .tarefas
                && telaSelecionada != .midias
                && !(telaSelecionada == .biblioteca && secaoDaBiblioteca == .lixeira),
            bibliotecaSelecionada: telaSelecionada == .biblioteca && secaoDaBiblioteca != .lixeira,
            tarefasSelecionada: telaSelecionada == .tarefas,
            midiasSelecionada: telaSelecionada == .midias,
            configuracoesSelecionada: telaSelecionada == .configuracoes,
            lixeiraSelecionada: telaSelecionada == .biblioteca && secaoDaBiblioteca == .lixeira,
            perfilConectado: perfil.conectado, perfilVerificando: perfil.verificando,
            avatarURL: perfil.avatarURL, contextoDaConta: contextoDaConta, equipeAtiva: equipeAtiva, equipes: equipes,
            gravando: modelo.gravando && focoNaGravacao, processandoBiblioteca: biblioteca?.processando ?? false,
            quantidadeDeAvisos: notificacoes.naoLidas, notificacoes: notificacoes.itens,
            aoEntrar: perfil.entrar, aoSair: sairDoPerfil,
            aoMarcarNotificacoesComoLidas: notificacoes.marcarComoLidas, aoLimparNotificacoes: notificacoes.limpar,
            aoVoltar: voltar, aoAbrirBiblioteca: voltarParaBiblioteca, aoAbrirTarefas: abrirTarefas,
            aoAbrirMidias: abrirMidias,
            aoAbrirConfiguracoes: { telaSelecionada = .configuracoes }, aoAbrirLixeira: abrirLixeira,
            aoUsarPerfil: selecionarPerfilPessoal, aoUsarEquipe: usarEquipe,
            aoGerenciarPerfil: abrirPerfil, aoGerenciarEquipe: abrirEquipe
        )
    }

    @ViewBuilder
    private var conteudoDaTela: some View {
        switch telaSelecionada {
        case .biblioteca:
            BibliotecaHomeView(gravador: modelo, biblioteca: biblioteca, modelos: modelos, googleCalendar: googleCalendar, consulta: $consulta,
                               secaoSelecionada: $secaoDaBiblioteca, pastaSelecionada: $pastaDaBibliotecaSelecionada,
                               mostrandoImportador: $mostrandoImportador, processamentoAutomatico: processamentoAutomatico,
                               aoAlternarGravacao: aoAlternarGravacao, aoPausarGravacao: aoPausarGravacao,
                               aoContinuarGravacao: aoContinuarGravacao, aoCancelarGravacao: aoPedirCancelamentoDaGravacao,
                               aoEscolherPastaDeModelos: escolherPastaDeModelos, aoUsarPastaDoApp: usarPastaDoApp,
                               aoSoltarArquivos: importarArrastados,
 aoPrepararGravacaoParaReuniao: { (pendente: ReuniaoPendenteCalendar) in
                                    // Marca ANTES de iniciar: se a pessoa
                                    // finalizar rápido, o handler de áudio
                                    // já precisa saber que é uma pendente.
                                    pendenteEmGravacao.pendente = pendente
                                    let equipe = equipes.first { $0.id == equipeAtivaID } ?? equipes.first
                                    let res = ClassificacaoDeParticipantes.classificar(pendente.participantes, equipe: equipe)
                                    ficha.titulo = pendente.titulo
                                    ficha.data = pendente.dataHora
                                    ficha.entrevistadores = res.equipeNomes
                                    ficha.emailDosEntrevistadores = res.equipeEmails
                                    ficha.entrevistado = res.externosNomes
                                    ficha.emailDoEntrevistado = res.externosEmails
                                    ficha.descricao = pendente.descricao ?? ""
                                    arquivoParaConfigurar = nil
                                    Task {
                                        await aoAlternarGravacao()
                                        if !modelo.gravando { pendenteEmGravacao.pendente = nil }
                                    }
                                },
                                aoImportarAudioDaReuniao: { (pendente: ReuniaoPendenteCalendar) in
                                    guard let bib = biblioteca else { return }
                                    let painel = NSOpenPanel()
                                    painel.title = "Escolha o arquivo de áudio da reunião".localized
                                    painel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
                                    painel.allowsMultipleSelection = false
                                    guard painel.runModal() == .OK, let url = painel.url else { return }
                                    Task {
                                        let acesso = url.startAccessingSecurityScopedResource()
                                        defer { if acesso { url.stopAccessingSecurityScopedResource() } }
                                        await googleCalendar?.importarAudioParaReuniao(pendente, audioURL: url, biblioteca: bib)
                                    }
                                },
                                aoIgnorarReuniao: { (pendente: ReuniaoPendenteCalendar) in
                                    Task { @MainActor in
                                        googleCalendar?.ignorarPendente(pendente)
                                    }
                                },
                               focoNaGravacao: $focoNaGravacao,
                               aoAbrirFicha: abrirFichaDaEntrevista)
        case .tarefas:
            TarefasView(biblioteca: biblioteca, consulta: consulta)
        case .midias:
            MidiasView(biblioteca: biblioteca, consulta: consulta)
        case .configuracoes:
            ConfiguracoesView(processamentoAutomatico: $processamentoAutomatico, exibirFichaAutomaticamente: $exibirFichaAutomaticamente, aparencia: aparencia,
                              granola: granola, googleCalendar: googleCalendar, biblioteca: biblioteca)
        case .perfil:
            PerfilPessoalView(perfil: perfil, equipeAtiva: equipeAtiva, equipes: equipes,
                               aoSelecionarEquipe: usarEquipe, aoAdicionarEquipe: adicionarEquipe,
                               aoEntrarComCodigo: entrarNaEquipeComCodigo,
                               aoSair: sairDoPerfil, aoExcluirConta: excluirConta)
        case .equipe:
            GestaoDeEquipeView(equipeAtiva: equipeAtiva, equipes: equipes,
                                aoSelecionarEquipe: usarEquipe,
                                aoAtualizarEquipe: atualizarEquipe,
                                aoExcluirEquipe: excluirEquipe,
                                nomeDoPerfil: perfil.nome,
                                estadoDaSincronizacao: biblioteca?.estadoDaSincronizacaoCloudKit ?? .local,
                                aoRetomarSincronizacao: {
                                    Task { await biblioteca?.sincronizarEquipeAgora() }
                                })
        }
    }

    private func abrir() async {
        guard biblioteca == nil else { return }
        do {
            let nova = try Biblioteca()
            nova.processamentoAutomatico = processamentoAutomatico
            if politicaDeInicializacaoExterna.permiteServicosExternos {
                nova.aoNotificar = { titulo, mensagem, tipo in
                    notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: tipo)
                }
            } else {
                nova.aoNotificar = nil
            }
            nova.aoConcluirProcessamento = { [weak nova] arquivo in
#if OMU_PERF
                PerfProbe.shared.registrarPipelineFim(arquivo)
#endif
                guard arquivosAguardandoFicha.contains(arquivo.id) else { return }
                arquivosAguardandoFicha.remove(arquivo.id)
                // Sempre marca como pendente; a exibição automática é decidida
                // pela View (onChange de arquivosComFichaPendente + preferência)
                // para manter a decisão de UI na camada de View.
                nova?.marcarFichaPendente(arquivo.id)
            }
            biblioteca = nova

            if politicaDeInicializacaoExterna.permiteServicosExternos {
                let conexao = GranolaViewModel()
                conexao.aoNotificar = { titulo, mensagem, tipo in
                    notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: tipo)
                }
                granola = conexao

                let conexaoGoogle = GoogleCalendarViewModel()
                conexaoGoogle.aoNotificar = { titulo, mensagem, tipo in
                    notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: tipo)
                }
                googleCalendar = conexaoGoogle
            }

#if OMU_PERF
            let pastaModelos = PerfProbe.configuracao?.modelos ?? nova.armazenamento.pastaDeModelos
            let gerenciador = ModelosViewModel(
                pastaDoContainer: pastaModelos,
                ignorarPastaEscolhidaPersistida: PerfProbe.ativada
            )
#else
            let pastaModelos = nova.armazenamento.pastaDeModelos
            let gerenciador = ModelosViewModel(
                pastaDoContainer: pastaModelos
            )
#endif
            gerenciador.verificar()
            nova.pastaDeModelos = gerenciador.pasta
            // Conversas recusadas por falta de modelos voltam à fila quando o
            // download termina, sem a pessoa precisar pedir de novo.
            gerenciador.aoFicarPronto = { [weak nova, weak gerenciador] in
                guard let nova, let gerenciador else { return }
                nova.pastaDeModelos = gerenciador.pasta
                nova.retomarProcessamentosPendentes()
            }
            modelos = gerenciador

            // A gravação entrega o áudio; a biblioteca salva e processa. Esta
            // ligação permanece na raiz para não desaparecer ao redesenhar uma
            // subview de biblioteca.
            // Caixa capturada por referência: `@State` não pode ser lido
            // diretamente num handler instalado uma vez (captura obsoleta).
            let caixaPendente = pendenteEmGravacao
            modelo.aoCancelarGravacao = {
                caixaPendente.pendente = nil
                focoNaGravacao = false
            }
            let gcalCapturado = googleCalendar
            modelo.aoProduzirAudio = { titulo, pasta, duracao, notas, dataDeGravacao, usavaFones in
                if let pendente = caixaPendente.pendente {
                    // Gravação iniciada a partir de uma reunião pendente do
                    // Calendar: o título vem do evento, não do relógio.
                    let audioURL = nova.armazenamento.resolver(relativo: pasta)
                        .appendingPathComponent(Armazenamento.Nome.microfone)
                    let criado = await gcalCapturado?.importarAudioParaReuniao(
                        pendente,
                        audioURL: audioURL,
                        biblioteca: nova,
                        duracao: duracao,
                        notas: notas,
                        usavaFones: usavaFones
                    )
                    caixaPendente.pendente = nil
                    focoNaGravacao = false
                    // A reunião pode já ter virado conversa (mesmo
                    // `idExterno`) ou o salvamento pode ter falhado. O áudio
                    // recém-gravado não fica órfão no disco por isso: entra
                    // como gravação comum, com o título do evento.
                    if criado == nil {
                        let avulso = await nova.registrar(
                            titulo: pendente.titulo,
                            pastaRelativa: pasta,
                            duracao: duracao,
                            notas: notas,
                            usavaFones: usavaFones
                        )
                        if avulso != nil {
                            notificacoes.registrar(
                                titulo: "Gravação salva como conversa avulsa".localized,
                                mensagem: "Não foi possível vinculá-la à reunião \"%@\"; o áudio está na biblioteca.".localized(pendente.titulo),
                                tipo: .aviso
                            )
                        }
                    }
                } else {
                    // Gravação normal
                    if let arquivo = await nova.registrar(
                        titulo: titulo,
                        pastaRelativa: pasta,
                        duracao: duracao,
                        notas: notas,
                        dataDeGravacao: dataDeGravacao,
                        usavaFones: usavaFones
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
#if OMU_PERF
                            switch PerfProbe.configuracao?.cenario.lowercased() {
                            case "i1", "s1-import": return
                            case "u3":
                                PerfProbe.shared.registrarNavegacaoSolicitada("detalhe")
                                conversaAberta.append(arquivo.id.rawValue)
                                return
                            default: break
                            }
#endif
                            abrirFichaDaEntrevista(para: arquivo)
                        }
                    }
                }
            }
            await nova.preparar()
            atualizarEspacoDaBiblioteca()
            // Anexos, pastas e tarefas que passaram do prazo da lixeira. As
            // conversas saem pela própria biblioteca, ao carregar.
            if politicaDeInicializacaoExterna.permiteServicosExternos {
                ExpurgoDaLixeira.lojasAuxiliares()
            }
            // Gravações que um encerramento forçado deixou sem registro. Fora
            // do host de testes; e nunca enquanto o gravador não souber dizer
            // quais pastas são dele (uma importação copiando).
            if politicaDeInicializacaoExterna.permiteServicosExternos,
               let pastasEmUso = modelo.pastasEmUso {
                await nova.recuperarGravacoesOrfas(ignorando: pastasEmUso)
            }
            // Só depois de a biblioteca estar na tela: a consulta ao banco
            // público (uma por equipe) esperava a rede antes de `preparar()`,
            // e com conexão lenta a biblioteca aparecia vazia até o iCloud
            // responder ou expirar.
            if politicaDeInicializacaoExterna.permiteServicosExternos {
                Task { await reconciliarEquipesExcluidas() }
            }
#if OMU_PERF
            if PerfProbe.ativada {
                await tarefaDeSelecaoDeEspaco?.value
                PerfProbe.shared.registrarBibliotecaPronta()
            }
#endif
        } catch {
            falhaDeAbertura = "Não foi possível abrir a biblioteca: %@".localized(error.localizedDescription)
        }
    }

    private func conectarGoogleCalendarSeAutorizado() async {
        guard let googleCalendar, let biblioteca,
              CredenciaisGoogle.estaConfigurado,
              googleCalendar.temAutorizacaoPersistida
        else { return }
        await googleCalendar.conectar(biblioteca: biblioteca, interativo: false)
    }

    private func abrirFichaDaEntrevista(para arquivo: Arquivo) {
        biblioteca?.limparFichaPendente(arquivo.id)
        let metadados = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
        arquivoParaConfigurar = arquivo
        ficha = FichaDaEntrevista(
            titulo: arquivo.resumo?.titulo ?? arquivo.titulo,
            entrevistado: metadados.entrevistado,
            emailDoEntrevistado: metadados.emailDoEntrevistado,
            entrevistadores: metadados.entrevistadores,
            emailDosEntrevistadores: metadados.emailDosEntrevistadores,
            descricao: metadados.descricao,
            formato: metadados.formato,
            participantes: "\(max(1, metadados.participantes ?? 1))",
            data: arquivo.criadoEm,
            duracao: arquivo.duracao.comoDuracaoPorExtenso
        )
    }

    private func abrirFichaPendenteSeNecessario(_ pendentes: Set<ArquivoID>?) {
        guard exibirFichaAutomaticamente,
              arquivoParaConfigurar == nil,
              let id = pendentes?.first,
              let arquivo = biblioteca?.arquivos.first(where: { $0.id == id })
        else { return }

        abrirFichaDaEntrevista(para: arquivo)
    }

    @ViewBuilder
    private func destinoDaConversa(_ id: UUID) -> some View {
        if let biblioteca, biblioteca.arquivo(id: id) != nil {
            ArquivoCompletoCarregado(id: id, biblioteca: biblioteca) { arquivo in
                self.detalheDaConversa(arquivo, na: biblioteca)
            }
        }
    }

    private func detalheDaConversa(_ arquivo: Arquivo, na biblioteca: Biblioteca) -> some View {
        ArquivoDetalheView(
            arquivo: arquivo,
            audio: biblioteca.audio(de: arquivo),
            audioSecundario: biblioteca.audioSecundario(de: arquivo),
            importado: biblioteca.importado(arquivo),
            estado: biblioteca.estado(de: arquivo),
            processando: biblioteca.estaProcessando(arquivo),
            naFila: biblioteca.estaNaFila(arquivo),
            responsaveisDisponiveis: responsaveisDaEquipeAtiva,
            aoTranscrever: { biblioteca.enfileirarProcessamento(arquivo) },
            // Só o resumo e os próximos passos, sobre a transcrição atual —
            // refazer a transcrição apagaria as correções feitas à mão.
            aoGerarNovoResumo: { biblioteca.enfileirarNovoResumo(arquivo) },
            aoAtualizarNotas: { notas in
                await biblioteca.atualizarNotas(notas, de: arquivo)
            },
            aoNotificarTarefa: { titulo, mensagem in
                notificacoes.registrar(titulo: titulo, mensagem: mensagem, tipo: .aviso)
            },
            aoAtualizarMetadados: { titulo, data, duracao in
                Task {
                    await biblioteca.atualizarMetadados(
                        arquivo,
                        titulo: titulo,
                        criadoEm: data,
                        duracao: duracao
                    )
                }
            },
            aoAtualizarTranscricao: { trechos in
                await biblioteca.atualizarTrechos(trechos, de: arquivo)
            },
            aoDitar: { url in try await biblioteca.transcreverDitado(url) }
        )
    }

    private func salvarFichaDaEntrevista() {
        guard let arquivo = arquivoParaConfigurar,
              let biblioteca
        else { return }

        let tituloLimpo = ficha.titulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty else { return }

        // Participantes deixou de ser um campo digitável na ficha: sai da soma
        // dos nomes que a pessoa acabou de preencher. Ler do estado antigo
        // deixava sempre "1", independente de quantos nomes havia.
        let quantidade = max(
            1,
            nomesInformados(ficha.entrevistado) + nomesInformados(ficha.entrevistadores)
        )
        let metadados = MetadadosVisuaisDoArquivo(
            entrevistado: ficha.entrevistado.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDoEntrevistado: ficha.emailDoEntrevistado.trimmingCharacters(in: .whitespacesAndNewlines),
            entrevistadores: ficha.entrevistadores.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDosEntrevistadores: ficha.emailDosEntrevistadores.trimmingCharacters(in: .whitespacesAndNewlines),
            descricao: ficha.descricao.trimmingCharacters(in: .whitespacesAndNewlines),
            formato: ficha.formato.trimmingCharacters(in: .whitespacesAndNewlines),
            participantes: quantidade
        )

        // Antes de sobrescrever: depois, os metadados antigos já não estão
        // por aqui para comparar, e a foto ficaria presa numa chave que nada
        // mais lê.
        let metadadosAntigos = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
        FotosDePessoas.migrarAoEditarNomes(de: metadadosAntigos.entrevistado, para: metadados.entrevistado)
        FotosDePessoas.migrarAoEditarNomes(de: metadadosAntigos.entrevistadores, para: metadados.entrevistadores)

        PreferenciasVisuaisDoArquivo.definirMetadados(metadados, para: arquivo.id)

        // A duração não é editável na ficha: continua sendo a do próprio áudio.
        let duracao = arquivo.duracao
        Task {
            await biblioteca.atualizarMetadados(arquivo, titulo: tituloLimpo, criadoEm: ficha.data, duracao: duracao)
            await MainActor.run {
                arquivoParaConfigurar = nil
                // Depois de preencher a ficha, a próxima coisa que se quer
                // ver é a própria conversa — o mesmo destino que o cartão
                // abre com um clique (`NavigationLink(value:
                // arquivo.id.rawValue)`), sem precisar desse clique extra.
                conversaAberta.append(arquivo.id.rawValue)
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

    /// As extensões aceitas na importação — única fonte de verdade, usada
    /// pelo `.fileImporter` (via `tiposDeAudio`) e pelo filtro do arraste.
    private static let extensoesDeAudio: Set<String> = [
        "m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov",
    ]

    /// Os mesmos formatos do arraste, como `UTType`, para o painel de
    /// importação. Extensão sem tipo conhecido não entra no painel — o
    /// caminho do arraste continua cobrindo.
    private static var tiposDeAudio: [UTType] {
        extensoesDeAudio.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    private func abrirLixeira() {
        telaSelecionada = .biblioteca
        secaoDaBiblioteca = .lixeira
    }

    private func abrirTarefas() {
        telaSelecionada = .tarefas
        secaoDaBiblioteca = .todos
    }

    private func abrirMidias() {
        telaSelecionada = .midias
        secaoDaBiblioteca = .todos
    }

    private func abrirPerfil() {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        telaSelecionada = .perfil
        secaoDaBiblioteca = .todos
    }

    private func abrirEquipe() {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        telaSelecionada = .equipe
        secaoDaBiblioteca = .todos
    }

    private func selecionarPerfilPessoal() {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        contextoDaConta = .perfil
        atualizarEspacoDaBiblioteca()
    }

    /// Entra no contexto de equipe mesmo sem equipe alguma — é lá que mora o
    /// estado vazio que convida a criar a primeira.
    private func selecionarEquipe() {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        contextoDaConta = .equipe
        if let equipeAtiva {
            equipeAtivaID = equipeAtiva.id
            garantirEspacoParaEquipe(id: equipeAtiva.id)
            atualizarEspacoDaBiblioteca()
        }
    }

    private func usarEquipe(_ equipe: EquipeDisponivel) {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        contextoDaConta = .equipe
        equipeAtivaID = equipe.id
        garantirEspacoParaEquipe(id: equipe.id)
        atualizarEspacoDaBiblioteca()
    }

    private func atualizarEquipe(_ equipe: EquipeDisponivel) {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        guard let indice = equipes.firstIndex(where: { $0.id == equipe.id }) else { return }
        equipes[indice] = equipe
        EquipesDoUsuario.salvar(equipes)
    }

    /// Só é chamado depois de o serviço confirmar a exclusão da zona remota.
    /// Assim a interface não esconde a equipe nem apaga este Mac por uma ação
    /// que falhou no CloudKit.
    private func excluirEquipe(_ equipe: EquipeDisponivel) async throws {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        try await servicoDeEquipesCloudKit.excluirEquipeGlobalmente(equipe)
        try await limparDadosLocais(da: equipe)
        MembrosDasEquipes.remover(equipeID: equipe.id)
        equipes.removeAll { $0.id == equipe.id }
        EquipesDoUsuario.salvar(equipes)

        if equipeAtivaID == equipe.id || equipes.isEmpty {
            tarefaDeSelecaoDeEspaco?.cancel()
            equipeAtivaID = ""
            contextoDaConta = .perfil
            await biblioteca?.usarEspaco(Biblioteca.espacoPessoal())
        }
    }

    /// A exclusão da zona remota não acorda Macs desligados. Ao abrir o app,
    /// cada instalação consulta o marcador público e só então remove a cópia
    /// local, inclusive mídia e itens na lixeira daquele espaço.
    private func reconciliarEquipesExcluidas() async {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        let candidatas = equipes.filter { $0.zonaCloudKit != nil }
        for equipe in candidatas {
            do {
                guard try await servicoDeEquipesCloudKit.equipeFoiExcluida(equipe) else { continue }
                try await limparDadosLocais(da: equipe)
                MembrosDasEquipes.remover(equipeID: equipe.id)
                equipes.removeAll { $0.id == equipe.id }
                if equipeAtivaID == equipe.id {
                    equipeAtivaID = ""
                    contextoDaConta = .perfil
                }
            } catch {
                // Uma falha transitória não autoriza apagar conteúdo local.
                // A próxima abertura ou troca de equipe tenta de novo.
            }
        }
        EquipesDoUsuario.salvar(equipes)
        if equipeAtivaID.isEmpty {
            await biblioteca?.usarEspaco(Biblioteca.espacoPessoal())
        }
    }

    /// Complementa a exclusão do SwiftData: tarefas, anexos, aparência e
    /// lixeiras vivem em stores locais separados, todos indexados pelo ID da
    /// conversa. Sem essa cascata a equipe sumiria da biblioteca, mas deixaria
    /// dados pessoais acessíveis em outros painéis do mesmo Mac.
    private func limparDadosLocais(da equipe: EquipeDisponivel) async throws {
        try await biblioteca?.descartarOperacoesPendentes(daEquipeComID: equipe.id)
        guard let texto = equipe.espacoID, let espaco = UUID(uuidString: texto) else { return }
        let arquivos = try await biblioteca?.excluirDadosDaConta(espaco: EspacoID(rawValue: espaco)) ?? []
        for arquivo in arquivos {
            LimpezaDeArquivo.executar(arquivo)
        }
    }

    private func adicionarEquipe(nome: String) {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
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
            quantidadeDeMembros: 1,
            espacoID: UUID().uuidString,
            codigoDeEntrada: EquipeDisponivel.novoCodigoDeEntrada()
        )
        Task { @MainActor in
            do {
                let publicada = try await servicoDeEquipesCloudKit.criarWorkspace(para: nova)
                equipes.append(publicada)
                EquipesDoUsuario.salvar(equipes)
                usarEquipe(publicada)
            } catch {
                falhaDeAbertura = "Não foi possível criar a equipe no iCloud: %@".localized(error.localizedDescription)
            }
        }
    }

    private func entrarNaEquipeComCodigo(_ codigo: String) {
        guard politicaDeInicializacaoExterna.permiteServicosExternos else { return }
        Task { @MainActor in
            do {
                let equipe = try await servicoDeEquipesCloudKit.entrarNaEquipe(com: codigo)
                guard EquipesDoUsuario.incluirOuAtualizar(equipe) else {
                    await servicoDeEquipesCloudKit.abandonarZonaCompartilhada(de: equipe)
                    throw ErroDeEquipeCloudKit.conviteConflitaComEquipeLocal
                }
                equipes = EquipesDoUsuario.carregar()
                usarEquipe(equipe)
            } catch {
                falhaDeAbertura = "Não foi possível entrar na equipe: %@".localized(error.localizedDescription)
            }
        }
    }

    private func garantirEspacoParaEquipe(id: String) {
        guard let indice = equipes.firstIndex(where: { $0.id == id }),
              UUID(uuidString: equipes[indice].espacoID ?? "") == nil
        else { return }
        equipes[indice].espacoID = UUID().uuidString
        EquipesDoUsuario.salvar(equipes)
    }

    private func atualizarEspacoDaBiblioteca() {
        tarefaDeSelecaoDeEspaco?.cancel()
        guard let biblioteca else { return }
        let espaco: EspacoID
        let equipeParaSincronizar: EquipeDisponivel?
#if OMU_PERF
        if PerfProbe.ativada {
            // O store de perf usa um espaço fixo e não consulta defaults do perfil.
            espaco = PerfProbe.espacoPadrao
            equipeParaSincronizar = nil
        } else if contextoDaConta == .equipe,
                  let equipe = equipeAtiva,
                  let texto = equipe.espacoID,
                  let id = UUID(uuidString: texto) {
            espaco = EspacoID(rawValue: id)
            equipeParaSincronizar = equipe.zonaCloudKit == nil ? nil : equipe
        } else {
            espaco = Biblioteca.espacoPessoal()
            equipeParaSincronizar = nil
        }
#else
        if contextoDaConta == .equipe,
           let equipe = equipeAtiva,
           let texto = equipe.espacoID,
           let id = UUID(uuidString: texto) {
            espaco = EspacoID(rawValue: id)
            equipeParaSincronizar = equipe.zonaCloudKit == nil ? nil : equipe
        } else {
            espaco = Biblioteca.espacoPessoal()
            equipeParaSincronizar = nil
        }
#endif
        tarefaDeSelecaoDeEspaco = Task { @MainActor in
            var equipeParaUsar = equipeParaSincronizar
            if let equipeParaSincronizar {
                do {
                    let corrigida = try await servicoDeEquipesCloudKit
                        .completarReferenciaDaZonaCompartilhada(da: equipeParaSincronizar)
                    guard !Task.isCancelled else { return }
                    equipeParaUsar = corrigida
                    if corrigida != equipeParaSincronizar,
                       let indice = equipes.firstIndex(where: { $0.id == corrigida.id }) {
                        equipes[indice] = corrigida
                        EquipesDoUsuario.salvar(equipes)
                    }
                } catch {
                    // A fila ainda tenta recuperar a referência antiga por
                    // conta própria; o estado de sincronização exibirá uma
                    // falha acionável se a zona não estiver disponível.
                }
            }
            guard !Task.isCancelled else { return }
            await biblioteca.usarEspaco(espaco, equipeCloudKit: equipeParaUsar)
        }
    }

    private func sairDoPerfil() {
        perfil.sair()
        contextoDaConta = .perfil
        atualizarEspacoDaBiblioteca()
        voltarParaBiblioteca()
    }

    /// Limpa apenas os dados que pertencem à conta local atual. Preferências
    /// do app e modelos baixados são preservados para que uma nova conta não
    /// precise reconfigurar a aparência nem baixar pesos novamente.
    private func excluirConta() async throws {
        tarefaDeSelecaoDeEspaco?.cancel()
        if modelo.gravando {
            await modelo.cancelar()
        }

        await googleCalendar?.encerrarLocalmenteParaExclusaoDoPerfil()
        await granola?.encerrarLocalmenteParaExclusaoDoPerfil()

        // Excluir o perfil pessoal não pode apagar a equipe que por acaso
        // esteja aberta. O identificador pessoal é capturado antes de remover
        // sua chave, e a biblioteca devolve exatamente os arquivos do espaço.
        let espacoPessoalExcluido = Biblioteca.espacoPessoal()
        let arquivosExcluidos = try await biblioteca?.excluirDadosDaConta(
            espaco: espacoPessoalExcluido
        ) ?? []

        LimpezaDeConta.executar(arquivos: arquivosExcluidos)
        LimpezaDeCredenciaisDaConta.executar()
        LimpezaDeVinculosDeEquipe.executar(equipes: equipes)

        perfil.excluirDadosDaConta()
        notificacoes.limpar()
        equipes.removeAll()
        equipeAtivaID = ""
        contextoDaConta = .perfil
        consulta = ""
        conversaAberta.removeAll()
        pastaDaBibliotecaSelecionada = nil
        secaoDaBiblioteca = .todos
        focoNaGravacao = false
        telaSelecionada = .biblioteca

        // A chave do espaço pessoal foi removida pela cascata. Abrir um novo
        // espaço vazio impede que a interface continue exibindo a equipe que
        // estava ativa e simula corretamente o próximo relançamento do app.
        await biblioteca?.usarEspaco(Biblioteca.espacoPessoal())
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
            HStack(spacing: PapagaioTema.Espaco.curto) {
                // O corpo do selo continua sendo o atalho de volta: é o gesto
                // mais provável de quem vê "Gravando" em outra tela.
                Button {
                    voltarParaGravacao()
                } label: {
                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        Circle()
                            .fill(modelo.pausado ? PapagaioTema.aviso : PapagaioTema.perigo)
                            .frame(width: 9, height: 9)

                        Text(modelo.pausado ? "Pausado".localized : "Gravando".localized)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(modelo.tempoDeGravacao.comoCronometro)
                            .font(.system(.callout, design: .monospaced))
                            .monospacedDigit()
                    }
                    .foregroundStyle(PapagaioTema.texto)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Voltar para a gravação em andamento".localized)

                Divider().frame(height: 18)

                // Pausar e cancelar sem precisar voltar: quem está no meio de
                // outra tarefa quer resolver ali, não navegar até a captura.
                BotaoDoSelo(
                    simbolo: modelo.pausado ? "play.fill" : "pause.fill",
                    ajuda: modelo.pausado ? "Continuar gravação".localized : "Pausar gravação".localized
                ) {
                    Task {
                        if modelo.pausado {
                            await aoContinuarGravacao()
                        } else {
                            await aoPausarGravacao()
                        }
                    }
                }

                BotaoDoSelo(simbolo: "stop.fill", ajuda: "Finalizar gravação".localized) {
                    Task { await aoAlternarGravacao() }
                }

                BotaoDoSelo(simbolo: "xmark", ajuda: "Cancelar gravação".localized, perigo: true) {
                    confirmandoCancelamentoDaGravacao = true
                }
            }
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .frame(height: PapagaioTema.Altura.padrao)
            .background(PapagaioTema.superficie, in: Capsule())
            .overlay { Capsule().stroke(PapagaioTema.borda, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(PapagaioTema.Espaco.secao)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .confirmationDialog(
                "Cancelar a gravação?".localized,
                isPresented: $confirmandoCancelamentoDaGravacao,
                titleVisibility: .visible
            ) {
                Button("Cancelar gravação".localized, role: .destructive) {
                    Task { await aoCancelarGravacao() }
                }
                Button("Continuar gravando".localized, role: .cancel) {}
            } message: {
                Text("O áudio capturado até agora é descartado.".localized)
            }
        }
    }

    /// Traz a pessoa de volta à tela de captura, de onde quer que ela esteja.
    private func voltarParaGravacao() {
        conversaAberta.removeAll()
        telaSelecionada = .biblioteca
        secaoDaBiblioteca = .todos
        withAnimation(.snappy(duration: 0.18)) { focoNaGravacao = true }
    }

    /// Finalizar a partir do selo: encerra a captura e desliga o foco, para a
    /// pessoa cair na biblioteca já com a conversa nova entrando na fila.
    private func aoAlternarGravacao() async {
        await modelo.alternarGravacao()
        withAnimation(.snappy(duration: 0.18)) {
            focoNaGravacao = modelo.gravando
        }
    }

    private func aoPausarGravacao() async { await modelo.pausar() }
    private func aoContinuarGravacao() async { await modelo.continuar() }

    /// Botão "Cancelar" da tela de gravação: confirma antes, como o selo. O
    /// contexto (pendente do Calendar, foco) é limpo por
    /// `modelo.aoCancelarGravacao` quando o cancelamento acontece de fato.
    private func aoPedirCancelamentoDaGravacao() async {
        await modelo.cancelarComConfirmacao()
    }

    private func aoCancelarGravacao() async {
        await modelo.cancelar()
        // Cancelar não produz áudio: sem isto, a próxima gravação comum seria
        // erroneamente roteada para a pendente do Calendar marcada antes.
        pendenteEmGravacao.pendente = nil
        focoNaGravacao = false
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

/// O cartão usa um preview sem timestamps de palavra. O detalhe só é criado
/// depois que o repositório reidrata a conversa completa.
private struct ArquivoCompletoCarregado<Conteudo: View>: View {
    let id: UUID
    let biblioteca: Biblioteca
    let conteudo: (Arquivo) -> Conteudo

    @State private var arquivo: Arquivo?
    @State private var erro: String?

    init(
        id: UUID,
        biblioteca: Biblioteca,
        @ViewBuilder conteudo: @escaping (Arquivo) -> Conteudo
    ) {
        self.id = id
        self.biblioteca = biblioteca
        self.conteudo = conteudo
    }

    var body: some View {
        Group {
            if let arquivo {
                conteudo(arquivo)
            } else if let erro {
                VStack(spacing: 12) {
                    Text(erro)
                        .multilineTextAlignment(.center)
                    Button("Tentar novamente") {
                        Task { @MainActor in await carregar() }
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        // A revisão sobe a cada mudança gravada (edição, processamento,
        // sincronização). Recarregar por ela é o que mantém a tela de
        // detalhe trabalhando sobre a versão atual: sem isso, ela seguia com
        // a cópia da abertura e cada correção desfazia a anterior.
        .task(id: Chave(id: id, revisao: biblioteca.revisao(de: id))) { await carregar() }
    }

    private struct Chave: Equatable {
        let id: UUID
        let revisao: Int
    }

    @MainActor
    private func carregar() async {
        // Só esvazia ao trocar de conversa. Numa recarga da mesma conversa a
        // versão antiga fica na tela até a nova chegar — trocar por um
        // spinner destruiria o estado do detalhe (aba, rolagem, player).
        if arquivo?.id.rawValue != id {
            arquivo = nil
        }
        erro = nil
        do {
            guard let completo = try await biblioteca.buscarArquivoCompleto(id: id) else {
                guard !Task.isCancelled else { return }
                arquivo = nil
                erro = "A conversa não está mais disponível na biblioteca.".localized
                return
            }
            guard !Task.isCancelled else { return }
            if arquivo != completo {
                arquivo = completo
            }
        } catch {
            guard !Task.isCancelled else { return }
            // Falha ao recarregar não derruba o que já está na tela.
            guard arquivo == nil else { return }
            erro = "Não foi possível abrir a conversa: %@".localized(error.localizedDescription)
        }
    }
}

#Preview {
    ContentView(gravador: GravadorViewModel())
}
