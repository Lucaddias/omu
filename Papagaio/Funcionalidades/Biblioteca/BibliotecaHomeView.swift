import PapagaioCore
import SwiftUI
import UniformTypeIdentifiers

/// Camada visual da biblioteca. Recebe estado e ações do coordenador raiz, sem
/// criar view models nem assumir responsabilidade pelo pipeline.
struct BibliotecaHomeView: View {
    let gravador: GravadorViewModel
    let biblioteca: Biblioteca?
    let modelos: ModelosViewModel?
    @Binding var consulta: String
    @Binding var secaoSelecionada: SecaoDaBiblioteca
    @Binding var pastaSelecionada: String?
    @Binding var mostrandoImportador: Bool
    let processamentoAutomatico: Bool
    let aoAlternarGravacao: () async -> Void
    let aoPausarGravacao: () async -> Void
    let aoContinuarGravacao: () async -> Void
    let aoCancelarGravacao: () async -> Void
    let aoEscolherPastaDeModelos: (URL) -> Void
    let aoUsarPastaDoApp: () -> Void
    let aoSoltarArquivos: ([URL]) -> Void
    /// Enquanto a gravação roda a pessoa pode sair da tela de captura e voltar
    /// à biblioteca; a gravação continua. Este é o foco visual, não o estado
    /// da gravação.
    @Binding var focoNaGravacao: Bool

    @State private var arquivoParaExclusaoDefinitiva: Arquivo?
    @State private var confirmandoEsvaziarLixeira = false
    @State private var erroDaLixeiraDeMidia: String?
    @State private var menuAberto: ArquivoID?
    @State private var filtroSelecionado: FiltroDaBiblioteca = .todas
    @State private var atalhoSelecionado: AtalhoDaBiblioteca?
    @State private var atalhoVisualSelecionado: AtalhoDaBiblioteca?
    @State private var versaoDasPreferenciasVisuais = 0
    @State private var criandoPasta = false
    @State private var novaPasta = ""

    /// Durante a captura, filtros e pastas somem: a página é a tela da
    /// gravação, e não um acervo para navegar.
    @ViewBuilder
    private var filtrosEPastas: some View {
        if secaoSelecionada == .todos, !emCaptura {
            // Filtros e atalhos na mesma linha: são a mesma decisão — qual
            // recorte da biblioteca estou vendo. Separados, "Recentes" e
            // "Favoritos" pareciam ações do título, e não filtros.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PapagaioTema.Espaco.largo) {
                    FiltroDeConversas(
                        selecionado: $filtroSelecionado,
                        pastaSelecionada: $pastaSelecionada,
                        atalhoSelecionado: $atalhoSelecionado,
                        aoLimparAtalhoVisual: limparAtalhoVisual
                    )

                    Spacer(minLength: PapagaioTema.Espaco.medio)

                    atalhosDaBiblioteca
                }

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    FiltroDeConversas(
                        selecionado: $filtroSelecionado,
                        pastaSelecionada: $pastaSelecionada,
                        atalhoSelecionado: $atalhoSelecionado,
                        aoLimparAtalhoVisual: limparAtalhoVisual
                    )

                    atalhosDaBiblioteca
                }
            }

            if filtroSelecionado == .pastas, pastaSelecionada == nil {
                GradeDePastas(
                    pastas: informacoesDasPastas,
                    selecionada: $pastaSelecionada,
                    aoCriarPasta: abrirCriacaoDePasta
                )
                .simultaneousGesture(TapGesture().onEnded { limparAtalhoVisual() })
            }
        }
    }

    private var atalhosDaBiblioteca: some View {
        AtalhosDaBiblioteca(
            selecionado: $atalhoVisualSelecionado,
            aoSelecionarRecentes: {
                withAnimation(.snappy(duration: 0.18)) {
                    filtroSelecionado = .todas
                    pastaSelecionada = nil
                    atalhoSelecionado = .recentes
                    atalhoVisualSelecionado = .recentes
                }
            },
            aoSelecionarFavoritos: {
                withAnimation(.snappy(duration: 0.18)) {
                    filtroSelecionado = .todas
                    pastaSelecionada = nil
                    atalhoSelecionado = .favoritos
                    atalhoVisualSelecionado = .favoritos
                }
            }
        )
    }

    @ViewBuilder
    private var capturaEmAndamento: some View {
        if emCaptura {
            PainelDeGravacao(
                waveform: gravador.waveform,
                tempoDeGravacao: gravador.tempoDeGravacao,
                pausado: gravador.pausado,
                aoPausar: aoPausarGravacao,
                aoContinuar: aoContinuarGravacao,
                aoFinalizar: aoAlternarGravacao,
                aoCancelar: aoCancelarGravacao
            )

            PainelDeNotasDuranteGravacao(gravador: gravador)
        }
    }

    /// Tela de captura: gravando **e** com o foco nela.
    private var emCaptura: Bool {
        gravador.gravando && focoNaGravacao
    }

    private var arquivosFiltrados: [Arquivo] {
        guard let biblioteca else { return [] }
        _ = versaoDasPreferenciasVisuais
        let fonte: [Arquivo]
        switch secaoSelecionada {
        case .todos:
            let recentes = biblioteca.arquivos.sorted { $0.criadoEm > $1.criadoEm }
            if let pastaSelecionada {
                fonte = recentes.filter { PreferenciasVisuaisDoArquivo.pasta($0.id) == pastaSelecionada }
            } else if filtroSelecionado == .pastas {
                fonte = []
            } else if atalhoSelecionado == .favoritos {
                fonte = recentes.filter { PreferenciasVisuaisDoArquivo.favorito($0.id) }
            } else {
                fonte = recentes
            }
        case .lixeira:
            fonte = biblioteca.arquivosNaLixeira
        }
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !termo.isEmpty else { return fonte }
        return fonte.filter { arquivo in
            let titulo = arquivo.resumo?.titulo ?? arquivo.titulo
            return titulo.localizedCaseInsensitiveContains(termo)
                || (secaoSelecionada == .todos
                    && biblioteca.estado(de: arquivo).descricao.localizedCaseInsensitiveContains(termo))
        }
    }

    private var subtitulo: String {
        switch secaoSelecionada {
        case .todos:
            emCaptura
                ? "Grave, transcreva e revise suas conversas."
                : "Gerencie suas transcrições e insights de entrevistas."
        case .lixeira:
            "Gerencie conversas excluídas. Itens na lixeira serão removidos permanentemente após 30 dias."
        }
    }

    private var tituloDaPagina: String {
        switch secaoSelecionada {
        case .todos:
            emCaptura ? "Gravações" : "Biblioteca de Conversas"
        case .lixeira:
            "Lixeira"
        }
    }

    private var falhaDaGravacao: String? {
        guard case let .falhou(motivo) = gravador.estado else { return nil }
        return motivo
    }

    private var pastasCriadas: [String] {
        _ = versaoDasPreferenciasVisuais
        return PreferenciasVisuaisDoArquivo.pastas()
    }

    private var informacoesDasPastas: [InformacaoDaPasta] {
        guard let biblioteca else { return [] }
        _ = versaoDasPreferenciasVisuais
        return pastasCriadas.map { pasta in
            let arquivos = biblioteca.arquivos.filter {
                PreferenciasVisuaisDoArquivo.pasta($0.id) == pasta
            }
            return InformacaoDaPasta(
                nome: pasta,
                quantidade: arquivos.count,
                duracaoTotal: arquivos.reduce(0) { $0 + $1.duracao },
                ultimoArquivo: arquivos.map(\.criadoEm).max()
            )
        }
    }

    private var midiasNaLixeira: [MidiaNaLixeira] {
        _ = versaoDasPreferenciasVisuais
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        let itens = LixeiraDeMidia.itens()
        guard !termo.isEmpty else { return itens }
        return itens.filter {
            $0.nome.localizedCaseInsensitiveContains(termo)
                || $0.conversaTitulo.localizedCaseInsensitiveContains(termo)
        }
    }

    private var tarefasNaLixeira: [TarefaNaLixeira] {
        _ = versaoDasPreferenciasVisuais
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        let tarefas = LixeiraDeTarefas.itens()
        guard !termo.isEmpty else { return tarefas }
        return tarefas.filter {
            $0.tarefa.titulo.localizedCaseInsensitiveContains(termo)
                || $0.conversaTitulo.localizedCaseInsensitiveContains(termo)
                || ($0.tarefa.responsavel?.localizedCaseInsensitiveContains(termo) ?? false)
        }
    }

    private var apresentandoConfirmacaoDeExclusao: Binding<Bool> {
        Binding(
            get: { arquivoParaExclusaoDefinitiva != nil },
            set: { apresentando in
                if !apresentando { arquivoParaExclusaoDefinitiva = nil }
            }
        )
    }

    private var apresentandoErroDaLixeira: Binding<Bool> {
        Binding(
            get: { biblioteca?.erroDaLixeira != nil },
            set: { apresentando in
                if !apresentando { biblioteca?.dispensarErroDaLixeira() }
            }
        )
    }

    private func recuperar(_ arquivo: Arquivo) {
        guard let biblioteca else { return }
        Task { @MainActor in
            if await biblioteca.restaurarDaLixeira(arquivo) {
                secaoSelecionada = .todos
            }
        }
    }

    private func apagarDefinitivamente(_ arquivo: Arquivo) {
        guard let biblioteca else { return }
        Task { @MainActor in
            await biblioteca.apagarDefinitivamente(arquivo)
        }
    }

    private func limparAtalhoVisual() {
        guard atalhoVisualSelecionado != nil else { return }
        withAnimation(.snappy(duration: 0.16)) {
            atalhoVisualSelecionado = nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                // Gravando, o cabeçalho inteiro sai: "Gravações / Grave,
                // transcreva e revise" empurrava o painel de captura — que é a
                // única coisa que importa nesse momento — para baixo. A frase
                // vira o "i" que fica ao lado do cronômetro.
                if !emCaptura {
                    CabecalhoDePagina(
                        titulo: tituloDaPagina,
                        subtitulo: subtitulo
                    ) {
                    HStack(spacing: PapagaioTema.Espaco.largo) {
                        if secaoSelecionada != .todos, let biblioteca {
                            AcoesDaLixeira(
                                temArquivos: !biblioteca.arquivosNaLixeira.isEmpty || !LixeiraDeTarefas.itens().isEmpty || !LixeiraDeMidia.itens().isEmpty,
                                aoRestaurarTudo: {
                                    Task { await biblioteca.restaurarTudoDaLixeira() }
                                    LixeiraDeTarefas.restaurarTudo(arquivos: biblioteca.arquivos + biblioteca.arquivosNaLixeira)
                                    LixeiraDeMidia.restaurarTudo()
                                    atualizarPreferenciasVisuais()
                                },
                                aoEsvaziar: {
                                    confirmandoEsvaziarLixeira = true
                                }
                            )
                        }

                        if let biblioteca, biblioteca.processando {
                            SeloDeStatus(
                                texto: "Processamento em andamento",
                                simbolo: "waveform",
                                estilo: .destaque
                            )
                        }
                        }
                    }
                }

                filtrosEPastas

                if let modelos, !modelos.pronto {
                    CartaoDeModelos(
                        modelos: modelos,
                        aoEscolherPasta: aoEscolherPastaDeModelos,
                        aoUsarPastaDoApp: aoUsarPastaDoApp
                    )
                }

                capturaEmAndamento

                if !gravador.avisos.isEmpty {
                    AvisosDaGravacao(avisos: gravador.avisos)
                }

                if let falhaDaGravacao {
                    FalhaDaGravacao(mensagem: falhaDaGravacao)
                }

                if !emCaptura {
                    gradeDeConversas
                        .simultaneousGesture(TapGesture().onEnded { limparAtalhoVisual() })
                }
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                fecharMenu()
            })
        }
        .background(PapagaioTema.fundo)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            fecharMenu()
        })
        .confirmationDialog(
            "Apagar definitivamente?",
            isPresented: apresentandoConfirmacaoDeExclusao,
            titleVisibility: .visible
        ) {
            if let arquivo = arquivoParaExclusaoDefinitiva {
                Button("Apagar definitivamente", role: .destructive) {
                    arquivoParaExclusaoDefinitiva = nil
                    apagarDefinitivamente(arquivo)
                }
                Button("Cancelar", role: .cancel) {
                    arquivoParaExclusaoDefinitiva = nil
                }
            }
        } message: {
            Text("Essa ação remove o áudio, a transcrição e o resumo do Mac e não pode ser desfeita.")
        }
        .alert("Não foi possível restaurar", isPresented: Binding(
            get: { erroDaLixeiraDeMidia != nil },
            set: { if !$0 { erroDaLixeiraDeMidia = nil } }
        )) {
            Button("OK", role: .cancel) { erroDaLixeiraDeMidia = nil }
        } message: {
            Text(erroDaLixeiraDeMidia ?? "")
        }
        .confirmationDialog(
            "Esvaziar lixeira?",
            isPresented: $confirmandoEsvaziarLixeira,
            titleVisibility: .visible
        ) {
            if let biblioteca {
                Button("Esvaziar lixeira", role: .destructive) {
                    Task { await biblioteca.esvaziarLixeira() }
                    LixeiraDeTarefas.esvaziar()
                    LixeiraDeMidia.esvaziar()
                    atualizarPreferenciasVisuais()
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Essa ação remove permanentemente todos os arquivos da lixeira e não pode ser desfeita.")
        }
        .alert("Não foi possível concluir a operação", isPresented: apresentandoErroDaLixeira) {
            Button("OK", role: .cancel) { biblioteca?.dispensarErroDaLixeira() }
        } message: {
            Text(biblioteca?.erroDaLixeira ?? "")
        }
        .alert("Criar pasta", isPresented: $criandoPasta) {
            TextField("Nome da pasta", text: $novaPasta)
            Button("Criar") {
                let nome = novaPasta.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nome.isEmpty else { return }
                PreferenciasVisuaisDoArquivo.criarPasta(nome)
                filtroSelecionado = .pastas
                atalhoSelecionado = nil
                atalhoVisualSelecionado = nil
                pastaSelecionada = nome
                novaPasta = ""
                atualizarPreferenciasVisuais()
            }
            Button("Cancelar", role: .cancel) {
                novaPasta = ""
            }
        } message: {
            Text("A pasta ficará disponível para organizar conversas.")
        }
    }

    @ViewBuilder
    private var gradeDeConversas: some View {
        // `.top`, e não `.center`: centralizado, um cartão mais baixo flutuava
        // no meio da linha e nem topo nem base batiam com o vizinho.
        let colunas = [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: PapagaioTema.Espaco.largo, alignment: .top)]
        let colunasDaLixeira = [GridItem(.adaptive(minimum: 270, maximum: 430), spacing: PapagaioTema.Espaco.secao, alignment: .top)]

        switch secaoSelecionada {
        case .todos:
            LazyVGrid(columns: colunas, spacing: PapagaioTema.Espaco.largo) {
                if !emCaptura && (filtroSelecionado != .pastas || pastaSelecionada != nil) {
                    CartaoNovaConversa(
                        gravando: gravador.gravando,
                        bloqueado: gravador.estado == .processando,
                        prontoParaEntrada: biblioteca != nil,
                        aoAlternarGravacao: aoAlternarGravacao,
                        aoImportar: { mostrandoImportador = true },
                        aoSoltarArquivos: aoSoltarArquivos
                    )
                }

                ForEach(arquivosFiltrados) { arquivo in
                    if let biblioteca {
                        CartaoDeConversa(
                            arquivo: arquivo,
                            estado: biblioteca.estado(de: arquivo),
                            progresso: biblioteca.progresso(de: arquivo),
                            importado: biblioteca.importado(arquivo),
                            processando: biblioteca.estaProcessando(arquivo),
                            naFila: biblioteca.estaNaFila(arquivo),
                            emOperacaoDeLixeira: biblioteca.estaEmOperacaoDeLixeira(arquivo),
                            aoReprocessar: { biblioteca.enfileirarProcessamento(arquivo) },
                            aoRenomear: { novoTitulo in Task { await biblioteca.renomear(arquivo, para: novoTitulo) } },
                            aoAtualizarMetadados: { titulo, data, duracao in
                                Task { await biblioteca.atualizarMetadados(arquivo, titulo: titulo, criadoEm: data, duracao: duracao) }
                            },
                            aoDuplicar: {
                                Task {
                                    if let copia = await biblioteca.duplicar(arquivo) {
                                        PreferenciasVisuaisDoArquivo.copiar(de: arquivo.id, para: copia.id)
                                        await MainActor.run {
                                            atualizarPreferenciasVisuais()
                                        }
                                    }
                                }
                            },
                            urlDeAudio: biblioteca.audio(de: arquivo),
                            menuAberto: menuAberto == arquivo.id,
                            aoAlternarMenu: { alternarMenu(de: arquivo) },
                            aoFecharMenu: { fecharMenu() },
                            aoAlterarPreferenciasVisuais: atualizarPreferenciasVisuais,
                            aoMoverParaLixeira: { Task { await biblioteca.moverParaLixeira(arquivo) } }
                        )
                    }
                }
            }

            if !emCaptura,
               filtroSelecionado != .pastas || pastaSelecionada != nil,
               biblioteca?.arquivos.isEmpty == false,
               arquivosFiltrados.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: simboloDoVazio,
                    titulo: tituloDoVazio,
                    mensagem: mensagemDoVazio
                )
                .frame(minHeight: 220)
                .cartaoPapagaio()
            }

            if !emCaptura,
               (filtroSelecionado != .pastas || pastaSelecionada != nil),
               biblioteca?.arquivos.isEmpty ?? true {
                Text("A primeira conversa aparecerá aqui depois de gravar ou importar um áudio.")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, PapagaioTema.Espaco.minimo)
            }

        case .lixeira:
            if (biblioteca?.arquivosNaLixeira.isEmpty ?? true) && tarefasNaLixeira.isEmpty && midiasNaLixeira.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "trash",
                    titulo: "A lixeira está vazia",
                    mensagem: "Arquivos movidos da biblioteca aparecerão aqui e poderão ser recuperados."
                )
                .frame(minHeight: 280)
                .cartaoPapagaio()
            } else if arquivosFiltrados.isEmpty && tarefasNaLixeira.isEmpty && midiasNaLixeira.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "magnifyingglass",
                    titulo: "Nenhum arquivo encontrado",
                    mensagem: "Tente buscar por outro título na lixeira."
                )
                .frame(minHeight: 220)
                .cartaoPapagaio()
            } else {
                LazyVGrid(columns: colunasDaLixeira, spacing: PapagaioTema.Espaco.secao) {
                    ForEach(arquivosFiltrados) { arquivo in
                        if let biblioteca {
                            CartaoDaLixeira(
                                arquivo: arquivo,
                                emOperacao: biblioteca.estaEmOperacaoDeLixeira(arquivo),
                                aoRestaurar: { recuperar(arquivo) },
                                aoPedirExclusaoDefinitiva: {
                                    arquivoParaExclusaoDefinitiva = arquivo
                                }
                            )
                        }
                    }

                    ForEach(midiasNaLixeira) { item in
                        CartaoDeMidiaNaLixeira(
                            item: item,
                            aoRestaurar: {
                                // Falha silenciosa aqui foi o que fez o player
                                // ficar mudo sem ninguém entender o motivo.
                                if !LixeiraDeMidia.restaurar(item) {
                                    erroDaLixeiraDeMidia = "Não foi possível devolver “\(item.nome)” para a conversa. O arquivo pode ter sido movido ou apagado por fora do app."
                                }
                                atualizarPreferenciasVisuais()
                            },
                            aoApagarDefinitivamente: {
                                LixeiraDeMidia.remover(item)
                                atualizarPreferenciasVisuais()
                            },
                            aoRevelarNoFinder: { LixeiraDeMidia.revelarNoFinder(item) }
                        )
                    }

                    ForEach(tarefasNaLixeira) { item in
                        if let biblioteca {
                            CartaoDaTarefaNaLixeira(
                                item: item,
                                aoRestaurar: {
                                    LixeiraDeTarefas.restaurar(item, arquivos: biblioteca.arquivos + biblioteca.arquivosNaLixeira)
                                    atualizarPreferenciasVisuais()
                                },
                                aoApagarDefinitivamente: {
                                    LixeiraDeTarefas.remover(item)
                                    atualizarPreferenciasVisuais()
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func alternarMenu(de arquivo: Arquivo) {
        let proximo: ArquivoID? = menuAberto == arquivo.id ? nil : arquivo.id
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.18)) {
                menuAberto = proximo
            }
        }
    }

    private func fecharMenu() {
        withAnimation(.snappy(duration: 0.14)) { menuAberto = nil }
    }

    private func atualizarPreferenciasVisuais() {
        versaoDasPreferenciasVisuais += 1
    }

    private func abrirCriacaoDePasta() {
        novaPasta = ""
        criandoPasta = true
    }

    private var simboloDoVazio: String {
        if pastaSelecionada != nil { return "folder" }
        if atalhoSelecionado == .favoritos { return "star" }
        return "magnifyingglass"
    }

    private var tituloDoVazio: String {
        if let pastaSelecionada { return "A pasta \(pastaSelecionada) está vazia" }
        if atalhoSelecionado == .favoritos { return "Nenhum favorito ainda" }
        return "Nenhuma conversa encontrada"
    }

    private var mensagemDoVazio: String {
        if pastaSelecionada != nil {
            return "Use Mover para pasta no menu de um card para organizar conversas aqui."
        }
        if atalhoSelecionado == .favoritos {
            return "Favorite uma conversa pelo botão de estrela para ela aparecer aqui."
        }
        return "Tente buscar por outro título ou estado de processamento."
    }
}
