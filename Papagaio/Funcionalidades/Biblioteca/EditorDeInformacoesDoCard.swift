import SwiftUI

struct EditorDeInformacoesDoCard: View {
    /// Exemplo neutro e válido, usado ao cadastrar alguém da equipe.
    ///
    /// Não é um domínio corporativo real: o formulário não deve sugerir que a
    /// pessoa precise ter e-mail em uma empresa para preencher a ficha.
    static let emailSugeridoDaEquipe = "joao.santos@email.com"

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
    /// Só em arquivos importados: quando o arquivo entrou no app, distinto
    /// de `data` — que aqui já é a data real da gravação, lida do arquivo
    /// original. Somente leitura: é um registro do que aconteceu, não algo
    /// que se edita.
    var importadoEm: Date? = nil
    let aoCancelar: () -> Void
    let aoSalvar: () -> Void

    enum Modo {
        case nova
        case edicao

        var titulo: String {
            switch self {
            case .nova: "Nova Entrevista".localized
            case .edicao: "Editar informações".localized
            }
        }

        var subtitulo: String {
            switch self {
            case .nova: "Configure os detalhes da sua nova sessão".localized
            case .edicao: "Atualize os dados que aparecem no card e no cabeçalho.".localized
            }
        }

        var botao: String {
            switch self {
            // Mesmo rótulo nos dois modos: o formulário não leva a lugar
            // nenhum, ele grava a ficha e fecha. "Continuar" prometia uma
            // próxima etapa que não existe.
            case .nova: "Salvar informações".localized
            case .edicao: "Salvar informações".localized
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(modo.subtitulo)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Spacer()

                // Na cor de destaque, como os demais controles da folha: em
                // cinza ele lia como glifo do sistema, não como botão do app.
                BotaoCircularPapagaio(
                    simbolo: "xmark",
                    ajuda: "Fechar sem salvar".localized,
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
                campo("Título da entrevista".localized, obrigatorio: true) {
                    TextField("Ex.: Entrevista com Stakeholders - UX Research".localized, text: $titulo)
                        .textFieldStyle(.plain)
                        .campoPapagaio()
                }

                // A descrição pertence ao título, não ao rodapé do formulário:
                // é a continuação do "sobre o que é esta conversa". Em largura
                // cheia e com várias linhas, porque uma linha só forçava a
                // pessoa a resumir o resumo.
                campo("Descrição".localized) {
                    TextField(
                        "Adicione uma descrição".localized,
                        text: $descricao,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .campoPapagaio(altura: nil)
                }

                PessoasDaFichaDaEntrevista(
                    titulo: "Equipe".localized,
                    nome: $entrevistadores,
                    email: $emailDosEntrevistadores,
                    placeholderNome: "Ex.: João Santos".localized,
                    placeholderEmail: Self.emailSugeridoDaEquipe
                )

                PessoasDaFichaDaEntrevista(
                    titulo: "Externos".localized,
                    nome: $entrevistado,
                    email: $emailDoEntrevistado,
                    placeholderNome: "Ex.: Ana Silva".localized,
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
    /// Zero enquanto ninguém foi preenchido: o campo mostra o que a ficha tem,
    /// e "1 participante" com o formulário em branco é um número inventado.
    private var participantesCalculados: Int {
        quantidadeDeLinhas(entrevistado) + quantidadeDeLinhas(entrevistadores)
    }

    private var textoDeParticipantes: String {
        switch participantesCalculados {
        case 0: "Nenhum informado".localized
        case 1: "1 participante".localized
        default: "%d participantes".localized(participantesCalculados)
        }
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
            campo("Participantes".localized) {
                valorCalculado(
                    textoDeParticipantes,
                    simbolo: participantesCalculados > 1 ? "person.2" : "person",
                    ajuda: "Somado a partir dos nomes de Equipe e Externos.".localized
                )
            }

            campo("Duração".localized) {
                valorCalculado(
                    duracao.isEmpty ? "—" : duracao,
                    simbolo: "clock",
                    ajuda: "Vem da duração do áudio desta conversa.".localized
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
                    .minimumScaleFactor(0.82)
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
        .accessibilityLabel("%@. %@".localized(texto, ajuda))
    }

    private var campoDeData: some View {
        campo("Data".localized) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                CampoDeDataPapagaio(data: $data, rotuloAcessivel: "Data da entrevista".localized)

                // Só aparece em arquivos importados: aqui "Data" já é a data
                // real da gravação, e esta legenda deixa claro que ela não é
                // o dia em que o arquivo apareceu na biblioteca — os dois
                // podem ser bem diferentes.
                if let importadoEm {
                    Text("Importado para o app em %@".localized(DataDigitada.texto(de: importadoEm)))
                        .font(.caption)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            }
        }
    }

    private func campo<Conteudo: View>(
        _ titulo: String,
        obrigatorio: Bool = false,
        @ViewBuilder conteudo: () -> Conteudo
    ) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
            HStack(spacing: 2) {
                Text(titulo)
                if obrigatorio {
                    Text("*")
                        .foregroundStyle(PapagaioTema.perigo)
                        .accessibilityLabel("obrigatório".localized)
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(PapagaioTema.textoSecundario)
            conteudo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// O avatar clicável do formulário: troca ou remove a foto da pessoa.
///
/// Guardado pelo **nome**, então a foto escolhida aqui vale para todas as
/// conversas com aquela pessoa — que é o que se espera de quem entrevista a
/// mesma equipe várias vezes.
struct BotaoDeFotoDaPessoa: View {
    let nome: String

    /// Força o redesenho depois de escolher: o avatar lê de um cache, e sem
    /// esta mudança de estado a nova foto só apareceria ao reabrir a folha.
    @State private var versao = 0

    private var nomeLimpo: String {
        nome.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            AvatarDePessoa(nome: nomeLimpo.isEmpty ? "?" : nomeLimpo, diametro: 42)
                .id(versao)

            VStack(alignment: .leading, spacing: 2) {
                Button((FotosDePessoas.url(de: nomeLimpo) == nil ? "Escolher…" : "Trocar…").localized) {
                    guard !nomeLimpo.isEmpty else { return }
                    if FotosDePessoas.escolherImagem(para: nomeLimpo) { versao += 1 }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)

                if FotosDePessoas.url(de: nomeLimpo) != nil {
                    Button("Remover".localized) {
                        FotosDePessoas.remover(de: nomeLimpo)
                        versao += 1
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.perigo)
                }
            }
        }
        // Sem nome não há onde guardar a foto — a chave é o próprio nome.
        .opacity(nomeLimpo.isEmpty ? 0.45 : 1)
        .help(nomeLimpo.isEmpty ? "Escreva o nome primeiro".localized : "Foto de %@".localized(nomeLimpo))
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
                Label("Adicionar pessoa".localized, systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func camposDaPessoa(_ indice: Int) -> some View {
        Group {
            // A foto vive ao lado do nome, e não numa tela à parte: é aqui que
            // a pessoa está pensando naquele participante. O avatar já mostra
            // as iniciais, então o botão nunca é um vazio — é uma troca.
            campo("Foto".localized) {
                BotaoDeFotoDaPessoa(nome: valorDaLinha(nome, indice: indice))
            }
            .fixedSize()

            campo("Nome".localized) {
                TextField(placeholderNome, text: bindingLinha($nome, indice: indice))
                    .textFieldStyle(.plain)
                    .campoPapagaio()
            }

            campo("E-mail".localized) {
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
                        .help("Remover pessoa".localized)
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
            Label(titulo.localized, systemImage: simbolo)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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
