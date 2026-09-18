import AppKit
import SwiftUI

struct InformacaoDaPasta: Identifiable {
    let nome: String
    let quantidade: Int
    /// Quando a pasta foi criada. `nil` nas criadas antes desta versão.
    let criadaEm: Date?

    var id: String { nome }
}

struct GradeDePastas: View {
    let pastas: [InformacaoDaPasta]
    @Binding var selecionada: String?
    let aoCriarPasta: () -> Void
    let aoApagarPasta: (String) -> Void
    let aoRenomearPasta: (String, String) -> Void
    let aoBaixarPasta: (String) -> Void
    let aoCompartilharPasta: (String) -> Void
    /// A grade está recortada pelo atalho Favoritos.
    var apenasFavoritas = false
    /// Esconde o botão "Nova pasta" — usado quando a grade aparece dentro de
    /// um resultado de busca, onde criar pasta não é o que se procura.
    var ocultarCriacao = false

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            // Sem o título "Pastas": o filtro logo acima já está marcado como
            // Pastas, e repetir a palavra a 40pt de distância não informa nada.
            // O botão herda a posição dele, à esquerda, onde a leitura começa.
            if !ocultarCriacao {
                // Mesma linha de sempre, só que o botão foi para a direita —
                // o `Spacer` agora vem antes dele, não depois.
                HStack {
                    Spacer()

                    Button("Nova pasta".localized, systemImage: "folder.badge.plus", action: aoCriarPasta)
                        .buttonStyle(BotaoDeContornoPapagaio())
                }
            }

            if pastas.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: apenasFavoritas ? "star" : "folder",
                    titulo: (apenasFavoritas ? "Nenhuma pasta favorita" : "Nenhuma pasta ainda").localized,
                    mensagem: (apenasFavoritas
                        ? "Toque na estrela de uma pasta para ela aparecer aqui."
                        : "Crie uma pasta para organizar conversas por projeto, cliente ou tema.").localized
                )
                .frame(minHeight: 220)
                .cartaoPapagaio()
            } else {
                // Colunas mais estreitas e espaçamento menor: são fileiras de
                // 56pt, não cartões — com a grade antiga sobrariam vãos
                // enormes entre elas.
                let colunas = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: PapagaioTema.Espaco.medio, alignment: .top)]

                LazyVGrid(columns: colunas, spacing: PapagaioTema.Espaco.curto) {
                    ForEach(pastas) { pasta in
                        CartaoDePasta(
                            pasta: pasta,
                            selecionado: selecionada == pasta.nome,
                            aoApagar: { aoApagarPasta(pasta.nome) },
                            aoRenomear: { novo in aoRenomearPasta(pasta.nome, novo) },
                            aoBaixar: { aoBaixarPasta(pasta.nome) },
                            aoCompartilhar: { aoCompartilharPasta(pasta.nome) }
                        ) {
                            withAnimation(.snappy(duration: 0.18)) {
                                selecionada = pasta.nome
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Pastas da biblioteca".localized)
    }
}

struct CartaoDePasta: View {
    let pasta: InformacaoDaPasta
    let selecionado: Bool
    let aoApagar: () -> Void
    let aoRenomear: (String) -> Void
    let aoBaixar: () -> Void
    let aoCompartilhar: () -> Void
    let acao: () -> Void

    @State private var cor: Color = PapagaioTema.destaque
    @State private var semCor = false
    @State private var capa: URL?
    @State private var favorita = false
    @State private var escolhendoAparencia = false
    @State private var confirmandoExclusao = false
    @State private var menuAberto = false
    @State private var ajuste: AjusteDeImagem = .preencher

    // Mesma escolha dos cartões de conversa: "Com capa" pinta a fileira
    // inteira na cor da pasta; "Compacto" usa a superfície neutra do cartão
    // compacto, com a cor só na tarja da esquerda — a identidade das pastas
    // acompanha a dos cartões, e não fica descombinando quando a pessoa troca
    // o modelo em Configurações.
    @AppStorage(ModeloDeCartao.chave) private var modeloBruto = ModeloDeCartao.padrao.rawValue

    private var modelo: ModeloDeCartao {
        ModeloDeCartao(rawValue: modeloBruto) ?? .padrao
    }

    private var imagem: NSImage? {
        guard capa != nil else { return nil }
        return AparenciaDasPastas.imagem(de: pasta.nome)
    }

    /// A cor do texto da fileira no modelo "Com capa".
    ///
    /// Sem cor, a fileira é a própria superfície do tema — que já é escura no
    /// modo escuro. `textoLegivel` mede uma cor fixa e não enxerga a troca de
    /// aparência; aqui o certo é a cor de texto do tema.
    private var corDoTexto: Color {
        semCor ? PapagaioTema.texto : cor.textoLegivel
    }

    /// A cor do nome da pasta, nos dois modelos.
    ///
    /// "Com capa" com imagem é sempre branco (o véu escuro garante o
    /// contraste); sem imagem, segue `corDoTexto`. No compacto o fundo é
    /// neutro — mesma cor de texto de qualquer outro cartão desse modelo.
    private var corDoTextoPrincipal: Color {
        guard modelo == .comCapa else { return PapagaioTema.texto }
        return imagem == nil ? corDoTexto : .white
    }

    private var corDoTextoSecundario: Color {
        guard modelo == .comCapa else { return PapagaioTema.textoSecundario }
        return (imagem == nil ? corDoTexto : .white).opacity(0.8)
    }

    /// A borda da fileira: no compacto ela é a mesma moldura sutil dos
    /// cartões de conversa desse modelo, e não a lógica de "sem cor e sem
    /// imagem" que só faz sentido quando o fundo é a cor da pasta.
    private var corDaBorda: Color {
        if selecionado {
            return modelo == .comCapa ? corDoTexto.opacity(0.7) : PapagaioTema.destaque
        }
        if modelo == .compacto {
            return cor.opacity(0.35)
        }
        return semCor && imagem == nil ? PapagaioTema.borda : .clear
    }

    var body: some View {
        Button(action: acao) {
            // Uma fileira, e não um cartão alto.
            //
            // Pasta é um rótulo: nome, cor e um menu. O cartão grande dedicava
            // 168pt de altura a mostrar duas linhas de texto, e a grade de
            // vinte pastas virava três telas de rolagem. Na fileira cabem
            // quatro por linha e a lista inteira fica visível de uma vez —
            // que é o que se quer de um índice.
            HStack(spacing: PapagaioTema.Espaco.medio) {
                // No modelo compacto a cor já mora na tarja da esquerda — o
                // quadradinho repetiria a mesma informação duas vezes na
                // mesma fileira.
                if modelo == .comCapa {
                    marca
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(pasta.nome)
                        .font(.callout.weight(.semibold))
                        // Com imagem no fundo, o texto é sempre claro: o véu
                        // escuro garante o contraste, e a cor da pasta não diz
                        // mais nada sobre o que está atrás do nome. No modelo
                        // compacto o fundo é neutro, então o texto usa a cor
                        // de texto do tema, como qualquer outro cartão dele.
                        .foregroundStyle(corDoTextoPrincipal)
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .truncationMode(.tail)

                    // A contagem de volta à face da fileira: escondida só no
                    // hover, ela obrigava a apontar o mouse em cada pasta para
                    // responder "vale a pena abrir esta?".
                    Text(textoDaQuantidade)
                        .font(.caption)
                        .foregroundStyle(corDoTextoSecundario)
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                }

                Spacer(minLength: PapagaioTema.Espaco.curto)

                menuDaPasta
            }
            .padding(.horizontal, PapagaioTema.Espaco.medio)
            // No compacto, a tarja mora na borda esquerda do cartão — o mesmo
            // recuo extra que o cartão de conversa dá ao título, para o texto
            // não encostar nela.
            .padding(.leading, modelo == .compacto ? PapagaioTema.Espaco.curto : 0)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            // A fileira **é** a cor da pasta no modelo "Com capa"; no
            // compacto ela é a mesma superfície neutra do cartão de conversa
            // compacto — a cor sobra para a tarja.
            //
            // Com a cor presa ao quadradinho de 34pt, era preciso caçar o
            // ícone para saber de quem era a linha; pintada, a pasta se
            // reconhece de longe, que é o motivo de existir cor aqui.
            // `background { }` com `clipShape`, e não `background(_:in:)`: a
            // versão com forma só aceita `ShapeStyle`, e aqui o fundo pode ser
            // uma imagem — que é uma View.
            .background {
                if modelo == .comCapa {
                    fundo
                } else {
                    PapagaioTema.superficie
                }
            }
            // A tarja **antes** do `.clipShape`, e não depois.
            //
            // Depois dele, a tarja é um retângulo reto por cima de um
            // cartão já arredondado — ela ultrapassa os cantos em vez de
            // acompanhá-los, e parece uma linha colada por cima, e não uma
            // borda que pertence ao cartão. Antes do corte, ela é recortada
            // junto com o resto: os cantos dela arredondam com os do
            // cartão, exatamente como já acontece na tarja dos cartões de
            // conversa e nos cartões de tarefa.
            .overlay(alignment: .leading) {
                if modelo == .compacto {
                    Rectangle().fill(cor).frame(width: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(
                        corDaBorda,
                        lineWidth: selecionado ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help("\(pasta.nome) · \(textoDaQuantidade)")
        // Botão direito, e não mais um ícone no cartão: personalizar é raro
        // perto de abrir, e um segundo alvo clicável dentro de um cartão que
        // inteiro já é um botão confunde quem só quer entrar na pasta.
        .contextMenu {
            Button("Editar…".localized, systemImage: "pencil") {
                escolhendoAparencia = true
            }

            Button("Apagar pasta".localized, systemImage: "trash", role: .destructive) {
                confirmandoExclusao = true
            }
        }
        .confirmationDialog(
            "Apagar a pasta %@?".localized(pasta.nome),
            isPresented: $confirmandoExclusao,
            titleVisibility: .visible
        ) {
            Button("Apagar pasta".localized, role: .destructive, action: aoApagar)
            Button("Cancelar".localized, role: .cancel) {}
        } message: {
            // O texto tira o susto: a palavra "apagar" ao lado de um número de
            // conversas faz qualquer um imaginar que elas vão junto.
            Text(
                pasta.quantidade == 0
                    ? "A pasta é só um rótulo. Nada mais será removido.".localized
                    : "As %d conversas continuam na biblioteca — só deixam de estar nesta pasta.".localized(pasta.quantidade)
            )
        }
        .popover(isPresented: $escolhendoAparencia, arrowEdge: .bottom) {
            AparenciaDaPastaPopover(
                pasta: pasta.nome,
                cor: $cor,
                semCor: $semCor,
                capa: $capa,
                ajuste: $ajuste,
                aoRenomear: aoRenomear
            )
        }
        .onAppear(perform: sincronizar)
        .onChange(of: pasta.nome) { _, _ in sincronizar() }
    }

    /// Os três pontos da direita, com tudo o que dá para fazer com a pasta.
    ///
    /// Um menu no lugar de ícones soltos: favoritar, baixar, renomear,
    /// compartilhar, cor e imagem e lixeira não caberiam numa fileira de 56pt,
    /// e três pontos é o mesmo gesto que o cartão de conversa já pede.
    private var menuDaPasta: some View {
            Button {
                menuAberto = true
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(corDoTextoSecundario.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ações da pasta".localized)
            .popover(isPresented: $menuAberto, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ItemDoMenuDeArquivo(
                        simbolo: favorita ? "star.slash" : "star",
                        titulo: (favorita ? "Desfavoritar" : "Favoritar").localized
                    ) {
                        menuAberto = false
                        favorita.toggle()
                        AparenciaDasPastas.definirFavorita(favorita, para: pasta.nome)
                    }

                    ItemDoMenuDeArquivo(simbolo: "arrow.down.circle", titulo: "Baixar".localized) {
                        menuAberto = false
                        DispatchQueue.main.async { aoBaixar() }
                    }
                    // Um "Editar" só: o popover que ele abre já tem o nome, a
                    // cor e a imagem. Dois itens abrindo exatamente a mesma
                    // tela obrigavam a escolher entre eles sem diferença.
                    ItemDoMenuDeArquivo(simbolo: "pencil", titulo: "Editar".localized) {
                        menuAberto = false
                        DispatchQueue.main.async { escolhendoAparencia = true }
                    }
                    // Separador entre "o que faço com o arquivo" e "com quem
                    // compartilho", como no menu do Drive.
                    SeparadorPapagaio()
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .padding(.vertical, PapagaioTema.Espaco.minimo)

                    ItemDoMenuDeArquivo(simbolo: "square.and.arrow.up", titulo: "Compartilhar".localized) {
                        menuAberto = false
                        DispatchQueue.main.async { aoCompartilhar() }
                    }
                    SeparadorPapagaio()
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .padding(.vertical, PapagaioTema.Espaco.minimo)

                    ItemDoMenuDeArquivo(
                        simbolo: "trash",
                        titulo: "Mover para Lixeira".localized,
                        destrutivo: true
                    ) {
                        menuAberto = false
                        DispatchQueue.main.async { confirmandoExclusao = true }
                    }
                }
                .frame(width: 214)
                .padding(.vertical, PapagaioTema.Espaco.minimo)
            }
    }

    /// A imagem, quando há; senão, a cor da pasta.
    /// A imagem quando há; senão, a cor.
    ///
    /// Ela aparece nos dois lugares de propósito: no fundo, para a fileira ser
    /// reconhecível de longe como qualquer outra; e no quadradinho, limpa, sem
    /// o véu que o fundo precisa para o nome sobreviver por cima.
    @ViewBuilder
    private var fundo: some View {
        if let imagem {
            ImagemDeFundo(imagem: imagem, ajuste: ajuste, corDeFundo: cor)
        } else {
            cor
        }
    }

    /// O quadradinho da esquerda: a imagem da pasta, quando há.
    ///
    /// Fica sempre visível — inclusive com imagem. Deixar a foto só no fundo
    /// da fileira, atrás do véu escuro que o texto exige, é o mesmo que não
    /// ter foto: ela vira uma textura irreconhecível. No quadradinho ela
    /// aparece limpa, e o fundo continua sendo a cor da pasta.
    private var marca: some View {
        ZStack {
            if let imagem {
                ImagemDeFundo(
                    imagem: imagem,
                    ajuste: ajuste,
                    corDeFundo: corDoTexto.opacity(0.18),
                    comVeu: false
                )
            } else {
                // Sobre a cor da fileira, o quadradinho é um véu do próprio
                // texto: cor sobre cor sumiria, e branco fixo brigaria com as
                // cores claras.
                corDoTexto.opacity(0.18)

                Image(systemName: "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(corDoTexto)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // A estrela vira um selo no canto do ícone: na fileira não há linha de
        // rodapé onde ela caberia, e favoritar é frequente demais para virar
        // item de menu.
        .overlay(alignment: .topTrailing) {
            if favorita {
                Image(systemName: "star.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(cor)
                    .padding(2)
                    .background(corDoTexto, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var textoDaQuantidade: String {
        pasta.quantidade == 1 ? "1 conversa".localized : "%d conversas".localized(pasta.quantidade)
    }

    private func sincronizar() {
        cor = AparenciaDasPastas.corResolvida(de: pasta.nome)
        semCor = AparenciaDasPastas.semCor(de: pasta.nome)
        capa = AparenciaDasPastas.capa(de: pasta.nome)
        favorita = AparenciaDasPastas.favorita(pasta.nome)
        ajuste = AparenciaDasPastas.ajuste(de: pasta.nome)
    }
}

/// A faixa que aparece no lugar da grade quando uma pasta está aberta.
///
/// Sem ela, entrar numa pasta era uma viagem sem sinalização: a grade sumia,
/// as conversas trocavam e nada na tela dizia onde você estava nem como sair.
/// A única saída era clicar de novo em "Pastas" — o que ninguém adivinha,
/// porque essa pastilha parece já estar selecionada.
struct CabecalhoDaPastaAberta: View {
    let nome: String
    let quantidade: Int
    let aoVoltar: () -> Void

    @State private var cor: Color = PapagaioTema.destaque
    @State private var semCor = false
    @State private var capa: URL?
    @State private var ajuste: AjusteDeImagem = .preencher

    private var imagem: NSImage? {
        guard capa != nil else { return nil }
        return AparenciaDasPastas.imagem(de: nome)
    }

    /// O que identifica a pasta aqui: a imagem dela, se houver; senão o ícone.
    ///
    /// A imagem vem antes da cor porque quem escolheu foto trocou a cor por
    /// ela — e sem isto uma pasta sem cor chegava neste cabeçalho como um
    /// ícone cinza-claro sobre fundo claro, que é o mesmo que não ter marca
    /// nenhuma. É a mesma regra da fileira da grade e da pastilha do cartão.
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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 15, weight: .semibold))
                // Sem cor, o ícone é a própria superfície do tema e sumiria
                // contra o fundo: aí ele vira texto secundário, como qualquer
                // outro ícone neutro do app.
                .foregroundStyle(semCor ? PapagaioTema.textoSecundario : cor)
        }
    }

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            // Seta à esquerda, como em qualquer navegação: é o gesto que a
            // pessoa já tem no dedo antes de aprender esta tela.
            Button(action: aoVoltar) {
                Label("Pastas".localized, systemImage: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Na cor da pasta aberta, e não mais fixo no coral da
                    // marca — o mesmo acento que já identifica essa pasta no
                    // ícone e na fileira da grade. A cor **crua**, e não
                    // `textoLegivel`: essa variante é pensada pra texto em
                    // cima da cor sólida, não pra ler sobre o fundo quase
                    // escuro que a cápsula tem aqui (foi o que ficou ilegível
                    // com amarelo — `textoLegivel` de amarelo é escuro, e
                    // escuro sobre um fundo já escuro some).
                    .foregroundStyle(semCor ? PapagaioTema.destaqueEscuro : cor)
                    .padding(.horizontal, PapagaioTema.Espaco.medio)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background((semCor ? PapagaioTema.destaque : cor).opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Voltar para todas as pastas".localized)

            HStack(spacing: PapagaioTema.Espaco.curto) {
                marca

                Text(nome)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(quantidade == 1 ? "1 conversa".localized : "%d conversas".localized(quantidade))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)
        }
        .onAppear(perform: sincronizar)
        .onChange(of: nome) { _, _ in sincronizar() }
    }

    private func sincronizar() {
        cor = AparenciaDasPastas.corResolvida(de: nome)
        semCor = AparenciaDasPastas.semCor(de: nome)
        capa = AparenciaDasPastas.capa(de: nome)
        ajuste = AparenciaDasPastas.ajuste(de: nome)
    }
}

/// Cor e imagem de uma pasta, num popover ancorado ao próprio cartão.
///
/// Popover e não folha: é uma escolha pequena, e ver o cartão mudar atrás
/// enquanto se escolhe vale mais do que qualquer prévia dentro de um modal.
struct AparenciaDaPastaPopover: View {
    let pasta: String
    @Binding var cor: Color
    @Binding var semCor: Bool
    @Binding var capa: URL?
    @Binding var ajuste: AjusteDeImagem
    let aoRenomear: (String) -> Void

    @State private var nomeDigitado = ""

    @State private var hexDigitado = ""
    @FocusState private var editandoHex: Bool

    private let colunas = [GridItem(.adaptive(minimum: 30), spacing: PapagaioTema.Espaco.curto)]

    /// Mesma leitura de `GradeDePastas`/`CartaoDePasta`: o modelo compacto
    /// não tem faixa (só a tarja lateral), então a seção "Imagem" não tem
    /// onde o resultado apareceria.
    @AppStorage(ModeloDeCartao.chave) private var modeloBruto = ModeloDeCartao.padrao.rawValue
    private var modelo: ModeloDeCartao {
        ModeloDeCartao(rawValue: modeloBruto) ?? .padrao
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Text("Nome".localized)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .textCase(.uppercase)

            // Renomear mora aqui, e não num diálogo próprio: trocar o nome e
            // trocar a cor são a mesma tarefa — "arrumar esta pasta".
            TextField("Nome da pasta".localized, text: $nomeDigitado)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { aoRenomear(nomeDigitado) }
                .padding(.horizontal, PapagaioTema.Espaco.curto)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        .stroke(PapagaioTema.borda, lineWidth: 1)
                }

            SeparadorPapagaio()

            Text("Cor".localized)
                .font(.caption.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .textCase(.uppercase)

            LazyVGrid(columns: colunas, spacing: PapagaioTema.Espaco.curto) {
                // "Sem cor" entre as cores, e não como um interruptor à parte:
                // é uma alternativa a elas, e é entre elas que se procura.
                BotaoSemCor(ativo: semCor, acao: aplicarSemCor)

                ForEach(AparenciaDasPastas.Cor.allCases) { opcao in
                    Button {
                        aplicar(opcao.cor)
                    } label: {
                        Circle()
                            .fill(opcao.cor)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(
                                    !semCor && cor == opcao.cor ? PapagaioTema.texto : PapagaioTema.borda,
                                    lineWidth: !semCor && cor == opcao.cor ? 2 : 1
                                )
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(opcao.titulo.localized)
                }
            }

            // Mesmos três caminhos do cartão de conversa: paleta para resolver
            // num clique, roda do sistema (com conta-gotas) para escolher no
            // olho, e hexadecimal para casar com a cor exata de uma marca.
            HStack(spacing: PapagaioTema.Espaco.curto) {
                ColorPicker("", selection: Binding(
                    get: { cor },
                    set: { aplicar($0) }
                ), supportsOpacity: false)
                .labelsHidden()

                TextField("#RRGGBB", text: $hexDigitado)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($editandoHex)
                    .onSubmit(aplicarHexDigitado)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                            .stroke(editandoHex ? PapagaioTema.destaque.opacity(0.6) : PapagaioTema.borda, lineWidth: 1)
                    }
            }

            if modelo == .comCapa {
                SeparadorPapagaio()

                Text("Imagem".localized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .textCase(.uppercase)

                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Button((capa == nil ? "Escolher imagem…" : "Trocar imagem…").localized, action: escolherImagem)
                        .buttonStyle(BotaoDeContornoPapagaio())

                    if capa != nil {
                        Button("Remover".localized, systemImage: "trash") {
                            AparenciaDasPastas.removerCapa(de: pasta)
                            capa = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.perigo)
                    }
                }

                if capa != nil {
                    SeletorDeAjusteDeImagem(ajuste: Binding(
                        get: { ajuste },
                        set: {
                            ajuste = $0
                            AparenciaDasPastas.definirAjuste($0, para: pasta)
                        }
                    ))
                }
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(width: 280)
        .onAppear {
            hexDigitado = cor.hexadecimal ?? ""
            nomeDigitado = pasta
        }
    }

    /// Deixa a pasta sem cor nenhuma: ela passa a usar a superfície neutra do
    /// tema, do mesmo jeito que uma pasta do Finder sem etiqueta.
    private func aplicarSemCor() {
        semCor = true
        AparenciaDasPastas.definirSemCor(true, para: pasta)
        cor = AparenciaDasPastas.corResolvida(de: pasta)
        hexDigitado = cor.hexadecimal ?? ""
    }

    private func aplicar(_ nova: Color) {
        semCor = false
        AparenciaDasPastas.definirSemCor(false, para: pasta)
        cor = nova
        AparenciaDasPastas.definirCorLivre(nova, para: pasta)
        hexDigitado = nova.hexadecimal ?? ""
    }

    /// Texto inválido não apaga a cor: volta a mostrar a atual, senão a pasta
    /// piscaria a cada caractere incompleto.
    private func aplicarHexDigitado() {
        guard let nova = Color(hexadecimal: hexDigitado) else {
            hexDigitado = cor.hexadecimal ?? ""
            return
        }
        aplicar(nova)
    }

    private func escolherImagem() {
        let painel = NSOpenPanel()
        painel.title = "Escolha uma imagem para a pasta".localized
        painel.prompt = "Usar imagem".localized
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = false
        painel.allowedContentTypes = [.image]

        guard painel.runModal() == .OK,
              let url = painel.url,
              url.startAccessingSecurityScopedResource()
        else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        try? AparenciaDasPastas.definirCapa(url, para: pasta)
        capa = AparenciaDasPastas.capa(de: pasta)
    }
}
