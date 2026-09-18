import PapagaioCore
import SwiftUI

/// Preferências que mudam a aparência do app e o gatilho do pipeline local,
/// sem criar um caminho de processamento paralelo.
struct ConfiguracoesView: View {
    @Binding var processamentoAutomatico: Bool
    @Binding var exibirFichaAutomaticamente: Bool
    /// Quando ligado, texto falado em idioma diferente do sistema é traduzido
    /// localmente antes do resumo. Desligado preserva o idioma falado.
    @Binding var traducaoAutomatica: Bool
    @Binding var aparencia: AparenciaDoApp
    /// A conexão Granola viva do app. Quem a cria e a observa é a `ContentView`.
    var granola: GranolaViewModel?
    /// A conexão Google Calendar viva do app.
    var googleCalendar: GoogleCalendarViewModel?
    /// Necessária para importar; `nil` enquanto a biblioteca não abriu.
    var biblioteca: Biblioteca?
    /// Mesma chave lida pelo `PapagaioApp`, que é quem abre e fecha o painel.
    @AppStorage("painelFlutuanteDuranteGravacao") private var painelFlutuante = true
    @AppStorage("mostrarPorcentagemConfianca") private var mostrarPorcentagemConfianca = true
    /// Reuniões marcadas para importar, pelos ids do Granola.
    @State private var selecionadas: Set<String> = []

    private var processamentoPausado: Binding<Bool> {
        Binding(
            get: { !processamentoAutomatico },
            set: { processamentoAutomatico = !$0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                cabecalhoDeConfiguracoes

                secaoDeAparencia

                SecaoDePersonalizacaoDosCartoes()

                secaoDeTranscricao

                secaoDeGranola

                secaoDeGoogleCalendar
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
        }
        .background(PapagaioTema.fundo)
    }

    /// O cabeçalho da tela, no mesmo molde do cartão de "Biblioteca de
    /// Conversas" e do de "Lixeira": título e um botão "i" com a explicação
    /// — em vez do subtítulo fixo, texto que se lê uma vez e depois só
    /// ocupa espaço — dentro de um cartão com borda e sombra.
    private var cabecalhoDeConfiguracoes: some View {
        HStack(alignment: .center, spacing: PapagaioTema.Espaco.medio) {
            Text("Configurações".localized)
                .font(PapagaioTema.Tipo.tituloDePagina)
                .foregroundStyle(PapagaioTema.texto)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)

            // Nudge de +3pt: mesmo ajuste de
            // `BibliotecaHomeView.cabecalhoDaBiblioteca` — o círculo do "i"
            // ficava acima do centro óptico da letra bold de 30pt mesmo com
            // `alignment: .center`.
            BotaoDeAjudaPapagaio(
                texto: "Aparência do app, os cartões da biblioteca e quando as transcrições começam.".localized,
                ajuda: "Sobre Configurações".localized,
                largura: 300
            )
            .offset(y: 3)

            Spacer(minLength: 0)
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var secaoDeAparencia: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            Label("Aparência".localized, systemImage: "paintpalette")
                .font(PapagaioTema.Tipo.tituloDeSecao)
                .foregroundStyle(PapagaioTema.destaqueEscuro)

            SeparadorPapagaio()

            // Amostras em vez de um menu: a escolha é visual, então mostrar as
            // três superfícies lado a lado responde à pergunta sem obrigar a
            // aplicar e desfazer para comparar.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                    opcoesDeAparencia
                }

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                    opcoesDeAparencia
                }
            }

            Text(aparencia.descricao.localized)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PapagaioTema.Espaco.secao)
        // Largura cheia: os 760pt fixos deixavam metade da janela vazia à
        // direita e faziam cada seção terminar num ponto diferente do painel
        // de baixo. O limite de leitura já vem do `larguraDeConteudoPapagaio`
        // da página.
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartaoPapagaio()
    }

    private var opcoesDeAparencia: some View {
        ForEach(AparenciaDoApp.allCases) { opcao in
            AmostraDeAparencia(
                opcao: opcao,
                selecionada: aparencia == opcao
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    aparencia = opcao
                }
            }
        }
    }

    private var secaoDeTranscricao: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            Label("Preferências".localized, systemImage: "text.quote")
                .font(PapagaioTema.Tipo.tituloDeSecao)
                .foregroundStyle(PapagaioTema.destaqueEscuro)

            SeparadorPapagaio()

            Toggle(isOn: processamentoPausado) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Pausar transcrições e resumos automáticos".localized)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Gravações e anexos ficarão prontos para transcrever. Você inicia o processamento pela aba Transcrição.".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $traducaoAutomatica) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Traduzir automaticamente para o idioma do sistema".localized)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Quando ligado, transcrições e resumos em outro idioma são traduzidos localmente para português ou inglês. Quando desligado, o idioma falado é preservado.".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(PapagaioTema.preenchimentoPrimario)

            Toggle(isOn: $painelFlutuante) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Mostrar painel flutuante durante a gravação".localized)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Uma janela pequena, sempre visível por cima dos outros apps, para anotar, pausar e finalizar sem voltar ao Ōmu.".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(PapagaioTema.preenchimentoPrimario)

            Toggle(isOn: $exibirFichaAutomaticamente) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Exibir ficha automaticamente após processar".localized)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Quando desligado, a ficha não abre automaticamente ao fim do processamento — ideal quando a ficha já foi preenchida pelo calendário.".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(PapagaioTema.preenchimentoPrimario)
            .accessibilityHint(
                "Quando ativado, novos áudios não entram na fila até você selecionar Transcrever.".localized
            )

            Toggle(isOn: $mostrarPorcentagemConfianca) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Mostrar porcentagem de confiança".localized)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Quando desligado, as palavras continuam destacadas por cor, mas o percentual não aparece.".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(PapagaioTema.preenchimentoPrimario)
        }
        .padding(PapagaioTema.Espaco.secao)
        // Largura cheia: os 760pt fixos deixavam metade da janela vazia à
        // direita e faziam cada seção terminar num ponto diferente do painel
        // de baixo. O limite de leitura já vem do `larguraDeConteudoPapagaio`
        // da página.
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartaoPapagaio()
    }

    // MARK: - Granola

    @ViewBuilder
    private var secaoDeGranola: some View {
        if let granola {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Label("Granola", systemImage: "link")
                    .font(PapagaioTema.Tipo.tituloDeSecao)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)

                SeparadorPapagaio()

                estadoDaConexao(granola)

                if granola.estado.conectado {
                    listaDeReunioes(granola)
                }

                Text("Conectado, o Ōmu pode ver suas reuniões do Granola e importá-las para a biblioteca — notas e resumo sempre; a transcrição quando o seu plano incluir. Nada é enviado para fora do seu Mac além do fluxo de autorização e das chamadas ao próprio Granola.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PapagaioTema.Espaco.secao)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cartaoPapagaio()
        } else {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Label("Granola", systemImage: "link")
                    .font(PapagaioTema.Tipo.tituloDeSecao)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)

                SeparadorPapagaio()

                Text("A biblioteca ainda está abrindo — a conexão com o Granola aparece aqui em instantes.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
            .padding(PapagaioTema.Espaco.secao)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cartaoPapagaio()
        }
    }

    @ViewBuilder
    private var secaoDeGoogleCalendar: some View {
        if let googleCalendar {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Label("Google Calendar", systemImage: "calendar")
                    .font(PapagaioTema.Tipo.tituloDeSecao)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)

                SeparadorPapagaio()

                estadoDaConexaoGoogleCalendar(googleCalendar)

                if googleCalendar.estado.conectado {
                    listaDeReunioesGoogleCalendar(googleCalendar)
                }

                Text("Conectado, o Ōmu pode ver suas reuniões futuras do Google Calendar e importá-las para a biblioteca — apenas título, data e participantes. Nada é enviado para fora do seu Mac além do fluxo de autorização e das chamadas ao próprio Google.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PapagaioTema.Espaco.secao)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cartaoPapagaio()
        } else {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Label("Google Calendar", systemImage: "calendar")
                    .font(PapagaioTema.Tipo.tituloDeSecao)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)

                SeparadorPapagaio()

                Text("A biblioteca ainda está abrindo — a conexão com o Google Calendar aparece aqui em instantes.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
            .padding(PapagaioTema.Espaco.secao)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cartaoPapagaio()
        }
    }

    @ViewBuilder
    private func estadoDaConexao(_ granola: GranolaViewModel) -> some View {
        switch granola.estado {
        case .desconectado:
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                Text("Importe reuniões do Granola para a biblioteca, com transcrição quando o plano permitir.".localized)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await granola.conectar() }
                } label: {
                    Label("Conectar conta Granola…".localized, systemImage: "person.badge.plus")
                }
                .help("Abre o navegador do macOS para autorizar o Ōmu na sua conta do Granola.".localized)
            }

        case .conectando:
            HStack(spacing: PapagaioTema.Espaco.medio) {
                ProgressView()
                    .controlSize(.small)
                Text("Autorize no navegador e volte ao Ōmu…".localized)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }

        case let .falhou(mensagem):
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                Label(mensagem.localized, systemImage: "exclamationmark.triangle.fill")
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.perigo)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await granola.conectar() }
                } label: {
                    Label("Tentar novamente".localized, systemImage: "arrow.clockwise")
                }
            }

        case let .conectado(conta):
            HStack(spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(conta.email)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)

                    if let workspace = conta.workspace, !workspace.isEmpty {
                        Text("\("Workspace".localized) \(workspace)")
                            .font(PapagaioTema.Tipo.apoio)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                    }
                }

                Spacer()

                Button("Desconectar".localized) {
                    selecionadas.removeAll()
                    Task { await granola.desconectar() }
                }
                .buttonStyle(.bordered)
                .help("Apaga as credenciais do Granola do Keychain.".localized)
            }
        }
    }

    @ViewBuilder
    private func listaDeReunioes(_ granola: GranolaViewModel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Reuniões acessíveis".localized)
                    .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                Spacer()

                Button {
                    Task { await granola.recarregar() }
                } label: {
                    Label("Atualizar".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.destaque)
            }

            if granola.carregandoReunioes {
                HStack(spacing: PapagaioTema.Espaco.medio) {
                    ProgressView().controlSize(.small)
                    Text("Carregando reuniões…".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            } else if granola.reunioes.isEmpty {
                Text("Nenhuma reunião acessível nesta conta.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            } else {
                VStack(spacing: PapagaioTema.Espaco.minimo) {
                    ForEach(granola.reunioes.prefix(20)) { reuniao in
                        linhaDeReuniao(reuniao)
                    }
                }
            }

            Button {
                importarSelecionadas(granola)
            } label: {
                if granola.importando {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        "Importar selecionadas".localized,
                        systemImage: "square.and.arrow.down"
                    )
                }
            }
            .disabled(biblioteca == nil || selecionadas.isEmpty || granola.importando)
            .help(
                biblioteca == nil
                    ? "A biblioteca ainda não abriu.".localized
                    : "Importa as reuniões marcadas para a biblioteca.".localized
            )

            if let falha = granola.falhaDeImportacao {
                Label(falha.localized, systemImage: "exclamationmark.triangle.fill")
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.perigo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func linhaDeReuniao(_ reuniao: ReuniaoExterna) -> some View {
        let marcada = Binding(
            get: { selecionadas.contains(reuniao.id) },
            set: { marcada in
                if marcada {
                    selecionadas.insert(reuniao.id)
                } else {
                    selecionadas.remove(reuniao.id)
                }
            }
        )

        return Toggle(isOn: marcada) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(reuniao.titulo)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Text(reuniao.data.formatted(date: .abbreviated, time: .omitted))
                    if !reuniao.participantesNomes.isEmpty {
                        Text("·")
                        Text(reuniao.participantesNomes.prefix(3).joined(separator: ", "))
                    }
                }
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.textoSecundario)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func importarSelecionadas(_ granola: GranolaViewModel) {
        let ids = selecionadas
        Task {
            guard let biblioteca else { return }
            let salvas = await granola.importar(ids, biblioteca: biblioteca)
            if salvas > 0 {
                selecionadas.subtract(ids)
            }
        }
    }

    @ViewBuilder
    private func estadoDaConexaoGoogleCalendar(_ googleCalendar: GoogleCalendarViewModel?) -> some View {
        if let googleCalendar {
        switch googleCalendar.estado {
        case .desconectado:
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                Text("Importe reuniões futuras do Google Calendar para a biblioteca.".localized)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)

                if !CredenciaisGoogle.estaConfigurado {
                    Label("Client ID/Secret não configurados".localized, systemImage: "exclamationmark.triangle.fill")
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.aviso)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await googleCalendar.conectar(biblioteca: biblioteca!) }
                } label: {
                    Label("Conectar conta Google…".localized, systemImage: "person.badge.plus")
                }
                .disabled(!CredenciaisGoogle.estaConfigurado)
                .help("Abre o navegador para autorizar o Ōmu na sua conta Google.".localized)
            }

        case .conectando:
            HStack(spacing: PapagaioTema.Espaco.medio) {
                ProgressView()
                    .controlSize(.small)
                Text("Autorize no navegador e volte ao Ōmu…".localized)
                    .font(PapagaioTema.Tipo.corpo)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }

        case let .falhou(mensagem):
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                Label(mensagem.localized, systemImage: "exclamationmark.triangle.fill")
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.perigo)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await googleCalendar.conectar(biblioteca: biblioteca!) }
                } label: {
                    Label("Tentar novamente".localized, systemImage: "arrow.clockwise")
                }
            }

        case let .conectado(conta):
            HStack(spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(conta.email)
                        .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                }

                Spacer()

                Button("Desconectar".localized) {
                    Task { await googleCalendar.desconectar() }
                }
                .buttonStyle(.bordered)
                .help("Apaga as credenciais do Google Calendar do Keychain.".localized)
            }
        }
    }
}

    @ViewBuilder
    private func listaDeReunioesGoogleCalendar(_ googleCalendar: GoogleCalendarViewModel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Reuniões futuras (próximas 24 horas)".localized)
                    .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                Spacer()

                Button {
                    Task { await googleCalendar.recarregar() }
                } label: {
                    Label("Atualizar".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(PapagaioTema.Tipo.apoio)
                .foregroundStyle(PapagaioTema.destaque)
            }

            if googleCalendar.carregandoReunioes {
                HStack(spacing: PapagaioTema.Espaco.medio) {
                    ProgressView().controlSize(.small)
                    Text("Carregando reuniões…".localized)
                        .font(PapagaioTema.Tipo.apoio)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            } else if googleCalendar.reunioesPendentes.isEmpty {
                Text("Nenhuma reunião futura encontrada.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            } else {
                Text("%d reunião(ões) com participantes — sincronizadas automaticamente na aba Calendário da biblioteca.".localized(googleCalendar.reunioesPendentes.count))
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let falha = googleCalendar.falhaDeImportacao {
                Label(falha.localized, systemImage: "exclamationmark.triangle.fill")
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.perigo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

/// Botão de tema com uma miniatura da interface no esquema correspondente.
private struct AmostraDeAparencia: View {
    let opcao: AparenciaDoApp
    let selecionada: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(spacing: PapagaioTema.Espaco.curto) {
                miniatura

                Label(opcao.titulo.localized, systemImage: opcao.simbolo)
                    .font(PapagaioTema.Tipo.apoio.weight(selecionada ? .semibold : .regular))
                    .foregroundStyle(selecionada ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(PapagaioTema.Espaco.medio)
            .frame(maxWidth: .infinity)
            .background(
                selecionada ? PapagaioTema.destaqueSuave.opacity(0.55) : Color.clear,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(
                        selecionada ? PapagaioTema.destaque : PapagaioTema.borda,
                        lineWidth: selecionada ? 2 : 1
                    )
            }
            // A forma vai **dentro** do rótulo, e não no botão.
            //
            // Fora, ela descreve o botão para quem o contém — o botão continua
            // decidindo o próprio alvo pelo desenho do rótulo, que aqui é a
            // miniatura e o texto. Na opção não selecionada, cujo fundo é
            // transparente, sobrava só isso de clicável e o resto do cartão era
            // buraco. Dentro, ela é o alvo.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(opcao.descricao.localized)
        .accessibilityLabel("Aparência %@".localized(opcao.titulo.localized))
        .accessibilityHint(opcao.descricao.localized)
        .accessibilityAddTraits(selecionada ? [.isSelected] : [])
    }

    /// Miniatura desenhada com cores fixas — ela precisa mostrar como o tema
    /// **ficaria**, então não pode usar os tokens dinâmicos: eles responderiam à
    /// aparência atual e deixariam as três amostras idênticas.
    private var miniatura: some View {
        let escuro = opcao == .escuro
        let claroFundo = Color(red: 0.980, green: 0.976, blue: 0.969)
        let escuroFundo = Color(red: 0.086, green: 0.080, blue: 0.075)
        let superficie = escuro ? Color(red: 0.137, green: 0.129, blue: 0.122) : .white
        let traco = escuro ? Color(red: 0.286, green: 0.247, blue: 0.227) : Color(red: 0.910, green: 0.796, blue: 0.761)
        let realce = escuro ? Color(red: 1.000, green: 0.576, blue: 0.435) : Color(red: 0.663, green: 0.278, blue: 0.161)

        return ZStack {
            if opcao == .sistema {
                // Metade e metade: comunica "os dois, conforme o Mac".
                HStack(spacing: 0) {
                    claroFundo
                    escuroFundo
                }
            } else {
                escuro ? escuroFundo : claroFundo
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Capsule()
                    .fill(realce)
                    .frame(width: 34, height: 6)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(opcao == .sistema ? Color.white.opacity(0.9) : superficie)
                    .frame(height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(traco, lineWidth: 1)
}
        }  // close ZStack
            .padding(PapagaioTema.Espaco.curto)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
}
