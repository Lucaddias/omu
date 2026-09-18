import SwiftUI

/// Os interruptores dos campos do cartão, sem moldura própria.
///
/// Existe separado porque os mesmos controles aparecem em dois lugares — nas
/// Configurações e no menu de um cartão. Duplicar a lista significaria, mais
/// cedo ou mais tarde, um campo novo aparecendo só num dos dois.
struct ListaDeCamposDoCartao: View {
    @Binding var campos: CamposDoCartao

    /// Fileiras, e não interruptores soltos numa coluna.
    ///
    /// Com o rótulo à esquerda e o interruptor lá no fim da linha, o olho tinha
    /// de atravessar um vão vazio para ligar um ao outro — e a alguns campos de
    /// distância já não dava para ter certeza de qual interruptor era de qual
    /// campo. Cada fileira ganha um fundo próprio: o par volta a ser um objeto
    /// só, e a linha inteira responde ao clique, que é o alvo que a pessoa
    /// mira de qualquer jeito.
    var body: some View {
        VStack(spacing: PapagaioTema.Espaco.minimo) {
            ForEach(CamposDoCartao.catalogo, id: \.campo.rawValue) { item in
                FileiraDeCampoDoCartao(
                    titulo: item.titulo,
                    detalhe: item.detalhe,
                    ligado: ligado(item.campo)
                )
            }
        }
    }

    /// Um `Binding` por campo, montado a partir do conjunto.
    ///
    /// Guardar um `Bool` de estado por campo daria dois lugares para a mesma
    /// verdade — e é aí que a lista e o cartão passam a discordar.
    private func ligado(_ campo: CamposDoCartao) -> Binding<Bool> {
        Binding(
            get: { campos.contains(campo) },
            set: { ativo in
                withAnimation(.snappy(duration: 0.22)) {
                    if ativo { campos.insert(campo) } else { campos.remove(campo) }
                }
            }
        )
    }
}

/// Uma linha da lista: nome, explicação e o interruptor, num bloco só.
private struct FileiraDeCampoDoCartao: View {
    let titulo: String
    let detalhe: String
    @Binding var ligado: Bool

    @State private var pairando = false

    var body: some View {
        HStack(alignment: .center, spacing: PapagaioTema.Espaco.medio) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo.localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detalhe.localized)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $ligado)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(PapagaioTema.destaque)
        }
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .padding(.vertical, PapagaioTema.Espaco.curto)
        .background(
            fundo,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
        )
        .contentShape(Rectangle())
        // A fileira inteira alterna o campo. O interruptor continua ali como
        // sinal de estado — e continua clicável por conta própria.
        .onTapGesture { ligado.toggle() }
        .onHover { pairando = $0 }
        .animation(.easeOut(duration: 0.12), value: pairando)
        .animation(.easeOut(duration: 0.12), value: ligado)
    }

    /// Ligado tem fundo, desligado não: a coluna vira um resumo visual do que
    /// está aparecendo no cartão, legível sem ler os interruptores um a um.
    private var fundo: Color {
        if ligado { return PapagaioTema.destaque.opacity(pairando ? 0.16 : 0.10) }
        return pairando ? PapagaioTema.superficieSuave : .clear
    }
}

/// A seção de personalização dentro das Configurações.
///
/// Aqui a lista ganha o que não cabia no menu do cartão: um exemplo que
/// responde em tempo real. Ler "Modalidade — presencial ou online" e ver a
/// linha aparecer no cartão são duas compreensões diferentes, e a segunda não
/// exige imaginar nada.
struct SecaoDePersonalizacaoDosCartoes: View {
    @AppStorage(CamposDoCartao.chave) private var camposBrutos = CamposDoCartao.padrao.rawValue
    @AppStorage(ModeloDeCartao.chave) private var modeloBruto = ModeloDeCartao.padrao.rawValue

    private var campos: Binding<CamposDoCartao> {
        Binding(
            get: { CamposDoCartao(rawValue: camposBrutos) },
            set: { camposBrutos = $0.rawValue }
        )
    }

    private var modelo: ModeloDeCartao {
        ModeloDeCartao(rawValue: modeloBruto) ?? .padrao
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            Label("Cartões da biblioteca".localized, systemImage: "rectangle.grid.2x2")
                .font(PapagaioTema.Tipo.tituloDeSecao)
                .foregroundStyle(PapagaioTema.destaqueEscuro)

            SeparadorPapagaio()

            // Escolha do modelo, e o que aparece nele.
            //
            // Os campos individuais (data, duração, participantes…) saíram
            // desta tela: cada cartão já tem seu próprio menu para isso
            // (`PersonalizacaoDoCartao.swift`), e repetir o controle aqui,
            // atrás de um botão, só empilhava mais uma decisão sobre a
            // decisão principal — qual modelo usar. O exemplo continua
            // visível, sempre, logo abaixo de cada modelo — os dois ao
            // mesmo tempo, não só o que está selecionado agora.
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
                Text("Modelo do cartão".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: PapagaioTema.Espaco.largo) {
                        opcoesDeModelo
                    }

                    VStack(spacing: PapagaioTema.Espaco.largo) {
                        opcoesDeModelo
                    }
                }
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartaoPapagaio()
    }

    private var opcoesDeModelo: some View {
        ForEach(ModeloDeCartao.allCases, id: \.rawValue) { opcao in
            AmostraDeModeloDeCartao(
                opcao: opcao,
                selecionada: modelo == opcao,
                campos: campos
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    modeloBruto = opcao.rawValue
                }
            }
        }
    }
}

/// Um cartão de mentira, com dados de exemplo, que obedece aos mesmos campos.
///
/// Não reaproveita `CartaoDeConversa` porque aquele depende de um `Arquivo`
/// real, de preferências gravadas e de navegação — fabricar tudo isso só para
/// desenhar um exemplo traria efeitos colaterais reais (gravar capa, abrir
/// conversa) numa tela de configuração.
struct PreviaDoCartaoDeConversa: View {
    let campos: CamposDoCartao
    var modelo: ModeloDeCartao = .comCapa

    /// A cor do exemplo. Sem pasta e sem escolha manual, o cartão real cai no
    /// coral da marca — é exatamente esse o caso aqui.
    private var cor: Color { PapagaioTema.destaque }

    /// Mesma regra do cartão real: os acentos do rodapé são lidos sobre o
    /// branco, e por isso a cor passa por `acentoSobreSuperficie`.
    private var acento: Color { cor.acentoSobreSuperficie }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if modelo == .comCapa {
                faixa
            } else {
                cabecalhoCompacto

                Rectangle()
                    .fill(acento.opacity(0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }

            corpo

            // A barra é uma camada sobre o rodapé no cartão real; aqui ela é o
            // último item da pilha, que dá no mesmo resultado visual.
            rodape
        }
        // Altura fixa, igual ao cartão de verdade, para o exemplo não mentir
        // sobre a proporção.
        // 360 é o teto da coluna adaptativa da biblioteca — ou seja, a largura
        // de um cartão real em janela cheia, que é onde a pessoa vai ver o
        // resultado. Em 300 o exemplo era o cartão mais estreito possível e
        // ainda deixava a coluna da direita meio vazia.
        .frame(width: 360, height: CartaoDeConversa.alturaDoCartao, alignment: .top)
        .overlay(alignment: .leading) {
            if modelo == .compacto {
                Rectangle().fill(acento).frame(width: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        .cartaoPapagaio(borda: acento.opacity(0.35))
        .animation(.snappy(duration: 0.22), value: campos.rawValue)
        .animation(.snappy(duration: 0.22), value: modelo)
        .accessibilityHidden(true)
    }

    /// O cabeçalho do modelo compacto no exemplo — mesma lógica do cartão
    /// real: só o título, a cor sobra para a tarja lateral.
    private var cabecalhoCompacto: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text("Entrevista com Ana Silva".localized)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(PapagaioTema.texto)
                .frame(height: CartaoDeConversa.alturaDoTituloCompacto, alignment: .top)

            if campos.contains(.descricao) {
                Text("Primeira rodada de testes do fluxo de cadastro.".localized)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(2)
                    .frame(height: CartaoDeConversa.alturaDaDescricaoCompacta, alignment: .top)
            }
        }
        .padding(.leading, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.medio)
        .padding(.trailing, PapagaioTema.Espaco.largo)
        .padding(.top, PapagaioTema.Espaco.largo + PapagaioTema.Espaco.minimo)
        .padding(.bottom, PapagaioTema.Espaco.medio)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Título no alto, descrição embaixo — as pessoas saíram daqui há tempos,
    /// e o exemplo ainda as mostrava em duas colunas que o cartão real não tem.
    private var faixa: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Entrevista com Ana Silva".localized)
                .font(.system(size: 20, weight: .regular))
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .truncationMode(.tail)

            Spacer(minLength: PapagaioTema.Espaco.curto)

            if campos.contains(.descricao) {
                Text("Primeira rodada de testes do fluxo de cadastro.".localized)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
        }
        .foregroundStyle(cor.textoLegivel)
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CartaoDeConversa.alturaDaFaixa)
        .background {
            ZStack {
                cor
                TexturaDaFaixa()
            }
        }
    }

    /// As mesmas linhas do cartão real, com os mesmos vãos elásticos: é o que
    /// faz o exemplo mostrar de verdade como os campos se espalham quando a
    /// pessoa desliga alguns.
    private var corpo: some View {
        VStack(alignment: .leading, spacing: 0) {
            if campos.contains(.data) {
                linha("calendar", "13/08/2026, 14:32")
                vao
            }

            if campos.contains(.duracao) {
                linha("clock", "42 min".localized)
                vao
            }

            if campos.contains(.participantes) {
                HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2")
                            .font(.system(size: 16))
                            .frame(width: 20, alignment: .leading)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.top, 5)

                    PilhaDeParticipantes(nomes: ["João Santos".localized, "Ana Silva".localized])
                        .padding(.leading, PapagaioTema.Espaco.minimo)
                }
                .foregroundStyle(PapagaioTema.textoSecundario)
            } else if campos.contains(.lacunas) {
                linha("person.badge.plus", "Participantes não informados".localized)
            }

            Spacer(minLength: 0)
                .frame(height: PapagaioTema.Espaco.medio)
        }
        .padding(PapagaioTema.Espaco.largo)
        .padding(.leading, modelo == .compacto ? PapagaioTema.Espaco.medio : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var rodape: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(acento.opacity(0.28))
                .frame(height: 1)

            HStack(spacing: PapagaioTema.Espaco.medio) {
                if campos.contains(.pasta) {
                    SeloDaPastaDoCartao(nome: "Pesquisa".localized)
                        .padding(.leading, PapagaioTema.Espaco.largo)
                }

                Spacer(minLength: 0)

                Image(systemName: "star")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 32, height: 32)

                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 32, height: 32)

                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(PapagaioTema.textoSecundario)
            .padding(.trailing, PapagaioTema.Espaco.largo)
            .frame(height: CartaoDeConversa.alturaDaBarra)
        }
    }

    /// Mesmo desenho de linha do cartão: ícone de largura fixa, texto de 16pt.
    private func linha(_ simbolo: String, _ texto: String) -> some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
                .font(.system(size: 16))
                .frame(width: 20, alignment: .leading)

            Text(texto)
                .font(.system(size: 16))
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
        }
        .foregroundStyle(PapagaioTema.textoSecundario)
    }

    /// O mesmo vão elástico do cartão real: piso fixo, teto de 34pt.
    private var vao: some View {
        Spacer(minLength: PapagaioTema.Espaco.medio)
            .frame(maxHeight: 34)
    }
}

/// A mesma fileira de pasta da grade real (`CartaoDePasta`), só que com dados
/// de mentira — para mostrar que o modelo escolhido também muda a identidade
/// das pastas, não só das conversas.
///
/// Não reaproveita `CartaoDePasta` pelo mesmo motivo que `PreviaDoCartaoDeConversa`
/// não reaproveita `CartaoDeConversa`: aquele depende de uma pasta real, com
/// efeitos colaterais (renomear, apagar) que não fazem sentido numa tela de
/// configuração.
struct PreviaDaPasta: View {
    var modelo: ModeloDeCartao = .comCapa

    private let cor = PapagaioTema.destaque

    private var corDoTexto: Color { cor.textoLegivel }

    var body: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pesquisa".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(modelo == .comCapa ? corDoTexto : PapagaioTema.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("8 conversas".localized)
                    .font(.caption)
                    .foregroundStyle(modelo == .comCapa ? corDoTexto.opacity(0.8) : PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((modelo == .comCapa ? corDoTexto : PapagaioTema.textoSecundario).opacity(0.85))
        }
        .padding(.horizontal, PapagaioTema.Espaco.medio)
        .padding(.leading, modelo == .compacto ? PapagaioTema.Espaco.curto : 0)
        .frame(width: 360, height: 56)
        .background { modelo == .comCapa ? AnyView(cor) : AnyView(PapagaioTema.superficie) }
        // Tarja antes do corte, como no cartão de pasta de verdade — depois
        // dele ela escapa dos cantos arredondados e parece colada por cima.
        .overlay(alignment: .leading) {
            if modelo == .compacto {
                Rectangle().fill(cor).frame(width: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(modelo == .compacto ? cor.opacity(0.35) : .clear, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Botão de modelo de cartão, com uma miniatura esquemática — mesma família
/// visual da `AmostraDeAparencia` do claro/escuro: uma prévia pequena, o
/// nome embaixo, e uma moldura que acende quando é a escolha atual.
private struct AmostraDeModeloDeCartao: View {
    let opcao: ModeloDeCartao
    let selecionada: Bool
    @Binding var campos: CamposDoCartao
    let acao: () -> Void

    var body: some View {
        // Um único botão em volta de tudo — miniatura e exemplo — e não mais
        // só a miniatura. O exemplo é a maior parte visual do card: exigir o
        // clique justo na faixinha do topo enquanto o resto parecia
        // clicável (mesma moldura, mesmo hover) era o tipo de alvo que some
        // debaixo do cursor.
        Button(action: acao) {
            VStack(spacing: PapagaioTema.Espaco.medio) {
                VStack(spacing: PapagaioTema.Espaco.curto) {
                    miniatura

                    // Sem `.lineLimit` — mesma régua da tela inteira de
                    // Configurações: nada deve depender de truncar para
                    // caber, nem um rótulo curto e fixo como este.
                    Label(opcao.titulo.localized, systemImage: opcao.simbolo)
                        .font(PapagaioTema.Tipo.apoio.weight(selecionada ? .semibold : .regular))
                        .foregroundStyle(selecionada ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                }

                // O exemplo deste modelo, sempre visível embaixo dele — não
                // só do modelo selecionado no momento.
                exemplo
            }
            .padding(PapagaioTema.Espaco.medio)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(opcao.descricao.localized)
        .accessibilityLabel("Modelo %@".localized(opcao.titulo.localized))
        .accessibilityHint(opcao.descricao.localized)
        .accessibilityAddTraits(selecionada ? [.isSelected] : [])
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
    }

    /// O exemplo deste modelo — sempre o `opcao` deste card, nunca o modelo
    /// selecionado globalmente, porque os dois cards mostram seu próprio
    /// exemplo ao mesmo tempo. Sem rótulo "Exemplo": o próprio cartão já diz
    /// o que é. A pasta entra junto, porque o modelo compacto também muda a
    /// identidade dela — sem os dois lado a lado, não dava para ver isso
    /// aqui.
    private var exemplo: some View {
        VStack(spacing: PapagaioTema.Espaco.medio) {
            PreviaDoCartaoDeConversa(campos: campos, modelo: opcao)
            PreviaDaPasta(modelo: opcao)
        }
    }

    /// Um desenho simplificado, não o cartão de verdade — a mesma escolha da
    /// miniatura de aparência: aqui o que importa é a silhueta do layout, não
    /// os detalhes que já aparecem no exemplo grande ao lado.
    private var miniatura: some View {
        ZStack(alignment: .topLeading) {
            PapagaioTema.superficie

            if opcao == .comCapa {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(PapagaioTema.destaque.opacity(0.55))
                        .frame(height: 24)

                    Capsule().fill(PapagaioTema.textoSecundario.opacity(0.35)).frame(width: 38, height: 4)
                    Capsule().fill(PapagaioTema.textoSecundario.opacity(0.35)).frame(width: 26, height: 4)
                }
                .padding(6)
            } else {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(PapagaioTema.destaque.opacity(0.7))
                        .frame(width: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(PapagaioTema.textoSecundario.opacity(0.55)).frame(width: 44, height: 5)
                        Capsule().fill(PapagaioTema.textoSecundario.opacity(0.35)).frame(width: 30, height: 4)
                        Capsule().fill(PapagaioTema.textoSecundario.opacity(0.35)).frame(width: 34, height: 4)
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 8)
                }
            }
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

