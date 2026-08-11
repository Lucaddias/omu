import SwiftUI

struct EditorDeInformacoesDoCard: View {
    let modo: Modo
    @Binding var titulo: String
    @Binding var entrevistado: String
    @Binding var emailDoEntrevistado: String
    @Binding var entrevistadores: String
    @Binding var emailDosEntrevistadores: String
    @Binding var descricao: String
    @Binding var formato: String
    @Binding var participantes: String
    @Binding var data: Date
    @Binding var duracao: String
    let aoCancelar: () -> Void
    let aoSalvar: () -> Void

    enum Modo {
        case nova
        case edicao

        var titulo: String {
            switch self {
            case .nova: "Nova Entrevista"
            case .edicao: "Editar informações"
            }
        }

        var subtitulo: String {
            switch self {
            case .nova: "Configure os detalhes da sua nova sessão"
            case .edicao: "Atualize os dados que aparecem no card e no cabeçalho."
            }
        }

        var botao: String {
            switch self {
            // Mesmo rótulo nos dois modos: o formulário não leva a lugar
            // nenhum, ele grava a ficha e fecha. "Continuar" prometia uma
            // próxima etapa que não existe.
            case .nova: "Salvar informações"
            case .edicao: "Salvar informações"
            }
        }
    }

    private var podeSalvar: Bool {
        !titulo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(modo.titulo)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PapagaioTema.texto)
                    Text(modo.subtitulo)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }

                Spacer()

                // Na cor de destaque, como os demais controles da folha: em
                // cinza ele lia como glifo do sistema, não como botão do app.
                BotaoCircularPapagaio(
                    simbolo: "xmark",
                    ajuda: "Fechar sem salvar",
                    destaque: true,
                    acao: aoCancelar
                )
            }
            .padding(PapagaioTema.Espaco.secao)

            SeparadorPapagaio()

            // Só o miolo rola: cabeçalho e botão de salvar ficam fixos, então
            // a ação principal nunca sai da tela por causa do tamanho do
            // formulário nem da altura da janela.
            ScrollView {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
                campo("Título da entrevista") {
                    TextField("Ex.: Entrevista com Stakeholders - UX Research", text: $titulo)
                        .textFieldStyle(.plain)
                        .campoPapagaio()
                }

                // A descrição pertence ao título, não ao rodapé do formulário:
                // é a continuação do "sobre o que é esta conversa". Em largura
                // cheia e com várias linhas, porque uma linha só forçava a
                // pessoa a resumir o resumo.
                campo("Descrição (opcional)") {
                    TextField(
                        "Adicione uma descrição opcional",
                        text: $descricao,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .campoPapagaio(altura: nil)
                }

                PessoasDaFichaDaEntrevista(
                    titulo: "Entrevistador(es)",
                    nome: $entrevistadores,
                    email: $emailDosEntrevistadores,
                    placeholderNome: "Ex.: João Santos",
                    placeholderEmail: "joao.santos@empresa.com"
                )

                PessoasDaFichaDaEntrevista(
                    titulo: "Entrevistado(s)",
                    nome: $entrevistado,
                    email: $emailDoEntrevistado,
                    placeholderNome: "Ex.: Ana Silva",
                    placeholderEmail: "ana.silva@email.com"
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                        participantesEDuracao
                    }

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                        participantesEDuracao
                    }
                }

                campo("Formato") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PapagaioTema.Espaco.curto) {
                            botoesDeFormato
                        }

                        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                            botoesDeFormato
                        }
                    }
                }

                campoDeData
                }
                .padding(PapagaioTema.Espaco.secao)
            }
            .scrollBounceBehavior(.basedOnSize)

            SeparadorPapagaio()

            // Sem "Cancelar" no rodapé: o X do topo já fecha sem salvar, e
            // dois caminhos para a mesma saída só dividem a atenção com a
            // ação principal.
            HStack(spacing: PapagaioTema.Espaco.medio) {
                Spacer()

                // Sem ícone: a seta sugeria "avançar para a próxima etapa", e
                // aqui não há próxima etapa — o botão salva e fecha.
                Button(modo.botao, action: aoSalvar)
                    .buttonStyle(BotaoPrincipalPapagaio())
                    .disabled(!podeSalvar)

                Spacer()
            }
            .padding(PapagaioTema.Espaco.secao)
            .background(PapagaioTema.superficieSuave.opacity(0.45))
        }
        .frame(minWidth: 360, idealWidth: 720, maxWidth: 780, alignment: .leading)
        // Teto de altura para a folha nunca passar da janela: acima disso o
        // miolo rola em vez de a folha ser cortada nas bordas.
        .frame(maxHeight: 720)
        .background(PapagaioTema.fundo, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
    }

    /// Participantes sai da soma de entrevistados e entrevistadores, e a
    /// duração vem do próprio arquivo de áudio. Os dois eram campos livres, o
    /// que permitia salvar "3 participantes" numa conversa com cinco nomes na
    /// ficha — dado editável que contradiz outro dado da mesma tela.
    private var participantesCalculados: Int {
        max(1, quantidadeDeLinhas(entrevistado) + quantidadeDeLinhas(entrevistadores))
    }

    private func quantidadeDeLinhas(_ texto: String) -> Int {
        texto
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    private var participantesEDuracao: some View {
        Group {
            campo("Participantes") {
                valorCalculado(
                    participantesCalculados == 1
                        ? "1 participante"
                        : "\(participantesCalculados) participantes",
                    simbolo: participantesCalculados == 1 ? "person" : "person.2",
                    ajuda: "Somado a partir dos nomes de entrevistado(s) e entrevistador(es)."
                )
            }

            campo("Duração") {
                valorCalculado(
                    duracao.isEmpty ? "—" : duracao,
                    simbolo: "clock",
                    ajuda: "Vem da duração do áudio desta conversa."
                )
            }
        }
    }

    /// Mesma moldura dos campos, em tom de leitura: parece um dado da ficha,
    /// não um campo que a pessoa tenta clicar e não responde.
    private func valorCalculado(_ texto: String, simbolo: String, ajuda: String) -> some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
            Text(texto)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(PapagaioTema.textoSecundario)
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .frame(height: PapagaioTema.Altura.padrao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda.opacity(0.6), lineWidth: 1)
        }
        .help(ajuda)
        .accessibilityLabel("\(texto). \(ajuda)")
    }

    private var botoesDeFormato: some View {
        Group {
                        BotaoDeFormatoDaEntrevista(
                            titulo: "Online",
                            simbolo: "video",
                            selecionado: formato == "Online"
                        ) {
                            formato = "Online"
                        }

                        BotaoDeFormatoDaEntrevista(
                            titulo: "Presencial",
                            simbolo: "mappin.and.ellipse",
                            selecionado: formato == "Presencial"
                        ) {
                            formato = "Presencial"
                        }
        }
    }

    private var campoDeData: some View {
        campo("Data") {
            CampoDeDataPapagaio(data: $data, rotuloAcessivel: "Data da entrevista")
        }
    }

    private func campo<Conteudo: View>(_ titulo: String, @ViewBuilder conteudo: () -> Conteudo) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text(titulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
            conteudo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PessoasDaFichaDaEntrevista: View {
    let titulo: String
    @Binding var nome: String
    @Binding var email: String
    let placeholderNome: String
    let placeholderEmail: String

    private var quantidade: Int {
        max(linhas(nome).count, linhas(email).count, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Text(titulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .textCase(.uppercase)

            ForEach(0..<quantidade, id: \.self) { indice in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                        camposDaPessoa(indice)
                    }

                    VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                        camposDaPessoa(indice)
                    }
                }
            }

            Button {
                adicionarPessoa()
            } label: {
                Label("Adicionar pessoa", systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func camposDaPessoa(_ indice: Int) -> some View {
        Group {
            campo("Nome") {
                TextField(placeholderNome, text: bindingLinha($nome, indice: indice))
                    .textFieldStyle(.plain)
                    .campoPapagaio()
            }

            campo("E-mail") {
                TextField(placeholderEmail, text: bindingLinha($email, indice: indice))
                    .textFieldStyle(.plain)
                    .campoPapagaio()
            }

            if quantidade > 1 {
                        Button {
                            removerPessoa(indice)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(PapagaioTema.textoSecundario)
                                .frame(width: 36, height: 42)
                        }
                        .buttonStyle(.plain)
                        .help("Remover pessoa")
            }
        }
    }

    private func campo<Conteudo: View>(_ titulo: String, @ViewBuilder conteudo: () -> Conteudo) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            Text(titulo)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
            conteudo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bindingLinha(_ texto: Binding<String>, indice: Int) -> Binding<String> {
        Binding(
            get: { valorDaLinha(texto.wrappedValue, indice: indice) },
            set: { novoValor in
                texto.wrappedValue = definirLinha(texto.wrappedValue, indice: indice, valor: novoValor)
            }
        )
    }

    private func adicionarPessoa() {
        nome = adicionarLinha(nome)
        email = adicionarLinha(email)
    }

    private func removerPessoa(_ indice: Int) {
        nome = removerLinha(nome, indice: indice)
        email = removerLinha(email, indice: indice)
    }

    private func linhas(_ texto: String) -> [String] {
        texto.components(separatedBy: .newlines)
    }

    private func valorDaLinha(_ texto: String, indice: Int) -> String {
        let valores = linhas(texto)
        guard valores.indices.contains(indice) else { return "" }
        return valores[indice]
    }

    private func definirLinha(_ texto: String, indice: Int, valor: String) -> String {
        var valores = linhas(texto)
        while valores.count <= indice { valores.append("") }
        valores[indice] = valor
        return valores.joined(separator: "\n")
    }

    private func adicionarLinha(_ texto: String) -> String {
        texto.isEmpty ? "\n" : texto + "\n"
    }

    private func removerLinha(_ texto: String, indice: Int) -> String {
        var valores = linhas(texto)
        guard valores.indices.contains(indice) else { return texto }
        valores.remove(at: indice)
        return valores.joined(separator: "\n")
    }
}

struct BotaoDeFormatoDaEntrevista: View {
    let titulo: String
    let simbolo: String
    let selecionado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Label(titulo, systemImage: simbolo)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selecionado ? PapagaioTema.textoSobrePrimario : PapagaioTema.textoSecundario)
                .frame(maxWidth: .infinity)
                .frame(height: PapagaioTema.Altura.padrao)
                .background(
                    selecionado ? PapagaioTema.preenchimentoPrimario : PapagaioTema.superficie,
                    in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        .stroke(selecionado ? Color.clear : PapagaioTema.borda, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
