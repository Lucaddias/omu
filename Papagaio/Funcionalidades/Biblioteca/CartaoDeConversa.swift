import AppKit
import PapagaioCore
import SwiftUI

struct CartaoDeConversa: View {
    let arquivo: Arquivo
    let estado: EstadoDoArquivo
    /// `nil` quando não há processamento em andamento.
    let progresso: (inicio: Date, estimativa: TimeInterval)?
    /// Veio de um arquivo escolhido pela pessoa, e não do microfone.
    let importado: Bool
    let processando: Bool
    let naFila: Bool
    let emOperacaoDeLixeira: Bool
    let aoReprocessar: () -> Void
    let aoRenomear: (String) -> Void
    let aoAtualizarMetadados: (String, Date, TimeInterval) -> Void
    let aoDuplicar: () -> Void
    let urlDeAudio: URL
    let menuAberto: Bool
    let aoAlternarMenu: () -> Void
    let aoFecharMenu: () -> Void
    let aoAlterarPreferenciasVisuais: () -> Void
    let aoMoverParaLixeira: () -> Void

    @State private var editandoInformacoes = false
    @State private var escolhendoPastaDestino = false
    /// O picker não retém o delegate; sem esta referência "Salvar em…" some.
    @State private var delegadoDeCompartilhamento: OpcoesDeCompartilhamento?
    @State private var criandoPastaParaMover = false
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
    @State private var nomeDaPasta = ""
    @State private var favorito: Bool
    @State private var pasta: String?
    @State private var capaURL: URL?
    @State private var metadados: MetadadosVisuaisDoArquivo

    init(
        arquivo: Arquivo,
        estado: EstadoDoArquivo,
        progresso: (inicio: Date, estimativa: TimeInterval)?,
        importado: Bool,
        processando: Bool,
        naFila: Bool,
        emOperacaoDeLixeira: Bool,
        aoReprocessar: @escaping () -> Void,
        aoRenomear: @escaping (String) -> Void,
        aoAtualizarMetadados: @escaping (String, Date, TimeInterval) -> Void,
        aoDuplicar: @escaping () -> Void,
        urlDeAudio: URL,
        menuAberto: Bool,
        aoAlternarMenu: @escaping () -> Void,
        aoFecharMenu: @escaping () -> Void,
        aoAlterarPreferenciasVisuais: @escaping () -> Void,
        aoMoverParaLixeira: @escaping () -> Void
    ) {
        self.arquivo = arquivo
        self.estado = estado
        self.progresso = progresso
        self.importado = importado
        self.processando = processando
        self.naFila = naFila
        self.emOperacaoDeLixeira = emOperacaoDeLixeira
        self.aoReprocessar = aoReprocessar
        self.aoRenomear = aoRenomear
        self.aoAtualizarMetadados = aoAtualizarMetadados
        self.aoDuplicar = aoDuplicar
        self.urlDeAudio = urlDeAudio
        self.menuAberto = menuAberto
        self.aoAlternarMenu = aoAlternarMenu
        self.aoFecharMenu = aoFecharMenu
        self.aoAlterarPreferenciasVisuais = aoAlterarPreferenciasVisuais
        self.aoMoverParaLixeira = aoMoverParaLixeira
        _favorito = State(initialValue: PreferenciasVisuaisDoArquivo.favorito(arquivo.id))
        _pasta = State(initialValue: PreferenciasVisuaisDoArquivo.pasta(arquivo.id))
        _capaURL = State(initialValue: PreferenciasVisuaisDoArquivo.capa(arquivo.id))
        _metadados = State(initialValue: PreferenciasVisuaisDoArquivo.metadados(arquivo.id))
    }

    private var titulo: String { arquivo.resumo?.titulo ?? arquivo.titulo }

    /// Só as pessoas que foram realmente preenchidas.
    ///
    /// Antes o cartão imprimia "Não informado" três vezes e dedicava a maior
    /// área da sua superfície a dados ausentes. Campo vazio agora simplesmente
    /// não ocupa espaço — quem preencheu vê a informação em destaque.
    /// Só quem foi preenchido.
    ///
    /// "Não informado" em negrito, duas vezes por cartão, era o maior ruído da
    /// grade: repetia a ausência com o mesmo peso visual de um nome de verdade
    /// e competia com o título. Quando nada foi preenchido, uma única linha
    /// discreta convida a preencher — ver `avisoDePessoas`.
    private var pessoasDoCard: [(simbolo: String, rotulo: String, valor: String)] {
        let entrevistado = listaDePessoas(metadados.entrevistado)
        let entrevistadores = listaDePessoas(metadados.entrevistadores)

        var linhas: [(simbolo: String, rotulo: String, valor: String)] = []
        if !entrevistadores.isEmpty {
            linhas.append((
                "person.crop.circle.badge.checkmark",
                quantidadeDePessoas(entrevistadores) > 1 ? "Entrevistadores" : "Entrevistador",
                entrevistadores
            ))
        }
        if !entrevistado.isEmpty {
            linhas.append((
                "person",
                quantidadeDePessoas(entrevistado) > 1 ? "Entrevistados" : "Entrevistado",
                entrevistado
            ))
        }
        return linhas
    }

    private func quantidadeDePessoas(_ lista: String) -> Int {
        lista
            .split(separator: ",")
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

    private var participantes: Int {
        max(1, metadados.participantes ?? participantesDetectados)
    }

    private var participantesDetectados: Int {
        let speakers = Set(arquivo.trechos.compactMap(\.speaker).filter { !$0.isEmpty })
        return max(1, speakers.count)
    }

    var body: some View {
        NavigationLink(value: arquivo.id.rawValue) {
            VStack(alignment: .leading, spacing: 0) {
                CapaDeConversa(arquivo: arquivo, capaURL: capaURL)

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                    Text(titulo)
                        .font(PapagaioTema.Tipo.tituloDeCard)
                        .foregroundStyle(PapagaioTema.texto)
                        // Reservar as duas linhas mantém os selos e o rodapé na
                        // mesma altura em todos os cartões da fileira. Sem isso
                        // um título de uma linha desalinhava o cartão inteiro em
                        // relação ao vizinho.
                        // Uma linha só, sem reticências: em vez de cortar, o
                        // título encolhe até caber. O alinhamento da fileira
                        // vem do `maxHeight`, não da altura do texto.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .help(titulo)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, PapagaioTema.Espaco.secao)

                    // A linha existe mesmo vazia, e não por simetria: sem ela
                    // um cartão com descrição e outro sem ficavam com o corpo
                    // deslocado na mesma fileira. Em itálico e sem negrito, o
                    // aviso se lê como lacuna, não como conteúdo.
                    if metadados.descricao.isEmpty {
                        Text("Sem descrição")
                            .font(PapagaioTema.Tipo.apoio.italic())
                            .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Text(metadados.descricao)
                            .font(PapagaioTema.Tipo.apoio)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(2)
                    }

                    // O selo "Áudio local" saiu: era verdadeiro em 100% dos
                    // cartões, então não distinguia nada — só competia por
                    // espaço com o estado, que é a informação que muda.
                    // O selo só aparece quando há algo a dizer. "Transcrito e
                    // resumido" é o estado de repouso de toda conversa madura:
                    // estaria em quase todos os cartões, o tempo todo, gastando
                    // uma linha para informar o esperado. Fila, processamento e
                    // falha são exceções, e mudam o que dá para fazer ali.
                    if estado != .transcritoEResumido || pasta != nil {
                        LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.curto, espacoVertical: PapagaioTema.Espaco.curto) {
                            if estado != .transcritoEResumido {
                                SeloDeStatus(
                                    texto: estado.descricao,
                                    simbolo: estado.simbolo,
                                    estilo: estado.estilo
                                )
                            }

                            if let pasta {
                                SeloDeStatus(texto: pasta, simbolo: "folder", estilo: .neutro)
                            }
                        }
                    }

                    if let progresso {
                        BarraDeProgressoDoProcessamento(
                            inicio: progresso.inicio,
                            estimativa: progresso.estimativa
                        )
                    }

                    if pessoasDoCard.isEmpty {
                        Label("Participantes não informados", systemImage: "person.badge.plus")
                            .font(PapagaioTema.Tipo.legenda)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                            ForEach(pessoasDoCard, id: \.rotulo) { pessoa in
                                MetadadoDoCard(
                                    simbolo: pessoa.simbolo,
                                    rotulo: pessoa.rotulo,
                                    valor: pessoa.valor
                                )
                            }
                        }
                    }

                    // Data, duração e participantes existem sempre — viram uma
                    // linha de rodapé em vez de três células de grade com
                    // rótulo em maiúscula competindo com o título.
                    LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.medio, espacoVertical: PapagaioTema.Espaco.minimo) {
                        Label(
                            arquivo.criadoEm.formatted(.dateTime.day().month(.abbreviated).year()),
                            systemImage: "calendar"
                        )
                        Label(arquivo.duracao.comoDuracaoPorExtenso, systemImage: "clock")

                        // Gravado e importado são conversas diferentes: uma tem
                        // dois canais e separa quem falou, a outra é um áudio
                        // só. Saber disso muda o que esperar da transcrição.
                        Label(
                            importado ? "Importado" : "Gravado",
                            systemImage: importado ? "square.and.arrow.down" : "mic"
                        )

                        // Participantes e modalidade só quando dizem algo: "1
                        // participante" e "modalidade não informada" apareciam
                        // em quase todo cartão, empurrando o rodapé para uma
                        // segunda linha e desalinhando a fileira.
                        if participantes > 1 {
                            Label("\(participantes) participantes", systemImage: "person.2")
                        }

                        if !metadados.formato.isEmpty {
                            Label(
                                metadados.formato,
                                systemImage: simboloDaModalidade(metadados.formato)
                            )
                        }
                    }
                    .font(PapagaioTema.Tipo.legenda)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                }
                .padding(PapagaioTema.Espaco.largo)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // O fundo é desenhado fora do link, então só o texto e a capa
            // recebiam clique — o vazio entre eles não abria nada.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Conversa \(titulo). \(estado.descricao)")
        // Sem `minHeight` fixo: os 390pt anteriores deixavam ~80pt de área
        // morta no fim de todo cartão, e mais ainda nos de título curto.
        // `maxHeight: .infinity` iguala a altura de todos na mesma fileira.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cartaoPapagaio()
        .overlay(alignment: .topLeading) {
            botaoDeFavoritoDoCard
        }
        .overlay(alignment: .topTrailing) {
            menuDoCard
        }
        .zIndex(menuAberto ? 10 : 0)
        .onAppear(perform: sincronizarPreferenciasVisuais)
        .onChange(of: arquivo.id.rawValue) { _, _ in
            sincronizarPreferenciasVisuais()
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
                aoSalvar: salvarInformacoesDoCard
            )
        }
        .confirmationDialog("Mover para pasta", isPresented: $escolhendoPastaDestino) {
            ForEach(PreferenciasVisuaisDoArquivo.pastas(), id: \.self) { nome in
                Button(nome) {
                    moverParaPasta(nome)
                }
            }

            Button("Criar nova pasta…") {
                nomeDaPasta = ""
                criandoPastaParaMover = true
            }

            if pasta != nil {
                Button("Remover da pasta", role: .destructive) {
                    pasta = nil
                    PreferenciasVisuaisDoArquivo.definirPasta(nil, para: arquivo.id)
                    aoAlterarPreferenciasVisuais()
                }
            }

            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Escolha para qual pasta esta conversa deve ir.")
        }
        .alert("Criar pasta e mover", isPresented: $criandoPastaParaMover) {
            TextField("Nome da pasta", text: $nomeDaPasta)
            Button("Criar e mover") {
                let limpa = nomeDaPasta.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !limpa.isEmpty else { return }
                moverParaPasta(limpa)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Crie uma pasta nova e esta conversa será movida para ela.")
        }
        .overlay {
            if emOperacaoDeLixeira {
                ProgressView("Movendo para a lixeira…")
                    .font(.callout.weight(.medium))
                    .padding(PapagaioTema.Espaco.largo)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            }
        }
        .opacity(emOperacaoDeLixeira ? 0.72 : 1)
    }

    @ViewBuilder
    private var menuDoCard: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                if menuAberto {
                    aoFecharMenu()
                } else {
                    aoAlternarMenu()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(menuAberto ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .frame(width: 36, height: 36)
                    .background(PapagaioTema.superficie.opacity(0.92), in: Circle())
                    .overlay {
                        Circle().stroke(menuAberto ? PapagaioTema.destaque.opacity(0.45) : .clear, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(PapagaioTema.Espaco.curto)
            .accessibilityLabel("Ações de \(titulo)")

            if menuAberto {
                MenuDeArquivoAberto(
                    bloqueioDeEdicao: processando || naFila || emOperacaoDeLixeira,
                    bloqueioDeLixeira: emOperacaoDeLixeira,
                    aoEditarImagem: executarMenu(editarImagem),
                    aoRenomear: executarMenu(abrirEditorDeInformacoes),
                    aoMoverParaPasta: executarMenu(abrirMoverParaPasta),
                    aoCompartilhar: executarMenu(compartilhar),
                    aoDuplicar: executarMenu(aoDuplicar),
                    aoMoverParaLixeira: executarMenu(aoMoverParaLixeira)
                )
                .padding(.top, PapagaioTema.Espaco.pagina)
                .padding(.trailing, PapagaioTema.Espaco.curto)
                .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                .zIndex(2)
            }
        }
    }

    private var botaoDeFavoritoDoCard: some View {
        Button(action: alternarFavorito) {
            Image(systemName: favorito ? "star.fill" : "star")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(favorito ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                .frame(width: 36, height: 36)
                .background(PapagaioTema.superficie.opacity(0.92), in: Circle())
                .overlay {
                    Circle().stroke(favorito ? PapagaioTema.destaque.opacity(0.5) : PapagaioTema.borda.opacity(0.9), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .padding(PapagaioTema.Espaco.curto)
        .help(favorito ? "Desfavoritar" : "Favoritar")
        .accessibilityLabel(favorito ? "Desfavoritar conversa" : "Favoritar conversa")
    }

    private func executarMenu(_ acao: @escaping () -> Void) -> () -> Void {
        {
            aoFecharMenu()
            acao()
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

    private func salvarInformacoesDoCard() {
        let tituloLimpo = tituloEditado.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty else { return }

        let participantesLimpos = participantesEditados.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantidade = Int(participantesLimpos).map { max(1, $0) }
        let novosMetadados = MetadadosVisuaisDoArquivo(
            entrevistado: entrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDoEntrevistado: emailDoEntrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            entrevistadores: entrevistadoresEditados.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDosEntrevistadores: emailDosEntrevistadoresEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            descricao: descricaoEditada.trimmingCharacters(in: .whitespacesAndNewlines),
            formato: formatoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            participantes: quantidade
        )

        metadados = novosMetadados
        PreferenciasVisuaisDoArquivo.definirMetadados(novosMetadados, para: arquivo.id)
        aoAtualizarMetadados(tituloLimpo, dataEditada, TimeInterval.lendo(duracaoEditada) ?? arquivo.duracao)
        aoAlterarPreferenciasVisuais()
        editandoInformacoes = false
    }

    private func abrirMoverParaPasta() {
        let pastas = PreferenciasVisuaisDoArquivo.pastas()
        if pastas.isEmpty {
            nomeDaPasta = ""
            criandoPastaParaMover = true
        } else {
            escolhendoPastaDestino = true
        }
    }

    private func moverParaPasta(_ nome: String) {
        let limpa = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpa.isEmpty else { return }
        pasta = limpa
        PreferenciasVisuaisDoArquivo.definirPasta(limpa, para: arquivo.id)
        aoAlterarPreferenciasVisuais()
    }

    private func alternarFavorito() {
        withAnimation(.snappy(duration: 0.16)) {
            favorito.toggle()
        }
        PreferenciasVisuaisDoArquivo.definirFavorito(favorito, para: arquivo.id)
        aoAlterarPreferenciasVisuais()
    }

    private func sincronizarPreferenciasVisuais() {
        favorito = PreferenciasVisuaisDoArquivo.favorito(arquivo.id)
        pasta = PreferenciasVisuaisDoArquivo.pasta(arquivo.id)
        capaURL = PreferenciasVisuaisDoArquivo.capa(arquivo.id)
        metadados = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
    }

    private func editarImagem() {
        #if os(macOS)
        let painel = NSOpenPanel()
        painel.title = "Escolha uma imagem para a capa"
        painel.prompt = "Usar imagem"
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = false
        painel.allowedContentTypes = [.image]

        guard painel.runModal() == .OK,
              let url = painel.url,
              url.startAccessingSecurityScopedResource()
        else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try PreferenciasVisuaisDoArquivo.definirCapa(url, para: arquivo.id)
            capaURL = PreferenciasVisuaisDoArquivo.capa(arquivo.id)
            aoAlterarPreferenciasVisuais()
        } catch {
            capaURL = url
            aoAlterarPreferenciasVisuais()
        }
        #endif
    }

    private func compartilhar() {
        #if os(macOS)
        // Uma ação só: documento e áudio juntos, e no mesmo painel a opção de
        // salvar em pasta. O áudio cru sozinho não dizia nada a quem recebe.
        let itens: [Any]
        do {
            itens = [try DossieDaConversa.pacoteComAudio(arquivo: arquivo, audioPrincipal: urlDeAudio)]
        } catch {
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent(DossieDaConversa.nomeDeArquivo(para: arquivo))
            if (try? DossieDaConversa.gerar(arquivo: arquivo)
                .write(to: destino, atomically: true, encoding: .utf8)) != nil {
                itens = [destino]
            } else {
                itens = [DossieDaConversa.gerar(arquivo: arquivo)]
            }
        }

        let picker = NSSharingServicePicker(items: itens)
        let opcoes = OpcoesDeCompartilhamento(arquivos: itens.compactMap { $0 as? URL })
        delegadoDeCompartilhamento = opcoes
        picker.delegate = opcoes
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
        #endif
    }
}

struct MetadadoDoCard: View {
    let simbolo: String
    let rotulo: String
    let valor: String

    /// O rótulo era `caption2.bold` em MAIÚSCULA e o valor `caption` normal —
    /// ou seja, "ENTREVISTADO" pesava mais na página do que o nome da pessoa.
    /// Aqui o valor é que tem cor e peso de texto; o rótulo só orienta.
    var body: some View {
        Label {
            HStack(spacing: PapagaioTema.Espaco.minimo) {
                Text("\(rotulo):")
                    .font(PapagaioTema.Tipo.legenda)
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.8))

                Text(valor)
                    .font(PapagaioTema.Tipo.legenda.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } icon: {
            Image(systemName: simbolo)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
        }
    }
}

struct CapaDeConversa: View {
    let arquivo: Arquivo
    let capaURL: URL?

    private var matiz: Double {
        let soma = arquivo.id.rawValue.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(soma % 20) / 100
    }

    /// A decodificação em si mora em `PreferenciasVisuaisDoArquivo`, que a
    /// guarda em cache — aqui isto roda a cada avaliação de body.
    ///
    /// `capaURL` continua sendo quem responde "tem capa?": ausência não é
    /// cacheável, então perguntar ao cache num cartão sem capa seria um read de
    /// `UserDefaults` por body. Ela também é o que faz o SwiftUI redesenhar a
    /// capa quando o usuário troca a imagem.
    private var imagemDaCapa: NSImage? {
        guard capaURL != nil else { return nil }
        return PreferenciasVisuaisDoArquivo.imagemDaCapa(arquivo.id)
    }

    var body: some View {
        ZStack {
            if let imagem = imagemDaCapa {
                Image(nsImage: imagem)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        PapagaioTema.destaqueSuave,
                        PapagaioTema.destaque.opacity(0.40 + matiz)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(PapagaioTema.destaqueEscuro.opacity(0.62))
            }
        }
        // 88 em vez de 116: a capa é decorativa e idêntica em todos os cartões
        // sem imagem própria, então não merece um terço da altura útil.
        .frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Barra fina com o quanto falta, em linguagem de gente.
///
/// Existe porque importar e esperar sem nenhum sinal é a pior parte do fluxo:
/// a pessoa não sabe se o app travou, se falta um minuto ou dez. Uma
/// estimativa aproximada, dita como aproximada, informa mais que o silêncio.
struct BarraDeProgressoDoProcessamento: View {
    let inicio: Date
    let estimativa: TimeInterval

    var body: some View {
        // `TimelineView` porque o progresso é função do relógio, não de estado:
        // sem uma batida de fora, a barra ficaria congelada até a fase mudar —
        // e a fase muda duas vezes em vários minutos.
        TimelineView(.periodic(from: inicio, by: 1)) { contexto in
            corpo(agora: contexto.date)
        }
    }

    private func corpo(agora: Date) -> some View {
        let decorrido = agora.timeIntervalSince(inicio)
        // Satura em 95% enquanto o trabalho não termina: barra parada em 100%
        // com o app ainda pensando é pior que barra lenta.
        let fracao = min(0.95, max(0, decorrido / estimativa))
        let restante = max(0, estimativa - decorrido)

        return VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            GeometryReader { geometria in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PapagaioTema.superficieSuave)

                    Capsule()
                        .fill(PapagaioTema.destaque)
                        .frame(width: max(4, geometria.size.width * fracao))
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(Int((fracao * 100).rounded()))%")
                    .monospacedDigit()

                Spacer()

                Text(textoDoRestante(restante))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario)
        }
        .animation(.easeOut(duration: 0.3), value: fracao)
    }

    /// "Cerca de" na frente porque é estimativa, e abaixo de um minuto o número
    /// exato em segundos daria uma precisão que o cálculo não tem.
    private func textoDoRestante(_ restante: TimeInterval) -> String {
        let segundos = Int(restante.rounded())
        if segundos <= 0 { return "finalizando…" }
        if segundos < 60 { return "menos de 1 min" }
        let minutos = Int((restante / 60).rounded())
        return "cerca de \(minutos) min"
    }
}
