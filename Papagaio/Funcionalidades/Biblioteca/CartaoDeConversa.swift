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
    let fichaPendente: Bool
    let seloDeConclusaoRevelado: Bool
    let aoAbrirFicha: () -> Void
    let aoReprocessar: @MainActor @Sendable () -> Void
    let aoDiarizar: @MainActor @Sendable () -> Void
    let aoRenomear: (String) -> Void
    let aoAtualizarMetadados: (String, Date, TimeInterval) -> Void
    let aoDuplicar: @MainActor @Sendable () -> Void
    let urlDeAudio: URL
    let menuAberto: Bool
    let aoAlternarMenu: () -> Void
    let aoFecharMenu: @MainActor @Sendable () -> Void
    let aoAlterarPreferenciasVisuais: () -> Void
    let aoMoverParaLixeira: @MainActor @Sendable () -> Void
    let aoAbrirPasta: (String) -> Void

    /// Preferência da grade inteira. `@AppStorage` porque um inteiro em
    /// `UserDefaults` faz todos os cartões se redesenharem quando ela muda,
    /// sem carregar um objeto observável por todo o caminho até aqui.
    @AppStorage(CamposDoCartao.chave) private var camposBrutos = CamposDoCartao.padrao.rawValue
    @AppStorage(ModeloDeCartao.chave) private var modeloBruto = ModeloDeCartao.padrao.rawValue

    @State private var editandoInformacoes = false
    @State private var mostrandoParticipantes = false
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
    @State private var corDaFaixaEscolhida: Color?
    @State private var faixaSemCor: Bool
    @State private var pairandoNaEstrela = false
    @State private var pairandoNaPasta = false
    @State private var pairandoNoMenu = false
    @State private var pairandoNaInfoDeData = false
    @State private var bannerURL: URL?
    @State private var editandoAparencia = false
    @State private var ajusteDaImagem: AjusteDeImagem = .preencher
    @State private var metadados: MetadadosVisuaisDoArquivo

    init(
        arquivo: Arquivo,
        estado: EstadoDoArquivo,
        progresso: (inicio: Date, estimativa: TimeInterval)?,
        importado: Bool,
        processando: Bool,
        naFila: Bool,
        emOperacaoDeLixeira: Bool,
        fichaPendente: Bool,
        seloDeConclusaoRevelado: Bool,
        aoAbrirFicha: @escaping () -> Void,
        aoReprocessar: @escaping @MainActor @Sendable () -> Void,
        aoDiarizar: @escaping @MainActor @Sendable () -> Void,
        aoRenomear: @escaping (String) -> Void,
        aoAtualizarMetadados: @escaping (String, Date, TimeInterval) -> Void,
        aoDuplicar: @escaping @MainActor @Sendable () -> Void,
        urlDeAudio: URL,
        menuAberto: Bool,
        aoAlternarMenu: @escaping () -> Void,
        aoFecharMenu: @escaping @MainActor @Sendable () -> Void,
        aoAlterarPreferenciasVisuais: @escaping () -> Void,
        aoMoverParaLixeira: @escaping @MainActor @Sendable () -> Void,
        aoAbrirPasta: @escaping (String) -> Void
    ) {
        self.arquivo = arquivo
        self.estado = estado
        self.progresso = progresso
        self.importado = importado
        self.processando = processando
        self.naFila = naFila
        self.emOperacaoDeLixeira = emOperacaoDeLixeira
        self.fichaPendente = fichaPendente
        self.seloDeConclusaoRevelado = seloDeConclusaoRevelado
        self.aoAbrirFicha = aoAbrirFicha
        self.aoReprocessar = aoReprocessar
        self.aoDiarizar = aoDiarizar
        self.aoRenomear = aoRenomear
        self.aoAtualizarMetadados = aoAtualizarMetadados
        self.aoDuplicar = aoDuplicar
        self.urlDeAudio = urlDeAudio
        self.menuAberto = menuAberto
        self.aoAlternarMenu = aoAlternarMenu
        self.aoFecharMenu = aoFecharMenu
        self.aoAlterarPreferenciasVisuais = aoAlterarPreferenciasVisuais
        self.aoMoverParaLixeira = aoMoverParaLixeira
        self.aoAbrirPasta = aoAbrirPasta
        _favorito = State(initialValue: PreferenciasVisuaisDoArquivo.favorito(arquivo.id))
        _pasta = State(initialValue: PreferenciasVisuaisDoArquivo.pasta(arquivo.id))
        _corDaFaixaEscolhida = State(initialValue: AparenciaDoCartao.cor(arquivo.id))
        _faixaSemCor = State(initialValue: AparenciaDoCartao.semCor(arquivo.id))
        _bannerURL = State(initialValue: AparenciaDoCartao.banner(arquivo.id))
        _ajusteDaImagem = State(initialValue: AparenciaDoCartao.ajuste(arquivo.id))
        _metadados = State(initialValue: PreferenciasVisuaisDoArquivo.metadados(arquivo.id))
    }

    private var titulo: String { arquivo.resumo?.titulo ?? arquivo.titulo }

/// Arquivos gravados antes da diarização existir têm palavras com
    /// timestamp, mas sem falante acústico: dá para distingui-los sem
    /// re-transcrever. Sem palavras não há o que alinhar.
    private var podeDiarizar: Bool {
        arquivo.trechos.contains { !$0.palavras.isEmpty }
    }

    /// Altura de todo cartão da biblioteca, independente dos campos ligados.
    ///
    /// 264 e não os 318 da grade de Mídia: sem a faixa de capa ocupando 88pt no
    /// topo, o conteúdo cabe folgado em menos altura — e o que sobrava virava
    /// vazio no meio do cartão. Mais achatado, entra uma fileira a mais na tela
    /// sem rolagem.
    static let alturaDoCartao: CGFloat = 336

    // As três medidas saem das proporções do cartão do Classroom, medidas na
    // captura: faixa 36% da altura, rodapé 16%, círculo 26% — daí 106, 48 e 78
    // num cartão de 300.

    /// A faixa de atalhos no pé do cartão.
    static let alturaDaBarra: CGFloat = 48

    /// A faixa colorida do topo.
    static let alturaDaFaixa: CGFloat = 124

    /// A largura da tarja lateral do modelo compacto, no seu estado mais
    /// grosso (em processamento). Serve de recuo para o que não pode ficar
    /// atrás dela, como a linha sob o cabeçalho.
    static let larguraMaximaDaTarja: CGFloat = 16

    /// A altura reservada para o título no cabeçalho do modelo compacto —
    /// duas linhas a 25pt cada, sempre a mesma. Título mais curto que isso
    /// sobra em branco; mais longo corta com reticências. As duas fixas são
    /// o que garante que a linha divisória caia sempre na mesma altura,
    /// cartão após cartão — variável, ela pulava de lugar conforme o título
    /// e a descrição de cada conversa.
    static let alturaDoTituloCompacto: CGFloat = 50

    /// A altura reservada para a descrição no cabeçalho do modelo compacto —
    /// duas linhas a 20pt cada, sempre a mesma, tenha a descrição de fato
    /// duas linhas, uma linha só, ou esteja em branco.
    static let alturaDaDescricaoCompacta: CGFloat = 40

    private var campos: CamposDoCartao {
        get { CamposDoCartao(rawValue: camposBrutos) }
        nonmutating set { camposBrutos = newValue.rawValue }
    }

    private var modelo: ModeloDeCartao {
        ModeloDeCartao(rawValue: modeloBruto) ?? .padrao
    }

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
                rotuloDeEntrevistadores(nomesDePessoas(metadados.entrevistadores)).localized,
                entrevistadores
            ))
        }
        if !entrevistado.isEmpty {
            linhas.append((
                "person",
                rotuloDeEntrevistados(nomesDePessoas(metadados.entrevistado)).localized,
                entrevistado
            ))
        }
        return linhas
    }

    private func simboloDaModalidade(_ formato: String) -> String {
        switch formato {
        case "Presencial": "mappin.and.ellipse"
        case "Online": "video"
        default: "questionmark.circle"
        }
    }

    /// Zero quando ninguém foi informado e a transcrição não separou falantes.
    ///
    /// O piso em 1 dizia "1 participante" para conversa nenhuma preenchida —
    /// um dado inventado, e que a pessoa não tem como corrigir, já que o número
    /// é calculado. Mesma regra da ficha, para as duas telas não discordarem.
    private var participantes: Int {
        metadados.participantes ?? participantesDetectados
    }

    /// A pasta, quando há uma e o campo está ligado na personalização.
    private var pastaVisivel: String? {
        campos.contains(.pasta) ? pasta : nil
    }

    private var participantesDetectados: Int {
        Set(arquivo.trechos.compactMap(\.speaker).filter { !$0.isEmpty }).count
    }

    var body: some View {
        NavigationLink(value: arquivo.id.rawValue) {
            VStack(alignment: .leading, spacing: 0) {
                if modelo == .comCapa {
                    faixaDoTopo
                } else {
                    cabecalhoCompacto

                    // No modelo com capa a própria faixa já separa o título
                    // dos dados abaixo; sem faixa, título e descrição
                    // encostavam direto nas linhas de data/duração/
                    // participantes, sem nenhuma fronteira entre as duas
                    // partes do cartão. Mesma linha do rodapé, ponta a
                    // ponta — sem recuo nenhum, como a linha de baixo.
                    // `maxWidth: .infinity` explícito: sem ele a régua fica
                    // do tamanho do título, que é mais estreito que o cartão.
                    //
                    // Recuo à esquerda do tamanho máximo da tarja, e só
                    // enquanto ela está em processamento: é só nesse estado
                    // que ela sobe com um trecho de fundo translúcido
                    // (opacity 0.22), e sem o recuo a linha aparecia
                    // atravessando esse trecho por trás dela. Parada, a tarja
                    // é fina e opaca — a linha pode ir ponta a ponta.
                    Rectangle()
                        .fill(progresso != nil ? PapagaioTema.borda : corDeAcento.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .padding(.leading, progresso != nil ? Self.larguraMaximaDaTarja : 0)
                }

                // Espaçamento elástico entre as linhas: o corpo tem altura de
                // sobra e três dados só; apertados no topo, deixavam metade do
                // cartão em branco e a leitura ficava concentrada num canto.
                // Com `spacing: 0` e um `vao` entre as linhas, a sobra vai para
                // os intervalos — as linhas se espalham pelo corpo em vez de se
                // empilharem no alto dele.
                VStack(alignment: .leading, spacing: 0) {
                    // O selo só aparece quando há algo a dizer. "Transcrito e
                    // resumido" é o estado de repouso de toda conversa madura:
                    // estaria em quase todos os cartões, o tempo todo, gastando
                    // uma linha para informar o esperado. Fila, processamento e
                    // falha são exceções, e mudam o que dá para fazer ali.
                    //
                    // No modelo compacto o selo desceu para o rodapé, ao lado
                    // da estrela — aqui em cima ele brigava por linha com os
                    // outros dados. O modelo com capa continua mostrando aqui.
                    if estado != .transcritoEResumido, modelo == .comCapa {
                        HStack(spacing: PapagaioTema.Espaco.curto) {
                            SeloDeStatus(
                                texto: estado.descricao,
                                simbolo: estado.simbolo,
                                estilo: estado.estilo
                            )
                        }
                        vao
                    }

                    // No modelo compacto o andamento já aparece na tarja
                    // lateral, subindo de baixo pra cima — repetir numa
                    // barra horizontal aqui seria dizer a mesma coisa duas
                    // vezes no mesmo cartão.
                    if let progresso, modelo == .comCapa {
                        BarraDeProgressoDoProcessamento(
                            inicio: progresso.inicio,
                            estimativa: progresso.estimativa
                        )
                        vao
                    }

                    // Uma linha por dado, na ordem em que se pergunta: quando
                    // foi, quanto durou, quem estava, de onde veio, como foi.
                    // Enfileirados, dependiam da largura da janela para saber
                    // onde quebravam — e o cartão tem altura de sobra.
                    // Participantes primeiro: é a resposta a "com quem foi
                    // essa conversa", a pergunta mais comum ao bater o olho
                    // na grade — antes de quando foi ou quanto durou.
                    if campos.contains(.participantes) {
                        botaoDeParticipantes
                        vao
                    }

                    if campos.contains(.data) {
                        HStack(spacing: PapagaioTema.Espaco.curto) {
                            linhaDoCorpo("calendar", DataDigitada.textoComHora(de: arquivo.criadoEm))
                            botaoInformacoesDeData
                        }
                        vao
                    }

                    if campos.contains(.duracao) {
                        linhaDoCorpo("clock", arquivo.duracao.comoDuracaoPorExtenso)
                    }

                    // Uma folga fixa no fim, e não um `Spacer` elástico.
                    //
                    // O elástico engolia toda a sobra de altura e empurrava as
                    // três linhas para o topo: elas ficavam coladas umas nas
                    // outras com um vazio grande embaixo. Agora a sobra é
                    // dividida entre as linhas pelos `vao`, e aqui fica só o
                    // respiro que o rótulo dos participantes precisa para
                    // aparecer sob os rostos sem ser cortado.
                    Spacer(minLength: 0)
                        .frame(height: PapagaioTema.Espaco.medio)
                }
                .padding(PapagaioTema.Espaco.largo)
                // No modelo compacto a tarja de cor mora na borda esquerda do
                // próprio cartão — sem este respiro extra o texto encostaria
                // nela. Mesmo recuo do título, para as linhas começarem
                // alinhadas com ele — o total (largo + medio = 28pt) já cobre
                // com folga a tarja mais larga (16pt) do estado em
                // processamento.
                .padding(.leading, modelo == .compacto ? PapagaioTema.Espaco.medio : 0)
                // A barra de atalhos é uma camada sobre o rodapé; sem esta
                // reserva o último dado passaria por baixo dela.
                .padding(.bottom, Self.alturaDaBarra)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Trava de segurança: a altura do cartão é fixa e o conteúdo
                // varia com o estado e com a personalização. Sem o corte, um
                // caso que não couber invade a barra de atalhos e o cartão
                // aparece com dois textos sobrepostos — foi o que acontecia
                // com o selo de progresso somado às linhas de lacuna.
                .clipped()
            }
            // O fundo é desenhado fora do link, então só o texto e a capa
            // recebiam clique — o vazio entre eles não abria nada.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "Conversa %@. %@".localized, titulo, estado.descricao))
        // Altura fixa, e não "o que o conteúdo pedir".
        //
        // Com os campos configuráveis, deixar a altura seguir o conteúdo fazia
        // a grade inteira mudar de proporção a cada interruptor: desligando
        // tudo, os cartões viravam faixas de 90pt e a primeira fileira ficava
        // alta sozinha, presa ao cartão de nova conversa. Fixando, a grade é a
        // mesma sempre — o cartão perde conteúdo por dentro, não muda de forma.
        //
        // 318 é a mesma altura dos cartões da aba Mídia, então as duas grades
        // do app têm o mesmo módulo.
        .frame(
            maxWidth: .infinity,
            minHeight: Self.alturaDoCartao,
            maxHeight: Self.alturaDoCartao,
            alignment: .top
        )
        // As duas camadas vêm **depois** do `frame`, e não antes.
        //
        // Aplicadas sobre o `NavigationLink`, elas se alinhavam à altura
        // natural do conteúdo — que é menor que a do cartão — e a barra de
        // atalhos aparecia no meio, flutuando onde o texto acabava.
        .overlay(alignment: .bottom) { barraDeAtalhos }
        // No modelo compacto, o selo de status sai do rodapé e vai para o
        // centro do cartão enquanto processa — é a informação mais
        // importante ali naquele momento, e no canto ela dividia atenção com
        // três ícones pequenos. No centro, sozinha, ela é a primeira coisa
        // que se vê.
        //
        // O véu escurece o título e os metadados atrás do selo — sem ele o
        // selo competia com o próprio texto do cartão pela mesma atenção.
        // Só até o rodapé: os ícones de favoritar/pasta/menu continuam
        // visíveis e clicáveis por baixo, sem véu nenhum em cima deles.
        //
        // O véu ocupa o cartão **inteiro** (`.frame(maxWidth/maxHeight:
        // .infinity)`), e não só o tamanho do selo — encolhido ao conteúdo,
        // ele virava uma caixa escura de cantos retos colada atrás do selo,
        // em vez de esmaecer o cartão ao redor dele.
        //
        // Nada aqui recebe toque, exceto o botão "Cancelar": sem
        // `allowsHitTesting(false)` em cada peça, elas ficariam na frente do
        // `NavigationLink` e engoliriam o clique que deveria abrir a
        // conversa (fora do botão) ou cancelar (dentro dele).
        .overlay {
            if modelo == .compacto, estado != .transcritoEResumido {
                ZStack {
                    PapagaioTema.fundo.opacity(0.6)
                        .allowsHitTesting(false)

                    VStack(spacing: PapagaioTema.Espaco.medio) {
                        SeloDeStatus(
                            texto: estado.descricao,
                            simbolo: estado.simbolo,
                            estilo: estado.estilo
                        )
                        .allowsHitTesting(false)

                        // Só aparece enquanto há de fato algo para
                        // interromper — uma conversa que falhou já parou
                        // sozinha, não faz sentido "cancelar" o que não está
                        // mais rodando.
                        if estado.ocupado {
                            botaoCancelarProcessamento
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, Self.alturaDaBarra)
            }
        }
        .overlay {
            if fichaPendente, seloDeConclusaoRevelado {
                ZStack {
                    PapagaioTema.fundo.opacity(0.6)
                        .allowsHitTesting(false)

                    VStack(spacing: PapagaioTema.Espaco.medio) {
                        SeloDeStatus(
                            texto: "Concluído".localized,
                            simbolo: "checkmark.circle.fill",
                            estilo: .sucesso
                        )
                        .allowsHitTesting(false)

                        botaoAbrirFicha
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, Self.alturaDaBarra)
            }
        }
        // A tarja do modelo compacto: sem faixa de capa, é ela que carrega a
        // cor da conversa/pasta — o mesmo papel que a faixa tinha no modelo
        // com capa, só que reduzido a uma lateral. Encostada nos quatro
        // cantos do cartão, do topo à base — o `.clipShape` logo abaixo é
        // quem arredonda as pontas dela junto com o resto do cartão.
        .overlay(alignment: .leading) {
            if modelo == .compacto {
                tarjaLateral
            }
        }
        // Recorta antes da moldura: sem isto a faixa colorida sai por cima dos
        // cantos arredondados e o cartão fica com dois cantos vivos no topo.
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        // A moldura na cor do cartão, e não no bege do tema. Bem mais fraca que
        // os ícones do rodapé: contorno é o elemento mais periférico do cartão,
        // e na intensidade dos acentos ele viraria um retângulo colorido em
        // volta de tudo — a grade inteira acabaria listrada.
        //
        // Em processamento, a moldura volta a ser neutra: quem já é o sinal
        // colorido ali é a tarja, subindo. Com a borda também colorida, o
        // cartão inteiro parecia tingido — mais parecido com um cartão de
        // cor própria do que com o painel neutro (ex.: "Biblioteca de
        // Conversas") que ele deveria lembrar fora da tarja.
        .cartaoPapagaio(borda: progresso != nil ? PapagaioTema.borda : corDeAcento.opacity(0.35))
        .onAppear(perform: sincronizarPreferenciasVisuais)
        .onChange(of: arquivo.id.rawValue) { _, _ in
            sincronizarPreferenciasVisuais()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferenciasVisuaisDoArquivo.metadadosDidChange)) { notification in
            if let uuid = notification.object as? UUID, uuid == arquivo.id.rawValue {
                sincronizarPreferenciasVisuais()
            }
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
                importadoEm: arquivo.importadoEm,
                aoCancelar: { editandoInformacoes = false },
                aoSalvar: salvarInformacoesDoCard
            )
        }
        .alert("Criar pasta e mover".localized, isPresented: $criandoPastaParaMover) {
            TextField("Nome da pasta".localized, text: $nomeDaPasta)
            Button("Criar e mover".localized) {
                let limpa = nomeDaPasta.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !limpa.isEmpty else { return }
                moverParaPasta(limpa)
            }
            Button("Cancelar".localized, role: .cancel) {}
        } message: {
            Text("Crie uma pasta nova e esta conversa será movida para ela.".localized)
        }
        .overlay {
            if emOperacaoDeLixeira {
                ProgressView("Movendo para a lixeira…".localized)
                    .font(.callout.weight(.medium))
                    .padding(PapagaioTema.Espaco.largo)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            }
        }
        .opacity(emOperacaoDeLixeira ? 0.72 : 1)
    }

    /// A faixa colorida do topo, no modelo do Classroom.
    ///
    /// Três linhas, em ordem de importância decrescente: o título, a referência
    /// temporal e a pessoa. É o mesmo esqueleto de "DSG1990 / 2026.2 / Guilherme
    /// Xavier" — e funciona pelo mesmo motivo: as três respondem "que conversa é
    /// esta, de quando, com quem" antes de qualquer detalhe.
    ///
    /// A cor vem da pasta. Conversas do mesmo projeto ficam da mesma cor, e a
    /// grade se agrupa visualmente sem precisar de rótulo.
    private var faixaDoTopo: some View {
        // Título no alto, e as linhas de apoio empurradas para a base da
            // faixa — é o que dá ao cartão do Classroom aquele bloco de texto
            // ancorado embaixo, e não centralizado.
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                // Sem reticências: em vez de cortar o nome da conversa, o
                // título quebra em duas linhas e encolhe até caber. Título
                // truncado obriga a abrir a conversa para saber qual é —
                // exatamente o que a grade existe para evitar.
                Text(titulo)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(corDoTextoDaFaixa)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(titulo)

                Spacer(minLength: PapagaioTema.Espaco.medio)

                // Só título e descrição na faixa. Os nomes desceram para o
                // corpo, atrás do contador de participantes: eram quatro linhas
                // de texto branco disputando a mesma área, e nomes próprios
                // longos empurravam tudo para fora.
                if campos.contains(.descricao), !metadados.descricao.isEmpty {
                    Text(metadados.descricao)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(corDoTextoDaFaixa)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .padding(.vertical, PapagaioTema.Espaco.medio)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.alturaDaFaixa,
                maxHeight: Self.alturaDaFaixa,
                alignment: .topLeading
            )
            // A imagem entra como **fundo**, e não como irmã do texto num
            // `ZStack`.
            //
            // Com `scaledToFill` dentro do ZStack, a foto passa a ser o maior
            // filho e define o tamanho da pilha: o bloco de texto ia parar no
            // centro dessa área enorme e sumia no recorte. Como fundo, ela não
            // participa do layout — o texto fica sempre sobre a faixa.
            .background(fundoDaFaixa)
            .clipped()
    }

    /// O cabeçalho do modelo compacto: só o título e a descrição, sem faixa
    /// nem imagem.
    ///
    /// A cor da conversa continua presente — só que na tarja lateral
    /// (`corDeAcento`, aplicada como `overlay` no cartão inteiro), não mais
    /// atrás do título. O título aqui fica na cor de texto do tema, e não
    /// numa cor calculada para contraste sobre uma faixa que deixou de existir.
    private var cabecalhoCompacto: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text(titulo)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(PapagaioTema.texto)
                // Duas linhas, com reticências passando disso — não mais
                // altura livre. Título comprido empurrava a linha divisória
                // (e tudo abaixo dela) para baixo, cartão a cartão numa
                // altura diferente; a `.help(titulo)` continua mostrando o
                // título inteiro ao passar o mouse, para quem precisar ler.
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: Self.alturaDoTituloCompacto, alignment: .top)
                .help(titulo)

            // A mesma descrição da faixa do modelo com capa — só que aqui, sem
            // faixa nenhuma, ela é só mais uma linha de texto, na cor
            // secundária do tema.
            //
            // Altura fixa de duas linhas, sempre reservada quando o campo
            // está ligado — tenha a conversa descrição, uma linha só, ou
            // nenhuma. Sem essa reserva, a linha divisória logo abaixo caía
            // numa altura diferente em cada cartão, conforme o tamanho da
            // descrição de cada um: uma bagunça na grade. Passando de duas
            // linhas, corta com reticências — não empurra a divisória mais
            // ainda.
            if campos.contains(.descricao) {
                Text(metadados.descricao)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: Self.alturaDaDescricaoCompacta, alignment: .top)
            }
        }
        // Recuo maior da esquerda: a tarja de cor mora bem na borda, e rente
        // a ela o título ficava com menos respiro que qualquer outra linha
        // do cartão.
        .padding(.leading, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.medio)
        .padding(.trailing, PapagaioTema.Espaco.largo)
        .padding(.top, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.minimo)
        .padding(.bottom, PapagaioTema.Espaco.medio)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A tarja lateral do modelo compacto — e o que ela mostra enquanto a
    /// conversa está sendo transcrita ou resumida.
    ///
    /// Parada, ela só diz a cor da conversa. Com o cartão em processamento,
    /// ela também é onde o andamento aparece: em vez de crescer da esquerda
    /// pra direita como a barra horizontal de outros lugares do app, aqui
    /// ela preenche de baixo pra cima, na própria faixa que já existe — sem
    /// disputar espaço com o título ou os metadados do corpo.
    @ViewBuilder
    private var tarjaLateral: some View {
        if let progresso {
            TarjaDeProgressoDoCartao(
                cor: corDaTarjaLateral,
                inicio: progresso.inicio,
                estimativa: progresso.estimativa
            )
        } else if naFila {
            // Ainda não começou: a tarja fica visível, mas apagada — a cor
            // plena é reservada para quem já está em andamento ou pronto.
            Rectangle()
                .fill(corDaTarjaLateral.opacity(0.35))
                .frame(width: 4)
        } else {
            Rectangle()
                .fill(corDaTarjaLateral)
                .frame(width: 4)
        }
    }

    /// O jeito de desistir de uma gravação enquanto ela ainda está sendo
    /// transcrita ou resumida.
    ///
    /// Antes disso a única saída era abrir o menu "..." e reconhecer "Mover
    /// para Lixeira" como também servindo para cancelar — nada dizia isso.
    /// Aqui a ação certa aparece no centro do cartão, no momento exato em
    /// que a pergunta "dá pra parar isso?" surge, com o nome que responde a
    /// ela. É a mesma ação de sempre (`aoMoverParaLixeira`, que já cancela o
    /// `Task` em andamento antes de mover para a lixeira) — só nomeada para
    /// quem está processando, e não para quem já processou.
    ///
    /// `highPriorityGesture`, e não `Button`: este botão mora dentro do
    /// `NavigationLink` do cartão (é um overlay sobre ele), e um botão comum
    /// aninhado ali perderia o toque para o link — a conversa abriria em vez
    /// de cancelar. Mesmo truque de `botaoDeParticipantes`.
    private var botaoCancelarProcessamento: some View {
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Cancelar".localized)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(PapagaioTema.perigo)
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .padding(.vertical, PapagaioTema.Espaco.curto)
        .background(PapagaioTema.superficie, in: Capsule())
        .overlay {
            Capsule().stroke(PapagaioTema.perigo.opacity(0.4), lineWidth: 1)
        }
        .contentShape(Capsule())
        .highPriorityGesture(TapGesture().onEnded(aoMoverParaLixeira))
        .help("Cancelar o processamento e mover para a lixeira".localized)
    }

    /// O "i" ao lado da data, na cor do cartão (a mesma da tarja) — mesma
    /// lógica de datas que já aparece na lixeira, só que aqui, aberta.
    ///
    /// Sempre visível, e não só em arquivos importados: mesmo numa gravação
    /// normal ele confirma "gravado em" com hora, que a linha de fora só
    /// mostra até o minuto. Importado, ganha uma segunda linha com a data
    /// real da importação — a mesma distinção que já existe no cartão da
    /// lixeira, só que aqui antes de a conversa ser apagada.
    ///
    /// `onHover`, como o `BotaoDeAjudaPapagaio`: não precisa de clique para
    /// abrir, e não disputa o toque com o `NavigationLink` do cartão — só um
    /// clique dispararia os dois ao mesmo tempo.
    private var botaoInformacoesDeData: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(corDeAcento.opacity(pairandoNaInfoDeData ? 1 : 0.65))
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .onHover { pairandoNaInfoDeData = $0 }
            .popover(isPresented: $pairandoNaInfoDeData, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    colunaDeInformacaoDeData(
                        rotulo: "Gravado em".localized,
                        valor: DataDigitada.textoComHora(de: arquivo.criadoEm)
                    )
                    if let importadoEm = arquivo.importadoEm {
                        colunaDeInformacaoDeData(
                            rotulo: "Importado em".localized,
                            valor: DataDigitada.textoComHora(de: importadoEm)
                        )
                    }
                }
                .padding(PapagaioTema.Espaco.largo)
                .frame(width: 240, alignment: .leading)
            }
            .accessibilityLabel("Datas da conversa".localized)
            .help(
                importado && arquivo.importadoEm != nil
                    ? String(format: "Gravado em %@ · Importado em %@".localized, DataDigitada.texto(de: arquivo.criadoEm), DataDigitada.texto(de: arquivo.importadoEm!))
                    : String(format: "Gravado em %@".localized, DataDigitada.texto(de: arquivo.criadoEm))
            )
    }

    private func colunaDeInformacaoDeData(rotulo: String, valor: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rotulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(corDeAcento)
                .textCase(.uppercase)
            Text(valor)
                .font(.callout)
                .foregroundStyle(PapagaioTema.texto)
        }
    }

    /// Ícone e texto com a mesma largura de ícone em todas as linhas.
    ///
    /// `Label` deixava cada linha com um recuo diferente, porque o glifo do
    /// calendário e o do relógio não têm a mesma largura — e três linhas
    /// levemente desalinhadas leem como descuido.
    private func linhaDoCorpo(_ simbolo: String, _ texto: String) -> some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
                .font(.system(size: 16))
                .frame(width: 20, alignment: .leading)

            Text(texto)
                // 16pt: o corpo do cartão tem três linhas e espaço de sobra —
                // 14 era tamanho de nota de rodapé para o conteúdo principal.
                .font(.system(size: 16))
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
        }
        .foregroundStyle(PapagaioTema.textoSecundario)
    }

    private var botaoAbrirFicha: some View {
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Clique para ver a conversa".localized)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(PapagaioTema.sucesso)
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .padding(.vertical, PapagaioTema.Espaco.curto)
        .background(PapagaioTema.superficie, in: Capsule())
        .overlay {
            Capsule().stroke(PapagaioTema.sucesso.opacity(0.4), lineWidth: 1)
        }
        .contentShape(Capsule())
        .highPriorityGesture(TapGesture().onEnded(aoAbrirFicha))
        .help("Ver a conversa".localized)
    }

    /// Os participantes, e o clique que abre a ficha com os nomes.
    ///
    /// O ícone tem a mesma largura fixa das linhas de data e duração, e o
    /// bloco é alinhado ao topo: com os rostos em 30pt e o texto em 16, o
    /// alinhamento central deslocava o ícone para baixo e a coluna da esquerda
    /// deixava de bater com as outras duas linhas.
    @ViewBuilder
    private var botaoDeParticipantes: some View {
        if mostraParticipantes {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                HStack(spacing: 3) {
                    Image(systemName: "person.2")
                        .font(.system(size: 16))
                        .frame(width: 20, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.top, 5)
                // A ficha nasce **no chevron**, e não na linha inteira.
                //
                // Ancorada na linha, ela saía do meio de um bloco que pode ter
                // quatro rostos de largura, e aparecia longe do que foi clicado
                // — com a seta apontando para o vazio entre dois avatares.
                .popover(isPresented: $mostrandoParticipantes, arrowEdge: .bottom) {
                    fichaDoCartao
                }

                if nomesDosParticipantes.isEmpty {
                    // Ninguém nomeado na ficha, mas a transcrição separou vozes.
                    Text(participantes == 1 ? "1 participante".localized : String(format: "%d participantes".localized, participantes))
                        .font(.system(size: 16))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 3)
                } else {
                    PilhaDeParticipantes(nomes: nomesDosParticipantes)
                        .padding(.leading, PapagaioTema.Espaco.minimo)
                }
            }
            .foregroundStyle(PapagaioTema.textoSecundario)
            .contentShape(Rectangle())
            // `highPriorityGesture`, e não um `Button`: esta linha mora dentro
            // do `NavigationLink` do cartão, e um botão aninhado ali perde o
            // clique para o link — a conversa abriria em vez do popover.
            .highPriorityGesture(TapGesture().onEnded { mostrandoParticipantes = true })
            .help("Ver quem participou".localized)
        } else if campos.contains(.lacunas) && !emProcessamento {
            linhaDoCorpo("person.badge.plus", "Participantes não informados".localized)
        }
    }

    /// O intervalo entre duas linhas do corpo.
    ///
    /// Tem um piso — as linhas nunca encostam — e cresce até um teto quando há
    /// altura sobrando. O teto existe porque sem ele, num cartão com um campo
    /// só ligado, o intervalo viraria metade do cartão e a linha solitária
    /// flutuaria no meio do nada.
    private var vao: some View {
        Spacer(minLength: PapagaioTema.Espaco.medio)
            .frame(maxHeight: 34)
    }

    /// O cartão está ocupado: fila, transcrição ou resumo em andamento.
    ///
    /// Nesse estado o selo e a barra de progresso ocupam duas linhas que não
    /// existem em repouso, e a altura do cartão é fixa — então as linhas de
    /// lacuna, que só dizem o que **falta**, saem de cena. Elas são o conteúdo
    /// mais dispensável do cartão justamente agora: quem ainda está
    /// transcrevendo não tem como ter informado participante nenhum.
    private var emProcessamento: Bool {
        processando || naFila || progresso != nil
    }

    /// Só mostra a linha quando ela diz alguma coisa.
    ///
    /// "1 participante" sem nome nenhum era ruído: toda gravação tem ao menos
    /// uma voz, então o número não distinguia uma conversa da outra, e quem
    /// clicava para ver quem era encontrava a ficha vazia — a linha prometia
    /// uma informação que não existia. Com dois ou mais o número volta a
    /// significar algo, mesmo sem nomes: diz que houve conversa, e não monólogo.
    private var mostraParticipantes: Bool {
        !nomesDosParticipantes.isEmpty || participantes > 1
    }

    /// A mesma ficha das outras telas, em miniatura.
    ///
    /// Quem participou, de onde veio o áudio e como a conversa aconteceu são
    /// dados de contexto: você olha uma vez ao abrir a conversa e não de novo.
    /// Na face do cartão gastavam três linhas em todos os cartões da grade;
    /// aqui ficam a um clique, agrupados como na ficha da tela de detalhe.
    private var fichaDoCartao: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            grupoDePessoas(
                rotuloDeEntrevistadores(nomesDePessoas(metadados.entrevistadores)).localized,
                nomesDePessoas(metadados.entrevistadores)
            )
            grupoDePessoas(
                rotuloDeEntrevistados(nomesDePessoas(metadados.entrevistado)).localized,
                nomesDePessoas(metadados.entrevistado)
            )

            if pessoasDoCard.isEmpty {
                Text("Ninguém informado na ficha.".localized)
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(width: 280, alignment: .leading)
    }

    /// Cada pessoa numa linha, com o rosto ao lado do nome.
    ///
    /// Nome corrido separado por vírgula obrigava a ler tudo para achar
    /// alguém. Em linhas, com a foto à esquerda, encontra-se pelo rosto.
    @ViewBuilder
    private func grupoDePessoas(_ rotulo: String, _ nomes: [String]) -> some View {
        if !nomes.isEmpty {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text(rotulo)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .textCase(.uppercase)

                ForEach(Array(nomes.enumerated()), id: \.offset) { _, nome in
                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        AvatarDePessoa(nome: nome, diametro: 32)

                        Text(nome)
                            .font(.callout)
                            .foregroundStyle(PapagaioTema.texto)
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    }
                }
            }
        }
    }

    /// Entrevistadores primeiro, entrevistados depois — a mesma ordem da ficha.
    private var nomesDosParticipantes: [String] {
        nomesDePessoas(metadados.entrevistadores) + nomesDePessoas(metadados.entrevistado)
    }

    private func textoDePessoas(_ bruto: String) -> String? {
        let lista = listaDePessoas(bruto)
        return lista.isEmpty ? nil : lista
    }

    private func colunaDePessoas(rotulo: String, valor: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rotulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .textCase(.uppercase)
            Text(valor)
                .font(.callout)
                .foregroundStyle(PapagaioTema.texto)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var fundoDaFaixa: some View {
        ZStack {
            if let imagem = imagemDaFaixa {
                // Em "ajustar", a cor da faixa entra atrás e preenche as sobras —
                // uma foto retrato numa faixa deitada deixaria duas tarjas vazias.
                ImagemDeFundo(imagem: imagem, ajuste: ajusteDaImagem, corDeFundo: corDaFaixa)
            } else {
                corDaFaixa
            }

            TexturaDaFaixa()
        }
    }

    /// `bannerURL` responde "tem imagem?" sem tocar o cache — ausência não é
    /// cacheável — e é o que faz o SwiftUI redesenhar quando a imagem troca.
    private var imagemDaFaixa: NSImage? {
        guard bannerURL != nil else { return nil }
        return AparenciaDoCartao.imagem(arquivo.id)
    }

    /// A cor da pasta é o padrão; a escolha manual vence quando existe.
    private var corPadraoDaFaixa: Color {
        guard let pasta else { return PapagaioTema.destaque }
        return AparenciaDasPastas.corResolvida(de: pasta)
    }

    /// Sem cor vence tudo: é uma escolha explícita, e não a ausência de uma.
    ///
    /// Nem toda conversa quer uma tarja colorida no topo. Quem organiza pela
    /// foto, ou simplesmente prefere a grade sóbria, precisava de uma saída que
    /// não fosse "escolher branco na roda" — cor branca escolhida à mão some
    /// contra o cartão e some junto com a borda dele.
    private var corDaFaixa: Color {
        if faixaSemCor { return PapagaioTema.superficieSuave }
        return corDaFaixaEscolhida ?? corPadraoDaFaixa
    }

    /// A cor que os controles do rodapé seguem.
    ///
    /// O rodapé pertence ao cartão, e o cartão tem uma cor: deixar a linha, o
    /// hover dos ícones e a estrela acesa no laranja da marca fazia todo cartão
    /// azul, verde ou roxo ter um rodapé emprestado de outro lugar.
    ///
    /// Com capa, a cor vem da própria imagem — é a única forma de o rodapé
    /// concordar com um cartão que não tem cor declarada. E qualquer que seja a
    /// origem, ela passa por `acentoSobreSuperficie`: estes acentos são lidos
    /// sobre o branco do cartão, não sobre a faixa, e um amarelo que funciona
    /// atrás do título some sobre o branco.
    private var corDeAcento: Color {
        if let imagem = imagemDaFaixa,
           let dominante = CorDominanteDeImagem.cor(de: imagem, chave: arquivo.id.rawValue.uuidString) {
            return dominante.acentoSobreSuperficie
        }
        // "Sem cor" é uma opção do modelo **com capa**: ela esvazia a faixa
        // colorida do topo, que só existe nesse modelo. No compacto não há
        // faixa nenhuma para esvaziar — a tarja lateral sempre mostra cor
        // (da pasta, ou a de marca), então o resto do cartão (borda, "i" da
        // data, estrela, pasta no rodapé) tem que concordar com ela. Sem
        // este `modelo == .comCapa`, uma conversa marcada "sem cor" no
        // compacto ficava com a tarja azul (da pasta) e tudo o mais em
        // laranja — a opção nem deveria valer aqui.
        if modelo == .comCapa {
            if faixaSemCor {
                if let pasta { return AparenciaDasPastas.corResolvida(de: pasta).acentoSobreSuperficie }
                return PapagaioTema.destaqueEscuro
            }
            return corDaFaixa.acentoSobreSuperficie
        }
        // Compacto ignora `faixaSemCor` por completo, e não só aqui — usa
        // `corDaFaixaEscolhida`/`corPadraoDaFaixa` direto, sem passar por
        // `corDaFaixa`: aquela também esvazia para cinza quando `faixaSemCor`
        // está ligado (é o que o modelo com capa precisa para a faixa
        // sumir), o que devolveria um acento sem graça mesmo tendo pulado a
        // checagem aqui em cima.
        //
        // E, numa pasta, a pasta vence a cor escolhida à mão — mesma
        // prioridade de `corDaTarjaLateral` logo abaixo. Sem isto, uma
        // conversa com cor própria salva (mesmo que "sem cor" nunca tenha
        // sido marcado) dentro de uma pasta azul mostrava a tarja azul (que
        // já respeitava essa prioridade) e a borda/ícones na cor escolhida à
        // mão — as duas cores do mesmo cartão discordando de novo.
        if let pasta { return AparenciaDasPastas.corResolvida(de: pasta).acentoSobreSuperficie }
        return (corDaFaixaEscolhida ?? PapagaioTema.destaque).acentoSobreSuperficie
    }

    /// A cor da tarja lateral do modelo compacto.
    ///
    /// Numa pasta, a tarja segue a cor **da pasta**, mesmo que a conversa
    /// tenha uma cor ou capa próprias — é o que faz todo cartão da mesma
    /// pasta se reconhecer de longe na grade, com a mesma cor da pastilha
    /// no rodapé. Sem pasta, cai no acento de sempre.
    private var corDaTarjaLateral: Color {
        if let pasta {
            return AparenciaDasPastas.corResolvida(de: pasta).acentoSobreSuperficie
        }
        return corDeAcento
    }

    /// Branco ou escuro, conforme a cor da faixa.
    ///
    /// Com imagem é sempre branco: o véu escuro em degradê já garante o
    /// contraste, e a foto pode ter regiões claras e escuras na mesma faixa.
    private var corDoTextoDaFaixa: Color {
        if bannerURL != nil { return .white }
        // Sem cor a faixa é a própria superfície do tema, que já vira escura no
        // modo escuro. `textoLegivel` mede uma cor fixa e não enxerga isso —
        // aqui o certo é a cor de texto do tema, que acompanha a aparência.
        if faixaSemCor { return PapagaioTema.texto }
        return corDaFaixa.textoLegivel
    }

    /// A barra do rodapé: favoritar, pasta e o menu.
    ///
    /// Antes esses controles flutuavam sobre o canto superior do cartão, onde
    /// competiam com o título — a estrela chegava a cobrir as primeiras letras
    /// quando não havia capa. No rodapé, separados por uma linha, eles têm um
    /// lugar próprio: o de cima é a conversa, o de baixo é o que dá para fazer
    /// com ela.
    ///
    /// Fora do `NavigationLink`, senão qualquer clique aqui abriria a conversa.
    private var barraDeAtalhos: some View {
        VStack(spacing: 0) {
            // A linha na cor do cartão, e não no cinza do tema: ela é a costura
            // entre a conversa e o que dá para fazer com ela, e no cinza
            // pertencia à moldura do app em vez de a este cartão.
            //
            // Só recuada enquanto a tarja está em processamento (mesmo
            // motivo da linha do cabeçalho) — parada, ela é fina e opaca, e a
            // linha vai ponta a ponta como sempre foi.
            Rectangle()
                .fill(progresso != nil ? PapagaioTema.borda : corDeAcento.opacity(0.28))
                .frame(height: 1)
                .padding(.leading, progresso != nil ? Self.larguraMaximaDaTarja : 0)

            // Alinhados à direita, como no Classroom: são ações secundárias, e
            // à esquerda competiriam com a leitura do conteúdo acima.
            HStack(spacing: PapagaioTema.Espaco.medio) {
                // No modelo compacto, o selo de status agora mora no centro
                // do cartão (ver overlay do corpo) enquanto processa — o
                // rodapé, nesse momento, fica só com os ícones à direita.
                if modelo == .compacto, estado != .transcritoEResumido {
                    EmptyView()
                } else if let pastaVisivel {
                    // A pasta ocupa o canto esquerdo do rodapé: é rótulo, não
                    // ação, e aqui ela fica na mesma linha do ícone que a
                    // muda, à direita — o que se lê e o que se altera, lado a
                    // lado.
                    SeloDaPastaDoCartao(nome: pastaVisivel) { aoAbrirPasta(pastaVisivel) }
                        .padding(.leading, PapagaioTema.Espaco.largo)
                }

                Spacer(minLength: 0)

                Button(action: alternarFavorito) {
                    Image(systemName: favorito ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .regular))
                        // Favoritada fica acesa na cor do cartão; sob o cursor,
                        // a mesma cor antecipa o que o clique vai fazer.
                        .foregroundStyle(favorito || pairandoNaEstrela ? corDeAcento : PapagaioTema.textoSecundario)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(favorito ? "Desfavoritar".localized : "Favoritar".localized)
                .onHover { pairandoNaEstrela = $0 }

                Button {
                    abrirMoverParaPasta()
                } label: {
                    // Sempre no mesmo estado: a pastilha logo acima já diz em
                    // qual pasta a conversa está. Um ícone preenchido e colorido
                    // repetia a informação e ainda parecia um botão ligado.
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(pairandoNaPasta || escolhendoPastaDestino ? corDeAcento : PapagaioTema.textoSecundario)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { pairandoNaPasta = $0 }
                .help(pasta.map { String(format: "Na pasta %@".localized, $0) } ?? "Mover para pasta".localized)
                // Popover, e não `confirmationDialog`: o diálogo do macOS
                // empilha um botão por pasta, sem rolagem, e a partir de umas
                // poucas pastas simplesmente para de mostrar o resto — foi o
                // que escondeu metade da lista.
                .popover(isPresented: $escolhendoPastaDestino, arrowEdge: .bottom) {
                    seletorDePasta
                }

                menuDoCard
            }
            .padding(.trailing, PapagaioTema.Espaco.largo)
            .frame(height: Self.alturaDaBarra)
        }
        .animation(.easeOut(duration: 0.12), value: pairandoNaEstrela)
        .animation(.easeOut(duration: 0.12), value: pairandoNaPasta)
        .animation(.easeOut(duration: 0.12), value: pairandoNoMenu)
        .animation(.easeOut(duration: 0.12), value: favorito)
    }

    /// O menu é um **popover**, e não uma camada dentro do cartão.
    ///
    /// Como overlay ele era desenhado dentro da árvore do cartão, e a grade
    /// recorta cada fileira: o menu era cortado na borda de baixo — "Mover para
    /// Lixeira" ficava pela metade — e passava por trás dos cartões vizinhos.
    /// Nenhum `zIndex` resolve isso, porque o problema é o recorte, não a ordem.
    ///
    /// Popover vive numa janela própria do sistema: não tem como ser cortado
    /// nem ficar atrás de nada, fecha sozinho ao clicar fora e some junto com a
    /// rolagem. É o que o macOS já faz em todo menu de contexto.
    private var menuDoCard: some View {
        Button {
            if menuAberto {
                aoFecharMenu()
            } else {
                aoAlternarMenu()
            }
        } label: {
            // Vertical, como nos cartões do Classroom: no rodapé, os três
            // pontos deitados leriam como um traço de separação a mais.
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(menuAberto || pairandoNoMenu ? corDeAcento : PapagaioTema.textoSecundario)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { pairandoNoMenu = $0 }
        .accessibilityLabel(String(format: "Ações de %@".localized, titulo))
        .popover(isPresented: $editandoAparencia, arrowEdge: .bottom) {
            EditorDeAparenciaDoCartao(
                arquivoID: arquivo.id,
                corPadrao: corPadraoDaFaixa,
                cor: $corDaFaixaEscolhida,
                semCor: $faixaSemCor,
                banner: $bannerURL,
                ajuste: $ajusteDaImagem,
                mostrarImagem: modelo == .comCapa
            )
        }
        .popover(isPresented: menuVisivel, arrowEdge: .bottom) {
            MenuDeArquivoAberto(
                bloqueioDeEdicao: processando || naFila || emOperacaoDeLixeira,
                bloqueioDeLixeira: emOperacaoDeLixeira,
                cancelavel: estado.ocupado,
                podeDiarizar: podeDiarizar,
                aoDiarizar: executarMenu(aoDiarizar),
                aoReprocessar: executarMenu(aoReprocessar),
                aoRenomear: executarMenu(abrirEditorDeInformacoes),
                aoBaixar: executarMenu(baixar),
                aoCompartilhar: executarMenu(compartilhar),
                aoDuplicar: executarMenu(aoDuplicar),
                aoEditarAparencia: executarMenu { editandoAparencia = true },
                aoMoverParaLixeira: executarMenu(aoMoverParaLixeira)
            )
        }
    }

    /// O estado de aberto continua morando na biblioteca, que garante um menu
    /// por vez; o popover só precisa saber avisar quando o próprio sistema o
    /// fecha — clique fora, `Esc`, rolagem.
    private var menuVisivel: Binding<Bool> {
        Binding(
            get: { menuAberto },
            set: { aberto in
                if !aberto, menuAberto { aoFecharMenu() }
            }
        )
    }

    private func executarMenu(
        _ acao: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void {
        {
            aoFecharMenu()
            // Um salto de runloop antes de agir: apresentar uma folha ou um
            // painel no mesmo ciclo em que o popover se fecha faz o AppKit
            // descartar uma das duas apresentações, e a folha simplesmente não
            // abre. O atraso é invisível.
            DispatchQueue.main.async(execute: acao)
        }
    }

    private func quantidadeDeNomes(_ texto: String) -> Int {
        texto
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
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

        // Contado a partir dos nomes que a pessoa **acabou de digitar**, e não
        // de `participantesEditados`, que é preenchido ao abrir o formulário e
        // nunca mais muda. Lendo dali, adicionar dois entrevistados e salvar
        // gravava o número antigo — o cartão mostrava um total, a ficha
        // mostrava outro, e nenhum dos dois batia com a lista de nomes.
        let quantidade = quantidadeDeNomes(entrevistadoEditado)
            + quantidadeDeNomes(entrevistadoresEditados)
        let novosMetadados = MetadadosVisuaisDoArquivo(
            entrevistado: entrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDoEntrevistado: emailDoEntrevistadoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            entrevistadores: entrevistadoresEditados.trimmingCharacters(in: .whitespacesAndNewlines),
            emailDosEntrevistadores: emailDosEntrevistadoresEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            descricao: descricaoEditada.trimmingCharacters(in: .whitespacesAndNewlines),
            formato: formatoEditado.trimmingCharacters(in: .whitespacesAndNewlines),
            // `nil` quando ninguém foi informado: guardar zero afirmaria que a
            // conversa não teve participantes, e o certo é dizer que não se
            // sabe. É o `nil` que faz o cartão cair na detecção por falante.
            participantes: quantidade > 0 ? quantidade : nil
        )

        // Antes de sobrescrever: depois, `metadados` já não tem o nome antigo
        // para comparar, e a foto ficaria presa numa chave que nada mais lê.
        FotosDePessoas.migrarAoEditarNomes(de: metadados.entrevistado, para: novosMetadados.entrevistado)
        FotosDePessoas.migrarAoEditarNomes(de: metadados.entrevistadores, para: novosMetadados.entrevistadores)

        metadados = novosMetadados
        PreferenciasVisuaisDoArquivo.definirMetadados(novosMetadados, para: arquivo.id)
        // A duração não é editável no formulário: vem do próprio áudio.
        aoAtualizarMetadados(tituloLimpo, dataEditada, arquivo.duracao)
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

    /// A lista de pastas, rolável, com a atual marcada.
    private var seletorDePasta: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text("Mover para pasta".localized)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .textCase(.uppercase)
                .padding(.horizontal, PapagaioTema.Espaco.curto)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(PreferenciasVisuaisDoArquivo.pastas(), id: \.self) { nome in
                        Button {
                            moverParaPasta(nome)
                            escolhendoPastaDestino = false
                        } label: {
                            HStack(spacing: PapagaioTema.Espaco.curto) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AparenciaDasPastas.corResolvida(de: nome))

                                Text(nome)
                                    .font(.callout)
                                    .foregroundStyle(PapagaioTema.texto)
                                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                                Spacer(minLength: PapagaioTema.Espaco.curto)

                                if nome == pasta {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(PapagaioTema.destaqueEscuro)
                                }
                            }
                            .padding(.horizontal, PapagaioTema.Espaco.curto)
                            .frame(height: PapagaioTema.Altura.compacta)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Teto de altura em vez de crescer sem fim: com trinta pastas o
            // popover viraria uma coluna do tamanho da tela.
            .frame(maxHeight: 220)

            SeparadorPapagaio()

            Button("Criar nova pasta…".localized, systemImage: "folder.badge.plus") {
                escolhendoPastaDestino = false
                nomeDaPasta = ""
                DispatchQueue.main.async { criandoPastaParaMover = true }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(PapagaioTema.destaqueEscuro)
            .padding(.horizontal, PapagaioTema.Espaco.curto)

            if pasta != nil {
                Button("Remover da pasta".localized, systemImage: "folder.badge.minus") {
                    pasta = nil
                    PreferenciasVisuaisDoArquivo.definirPasta(nil, para: arquivo.id)
                    aoAlterarPreferenciasVisuais()
                    escolhendoPastaDestino = false
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(PapagaioTema.perigo)
                .padding(.horizontal, PapagaioTema.Espaco.curto)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(width: 260)
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
        corDaFaixaEscolhida = AparenciaDoCartao.cor(arquivo.id)
        faixaSemCor = AparenciaDoCartao.semCor(arquivo.id)
        CorDominanteDeImagem.esquecer(arquivo.id.rawValue.uuidString)
        bannerURL = AparenciaDoCartao.banner(arquivo.id)
        ajusteDaImagem = AparenciaDoCartao.ajuste(arquivo.id)
        metadados = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
    }

    /// Salva o dossiê da conversa numa pasta escolhida pela pessoa.
    ///
    /// O mesmo pacote do compartilhamento — documento e áudio juntos —, mas
    /// indo para o disco em vez de para o painel do sistema. São coisas
    /// diferentes: compartilhar é mandar para alguém, baixar é ficar com uma
    /// cópia, e o menu da pasta já oferecia as duas.
    private func baixar() {
        #if os(macOS)
        guard let pacote = try? DossieDaConversa.pacoteComAudio(
            arquivo: arquivo,
            audioPrincipal: urlDeAudio
        ) else { return }

        let painel = NSOpenPanel()
        painel.title = String(format: "Escolha onde salvar %@".localized, titulo)
        painel.prompt = "Salvar aqui".localized
        painel.canChooseFiles = false
        painel.canChooseDirectories = true
        painel.canCreateDirectories = true

        guard painel.runModal() == .OK,
              let destino = painel.url,
              destino.startAccessingSecurityScopedResource()
        else { return }
        defer { destino.stopAccessingSecurityScopedResource() }

        let alvo = destino.appendingPathComponent(pacote.lastPathComponent)
        try? FileManager.default.removeItem(at: alvo)
        try? FileManager.default.copyItem(at: pacote, to: alvo)
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

/// Os participantes como círculos sobrepostos, com as iniciais de cada um.
///
/// Substituiu a imagem grande da conversa. Aquela imagem era decoração: uma
/// foto qualquer que não dizia quem estava na sala. Estes círculos ocupam menos
/// e respondem à pergunta que o cartão de fato levanta — quem participou —
/// antes de a pessoa clicar em nada.
///
/// Três é o teto visível; acima disso entra um `+N`. Quatro círculos já viram
/// mancha, e a lista completa está a um clique.
struct PilhaDeParticipantes: View {
    let nomes: [String]
    var diametro: CGFloat = 30

    /// Quem está sob o cursor agora.
    @State private var emDestaque: String?

    private static let maximo = 4

    var body: some View {
        // Lado a lado, sem sobreposição: sobrepostos, metade de cada rosto
        // ficava escondida atrás do vizinho — e rosto pela metade não se
        // reconhece. O ganho de espaço não valia o que se perdia.
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            ForEach(Array(nomes.prefix(Self.maximo).enumerated()), id: \.offset) { _, nome in
                AvatarDePessoa(nome: nome, diametro: diametro)
                    .opacity(emDestaque == nil || emDestaque == nome ? 1 : 0.5)
                    // A legenda é do rosto, e não da fileira: presa ao avatar,
                    // ela nasce centrada nele sozinha — do mesmo jeito que a
                    // legenda dos atalhos da barra nasce centrada no ícone.
                    .overlay(alignment: .top) {
                        if emDestaque == nome {
                            legenda(nome)
                                .offset(y: diametro + PapagaioTema.Espaco.minimo)
                        }
                    }
                    // Sem isto a legenda de um rosto passaria por baixo do
                    // rosto seguinte, que é desenhado depois dele.
                    .zIndex(emDestaque == nome ? 10 : 0)
                    .onHover { dentro in
                        withAnimation(.easeOut(duration: 0.12)) {
                            emDestaque = dentro ? nome : (emDestaque == nome ? nil : emDestaque)
                        }
                    }
            }

            if nomes.count > Self.maximo {
                Text("+\(nomes.count - Self.maximo)")
                    .font(.system(size: diametro * 0.38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: diametro, height: diametro)
                    .background(PapagaioTema.textoSecundario, in: Circle())
                    .overlay { Circle().stroke(PapagaioTema.superficie, lineWidth: 2) }
                    .help(nomes.dropFirst(Self.maximo).joined(separator: ", "))
            }
        }
    }

    /// A mesma cápsula das legendas da barra superior: fundo de superfície,
    /// contorno fino e sombra baixa.
    ///
    /// Repetida aqui em vez de reaproveitar `LegendaGlobalDaBarra` porque
    /// aquela desenha numa camada global, posicionada por coordenadas de tela —
    /// coisa que a barra precisa (os ícones ficam dentro de uma faixa de 36pt
    /// que recortaria a legenda) e o cartão não: aqui sobra espaço abaixo dos
    /// rostos, e um overlay local acompanha o avatar sem plumbing nenhum.
    private func legenda(_ nome: String) -> some View {
        Text(nome)
            .font(.caption2.weight(.semibold))
            // O nome na cor do próprio rosto: é o que amarra o rótulo ao
            // círculo de onde ele saiu quando há quatro deles lado a lado.
            .foregroundStyle(AvatarDePessoa.corDeAcento(de: nome))
            .lineLimit(1)
                    .minimumScaleFactor(0.82)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .padding(.vertical, PapagaioTema.Espaco.minimo)
            .background(PapagaioTema.superficie, in: Capsule())
            .overlay {
                Capsule().stroke(PapagaioTema.borda.opacity(0.92), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            // A legenda não recebe cliques: o alvo continua sendo a linha, que
            // abre a ficha.
            .allowsHitTesting(false)
    }
}

/// A pastilha da pasta no cartão da conversa, na cor escolhida para a pasta.
///
/// Não usa `SeloDeStatus` porque aquele componente só aceita a paleta fechada
/// de estados — sucesso, aviso, erro, neutro. Aqui a cor é dado do usuário.
struct SeloDaPastaDoCartao: View {
    let nome: String
    /// Levar para a pasta. `nil` onde a pastilha é só rótulo — no exemplo das
    /// Configurações, por exemplo.
    var aoAbrir: (() -> Void)?

    @State private var cor: Color = PapagaioTema.destaque
    @State private var semCor = false
    @State private var imagem: NSImage?
    @State private var ajuste: AjusteDeImagem = .preencher

    /// A miniatura da pasta, quando ela usa imagem em vez de cor.
    ///
    /// Sem isto a pastilha mostrava um ícone de pasta colorido para uma pasta
    /// que a pessoa identificou por foto — dois vocabulários diferentes para a
    /// mesma pasta, um em cada tela.
    @ViewBuilder
    private var marca: some View {
        if let imagem {
            ImagemDeFundo(
                imagem: imagem,
                ajuste: ajuste,
                corDeFundo: PapagaioTema.superficieSuave,
                comVeu: false
            )
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            // Um anel na cor da pasta em volta da foto: é o que faz a cor
            // aparecer mesmo quando a miniatura ocupa o lugar do ícone.
            .overlay {
                if !semCor {
                    Circle().stroke(cor, lineWidth: 1.5)
                }
            }
        } else {
            Image(systemName: "folder.fill")
                .foregroundStyle(semCor ? PapagaioTema.textoSecundario : cor)
        }
    }

    /// Imagem e cor convivem: quem manda é "sem cor", não a imagem.
    ///
    /// Antes a imagem apagava a cor, na suposição de que uma tivesse substituído
    /// a outra. Com "Sem cor" existindo como escolha própria, a suposição virou
    /// erro: a pasta com foto **e** cor chegava aqui cinza, perdendo a cor que a
    /// pessoa tinha escolhido de propósito. Só quem pediu para não ter cor fica
    /// neutro.
    private var selo: some View {
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            marca

            Text(nome)
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
        }
        .font(PapagaioTema.Tipo.rotulo)
        .foregroundStyle(semCor ? PapagaioTema.texto : cor)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .padding(.leading, imagem == nil ? 0 : -PapagaioTema.Espaco.curto)
        .frame(height: PapagaioTema.Altura.compacta)
        .background(
            semCor ? PapagaioTema.superficieSuave : cor.opacity(0.14),
            in: Capsule()
        )
    }

    var body: some View {
        Group {
            if let aoAbrir {
                // A pastilha diz onde a conversa está; clicar nela é o gesto
                // natural de "me leva lá". Sem isso, era um rótulo bonito que
                // obrigava a voltar até Pastas e procurar o nome na grade.
                Button(action: aoAbrir) {
                    selo.contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(format: "Abrir a pasta %@".localized, nome))
            } else {
                selo
            }
        }
        .onAppear(perform: sincronizar)
        .onChange(of: nome) { _, _ in sincronizar() }
    }

    private func sincronizar() {
        cor = AparenciaDasPastas.corResolvida(de: nome)
        semCor = AparenciaDasPastas.semCor(de: nome)
        ajuste = AparenciaDasPastas.ajuste(de: nome)
        imagem = AparenciaDasPastas.capa(de: nome) == nil
            ? nil
            : AparenciaDasPastas.imagem(de: nome)
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
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
            }
        } icon: {
            Image(systemName: simbolo)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
        }
    }
}



/// A tarja lateral do cartão compacto, preenchendo de baixo pra cima
/// conforme o processamento avança.
///
/// Mesmo relógio da `BarraDeProgressoDoProcessamento` — reaproveita
/// `fracao(decorrido:estimativa:)` para as duas leituras nunca discordarem
/// sobre "quanto já andou". A trilha de fundo fica na cor apagada da tarja
/// parada; o preenchimento é a cor cheia, subindo por cima dela.
struct TarjaDeProgressoDoCartao: View {
    let cor: Color
    let inicio: Date
    let estimativa: TimeInterval

    /// O que a tarja mostra agora — separado da fração real (`fracao`,
    /// calculada a cada tique do relógio) para a barra poder nascer do zero
    /// e subir até lá, em vez de aparecer já no meio do caminho.
    ///
    /// Sem essa separação, um cartão que entra na tela com o processamento
    /// já em andamento há alguns segundos (rolando a grade, reabrindo o
    /// app no meio de um resumo) mostrava o número direto em "8%", "15%" —
    /// como se tivesse pulado etapas. Começando daqui, a primeira coisa que
    /// se vê é sempre "0%" subindo, e só depois ela acompanha o relógio de
    /// verdade.
    @State private var fracaoExibida: Double = 0

    var body: some View {
        TimelineView(.periodic(from: inicio, by: 1)) { contexto in
            let fracao = BarraDeProgressoDoProcessamento.fracao(
                decorrido: contexto.date.timeIntervalSince(inicio),
                estimativa: estimativa
            )

            GeometryReader { geometria in
                let alturaPreenchida = max(6, geometria.size.height * fracaoExibida)

                ZStack(alignment: .bottom) {
                    Rectangle().fill(cor.opacity(0.22))

                    Rectangle()
                        .fill(cor)
                        .frame(height: alturaPreenchida)
                }

                // O número sobe junto com o preenchimento, e não fica
                // parado no meio da tarja — é ele quem "anda" com a barra,
                // não um rótulo estático do lado. `.position`, e não
                // alinhamento + offset: os dois combinados ficam difíceis de
                // acertar o sinal certo; posição absoluta é direta.
                Text("\(Int((fracaoExibida * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    // Branco fixo, com uma sombra escura por baixo — e não
                    // `cor.textoLegivel`. O número não fica só sobre o
                    // preenchimento sólido: perto do início do
                    // processamento ele cai sobre a trilha translúcida
                    // (22% de opacidade), que é um fundo bem mais escuro e
                    // dessaturado que a cor cheia — contraste calculado para
                    // uma coisa aparecia errado sobre a outra, e o número
                    // sumia quase na própria cor da tarja. A sombra garante
                    // leitura nos dois fundos, sólido ou translúcido.
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1.5)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .position(
                        x: geometria.size.width / 2,
                        // 12pt abaixo do topo do preenchimento: perto da
                        // ponta de cima, sem sair da área colorida em quase
                        // nenhum estágio do andamento.
                        y: max(12, geometria.size.height - alturaPreenchida + 12)
                    )
            }
            .animation(.easeOut(duration: 0.3), value: fracaoExibida)
            .onChange(of: fracao) { _, novaFracao in
                fracaoExibida = novaFracao
            }
            .onAppear {
                guard fracao > 0 else { return }
                // A entrada é mais lenta que o tique normal (0.3s): 0% até a
                // fração real é um salto maior que "mais um segundo se
                // passou", e merece se notar como uma subida, não um pulo.
                withAnimation(.easeOut(duration: 0.7)) {
                    fracaoExibida = fracao
                }
            }
        }
        // Mais espessa que a tarja parada (4pt): em processamento ela é o
        // único sinal de que algo está acontecendo, e precisa se notar sem
        // precisar ler a porcentagem. Ainda dentro do cartão — quem arredonda
        // as pontas é o `.clipShape` do cartão, então ela nunca escapa do
        // canto mesmo mais grossa.
        .frame(width: CartaoDeConversa.larguraMaximaDaTarja)
    }
}

/// Barra fina com o andamento do processamento.
///
/// Mostra só a porcentagem, à direita. O tempo restante saiu porque era a parte
/// menos confiável e a mais lida: dizer "cerca de 40 min" e terminar em 12 faz
/// a pessoa desconfiar do número seguinte. A porcentagem que avança sozinha já
/// responde à pergunta real, que é "isto está vivo?".
struct BarraDeProgressoDoProcessamento: View {
    let inicio: Date
    let estimativa: TimeInterval

    var body: some View {
        // `TimelineView` porque o progresso é função do relógio, não de estado:
        // sem uma batida de fora, a barra ficaria congelada até a fase mudar —
        // e a fase muda duas vezes em vários minutos.
        TimelineView(.periodic(from: inicio, by: 1)) { contexto in
            corpo(fracao: Self.fracao(
                decorrido: contexto.date.timeIntervalSince(inicio),
                estimativa: estimativa
            ))
        }
    }

    private func corpo(fracao: Double) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
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

            Text("\(Int((fracao * 100).rounded()))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.3), value: fracao)
    }

    /// Avança rápido até a estimativa e desacelera depois, sem nunca travar.
    ///
    /// A versão anterior era linear e saturava em 95%: se a estimativa errasse
    /// para menos, a barra ficava parada nesse número por minutos, que é a
    /// aparência exata de um app travado.
    ///
    /// Aqui são duas partes. Até a estimativa, avanço proporcional até 90% — é
    /// o trecho em que a previsão vale alguma coisa. Passando dela, o que sobra
    /// é consumido de forma assintótica: cada minuto extra come uma fração do
    /// que falta, então o número sempre sobe, sempre menos, e chega perto de
    /// 100 sem nunca prometer o fim antes da hora.
    ///
    /// Errar para menos deixou de ser um congelamento e virou uma desaceleração
    /// — que é como a espera realmente se comporta.
    static func fracao(decorrido: TimeInterval, estimativa: TimeInterval) -> Double {
        guard estimativa > 0, decorrido > 0 else { return 0 }

        if decorrido < estimativa {
            return 0.9 * (decorrido / estimativa)
        }

        let excedente = (decorrido - estimativa) / estimativa
        return 0.9 + 0.1 * (1 - exp(-excedente))
    }
}
