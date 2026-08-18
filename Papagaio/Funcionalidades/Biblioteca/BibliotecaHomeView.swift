import AppKit
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
    /// O picker não retém o delegate; sem esta referência o "Salvar em…" some
    /// do painel de compartilhamento.
    @State private var delegadoDeCompartilhamento: OpcoesDeCompartilhamento?
    @State private var novaPasta = ""

    /// Durante a captura, filtros e pastas somem: a página é a tela da
    /// gravação, e não um acervo para navegar.
    @ViewBuilder
    private var filtrosEPastas: some View {
        if secaoSelecionada == .todos, !emCaptura {
            // Filtros e atalhos na mesma linha: são a mesma decisão — qual
            // recorte da biblioteca estou vendo. Separados, "Recentes" e
            // "Favoritos" pareciam ações do título, e não filtros.
            // Uma linha só, e não um `ViewThatFits` com três arranjos.
            //
            // O `ViewThatFits` monta **todos** os candidatos para medi-los e
            // descarta os que não couberem. Os três traziam um `FiltroDeConversas`
            // próprio, e os três posicionavam esse filtro no mesmo canto — o
            // superior esquerdo, que é justamente onde fica "Todas". Bastava um
            // candidato descartado continuar recebendo o clique para a pastilha
            // da esquerda parar de responder enquanto a da direita, mais para
            // dentro da linha, seguia funcionando. Era exatamente o sintoma.
            //
            // Com uma instância só não existe a quem confundir. As pastilhas são
            // pequenas e o `Spacer` cede primeiro, então a linha aguenta janela
            // estreita sem precisar de arranjo alternativo.
            HStack(spacing: PapagaioTema.Espaco.largo) {
                FiltroDeConversas(
                    selecionado: $filtroSelecionado,
                    pastaSelecionada: $pastaSelecionada,
                    atalhoSelecionado: $atalhoSelecionado,
                    aoLimparAtalhoVisual: limparAtalhoVisual
                )

                Spacer(minLength: PapagaioTema.Espaco.curto)

                atalhosDaBiblioteca
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Acima do que vem depois — inclusive da grade de pastas, que é
            // irmã desta linha dentro do mesmo `if`.
            //
            // O `.zIndex(1)` já existiu, mas no `filtrosEPastas` inteiro, do
            // lado de fora. Um `@ViewBuilder` com duas visões em sequência —
            // esta `HStack` e o `if filtroSelecionado == .pastas` logo abaixo
            // — vira uma só `TupleView` quando entra na `VStack` de fora, e um
            // modificador aplicado a ela se distribui igual para as duas
            // partes. Pastilhas e grade acabavam com o mesmo `zIndex`, e numa
            // `VStack` quem desenha por cima em caso de empate é o irmão
            // seguinte — a grade —, então bastava ela invadir a borda de baixo
            // das pastilhas (uma sombra, um cartão com moldura maior que o
            // conteúdo visível) para roubar o clique bem ali. O `zIndex` tem
            // que estar aqui dentro, só nesta linha, pra valer só para ela.
            .zIndex(1)

            // A pasta aberta manda no cabeçalho, não a aba.
            //
            // Uma pasta também se abre pelos resultados de busca em "Todas" —
            // é a grade de "Pastas" logo abaixo, quando o termo casa com
            // alguma. Prender este cabeçalho a `filtroSelecionado == .pastas`
            // deixava quem entrou por ali sem nome de pasta, sem contagem e
            // sem botão de voltar: a única saída era lembrar de clicar em
            // "Todas" de novo. `pastaSelecionada` já é a mesma verdade nos
            // dois casos — é ela quem deve decidir se o cabeçalho aparece.
            if let pastaAberta = pastaSelecionada {
                CabecalhoDaPastaAberta(
                    nome: pastaAberta,
                    // Contado direto, e não pela lista de pastas: com o
                    // atalho Favoritos ativo aquela lista está recortada, e
                    // uma pasta aberta que não é favorita apareceria como
                    // "0 conversas".
                    quantidade: biblioteca?.arquivos.count {
                        PreferenciasVisuaisDoArquivo.pasta($0.id) == pastaAberta
                    } ?? 0
                ) {
                    withAnimation(.snappy(duration: 0.18)) {
                        pastaSelecionada = nil
                    }
                }
            } else if filtroSelecionado == .pastas {
                GradeDePastas(
                    pastas: informacoesDasPastas,
                    selecionada: $pastaSelecionada,
                    aoCriarPasta: abrirCriacaoDePasta,
                    aoApagarPasta: apagarPasta,
                    aoRenomearPasta: { antigo, novo in
                        withAnimation(.snappy(duration: 0.2)) {
                            PreferenciasVisuaisDoArquivo.renomearPasta(antigo, para: novo)
                            if pastaSelecionada == antigo {
                                pastaSelecionada = novo.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            atualizarPreferenciasVisuais()
                        }
                    },
                    aoBaixarPasta: baixarPasta,
                    aoCompartilharPasta: compartilharPasta,
                    apenasFavoritas: atalhoSelecionado == .favoritos
                )
                .simultaneousGesture(TapGesture().onEnded { limparAtalhoVisual() })
            }
        }
    }

    /// O que era o subtítulo da página, agora sob demanda.
    ///
    /// Texto que se lê uma vez e depois só ocupa a primeira dobra da tela
    /// inicial — mesmo tratamento que a explicação da aba Mídia já tinha
    /// recebido.
    private var ajudaDaBiblioteca: some View {
        BotaoDeAjudaPapagaio(
            texto: "Gerencie suas transcrições e insights de entrevistas.",
            ajuda: "Sobre a biblioteca",
            largura: 300
        )
    }

    private var atalhosDaBiblioteca: some View {
        AtalhosDaBiblioteca(
            selecionado: $atalhoVisualSelecionado,
            aoSelecionarRecentes: {
                withAnimation(.snappy(duration: 0.18)) {
                    // Mesma regra do Favoritos: em Pastas, o atalho reordena as
                    // pastas em vez de trocar o que está sendo mostrado.
                    if filtroSelecionado != .pastas {
                        filtroSelecionado = .todas
                        pastaSelecionada = nil
                    }
                    atalhoSelecionado = .recentes
                    atalhoVisualSelecionado = .recentes
                }
            },
            aoSelecionarFavoritos: {
                withAnimation(.snappy(duration: 0.18)) {
                    // Em Pastas, "Favoritos" filtra pastas favoritas; forçar
                    // .todas jogava a pessoa de volta para as conversas e
                    // desfazia o recorte que ela tinha acabado de escolher.
                    if filtroSelecionado != .pastas {
                        filtroSelecionado = .todas
                        pastaSelecionada = nil
                    }
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
                waveformSistema: gravador.waveformSistema,
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
            // Conversas que foram para a lixeira junto com a pasta aparecem
            // dentro do cartão dela, não soltas: repetidas nos dois lugares,
            // restaurar num deles deixaria o outro mentindo.
            let dentroDePastaApagada = Set(LixeiraDePastas.itens().flatMap(\.conversas))
            fonte = biblioteca.arquivosNaLixeira.filter {
                !dentroDePastaApagada.contains($0.id.rawValue)
            }
        }
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !termo.isEmpty else { return fonte }
        return fonte.filter { arquivo in
            let titulo = arquivo.resumo?.titulo ?? arquivo.titulo
            // Pelo nome da pasta também: "Cliente X" é como se pensa no
            // projeto, e a pessoa não deveria ter de lembrar o título de cada
            // conversa dentro dele para encontrá-las.
            let pastaDaConversa = PreferenciasVisuaisDoArquivo.pasta(arquivo.id) ?? ""
            return titulo.localizedCaseInsensitiveContains(termo)
                || pastaDaConversa.localizedCaseInsensitiveContains(termo)
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

        var visiveis = atalhoSelecionado == .favoritos
            ? pastasCriadas.filter { AparenciaDasPastas.favorita($0) }
            : pastasCriadas

        // A busca também recorta a grade de pastas. Uma pasta vazia não tem
        // conversa que a traga no resultado, então sem isto ela era
        // inalcançável pela busca — e pasta vazia é justamente a que se acabou
        // de criar e se quer encontrar.
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !termo.isEmpty {
            visiveis = visiveis.filter { $0.localizedCaseInsensitiveContains(termo) }
        }

        let informacoes = visiveis.map { pasta in
            InformacaoDaPasta(
                nome: pasta,
                quantidade: biblioteca.arquivos.count {
                    PreferenciasVisuaisDoArquivo.pasta($0.id) == pasta
                },
                criadaEm: AparenciaDasPastas.criadaEm(pasta)
            )
        }

        guard atalhoSelecionado == .recentes else { return informacoes }

        // Ordena pela data de criação, que é a data que o cartão mostra.
        // Ordenar por outro critério — a conversa mais nova de dentro, por
        // exemplo — deixaria a grade numa ordem que a própria tela contradiz.
        return informacoes.sorted {
            ($0.criadaEm ?? .distantPast) > ($1.criadaEm ?? .distantPast)
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

    /// Apagar a pasta leva as conversas dela para a lixeira, junto.
    ///
    /// A alternativa — apagar só o rótulo e deixar as conversas soltas em
    /// "Todas" — parece mais gentil e é pior: quem apaga a pasta "Cliente X"
    /// quer o projeto fora da vista, e encontraria as mesmas conversas
    /// espalhadas na grade um segundo depois. Na lixeira nada se perde, e a
    /// pasta ali dentro permite trazer de volta o conjunto ou um arquivo só.
    private func apagarPasta(_ nome: String) {
        guard let biblioteca else { return }
        let conversas = biblioteca.arquivos.filter {
            PreferenciasVisuaisDoArquivo.pasta($0.id) == nome
        }

        if pastaSelecionada == nome { pastaSelecionada = nil }

        Task {
            for arquivo in conversas {
                await biblioteca.moverParaLixeira(arquivo)
            }
            // Depois de mover: `apagarPasta` lê quem ainda tem o rótulo para
            // montar o retrato, e o rótulo sobrevive à ida para a lixeira.
            PreferenciasVisuaisDoArquivo.apagarPasta(nome)
            atualizarPreferenciasVisuais()
        }
    }

    private func conversasDa(_ pasta: PastaNaLixeira) -> [Arquivo] {
        guard let biblioteca else { return [] }
        // A ordem é a da lixeira, não a de `conversas`: é a mesma ordem dos
        // outros cartões da tela.
        return biblioteca.arquivosNaLixeira.filter { pasta.conversas.contains($0.id.rawValue) }
    }

    /// Devolve a pasta e tudo o que ainda estava dentro dela.
    private func restaurarPasta(_ pasta: PastaNaLixeira) {
        guard let biblioteca else { return }
        let conversas = conversasDa(pasta)

        Task {
            for arquivo in conversas where await biblioteca.restaurarDaLixeira(arquivo) {
                LixeiraDePastas.devolverRotulo(pasta.nome, para: arquivo.id)
            }
            LixeiraDePastas.restaurar(pasta)
            atualizarPreferenciasVisuais()
        }
    }

    /// Traz uma conversa de volta sem restaurar a pasta.
    ///
    /// Ela volta para "Todas", sem rótulo: a pasta não existe mais, e inventar
    /// uma para ela criaria uma pasta que a pessoa não pediu.
    private func restaurarConversaDaPasta(_ arquivo: Arquivo, de pasta: PastaNaLixeira) {
        guard let biblioteca else { return }
        Task {
            guard await biblioteca.restaurarDaLixeira(arquivo) else { return }
            LixeiraDePastas.desvincular(arquivo.id)
            atualizarPreferenciasVisuais()
        }
    }

    /// As conversas de uma pasta, como arquivos prontos para sair do app.
    ///
    /// Um dossiê por conversa — texto com resumo, transcrição e tarefas — e não
    /// o áudio: "baixar a pasta" quase sempre quer dizer levar o conteúdo para
    /// um relatório, e o áudio de doze entrevistas são gigabytes que ninguém
    /// pediu. Quem quer o áudio de uma conversa usa o Compartilhar dela.
    private func pacoteDaPasta(_ nome: String) -> URL? {
        guard let biblioteca else { return nil }
        let conversas = biblioteca.arquivos
            .filter { PreferenciasVisuaisDoArquivo.pasta($0.id) == nome }
            .map { (arquivo: $0, audio: biblioteca.audio(de: $0)) }

        guard !conversas.isEmpty else { return nil }
        return try? DossieDaConversa.pastaComTudo(nome: nome, conversas: conversas)
    }

    /// Salva a pasta inteira onde a pessoa escolher, como pasta de verdade.
    private func baixarPasta(_ nome: String) {
        guard let pacote = pacoteDaPasta(nome) else { return }

        let painel = NSOpenPanel()
        painel.title = "Escolha onde salvar a pasta \(nome)"
        painel.prompt = "Salvar aqui"
        painel.canChooseFiles = false
        painel.canChooseDirectories = true
        painel.canCreateDirectories = true

        guard painel.runModal() == .OK,
              let destino = painel.url,
              destino.startAccessingSecurityScopedResource()
        else { return }
        defer { destino.stopAccessingSecurityScopedResource() }

        let alvo = destino.appendingPathComponent(nome, isDirectory: true)
        try? FileManager.default.removeItem(at: alvo)
        try? FileManager.default.copyItem(at: pacote, to: alvo)
    }

    /// Compartilha como um `.zip` único.
    ///
    /// Um arquivo só, e não uma lista: mandar quarenta arquivos soltos pelo
    /// painel de compartilhamento é o que trava e-mail e mensagem — e do outro
    /// lado ninguém remonta a estrutura de pastas na mão.
    private func compartilharPasta(_ nome: String) {
        guard let pacote = pacoteDaPasta(nome),
              let zip = try? DossieDaConversa.zipar(pacote),
              let view = NSApp.keyWindow?.contentView
        else { return }

        // O mesmo painel do cartão de conversa, com o delegate que acrescenta
        // "Salvar em…". Sem ele, compartilhar uma pasta oferecia só os apps —
        // e guardar num diretório, que é o caso mais comum, ficava de fora.
        let picker = NSSharingServicePicker(items: [zip])
        let opcoes = OpcoesDeCompartilhamento(arquivos: [zip])
        delegadoDeCompartilhamento = opcoes
        picker.delegate = opcoes
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// As pastas cujo nome casa com a busca. Vazio sem termo digitado.
    private var pastasEncontradas: [InformacaoDaPasta] {
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !termo.isEmpty, secaoSelecionada == .todos else { return [] }
        return informacoesDasPastas
    }

    private var pastasNaLixeira: [PastaNaLixeira] {
        _ = versaoDasPreferenciasVisuais
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        let itens = LixeiraDePastas.itens()
        guard !termo.isEmpty else { return itens }
        return itens.filter { $0.nome.localizedCaseInsensitiveContains(termo) }
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

    private var apresentandoErroDeCarregamento: Binding<Bool> {
        Binding(
            get: { biblioteca?.erroDeCarregamento != nil },
            set: { apresentando in
                if !apresentando { biblioteca?.dispensarErroDeCarregamento() }
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

    /// Título, filtros e grade dentro de um painel só.
    ///
    /// É o "cardzão" do Classroom: a grade não flutua sobre o fundo da janela,
    /// ela mora numa superfície com nome. O ganho não é decorativo — o painel
    /// delimita o que o título e os filtros governam, e separa a biblioteca do
    /// que aparece fora dela, como o aviso de download dos modelos.
    private var painelDaBiblioteca: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
                Text("Biblioteca de Conversas")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                // Ao lado do título, e não dos filtros: o que ele explica é o
                // que a seção é, não como ela está recortada.
                ajudaDaBiblioteca

                Spacer(minLength: 0)

                if let biblioteca, biblioteca.processando {
                    SeloDeStatus(
                        texto: "Processamento em andamento",
                        simbolo: "waveform",
                        estilo: .destaque
                    )
                }
            }

            filtrosEPastas

            // Buscando em "Todas", as pastas que casam com o termo aparecem
            // antes das conversas. Sem isto, procurar por um projeto só
            // encontrava as conversas dentro dele — e uma pasta recém-criada,
            // ainda vazia, não aparecia em lugar nenhum.
            //
            // `pastaSelecionada == nil`: com uma pasta já aberta esta grade de
            // resultados perdia sentido — ela reaparecia por cima da conversa
            // filtrada, com o mesmo termo ainda casando o nome da pasta aberta.
            if pastaSelecionada == nil, filtroSelecionado != .pastas, !pastasEncontradas.isEmpty {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    Text("Pastas")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .textCase(.uppercase)

                    GradeDePastas(
                        pastas: pastasEncontradas,
                        selecionada: $pastaSelecionada,
                        aoCriarPasta: abrirCriacaoDePasta,
                        aoApagarPasta: apagarPasta,
                        aoRenomearPasta: { antigo, novo in
                            PreferenciasVisuaisDoArquivo.renomearPasta(antigo, para: novo)
                            atualizarPreferenciasVisuais()
                        },
                        aoBaixarPasta: baixarPasta,
                        aoCompartilharPasta: compartilharPasta,
                        ocultarCriacao: true
                    )
                }
            }

            gradeDeConversas
                .simultaneousGesture(TapGesture().onEnded { limparAtalhoVisual() })
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        // Contorno mais firme que o dos cartões de dentro: é ele que separa o
        // painel do fundo da janela, que aqui tem quase a mesma luminosidade.
        // Sem a linha, o painel só existia por causa da sombra.
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                // Gravando, o cabeçalho inteiro sai: "Gravações / Grave,
                // transcreva e revise" empurrava o painel de captura — que é a
                // única coisa que importa nesse momento — para baixo. A frase
                // vira o "i" que fica ao lado do cronômetro.
                // Na biblioteca, o cabeçalho inteiro saiu: "Biblioteca de
                // Conversas / Gerencie suas transcrições" ocupava a primeira
                // dobra para dizer o que a grade de cartões logo abaixo já
                // mostra. É a tela inicial do app — ninguém chega nela sem
                // saber onde está. A frase virou o "i" ao lado dos filtros.
                if !emCaptura, secaoSelecionada == .todos {
                    if let modelos, !modelos.pronto {
                        CartaoDeModelos(
                            modelos: modelos,
                            aoEscolherPasta: aoEscolherPastaDeModelos,
                            aoUsarPastaDoApp: aoUsarPastaDoApp
                        )
                    }

                    painelDaBiblioteca
                } else if !emCaptura {
                    CabecalhoDePagina(
                        titulo: tituloDaPagina,
                        subtitulo: subtitulo
                    ) {
                    HStack(spacing: PapagaioTema.Espaco.largo) {
                        if secaoSelecionada != .todos, let biblioteca {
                            AcoesDaLixeira(
                                temArquivos: !biblioteca.arquivosNaLixeira.isEmpty || !LixeiraDeTarefas.itens().isEmpty || !LixeiraDeMidia.itens().isEmpty || !LixeiraDePastas.itens().isEmpty,
                                aoRestaurarTudo: {
                                    Task { await biblioteca.restaurarTudoDaLixeira() }
                                    LixeiraDeTarefas.restaurarTudo(arquivos: biblioteca.arquivos + biblioteca.arquivosNaLixeira)
                                    LixeiraDeMidia.restaurarTudo()
                                    LixeiraDePastas.restaurarTudo()
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

                if emCaptura || secaoSelecionada != .todos {
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
        // Apagar a busca devolve a tela inicial inteira, pasta aberta
        // inclusa. Sem isto, quem entrou numa pasta a partir de um resultado
        // de busca via campo de texto continuava "dentro" dela depois de
        // limpar o termo — via de volta que só o botão do cabeçalho oferecia.
        .onChange(of: consulta) { _, novoValor in
            guard novoValor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pastaSelecionada != nil
            else { return }
            withAnimation(.snappy(duration: 0.18)) {
                pastaSelecionada = nil
            }
        }
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
                    LixeiraDePastas.esvaziar()
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
        .alert("Não foi possível abrir a biblioteca", isPresented: apresentandoErroDeCarregamento) {
            Button("OK", role: .cancel) { biblioteca?.dispensarErroDeCarregamento() }
        } message: {
            Text(biblioteca?.erroDeCarregamento ?? "")
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
                        aoSoltarArquivos: aoSoltarArquivos,
                        aoVoltarParaGravacao: { focoNaGravacao = true }
                    )
                }

                ForEach(arquivosFiltrados) { arquivo in
                    if let biblioteca {
                        cartaoDeConversa(arquivo, biblioteca: biblioteca)
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
            if (biblioteca?.arquivosNaLixeira.isEmpty ?? true) && tarefasNaLixeira.isEmpty && midiasNaLixeira.isEmpty && pastasNaLixeira.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "trash",
                    titulo: "A lixeira está vazia",
                    mensagem: "Arquivos movidos da biblioteca aparecerão aqui e poderão ser recuperados."
                )
                .frame(minHeight: 280)
                .cartaoPapagaio()
            } else if arquivosFiltrados.isEmpty && tarefasNaLixeira.isEmpty && midiasNaLixeira.isEmpty && pastasNaLixeira.isEmpty {
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

                    ForEach(pastasNaLixeira) { item in
                        CartaoDePastaNaLixeira(
                            item: item,
                            conversas: conversasDa(item),
                            aoRestaurar: { restaurarPasta(item) },
                            aoRestaurarConversa: { arquivo in
                                restaurarConversaDaPasta(arquivo, de: item)
                            },
                            aoApagarDefinitivamente: {
                                LixeiraDePastas.remover(item)
                                atualizarPreferenciasVisuais()
                            }
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

    private func cartaoDeConversa(_ arquivo: Arquivo, biblioteca: Biblioteca) -> some View {
        CartaoDeConversa(
            arquivo: arquivo,
            estado: biblioteca.estado(de: arquivo),
            progresso: biblioteca.progresso(de: arquivo),
            importado: biblioteca.importado(arquivo),
            processando: biblioteca.estaProcessando(arquivo),
            naFila: biblioteca.estaNaFila(arquivo),
            emOperacaoDeLixeira: biblioteca.estaEmOperacaoDeLixeira(arquivo),
            aoReprocessar: { biblioteca.enfileirarProcessamento(arquivo) },
            aoRenomear: { novoTitulo in
                Task { await biblioteca.renomear(arquivo, para: novoTitulo) }
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
            aoDuplicar: { duplicar(arquivo, na: biblioteca) },
            urlDeAudio: biblioteca.audio(de: arquivo),
            menuAberto: menuAberto == arquivo.id,
            aoAlternarMenu: { alternarMenu(de: arquivo) },
            aoFecharMenu: fecharMenu,
            aoAlterarPreferenciasVisuais: atualizarPreferenciasVisuais,
            aoMoverParaLixeira: {
                Task { await biblioteca.moverParaLixeira(arquivo) }
            },
            aoAbrirPasta: { nome in
                withAnimation(.snappy(duration: 0.2)) {
                    filtroSelecionado = .pastas
                    pastaSelecionada = nome
                    atalhoSelecionado = nil
                    limparAtalhoVisual()
                }
            }
        )
    }

    private func duplicar(_ arquivo: Arquivo, na biblioteca: Biblioteca) {
        Task {
            guard let copia = await biblioteca.duplicar(arquivo) else { return }
            PreferenciasVisuaisDoArquivo.copiar(de: arquivo.id, para: copia.id)
            atualizarPreferenciasVisuais()
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
