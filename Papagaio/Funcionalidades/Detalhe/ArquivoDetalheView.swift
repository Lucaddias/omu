import PapagaioCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tipo de item sendo editado inline
enum ItemEmEdicao: Equatable {
    case trecho(UUID)
    case fala(UUID)
}

/// Superfície do Passo 10: ouvir a gravação e navegar por trecho.
///
/// Clicar num trecho salta o áudio para o `start` dele; o trecho que está
/// tocando fica destacado e a lista rola sozinha até ele.
struct ArquivoDetalheView: View {
    let arquivo: Arquivo
    let audio: URL
    /// Canal do sistema (`sistema.caf`) para reprodução em paralelo ao
    /// microfone — `nil` para importado e gravação legada, que têm canal único.
    let audioSecundario: URL?
    /// Veio de um arquivo escolhido pela pessoa, em vez de uma gravação feita
    /// dentro do app.
    let importado: Bool
    /// Texto de status vindo da `Biblioteca` — "transcrevendo…", um erro, ou
    /// "transcrito e resumido".
    let estado: EstadoDoArquivo
    let processando: Bool
    let naFila: Bool
    let responsaveisDisponiveis: [ResponsavelDaTarefa]
    let aoTranscrever: () -> Void
    let aoGerarNovoResumo: () -> Void
    let aoAtualizarNotas: ([NotaDaConversa]) async -> Void
    let aoNotificarTarefa: (_ titulo: String, _ mensagem: String) -> Void
    let aoAtualizarMetadados: (String, Date, TimeInterval) -> Void
    /// Salva a transcrição corrigida à mão.
    let aoAtualizarTranscricao: ([Trecho]) async -> Void
    /// Refina com o Whisper local o trecho ditado numa nota.
    let aoDitar: (URL) async throws -> String

    @State private var reprodutor: ReprodutorDeArquivo?
    @State private var secaoSelecionada: SecaoDoDetalhe = .resumo
    @State private var mostrandoPlayer = false
    @State private var tempoEmEdicao: TimeInterval?
    /// Altura de verdade do player flutuante, medida — e não mais os "116"
    /// fixos que existiam aqui, calibrados só para a versão de uma linha
    /// (88pt). Na versão empilhada (janela estreita, `compacto: true`), o
    /// player passou a ter a altura que o próprio conteúdo pede — que pode
    /// passar bem de 116 quando o título ocupa duas linhas — e a reserva de
    /// baixo da rolagem continuava fixa nesse valor antigo. Resultado: o
    /// player (opaco) cobria o fim da transcrição/notas, e rolar até lá
    /// parecia "travado" sem realmente estar. Medindo a altura de verdade,
    /// a reserva sempre cobre exatamente o que o player ocupa.
    @State private var alturaMedidaDoPlayer: CGFloat = 116
    @State private var mostrandoExportador = false
    @State private var notasEditaveis: [NotaDaConversa] = []
    @State private var estadoDeSalvamentoDasNotas = "Salvo"
    @State private var tarefaDeSalvamentoDasNotas: Task<Void, Never>?
    /// Anexos, áudios da gravação e lixeira de mídia num view model próprio —
    /// a duplicata que vivia aqui (painel, cópia, lixeira, tradução de erro)
    /// foi removida quando a view passou a usar o VM.
    @State private var midiasDaConversaVM: MidiasDaConversaViewModel
    /// As tarefas da conversa num view model próprio: a regra de prazo, o
    /// formulário e a gravação em disco viviam duplicados aqui (o VM existia
    /// e ninguém usava). A view só desenha e repassa ações.
    @State private var tarefasDaConversaVM: TarefasDaConversaViewModel
    /// Muda a cada renomeação de voz — `nomesDeVoz` lê direto do
    /// `UserDefaults`, que o SwiftUI não observa sozinho; sem um `@State`
    /// junto dele, salvar um nome novo não redesenhava a transcrição.
    @State private var geracaoDeNomesDeVoz = 0
    @State private var editandoInformacoes = false
    @State private var tituloEditado = ""
    @State private var entrevistadoEditado = ""
    @State private var emailDoEntrevistadoEditado = ""
    @State private var entrevistadoresEditados = ""
    @State private var emailDosEntrevistadoresEditado = ""
    @State private var descricaoEditada = ""
    @State private var formatoEditado = ""
    @State private var participantesEditados = ""
    @State private var dataEditada = Date()
    @State private var duracaoEditada = ""
    @State private var ditado = DitadoDeNota()
    /// O picker não retém o delegate; sem esta referência "Salvar em…" some.
    @State private var delegadoDeCompartilhamento: OpcoesDeCompartilhamento?
    @State private var itemEmEdicao: ItemEmEdicao?
    @State private var textoEmEdicao = ""
    @State private var buscaTranscricao = ""
    @AppStorage("mostrarConfiancaTranscricao") private var mostrarConfianca = false
    @AppStorage("mostrarPorcentagemConfianca") private var mostrarPorcentagemConfianca = true
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento
    @Environment(\.dismiss) private var fechar

    private var titulo: String { arquivo.resumo?.titulo ?? arquivo.titulo }

    init(
        arquivo: Arquivo,
        audio: URL,
        audioSecundario: URL?,
        importado: Bool,
        estado: EstadoDoArquivo,
        processando: Bool,
        naFila: Bool,
        responsaveisDisponiveis: [ResponsavelDaTarefa],
        aoTranscrever: @escaping () -> Void,
        aoGerarNovoResumo: @escaping () -> Void = {},
        aoAtualizarNotas: @escaping ([NotaDaConversa]) async -> Void,
        aoNotificarTarefa: @escaping (_ titulo: String, _ mensagem: String) -> Void,
        aoAtualizarMetadados: @escaping (String, Date, TimeInterval) -> Void,
        aoAtualizarTranscricao: @escaping ([Trecho]) async -> Void,
        aoDitar: @escaping (URL) async throws -> String
    ) {
        self.arquivo = arquivo
        self.audio = audio
        self.audioSecundario = audioSecundario
        self.importado = importado
        self.estado = estado
        self.processando = processando
        self.naFila = naFila
        self.responsaveisDisponiveis = responsaveisDisponiveis
        self.aoTranscrever = aoTranscrever
        self.aoGerarNovoResumo = aoGerarNovoResumo
        self.aoAtualizarNotas = aoAtualizarNotas
        self.aoNotificarTarefa = aoNotificarTarefa
        self.aoAtualizarMetadados = aoAtualizarMetadados
        self.aoAtualizarTranscricao = aoAtualizarTranscricao
        self.aoDitar = aoDitar
        _tarefasDaConversaVM = State(
            initialValue: TarefasDaConversaViewModel(arquivoID: arquivo.id)
        )
        _midiasDaConversaVM = State(
            initialValue: MidiasDaConversaViewModel(
                arquivoID: arquivo.id,
                pastaDaConversa: audio.deletingLastPathComponent(),
                tituloDaConversa: arquivo.resumo?.titulo ?? arquivo.titulo,
                audiosDaGravacao: [audio, audioSecundario].compactMap { $0 }
            )
        )
    }
    @State private var pairandoNoTitulo = false
    @State private var legendaDaBarra: LegendaDaBarra?
    @State private var mostrandoFicha = false
    @State private var pairandoNaFicha = false
    @State private var entrevistadoDaFicha = ""
    @State private var entrevistadoresDaFicha = ""
    @State private var formatoDaFicha = ""
    private var metadados: MetadadosVisuaisDoArquivo {
        PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
    }
    /// Vazio quando não foi preenchido; o cabeçalho assinala isso em vez de
    /// esconder a linha, para o campo não parecer inexistente.
    private var entrevistado: String {
        listaDePessoas(metadados.entrevistado)
    }
    private var entrevistadores: String {
        listaDePessoas(metadados.entrevistadores)
    }
    private var participantes: Int {
        max(1, metadados.participantes ?? participantesDetectados)
    }
    private var participantesDetectados: Int {
        let speakers = Set(arquivo.trechos.compactMap(\.speaker).filter { !$0.isEmpty })
        return max(1, speakers.count)
    }
    private var trechos: [Trecho] { arquivo.trechos }
    /// A conversa em falas por falante acústico — `nil` sem diarização, quando
    /// a transcrição continua em blocos de trecho.
    private var falas: [FalaDeFalante]? { FalasDaConversa.agrupar(trechos) }
    /// Rótulos escolhidos para cada voz acústica, persistidos por conversa.
    private var nomesDeVoz: [String: String] {
        _ = geracaoDeNomesDeVoz
        return PreferenciasVisuaisDoArquivo.nomesDeVoz(arquivo.id)
    }
    /// Rótulos brutos da diarização ("S1", "S2"...), na ordem em que cada um
    /// aparece pela primeira vez na conversa — é essa ordem que decide se
    /// "Voz 1" é a primeira pessoa a falar ou a segunda.
    private var vozesAcusticas: [String] {
        var vistas = Set<String>()
        var ordem: [String] = []
        for trecho in trechos {
            for palavra in trecho.palavras {
                guard let falante = palavra.falanteAcustico, vistas.insert(falante).inserted else { continue }
                ordem.append(falante)
            }
        }
        return ordem
    }
    /// Nomes já digitados na ficha da entrevista, para sugerir enquanto a
    /// pessoa nomeia uma voz — quem apareceu na gravação costuma ser
    /// exatamente quem está na ficha.
    private var sugestoesDeNomeDeVoz: [String] {
        nomesDePessoas(metadados.entrevistado) + nomesDePessoas(metadados.entrevistadores)
    }
    private var termoDeBuscaTranscricao: String {
        buscaTranscricao.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // MARK: - Busca Cmd+F (estilo navegador)
    @State private var mostrandoBuscaTranscricao = false
    @FocusState private var focoBuscaTranscricao: Bool
    @State private var indiceOcorrenciaBusca = 0
    @State private var alvoDaBusca: UUID?
    private struct OcorrenciaBusca: Identifiable { let id = UUID(); let falaId: UUID?; let trechoId: UUID; let palavraId: UUID? }
    private var ocorrenciasDaBusca: [OcorrenciaBusca] {
        guard !termoDeBuscaTranscricao.isEmpty else { return [] }
        if let falas {
            var out: [OcorrenciaBusca] = []
            for fala in falas {
                if fala.palavras.isEmpty {
                    if fala.texto.casaComBusca(termoDeBuscaTranscricao) {
                        out.append(OcorrenciaBusca(falaId: fala.id, trechoId: fala.trechoIds.first ?? fala.id, palavraId: nil))
                    }
                } else {
                    for p in fala.palavras where p.palavra.texto.casaComBusca(termoDeBuscaTranscricao) {
                        out.append(OcorrenciaBusca(falaId: fala.id, trechoId: p.trechoId, palavraId: p.palavra.id))
                    }
                }
            }
            return out
        } else {
            var out: [OcorrenciaBusca] = []
            for trecho in trechos {
                if trecho.palavras.isEmpty {
                    if trecho.texto.casaComBusca(termoDeBuscaTranscricao) {
                        out.append(OcorrenciaBusca(falaId: nil, trechoId: trecho.id, palavraId: nil))
                    }
                } else {
                    for palavra in trecho.palavras where palavra.texto.casaComBusca(termoDeBuscaTranscricao) {
                        out.append(OcorrenciaBusca(falaId: nil, trechoId: trecho.id, palavraId: palavra.id))
                    }
                }
            }
            return out
        }
    }
    private var textoContagemBusca: String {
        let total = ocorrenciasDaBusca.count
        guard !termoDeBuscaTranscricao.isEmpty else {
            return total == 1 ? "1 ocorrência".localized : "%d ocorrências".localized(total)
        }
        if total == 0 { return "Nenhum resultado".localized }
        return "%d de %d".localized(indiceOcorrenciaBusca + 1, total)
    }
    private func irParaOcorrencia(_ indice: Int) {
        guard !ocorrenciasDaBusca.isEmpty else { return }
        let clamped = (indice % ocorrenciasDaBusca.count + ocorrenciasDaBusca.count) % ocorrenciasDaBusca.count
        indiceOcorrenciaBusca = clamped
        let occ = ocorrenciasDaBusca[clamped]
        alvoDaBusca = occ.falaId ?? occ.trechoId
    }
    private func abrirBuscaTranscricao() {
        secaoSelecionada = .transcricao
        mostrandoBuscaTranscricao = true
        // Foca no próximo ciclo para garantir que o campo já existe
        DispatchQueue.main.async { focoBuscaTranscricao = true }
    }
    private func fecharBuscaTranscricao() {
        mostrandoBuscaTranscricao = false
        focoBuscaTranscricao = false
        buscaTranscricao = ""
        alvoDaBusca = nil
    }
    private var barraDeBuscaTranscricao: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PapagaioTema.textoSecundario)
            TextField("Buscar".localized, text: $buscaTranscricao)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focoBuscaTranscricao)
                .onSubmit { irParaOcorrencia(indiceOcorrenciaBusca + 1) }
            Text(textoContagemBusca)
                .font(.caption)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
            Button {
                irParaOcorrencia(indiceOcorrenciaBusca - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .background(PapagaioTema.superficieSuave, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(ocorrenciasDaBusca.isEmpty)
            .help("Ocorrência anterior (Shift+Enter)".localized)
            Button {
                irParaOcorrencia(indiceOcorrenciaBusca + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .background(PapagaioTema.superficieSuave, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(ocorrenciasDaBusca.isEmpty)
            .help("Próxima ocorrência (Enter)".localized)
            Button {
                fecharBuscaTranscricao()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Fechar (Esc)".localized)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .frame(height: PapagaioTema.Altura.padrao)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .onChange(of: buscaTranscricao) { _, _ in
            indiceOcorrenciaBusca = 0
            if let primeira = ocorrenciasDaBusca.first {
                alvoDaBusca = primeira.falaId ?? primeira.trechoId
            } else {
                alvoDaBusca = nil
            }
        }
        .onChange(of: ocorrenciasDaBusca.count) { _, _ in
            indiceOcorrenciaBusca = 0
        }
    }
    private var dicaBuscaTranscricao: some View {
        HStack {
            Spacer()
            Text("Pesquisar na transcrição: Cmd + F".localized)
                .font(.caption)
                .foregroundStyle(PapagaioTema.textoSecundario)
        }
    }
    private func falanteExibidoParaFala(_ fala: FalaDeFalante) -> String? {
        if let f = fala.falanteAcustico { return f }
        if let p = FalantePreservadoParaTrecho.obter(para: fala.id, arquivo: arquivo.id) { return p }
        for tid in fala.trechoIds {
            if let p = FalantePreservadoParaTrecho.obter(para: tid, arquivo: arquivo.id) { return p }
        }
        return nil
    }
    private func falanteExibidoParaTrecho(_ trecho: Trecho) -> String? {
        if let d = trecho.falanteAcusticoDominante { return d }
        if let p = FalantePreservadoParaTrecho.obter(para: trecho.id, arquivo: arquivo.id) { return p }
        return trecho.palavras.first?.falanteAcustico
    }
    private var notas: [NotaDaConversa] { notasEditaveis }
    private var podeIniciarTranscricao: Bool {
        trechos.isEmpty && !processando && !naFila
    }
    private var exibindoEstadoVazio: Bool {
        switch secaoSelecionada {
        case .resumo:
            arquivo.resumo == nil
        case .transcricao:
            trechos.isEmpty
        case .notas:
            // O painel tem estado vazio próprio, com as ações de criar nota.
            false
        case .midia:
            false
        case .tarefas:
            false
        }
    }
    private var animacaoDeInterface: Animation? {
        reduzirMovimento ? nil : .easeInOut(duration: 0.2)
    }
    /// O player também aparece nas Notas: sem ele, num arquivo importado, ⌘N e
    /// ⌘K criariam tudo em 0:00 — a âncora de tempo, que é o valor da nota,
    /// deixaria de existir.
    private var deveMostrarPlayer: Bool {
        mostrandoPlayer || secaoSelecionada == .transcricao || secaoSelecionada == .notas
    }
    /// Pergunta ao próprio player se ele conseguiu abrir o arquivo, em vez de
    /// checar um caminho na mão.
    ///
    /// Checar `audio.path` dava falso negativo: um áudio que está na aba Mídia
    /// mas não no nome canônico da conversa fazia a barra dizer "removido"
    /// mesmo com o arquivo visível ali. Duração zero depois de `preparar()` é
    /// o único sinal confiável de que o `AVAudioPlayer` não abriu nada.
    private var audioIndisponivel: Bool {
        guard let reprodutor else { return false }
        return reprodutor.duracao <= 0
    }

    /// O AppKit usa um `NSTextView` como field editor de `NSTextField` e
    /// `TextEditor`. O atalho global não pode roubar a barra de espaço de quem
    /// está escrevendo uma nota, corrigindo um trecho ou editando metadados.
    static func atalhoDeReproducaoEstaDisponivel(
        primeiroRespondedor: NSResponder?
    ) -> Bool {
        !(primeiroRespondedor is NSTextView || primeiroRespondedor is NSTextField)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // O botão sem representação visual registra Space no escopo desta
            // tela. A ação ainda confere o foco nativo, pois atalhos podem ser
            // disparados enquanto uma sheet ou um editor de texto está aberto.
            Button(action: alternarReproducaoComEspaco) { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                barraDeAcoes

                cabecalho

                seletorDeSecao

                ZStack(alignment: .top) {
                    areaDeConteudo
                    if mostrandoBuscaTranscricao {
                        barraDeBuscaTranscricao
                            .padding(.horizontal, PapagaioTema.Espaco.medio)
                            .background(PapagaioTema.fundo.opacity(0.98))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if deveMostrarPlayer, audioIndisponivel {
                avisoDeAudioRemovido
                    .transition(.opacity)
            } else if deveMostrarPlayer, let reprodutor {
                // `.frame(maxHeight: .infinity, alignment: .bottom)`, e não
                // só o `alignment: .bottom` do `ZStack` em volta: depois de
                // `BarraDeAudioDaConversa` passar a usar `.fixedSize(vertical:)`
                // para não ficar mais alta que o necessário, ela relatava uma
                // altura "ideal" curta o bastante para o `ZStack` encaixá-la
                // sem grudar de verdade no fundo da janela — sobrava uma
                // faixa vazia embaixo dela. Esta `.frame` força a área
                // reservada a ir até o fim da janela e só então alinha o
                // player (com sua altura própria, inalterada) na base dela.
                barraFlutuante(reprodutor)
                    // Medida antes do `.frame(maxHeight: .infinity)` logo
                    // abaixo — ali embaixo o próprio player já reportaria a
                    // altura da janela inteira, não a dele.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alturaMedidaDoPlayer = $0 }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(
                        reduzirMovimento
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        // `ignoresSafeArea` porque a janela está sem barra de título: sem
        // isto o topo ficava transparente e mostrava o papel de parede,
        // que era a faixa estranha acima do título.
        // Anuncia o espaço do player para quem posiciona o selo de gravação.
        // `alturaMedidaDoPlayer` (medida de verdade, ver o `@State` acima) —
        // zero quando o player não está na tela, e aí o selo volta para o
        // canto de baixo.
        .alturaDoPlayerPapagaio(espacoReservadoParaPlayer)
        .overlay { LegendaGlobalDaBarra(texto: legendaDaBarra) }
        .background(PapagaioTema.fundo.ignoresSafeArea())
        .background {
            // Atalho global da transcrição — Cmd+F abre a busca estilo navegador
            Button("") { abrirBuscaTranscricao() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        // Piso baixo de propósito: acima disso o conteúdo era desenhado mais
        // largo que a janela e ficava cortado à direita em vez de se reorganizar.
        .frame(minWidth: 320, minHeight: 360, alignment: .topLeading)
        // Sem título na barra de navegação: o mesmo texto já aparece logo
        // abaixo como H1, e ver a frase duas vezes em 40pt de distância não
        // acrescenta nada. A janela continua identificada pelo H1 da página.
        .navigationTitle("")
        // O chevron do `NavigationStack` é desenhado pelo macOS e não aceita a
        // paleta do app — ficava um botão cinza do sistema convivendo com o
        // nosso, coral e com borda. Escondido, sobra só o da barra superior,
        // que já sabe desempilhar a conversa.
        .navigationBarBackButtonHidden(true)
        .task {
            sincronizarNotasComArquivo()
            midiasDaConversaVM.transcricaoDisponivel = !trechos.isEmpty
            midiasDaConversaVM.aoPausarReproducao = { reprodutor?.pausar() }
            midiasDaConversaVM.carregar()
            tarefasDaConversaVM.aoNotificar = aoNotificarTarefa
            tarefasDaConversaVM.carregar(
                base: arquivo.resumo?.proximosPassos ?? [],
                tituloDaConversa: titulo,
                dataDaConversa: arquivo.criadoEm
            )
            let novo = ReprodutorDeArquivo(audio: audio, trechos: trechos, secundario: audioSecundario)
            await novo.preparar()
            // Se a view sumiu no meio do carregamento, o `.task` já foi
            // cancelado e o `onDisappear` já rodou: atribuir aqui deixaria
            // vivo um player sem caminho de `encerrar()`.
            guard !Task.isCancelled else {
                novo.encerrar()
                return
            }
            reprodutor = novo
        }
        .onChange(of: trechos) { _, novos in
            // A transcrição chega minutos depois de a tela abrir. Atualizar em
            // vez de recriar mantém a posição de escuta.
            reprodutor?.trechos = novos
            // E libera (ou não) a remoção do áudio da gravação.
            midiasDaConversaVM.transcricaoDisponivel = !novos.isEmpty
        }
        .onDisappear {
            // Sem isto o observador periódico sobrevive à view — critério de
            // aceite do Passo 10.
            tarefaDeSalvamentoDasNotas?.cancel()
            salvarNotasAgora()
            reprodutor?.encerrar()
            reprodutor = nil
        }
        .fileExporter(
            isPresented: $mostrandoExportador,
            // Mesmo conteúdo do Compartilhar do cartão: resumo, transcrição,
            // notas, mídia e tarefas num documento só. O áudio não vai junto —
            // fica na aba Mídia, de onde pode ser aberto ou apagado.
            document: DocumentoMarkdown(conteudo: DossieDaConversa.gerar(arquivo: arquivo)),
            contentType: DocumentoMarkdown.tipo,
            defaultFilename: DossieDaConversa.nomeDeArquivo(para: arquivo)
        ) { _ in }
        .alert("Não foi possível adicionar a mídia".localized, isPresented: Binding(
            get: { midiasDaConversaVM.erro != nil },
            set: { if !$0 { midiasDaConversaVM.erro = nil } }
        )) {
            Button("OK".localized, role: .cancel) { midiasDaConversaVM.erro = nil }
        } message: {
            Text(midiasDaConversaVM.erro ?? "")
        }
        .sheet(isPresented: $editandoInformacoes) {
            EditorDeInformacoesDoCard(
                modo: .edicao,
                titulo: $tituloEditado,
                entrevistado: $entrevistadoEditado,
                emailDoEntrevistado: $emailDoEntrevistadoEditado,
                entrevistadores: $entrevistadoresEditados,
                emailDosEntrevistadores: $emailDosEntrevistadoresEditado,
                descricao: $descricaoEditada,
                formato: $formatoEditado,
                participantes: $participantesEditados,
                data: $dataEditada,
                duracao: $duracaoEditada,
                aoCancelar: { editandoInformacoes = false },
                aoSalvar: salvarInformacoesDaConversa
            )
        }
        .sheet(isPresented: $tarefasDaConversaVM.mostrandoCriacao) {
            NovaTarefaDaConversaSheet(
                modo: .criacao,
                titulo: $tarefasDaConversaVM.tituloDaTarefa,
                responsavel: $tarefasDaConversaVM.responsavelDaTarefa,
                prioridade: $tarefasDaConversaVM.prioridadeDaTarefa,
                status: $tarefasDaConversaVM.statusDaTarefa,
                prazo: $tarefasDaConversaVM.prazoDaTarefa,
                responsaveisDisponiveis: responsaveisDisponiveis,
                aoCancelar: tarefasDaConversaVM.cancelarCriacao,
                aoAdicionar: { tarefasDaConversaVM.adicionar(origem: titulo) }
            )
        }
        .sheet(isPresented: $tarefasDaConversaVM.mostrandoEdicao) {
            NovaTarefaDaConversaSheet(
                modo: .edicao,
                titulo: $tarefasDaConversaVM.tituloDaTarefa,
                responsavel: $tarefasDaConversaVM.responsavelDaTarefa,
                prioridade: $tarefasDaConversaVM.prioridadeDaTarefa,
                status: $tarefasDaConversaVM.statusDaTarefa,
                prazo: $tarefasDaConversaVM.prazoDaTarefa,
                responsaveisDisponiveis: responsaveisDisponiveis,
                aoCancelar: tarefasDaConversaVM.cancelarEdicao,
                aoAdicionar: tarefasDaConversaVM.salvarEdicao
            )
        }
    }

    private var espacoReservadoParaPlayer: CGFloat {
        deveMostrarPlayer ? alturaMedidaDoPlayer : 0
    }

    @ViewBuilder
    private var areaDeConteudo: some View {
        GeometryReader { _ in
            if exibindoEstadoVazio {
                conteudoDaSecao
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    conteudoDaSecao
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, espacoReservadoParaPlayer)
                        .padding(.top, mostrandoBuscaTranscricao ? 56 : 0)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Navegação por conteúdo

    /// A ficha troca de lugar com o selo de estado.
    ///
    /// Quem participou, quando e por quanto tempo é o que se consulta durante
    /// a leitura; "transcrito e resumido" é status de processamento, que
    /// interessa uma vez e depois vira paisagem. O ponto mais nobre da tela,
    /// ao lado do título, cabe ao primeiro.
    private var cabecalho: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.largo) {
                textoDoCabecalho
                Spacer(minLength: 16)
                botaoDeFicha
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                textoDoCabecalho
                botaoDeFicha
            }
        }
    }

    /// Ações da conversa dentro da página, e não numa `toolbar`.
    ///
    /// A toolbar do macOS desenha a própria faixa no topo da janela, com
    /// material translúcido — era aquela tira que insistia em aparecer, ainda
    /// mais visível em tela cheia. Como linha da página, ela é do mesmo fundo
    /// de tudo o mais, e a tela vira uma superfície só. O recuo à esquerda
    /// abre espaço para os semáforos da janela, que sem barra de título
    /// passam a flutuar sobre o conteúdo.
    private var barraDeAcoes: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            BotaoCircularPapagaio(
                simbolo: "chevron.backward",
                ajuda: "Voltar para a biblioteca".localized,
                legendaAtiva: $legendaDaBarra
            ) {
                fechar()
            }

            Spacer(minLength: PapagaioTema.Espaco.curto)

            BotaoCircularPapagaio(
                simbolo: "square.and.arrow.up",
                ajuda: arquivo.resumo == nil
                    ? "Disponível depois que o resumo estiver pronto".localized
                    : "Compartilhar conversa".localized,
                legendaAtiva: $legendaDaBarra
            ) {
                compartilhar()
            }
            .disabled(arquivo.resumo == nil)
        }
    }

    private var textoDoCabecalho: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            // O título abre a ficha completa — é de lá que saem título e
            // descrição, que não cabem num popover de campo isolado.
            Button {
                abrirEditorDeInformacoes()
            } label: {
                // O chevron é o único indício de que o título abre alguma
                // coisa. Sem ele, um título grande em negrito parece só um
                // título, e a ficha ficava escondida atrás de um clique que
                // ninguém adivinha. Alinhado pela linha de base do texto para
                // não flutuar quando o título quebra em duas ou três linhas.
                HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.curto) {
                    Text(titulo)
                        .font(PapagaioTema.Tipo.tituloDePagina)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            pairandoNoTitulo
                                ? PapagaioTema.destaqueEscuro
                                : PapagaioTema.textoSecundario
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Editar título e descrição".localized)
            .onHover { pairandoNoTitulo = $0 }
            .animation(.easeOut(duration: 0.14), value: pairandoNoTitulo)

            if !metadados.descricao.isEmpty {
                Text(metadados.descricao)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    /// Ficha na ponta direita da linha das abas — só leitura.
    ///
    /// Editar acontece no formulário (pelo título ou pelo menu do cartão), que
    /// é onde a pessoa preenche isso de qualquer jeito. Deixar cada campo
    /// clicável aqui duplicava o mesmo caminho em dois lugares.
    /// A ficha virou botão.
    ///
    /// Em linha, ela ocupava a largura toda ao lado das abas e ainda assim só
    /// dava para ler — editar exigia abrir o editor completo pelo título. Como
    /// popover, ela some quando não interessa e vira formulário quando
    /// interessa, com o que faz sentido mudar já editável ali mesmo.
    private var botaoDeFicha: some View {
        Button {
            entrevistadoDaFicha = metadados.entrevistado
            entrevistadoresDaFicha = metadados.entrevistadores
            formatoDaFicha = metadados.formato
            mostrandoFicha = true
        } label: {
            // `person.text.rectangle` em vez de `info.circle`: o conteúdo é a
            // ficha de quem participou, não um aviso genérico. E o "i" já é o
            // símbolo da ajuda em outras abas — dois significados para o mesmo
            // desenho confundia.
            // Pastilha, e não aba: fora da barra de seções, o filete de 3pt
            // não teria com o que se alinhar. Mesma forma dos filtros da
            // biblioteca, que é a linguagem do app para "isto se clica".
            Label("Ficha".localized, systemImage: "person.text.rectangle")
                .labelStyle(.titleAndIcon)
                .font(PapagaioTema.Tipo.apoio.weight(.semibold))
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(
                    mostrandoFicha || pairandoNaFicha
                        ? PapagaioTema.destaqueEscuro
                        : PapagaioTema.textoSecundario
                )
                .padding(.horizontal, PapagaioTema.Espaco.medio)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(
                    mostrandoFicha ? PapagaioTema.destaque.opacity(0.14) : .clear,
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(
                        mostrandoFicha || pairandoNaFicha
                            ? PapagaioTema.destaque.opacity(0.58)
                            : PapagaioTema.borda.opacity(0.76),
                        lineWidth: 1
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ficha da conversa".localized)
        .accessibilityLabel("Ficha da conversa".localized)
        .onHover { pairandoNaFicha = $0 }
        .animation(.easeOut(duration: 0.14), value: pairandoNaFicha)
        .popover(isPresented: $mostrandoFicha, arrowEdge: .bottom) {
            fichaEmPopover
        }
    }

    /// A ficha só mostra. Quem edita é o formulário, no clique do título.
    ///
    /// Ter os dois caminhos de edição — o formulário completo e um modo de
    /// edição aqui dentro — significava manter duas telas fazendo a mesma
    /// coisa, com regras que precisavam concordar. E o popover crescia de 280
    /// para 460pt no clique do "Editar", o que fazia a tela pular. Como espelho
    /// do formulário, ele fica sempre do mesmo tamanho e sempre igual.
    private var fichaEmPopover: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            // Rótulo concordando em gênero e número com quem está na lista:
            // "Entrevistado: Ana, João" lia errado duas vezes — como se fosse
            // uma pessoa só, e como se essa pessoa fosse homem.
            linhaDaFicha(
                rotuloDeEntrevistadores(nomesDePessoas(entrevistadoresDaFicha)).localized,
                valor: entrevistadoresDaFicha,
                simbolo: "person.crop.circle.badge.checkmark"
            )
            linhaDaFicha(
                rotuloDeEntrevistados(nomesDePessoas(entrevistadoDaFicha)).localized,
                valor: entrevistadoDaFicha,
                simbolo: "person"
            )
            linhaDaFicha(
                "Modalidade".localized,
                valor: formatoDaFicha,
                simbolo: simboloDaModalidade(formatoDaFicha)
            )

            Divider()

            // Estes três são consequência, não escolha: participantes sai dos
            // nomes acima, data e duração vêm do próprio áudio.
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                dadoDaFicha(textoDeParticipantes, simbolo: participantesDaFicha > 1 ? "person.2" : "person")
                dadoDaFicha(
                    DataDigitada.textoComHora(de: arquivo.criadoEm),
                    simbolo: "calendar"
                )
                dadoDaFicha(arquivo.duracao.comoDuracaoPorExtenso, simbolo: "clock")
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(width: 300)
    }

    /// Contado a partir dos nomes salvos, e não de um campo próprio: o número
    /// é consequência de quem foi preenchido no formulário.
    private var participantesDaFicha: Int {
        nomesInformados(entrevistadoDaFicha) + nomesInformados(entrevistadoresDaFicha)
    }

    /// Ninguém preenchido é **zero**, não um.
    ///
    /// O piso em 1 vinha de supor que sempre há ao menos quem gravou. Mas a
    /// ficha mostra quem foi *informado*, e afirmar "1 participante" para uma
    /// conversa vazia é inventar um dado — ainda por cima um que a pessoa não
    /// tem como corrigir, já que o número é calculado.
    private var textoDeParticipantes: String {
        switch participantesDaFicha {
        case 0: "Participantes não informados".localized
        case 1: "1 participante".localized
        default: "%d participantes".localized(participantesDaFicha)
        }
    }

    /// Mesma coluna de ícone das linhas de cima — 18pt fixos.
    ///
    /// `Label` dimensiona cada glifo pelo desenho, e `person.2` é bem mais
    /// largo que `clock`: os textos começavam em três posições diferentes.
    private func dadoDaFicha(_ texto: String, simbolo: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: 18, alignment: .leading)

            Text(texto)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.textoSecundario)
        }
    }

    /// Uma linha da ficha em leitura. Campo vazio continua aparecendo, dizendo
    /// que não foi informado: sumir dava a impressão de que a ficha nem existe.
    private func linhaDaFicha(_ rotulo: String, valor: String, simbolo: String) -> some View {
        let limpo = valor.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(rotulo)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .textCase(.uppercase)
                Text(limpo.isEmpty ? "Não informado".localized : limpo.localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(limpo.isEmpty ? PapagaioTema.textoSecundario : PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fichaDoCabecalho: some View {
        // Fluxo em vez de linha rígida: com muitos nomes ela quebra dentro do
        // próprio espaço, sem empurrar as abas nem sumir na borda da janela.
        LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.medio, espacoVertical: PapagaioTema.Espaco.minimo) {
            // Campo vazio continua visível, dizendo que não foi informado:
            // sumir dava a impressão de que a ficha nem existia.
            metadadoDoCabecalho(
                entrevistado.isEmpty
                    ? "Entrevistado não informado".localized
                    : "\(rotuloDeEntrevistados(nomesDePessoas(entrevistado)).localized): \(entrevistado)",
                simbolo: "person"
            )
            metadadoDoCabecalho(
                entrevistadores.isEmpty
                    ? "Entrevistador não informado".localized
                    : "\(rotuloDeEntrevistadores(nomesDePessoas(entrevistadores)).localized): \(entrevistadores)",
                simbolo: "person.crop.circle.badge.checkmark"
            )
            metadadoDoCabecalho(
                metadados.formato.isEmpty ? "Modalidade não informada".localized : metadados.formato.localized,
                simbolo: simboloDaModalidade(metadados.formato)
            )
            metadadoDoCabecalho(
                participantes == 1 ? "1 participante".localized : "%d participantes".localized(participantes),
                simbolo: participantes == 1 ? "person" : "person.2"
            )
            metadadoDoCabecalho(
                DataDigitada.textoComHora(de: arquivo.criadoEm),
                simbolo: "calendar"
            )
            metadadoDoCabecalho(arquivo.duracao.comoDuracaoPorExtenso, simbolo: "clock")
        }
    }

    private func abrirEditorDeInformacoes() {
        tituloEditado = titulo
        entrevistadoEditado = metadados.entrevistado
        emailDoEntrevistadoEditado = metadados.emailDoEntrevistado
        entrevistadoresEditados = metadados.entrevistadores
        emailDosEntrevistadoresEditado = metadados.emailDosEntrevistadores
        descricaoEditada = metadados.descricao
        formatoEditado = metadados.formato
        participantesEditados = "\(participantes)"
        dataEditada = arquivo.criadoEm
        duracaoEditada = arquivo.duracao.comoDuracaoPorExtenso
        editandoInformacoes = true
    }

    private func salvarInformacoesDaConversa() {
        let tituloLimpo = tituloEditado.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty else { return }

        let quantidade = max(
            1,
            nomesInformados(entrevistadoEditado) + nomesInformados(entrevistadoresEditados)
        )

        PreferenciasVisuaisDoArquivo.definirMetadados(
            MetadadosVisuaisDoArquivo(
                entrevistado: entrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
                emailDoEntrevistado: emailDoEntrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
                entrevistadores: entrevistadoresEditados.trimmingCharacters(in: .whitespacesAndNewlines),
                emailDosEntrevistadores: emailDosEntrevistadoresEditado.trimmingCharacters(in: .whitespacesAndNewlines),
                descricao: descricaoEditada.trimmingCharacters(in: .whitespacesAndNewlines),
                formato: formatoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
                participantes: quantidade
            ),
            para: arquivo.id
        )

        aoAtualizarMetadados(tituloLimpo, dataEditada, arquivo.duracao)
        editandoInformacoes = false
    }

    private func nomesInformados(_ texto: String) -> Int {
        texto
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    private func simboloDaModalidade(_ formato: String) -> String {
        switch formato {
        case "Presencial": "mappin.and.ellipse"
        case "Online": "video"
        default: "questionmark.circle"
        }
    }

    private func metadadoDoCabecalho(_ texto: String, simbolo: String) -> some View {
        Label(texto, systemImage: simbolo)
            .font(PapagaioTema.Tipo.apoio)
            .foregroundStyle(PapagaioTema.textoSecundario)
            .lineLimit(1)
                    .minimumScaleFactor(0.82)
            // `LayoutDeFluxo` mede cada item pelo tamanho natural; sem isto o
            // rótulo comprido tentaria ocupar a linha toda.
            .fixedSize(horizontal: true, vertical: false)
    }

    private var seletorDeSecao: some View {
        // Hint na mesma linha das abas, à direita; some quando a janela aperta
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.medio) {
                BarraDeSecoesDaConversa(
                    secaoSelecionada: secaoSelecionada,
                    aoSelecionar: { secao in
                        withAnimation(animacaoDeInterface) {
                            secaoSelecionada = secao
                        }
                    },
                    acessorio: { EmptyView() }
                )
                Spacer(minLength: PapagaioTema.Espaco.medio)
                if secaoSelecionada == .transcricao && !trechos.isEmpty && !mostrandoBuscaTranscricao {
                    HStack(spacing: PapagaioTema.Espaco.medio) {
                        Toggle("Mostrar confiança".localized, isOn: $mostrarConfianca)
                            .font(.caption)
                            .toggleStyle(.switch)
                            .tint(PapagaioTema.destaque)
                            .fixedSize()
                        Text("Pesquisar na transcrição: Cmd + F".localized)
                            .font(.caption2)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            .fixedSize()
                    }
                }
            }
            BarraDeSecoesDaConversa(
                secaoSelecionada: secaoSelecionada,
                aoSelecionar: { secao in
                    withAnimation(animacaoDeInterface) {
                        secaoSelecionada = secao
                    }
                },
                acessorio: { EmptyView() }
            )
        }
    }

    /// Todo o conteúdo da conversa é texto selecionável.
    ///
    /// Resumo, transcrição, citações e tarefas existem para serem levados para
    /// fora — relatório, e-mail, Notion. Sem seleção, a única saída era o
    /// Compartilhar, que exporta a conversa inteira; copiar uma frase exigia
    /// redigitá-la.
    ///
    /// `.textSelection(.enabled)` no contêiner vale para todo `Text` abaixo
    /// dele, e traz junto o que o macOS já sabe fazer com texto selecionado:
    /// Cmd+C, arrastar para outro app, Serviços e o menu de contexto.
    @ViewBuilder
    private var conteudoDaSecao: some View {
        conteudoBrutoDaSecao
            .textSelection(.enabled)
            // Atalho para quem quer tudo: selecionar a conversa inteira à mão
            // dá trabalho, e é o caso mais comum depois de copiar uma frase.
            .contextMenu {
                Button("Copiar conversa inteira".localized, systemImage: "doc.on.doc") {
                    let texto = DossieDaConversa.gerar(arquivo: arquivo)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(texto, forType: .string)
                }
            }
    }

    @ViewBuilder
    private var conteudoBrutoDaSecao: some View {
        switch secaoSelecionada {
        case .resumo:
            resumo
        case .transcricao:
            transcricao
        case .notas:
            notasDaConversa
        case .midia:
            midia
        case .tarefas:
            tarefas
        }
    }

    // MARK: - Resumo

    @ViewBuilder
    private var resumo: some View {
        if let resumo = arquivo.resumo {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Text(resumo.visaoGeral)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)

                if !resumo.temas.isEmpty {
                    secao("Temas".localized) {
                        // Grade adaptativa: numa janela estreita vira uma coluna,
                        // numa tela larga os temas ocupam a faixa toda em vez de
                        // formarem uma lista fina no canto esquerdo.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 320), spacing: PapagaioTema.Espaco.largo, alignment: .topLeading)],
                            alignment: .leading,
                            spacing: PapagaioTema.Espaco.medio
                        ) {
                            ForEach(Array(resumo.temas.enumerated()), id: \.offset) { _, tema in
                                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                                    Text(tema.titulo)
                                        .font(PapagaioTema.Tipo.apoio.weight(.semibold))
                                        .foregroundStyle(PapagaioTema.texto)
                                    Text(tema.detalhe)
                                        .font(PapagaioTema.Tipo.apoio)
                                        .foregroundStyle(PapagaioTema.textoSecundario)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.vertical, PapagaioTema.Espaco.minimo)
                            }
                        }
                    }
                }

                Divider()
                    .padding(.top, PapagaioTema.Espaco.medio)

                HStack {
                    Spacer()
                    if processando || naFila {
                        HStack(spacing: PapagaioTema.Espaco.curto) {
                            ProgressView().controlSize(.small)
                            Text("Gerando novo resumo…".localized)
                                .font(.callout)
                                .foregroundStyle(PapagaioTema.textoSecundario)
                        }
                    } else {
                        Button(action: aoGerarNovoResumo) {
                            Label("Gerar novo resumo".localized, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(BotaoDeContornoPapagaio())
                        .disabled(arquivo.trechos.isEmpty)
                        .help("Reprocessa a conversa inteira: transcrição, resumo e próximos passos".localized)
                    }
                }

            }
            // O card acompanha a janela (até o limite de página) em vez de ficar
            // preso a 720pt: em tela cheia sobrava um vazio enorme à direita.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PapagaioTema.Espaco.secao)
            .cartaoPapagaio()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CartaoDeEstadoVazio(
                simbolo: "text.alignleft",
                titulo: "Resumo indisponível".localized,
                mensagem: "O resumo aparecerá depois do processamento.".localized
            )
        }
    }

    private var tarefas: some View {
        @Bindable var vm = tarefasDaConversaVM
        return TarefasDaConversaView(
            tarefas: vm.tarefasAceitas,
            sugestoes: vm.sugestoes,
            filtro: $vm.filtro,
            aoAdicionar: { vm.mostrandoCriacao = true },
            aoAlternarConclusao: vm.alternarConclusao,
            aoEditar: vm.iniciarEdicao,
            aoMover: vm.mover,
            aoAceitarSugestao: vm.aceitarSugestao,
            aoEditarSugestao: vm.iniciarEdicao,
            aoRejeitarSugestao: vm.rejeitarSugestao
        )
    }

    private func secao<Conteudo: View>(
        _ titulo: String, @ViewBuilder _ conteudo: () -> Conteudo
    ) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text(titulo)
                .font(PapagaioTema.Tipo.tituloDeSecao)
                .foregroundStyle(PapagaioTema.texto)
            conteudo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PapagaioTema.Espaco.curto)
    }

    // MARK: - Mídia

    private var midia: some View {
        MidiaDaConversaView(
            anexos: midiasDaConversaVM.todosOsAnexos,
            aoAdicionar: midiasDaConversaVM.selecionar,
            aoSoltarArquivos: { urls in
                urls.forEach(midiasDaConversaVM.adicionar)
            },
            aoAbrir: midiasDaConversaVM.abrir,
            aoRemover: midiasDaConversaVM.remover,
            naLixeira: midiasDaConversaVM.naLixeira,
            aoRestaurar: midiasDaConversaVM.restaurar,
            aoApagarDeVez: midiasDaConversaVM.apagarDeVez
        )
    }

    // MARK: - Tarefas
    //
    // Regra de prazo, formulário e gravação vivem no
    // `TarefasDaConversaViewModel` — a duplicata que existia aqui foi
    // removida quando a view passou a usar o VM (o VM existia e ninguém
    // usava).

    private func revelarPlayer() {
        guard !mostrandoPlayer else { return }
        withAnimation(animacaoDeInterface) {
            mostrandoPlayer = true
        }
    }

    private func tocar(_ trecho: Trecho, no reprodutor: ReprodutorDeArquivo) {
        tempoEmEdicao = nil
        revelarPlayer()
        Task { @MainActor in
            await reprodutor.tocar(aPartirDe: trecho)
        }
    }

    private func tocar(_ nota: NotaDaConversa) {
        guard let reprodutor else { return }
        let inicio = min(max(0, nota.start), reprodutor.duracao)
        revelarPlayer()
        Task { @MainActor in
            await reprodutor.saltar(paraSegundo: inicio)
            reprodutor.tocar()
        }
    }

    private func concluirEdicaoDaPosicao(_ reprodutor: ReprodutorDeArquivo) {
        guard let destino = tempoEmEdicao else { return }
        Task { @MainActor in
            await reprodutor.saltar(paraSegundo: destino)
            tempoEmEdicao = nil
        }
    }

    /// Uma ação só: documento e áudio no mesmo pacote, e dentro do painel do
    /// sistema também a opção de salvar em pasta.
    private func compartilhar() {
        Task { @MainActor in
            let itens: [Any]
            do {
                let arquivoParaExportar = arquivo
                let audioParaExportar = audio
                itens = [try await Task.detached {
                    try DossieDaConversa.pacoteComAudio(
                        arquivo: arquivoParaExportar,
                        audioPrincipal: audioParaExportar
                    )
                }.value]
            } catch {
                if let destino = try? DossieDaConversa.markdownTemporario(arquivo: arquivo) {
                    itens = [destino]
                } else {
                    itens = [DossieDaConversa.gerar(arquivo: arquivo)]
                }
            }

            apresentarCompartilhamento(itens)
        }
    }

    private func apresentarCompartilhamento(_ itens: [Any]) {
        let picker = NSSharingServicePicker(items: itens)
        let opcoes = OpcoesDeCompartilhamento(arquivos: itens.compactMap { $0 as? URL })
        delegadoDeCompartilhamento = opcoes
        picker.delegate = opcoes

        guard let view = NSApp.keyWindow?.contentView else {
            itens.compactMap { $0 as? URL }.forEach(DossieDaConversa.descartarArquivoTemporario)
            return
        }
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private var avisoDeAudioRemovido: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PapagaioTema.aviso)
                .frame(width: 48, height: 48)
                .background(PapagaioTema.aviso.opacity(0.12), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text("Não foi possível abrir o áudio desta conversa".localized)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                Text("A transcrição, as notas e o resumo continuam aqui. Restaure o áudio pela Lixeira do app — assim ele volta com o nome que a reprodução espera.".localized)
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, PapagaioTema.Espaco.secao)
        .padding(.vertical, PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(PapagaioTema.superficie)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PapagaioTema.borda.opacity(0.75))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// O player em uma linha quando cabe, empilhado só quando não cabe.
    ///
    /// Estava fixo em `compacto: true`, ou seja, sempre na versão empilhada de
    /// 208pt — três vezes a altura necessária numa janela larga, comendo a
    /// parte de baixo da transcrição sem motivo. `ViewThatFits` escolhe pela
    /// largura real: a faixa de 88pt em tela normal, a empilhada só na estreita,
    /// que é o caso para o qual ela foi feita.
    private func barraFlutuante(_ reprodutor: ReprodutorDeArquivo) -> some View {
        ViewThatFits(in: .horizontal) {
            barraDeAudio(reprodutor, compacto: false)
            barraDeAudio(reprodutor, compacto: true)
        }
    }

    private func barraDeAudio(_ reprodutor: ReprodutorDeArquivo, compacto: Bool) -> some View {
        BarraDeAudioDaConversa(
            titulo: titulo,
            data: arquivo.criadoEm,
            reprodutor: reprodutor,
            tempoEmEdicao: $tempoEmEdicao,
            aoConcluirEdicao: { concluirEdicaoDaPosicao(reprodutor) },
            compacto: compacto
        )
    }

    private func alternarReproducaoComEspaco() {
        guard Self.atalhoDeReproducaoEstaDisponivel(
            primeiroRespondedor: NSApp.keyWindow?.firstResponder
        ), let reprodutor, reprodutor.duracao > 0 else {
            return
        }

        if reprodutor.tocando {
            reprodutor.pausar()
        } else {
            reprodutor.tocar()
        }
    }

    // MARK: - Transcrição

    /// Sem `ScrollView` próprio: o conteúdo da seção já vive dentro de um.
    ///
    /// Duas rolagens empilhadas davam duas barras — uma delas caindo por cima
    /// dos botões das notas — e faziam o bloco de escrita rolar para fora da
    /// tela e ser cortado pela barra de abas. A de fora basta.
    private var notasDaConversa: some View {
        PainelDeNotasDaConversa(
            notas: $notasEditaveis,
            estadoDeSalvamento: estadoDeSalvamentoDasNotas,
            duracao: arquivo.duracao,
            instanteAtual: { reprodutor?.tempo ?? 0 },
            ditado: ditado,
            aoTocar: tocar,
            aoSalvar: agendarSalvamentoDasNotas,
            aoAlternarDitado: alternarDitado
        )
        .padding(.bottom, PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Carrega as notas do arquivo. O bloco único que existia antes continua
    /// válido — vira uma nota como as outras, ancorada em 0:00.
    private func sincronizarNotasComArquivo() {
        notasEditaveis = arquivo.notas.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }

    private func agendarSalvamentoDasNotas() {
        tarefaDeSalvamentoDasNotas?.cancel()
        estadoDeSalvamentoDasNotas = "Salvando..."
        tarefaDeSalvamentoDasNotas = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            salvarNotasAgora()
        }
    }

    private func salvarNotasAgora() {
        let atualizadas = notasEditaveis.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        notasEditaveis = atualizadas
        estadoDeSalvamentoDasNotas = "Salvando..."

        Task { @MainActor in
            await aoAtualizarNotas(atualizadas)
            estadoDeSalvamentoDasNotas = "Salvo"
        }
    }

    /// Ditar acrescenta uma nota nova no instante atual, em vez de emendar no
    /// fim de um bloco — cada fala vira um item que se pode marcar e filtrar.
    private func alternarDitado() {
        ditado.limparFalha()

        Task { @MainActor in
            if ditado.gravando {
                guard let falado = await ditado.concluir(transcrever: aoDitar) else { return }
                let instante = min(max(0, reprodutor?.tempo ?? 0), max(arquivo.duracao, 0))
                notasEditaveis.append(
                    NotaDaConversa(texto: falado, start: instante, critica: false, tipo: .nota)
                )
                salvarNotasAgora()
            } else {
                await ditado.iniciar()
            }
        }
    }

    @ViewBuilder
    private var transcricao: some View {
        if trechos.isEmpty {
            if podeIniciarTranscricao {
                transcricaoPendente
            } else {
                CartaoDeEstadoVazio(
                    simbolo: "text.quote",
                    titulo: "Transcrição em preparação".localized,
                    mensagem: "A transcrição aparecerá depois do processamento.".localized
                )
            }
        } else if let reprodutor {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                // Só quando a diarização de fato separou vozes — uma
                // conversa de canal único não tem "quem é quem" para nomear.
                if !vozesAcusticas.isEmpty {
                    EditorDeNomesDeVoz(
                        vozes: vozesAcusticas,
                        nomes: nomesDeVoz,
                        sugestoes: sugestoesDeNomeDeVoz,
                        aoRenomear: renomearVoz
                    )
                }

                if let falas {
                    transcricaoDeFalas(falas, no: reprodutor)
                } else {
                    transcricaoDeTrechos(no: reprodutor)
                }
            }
            .background {
                // Atalho Cmd+F estilo navegador
                Button("") { abrirBuscaTranscricao() }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }
        }
    }

    /// Salva (ou apaga, se o nome ficou vazio) o rótulo de uma voz acústica.
    private func renomearVoz(_ vozAcustica: String, novoNome: String) {
        var mapa = PreferenciasVisuaisDoArquivo.nomesDeVoz(arquivo.id)
        if novoNome.isEmpty {
            mapa.removeValue(forKey: vozAcustica)
        } else {
            mapa[vozAcustica] = novoNome
        }
        PreferenciasVisuaisDoArquivo.definirNomesDeVoz(mapa, para: arquivo.id)
        geracaoDeNomesDeVoz += 1
    }

    /// Leitura por fala de falante: a voz é a unidade, não o bloco de texto.
    ///
    /// O destaque do player continua casando pela âncora da palavra — cada
    /// palavra da fala sabe o trecho e o índice de onde veio, então a rolagem
    /// e o destaque reagem ao áudio como na lista de trechos.
    private func transcricaoDeFalas(
        _ falas: [FalaDeFalante], no reprodutor: ReprodutorDeArquivo
    ) -> some View {
        let idAtual = ocorrenciasDaBusca.indices.contains(indiceOcorrenciaBusca) ? ocorrenciasDaBusca[indiceOcorrenciaBusca].palavraId ?? ocorrenciasDaBusca[indiceOcorrenciaBusca].falaId : nil
        return ScrollViewReader { rolagem in
            LazyVStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                ForEach(falas) { fala in
                    let preservado: String? = {
                        if fala.falanteAcustico != nil { return nil }
                        if let p = FalantePreservadoParaTrecho.obter(para: fala.id, arquivo: arquivo.id) { return p }
                        for tid in fala.trechoIds {
                            if let p = FalantePreservadoParaTrecho.obter(para: tid, arquivo: arquivo.id) { return p }
                        }
                        return nil
                    }()
                    LinhaDeFala(
                        fala: fala,
                        ativo: falaEstaAtiva(fala, no: reprodutor),
                        palavraAtiva: palavraAtiva(fala, no: reprodutor),
                        animacao: animacaoDeInterface,
                        nomesDeVoz: nomesDeVoz,
                        aoTocarFala: { tocar(fala, no: reprodutor) },
                        aoTocarPalavra: { palavra in
                            tocar(palavra, no: reprodutor)
                        },
                        aoEditar: { iniciarEdicaoDaFala(fala) },
                        termoDeBusca: termoDeBuscaTranscricao,
                        idOcorrenciaAtual: idAtual,
                        falantePreservado: preservado,
                        mostrarConfianca: mostrarConfianca,
                        mostrarPorcentagemConfianca: mostrarPorcentagemConfianca,
                        estaEditando: itemEmEdicao == .fala(fala.id),
                        textoEditado: $textoEmEdicao,
                        aoSalvarEdicao: { salvarEdicaoDaFala(fala) },
                        aoCancelarEdicao: { cancelarEdicaoDaFala() }
                    )
                    .id(fala.id)
                }
            }
            .onChange(of: reprodutor.indiceAtivo) { _, novo in
                guard let novo, trechos.indices.contains(novo) else { return }
                let trechoAtivo = trechos[novo]
                guard let fala = falas.first(where: { $0.trechoIds.contains(trechoAtivo.id) }) else {
                    return
                }
                withAnimation(animacaoDeInterface) {
                    rolagem.scrollTo(fala.id, anchor: .center)
                }
            }
            .onChange(of: alvoDaBusca) { _, novo in
                guard let novo else { return }
                withAnimation(animacaoDeInterface) {
                    rolagem.scrollTo(novo, anchor: .center)
                }
            }
        }
    }

    /// A fala está tocando quando o tempo atual está dentro do intervalo dela.
    /// Usa o tempo (palavra.start/end) em vez de `trechoId`, porque um mesmo
    /// trecho pode ter sido dividido em várias falas quando a diarização detectou
    /// troca de voz dentro da janela de 40 s — com o check por `trechoId` as
    /// duas falas ficavam laranja ao mesmo tempo.
    private func falaEstaAtiva(_ fala: FalaDeFalante, no reprodutor: ReprodutorDeArquivo) -> Bool {
        // Falas com palavras têm intervalo preciso.
        if !fala.palavras.isEmpty {
            let t = reprodutor.tempo
            // `fim` é exclusivo; gap entre falas fica sem destaque (não herda o anterior)
            return t >= fala.inicio && t < fala.fim
        }
        // Falas legadas/editadas (sem palavras): fallback por trechoId — são únicas.
        guard let indice = reprodutor.indiceAtivo, trechos.indices.contains(indice) else {
            return false
        }
        return fala.trechoIds.contains(trechos[indice].id)
    }

    /// A palavra tocando dentro da fala, casada pela âncora no trecho de
    /// origem — ou `nil` quando a fala não está ativa ou é legada.
    private func palavraAtiva(_ fala: FalaDeFalante, no reprodutor: ReprodutorDeArquivo) -> PalavraDeFala? {
        guard falaEstaAtiva(fala, no: reprodutor),
              let indiceDoTrecho = reprodutor.indiceAtivo,
              let indiceDaPalavra = reprodutor.indiceDePalavraAtiva,
              trechos.indices.contains(indiceDoTrecho)
        else { return nil }
        let trecho = trechos[indiceDoTrecho]
        guard trecho.palavras.indices.contains(indiceDaPalavra) else { return nil }
        return PalavraDeFala(
            palavra: trecho.palavras[indiceDaPalavra],
            trechoId: trecho.id,
            indiceNoTrecho: indiceDaPalavra
        )
    }

    private func transcricaoDeTrechos(no reprodutor: ReprodutorDeArquivo) -> some View {
        let idAtual = ocorrenciasDaBusca.indices.contains(indiceOcorrenciaBusca) ? ocorrenciasDaBusca[indiceOcorrenciaBusca].palavraId ?? ocorrenciasDaBusca[indiceOcorrenciaBusca].trechoId : nil
        return ScrollViewReader { rolagem in
            LazyVStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                ForEach(trechos, id: \.id) { trecho in
                    let ativo = trechos.firstIndex(where: { $0.id == trecho.id }) == reprodutor.indiceAtivo
                    let preservado = FalantePreservadoParaTrecho.obter(para: trecho.id, arquivo: arquivo.id)
                        LinhaDeTranscricao(
                            trecho: trecho,
                            ativo: ativo,
                            // Só o trecho ativo consulta a palavra: o
                            // destaque por palavra é observado na linha
                            // certa, não na transcrição inteira.
                            indiceDePalavraAtiva: ativo ? reprodutor.indiceDePalavraAtiva : nil,
                            animacao: animacaoDeInterface,
                            nomesDeVoz: nomesDeVoz,
                            aoTocarLinha: { tocar(trecho, no: reprodutor) },
                            aoTocarPalavra: { palavra in
                                tocar(palavra, no: reprodutor)
                            },
                            aoEditar: { iniciarEdicaoDoTrecho(trecho) },
                            termoDeBusca: termoDeBuscaTranscricao,
                            idOcorrenciaAtual: idAtual,
                            falantePreservado: preservado,
                            mostrarConfianca: mostrarConfianca,
                            mostrarPorcentagemConfianca: mostrarPorcentagemConfianca,
                            estaEditando: itemEmEdicao == .trecho(trecho.id),
                            textoEditado: $textoEmEdicao,
                            aoSalvarEdicao: { salvarEdicaoDoTrecho(trecho) },
                            aoCancelarEdicao: { cancelarEdicaoDoTrecho() }
                        )
                        .id(trecho.id)
                }
            }
            .onChange(of: reprodutor.indiceAtivo) { _, novo in
                guard let novo, trechos.indices.contains(novo) else { return }
                withAnimation(animacaoDeInterface) {
                    rolagem.scrollTo(trechos[novo].id, anchor: .center)
                }
            }
            .onChange(of: alvoDaBusca) { _, novo in
                guard let novo else { return }
                withAnimation(animacaoDeInterface) {
                    rolagem.scrollTo(novo, anchor: .center)
                }
            }
        }
    }

    private func iniciarEdicaoDoTrecho(_ trecho: Trecho) {
        textoEmEdicao = trecho.texto
        itemEmEdicao = .trecho(trecho.id)
    }

    private func cancelarEdicaoDoTrecho() {
        itemEmEdicao = nil
        textoEmEdicao = ""
    }

    private func iniciarEdicaoDaFala(_ fala: FalaDeFalante) {
        textoEmEdicao = fala.texto
        itemEmEdicao = .fala(fala.id)
    }

    private func cancelarEdicaoDaFala() {
        itemEmEdicao = nil
        textoEmEdicao = ""
    }

    private func salvarEdicaoDoTrecho(_ trecho: Trecho) {
        let limpo = textoEmEdicao.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelarEdicaoDoTrecho()
        guard !limpo.isEmpty, limpo != trecho.texto else { return }

        // Preserva o falante para não virar "voz desconhecida", mas mantém
        // o trecho distinto (palavras vazias) para não fundir com a seguinte
        let falante = falanteExibidoParaTrecho(trecho)
        let novo = Trecho(
            id: trecho.id,
            start: trecho.start,
            end: trecho.end,
            texto: limpo,
            speaker: trecho.speaker,
            palavras: []
        )
        if let falante {
            FalantePreservadoParaTrecho.definir(falante, para: novo.id, arquivo: arquivo.id)
        } else {
            FalantePreservadoParaTrecho.remover(para: novo.id, arquivo: arquivo.id)
        }
        let atualizados = trechos.map { atual in
            atual.id == trecho.id ? novo : atual
        }

        Task { @MainActor in
            await aoAtualizarTranscricao(atualizados)
        }
    }

    /// Corrige o texto de uma fala inteira.
    ///
    /// A fala atravessa trechos; ao salvar, os trechos de onde ela saiu são
    /// fundidos num só com o texto corrigido (o `start`/`end` dos trechos
    /// originais são mantidos: a janela da fala não muda, só o texto). O falante
    /// acústico é preservado com timestamp aproximado para não virar "voz desconhecida".
    private func salvarEdicaoDaFala(_ fala: FalaDeFalante) {
        let limpo = textoEmEdicao.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelarEdicaoDaFala()
        guard !limpo.isEmpty, limpo != fala.texto else { return }

        let idsDaFala = Set(fala.trechoIds)
        guard let primeiro = trechos.first(where: { idsDaFala.contains($0.id) })
        else { return }

        let fundidoId = UUID()
        // Preserva o falante: tenta o acústico direto da fala, e se não
        // tiver (fala já editada, sem palavras), busca o preservado dos
        // trechos anteriores para não virar "voz desconhecida".
        let falantePreservado: String? = fala.falanteAcustico ?? {
            for tid in fala.trechoIds {
                if let p = FalantePreservadoParaTrecho.obter(para: tid, arquivo: arquivo.id) {
                    return p
                }
            }
            return nil
        }()
        if let falante = falantePreservado {
            FalantePreservadoParaTrecho.definir(falante, para: fundidoId, arquivo: arquivo.id)
        }
        let fundido = Trecho(
            id: fundidoId,
            start: fala.inicio,
            end: fala.fim,
            texto: limpo,
            speaker: primeiro.speaker,
            palavras: []
        )
        // Preserva palavras de outras falas que compartilham o mesmo trecho.
        // Quando a diarização divide um trecho em duas falas (ex.: S1/S2 dentro
        // da mesma janela de 40 s), `trechoIds` se repete. Remover o trecho
        // inteiro apagaria a outra fala — editas U e some V.
        let idsDasPalavrasDaFala = Set(fala.palavras.map(\.palavra.id))
        var atualizados: [Trecho] = []
        for trecho in trechos {
            guard idsDaFala.contains(trecho.id) else {
                atualizados.append(trecho)
                continue
            }
            if trecho.palavras.isEmpty {
                // Trecho legado/editado já sem palavras — pertence só a esta fala
                continue
            }
            let restantes = trecho.palavras.filter { !idsDasPalavrasDaFala.contains($0.id) }
            if restantes.isEmpty {
                continue
            }
            let textoRestante = restantes.map(\.texto).joined(separator: " ")
            atualizados.append(Trecho(
                id: trecho.id,
                start: trecho.start,
                end: trecho.end,
                texto: textoRestante,
                speaker: trecho.speaker,
                palavras: restantes
            ))
        }
        // `atualizados` já está na ordem original — percorre `trechos` em
        // ordem e só remove/substitui os que pertencem a esta fala. Não
        // reordenar: o sort por `start` bagunça trechos com mesmo instante.
        atualizados.insert(fundido, at: indiceDeInsercao(fundido, em: atualizados))

        Task { @MainActor in
            await aoAtualizarTranscricao(atualizados)
        }
    }

    /// Posição do trecho fundido numa lista ordenada por `start` — o trecho
    /// mantém a ordem cronológica depois de substituir a fala.
    private func indiceDeInsercao(_ trecho: Trecho, em trechos: [Trecho]) -> Int {
        trechos.firstIndex { $0.start > trecho.start } ?? trechos.endIndex
    }

    private var transcricaoPendente: some View {
        VStack(spacing: PapagaioTema.Espaco.medio) {
            Image(systemName: "text.quote")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 64, height: 64)
                .background(PapagaioTema.destaqueSuave, in: Circle())

            Text("Pronto para transcrever".localized)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PapagaioTema.texto)

            Text("Inicie a transcrição quando quiser. O resumo será gerado em seguida, respeitando a fila de processamento.".localized)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(maxWidth: 420)

            Button("Transcrever".localized, systemImage: "text.badge.plus", action: aoTranscrever)
                .buttonStyle(BotaoPrincipalPapagaio())
                .accessibilityHint("Adiciona esta conversa à fila. O resumo será feito após a transcrição.".localized)
        }
        .padding(PapagaioTema.Espaco.pagina)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func tocar(_ palavra: Palavra, no reprodutor: ReprodutorDeArquivo) {
        tempoEmEdicao = nil
        Task { @MainActor in
            // O timestamp é próprio da palavra (token_timestamps) — o salto
            // pousa no átomo da fala, não numa divisão do trecho.
            await reprodutor.saltar(paraSegundo: palavra.start)
        }
    }

    private func tocar(_ fala: FalaDeFalante, no reprodutor: ReprodutorDeArquivo) {
        tempoEmEdicao = nil
        revelarPlayer()
        Task { @MainActor in
            // A fala pode ter nascido no fim de um trecho; o salto usa o
            // início da fala, não o do trecho — o áudio começa na fala.
            await reprodutor.saltar(paraSegundo: fala.inicio)
            reprodutor.tocar()
        }
    }

    // MARK: - Formatação

}
