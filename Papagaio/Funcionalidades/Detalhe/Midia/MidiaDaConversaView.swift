import SwiftUI
import UniformTypeIdentifiers

struct MidiaDaConversaView: View {
    let anexos: [AnexoDeMidiaDaConversa]
    let aoAdicionar: () -> Void
    /// Arrastar do Finder direto para o cartão tracejado — um print recém
    /// tirado para a área de trabalho, um PDF, o que for — sem precisar
    /// abrir o painel de arquivos primeiro.
    let aoSoltarArquivos: ([URL]) -> Void
    let aoAbrir: (AnexoDeMidiaDaConversa) -> Void
    let aoRemover: (AnexoDeMidiaDaConversa) -> Void
    /// Só os itens desta conversa. A lixeira geral, na barra do app, mostra os
    /// de todas — aqui interessa desfazer o que acabou de acontecer nesta tela.
    let naLixeira: [MidiaNaLixeira]
    let aoRestaurar: (MidiaNaLixeira) -> Void
    let aoApagarDeVez: (MidiaNaLixeira) -> Void

    /// Realce enquanto o arquivo paira sobre o cartão — mesmo sinal do
    /// `CartaoNovaConversa` ao arrastar um áudio para a biblioteca: sem ele,
    /// arrastar até aqui é um chute, nada na tela confirma que soltar vai
    /// funcionar.
    @State private var recebendoArraste = false

    var body: some View {
        // Em janela estreita a coluna lateral roubaria a largura de um cartão
        // inteiro; aí ela volta a ser uma faixa acima da grade.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.secao) {
                grade
                resumoDaMidia
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                resumoDaMidia
                    .frame(maxWidth: .infinity, alignment: .leading)
                grade
            }
        }
    }

    private var grade: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            // Sem H1 nem subtítulo: a aba já se chama "Mídia", o título da
            // conversa está logo acima, e "Foto, vídeo, áudio ou arquivo" já
            // aparece dentro do cartão de adicionar. Eram três textos dizendo
            // a mesma coisa, empurrando os arquivos para baixo da dobra.
            // Sem `maximum` na `.adaptive`: com um teto (era 380), quando só
            // 1-2 colunas cabem numa janela mais larga que `N × maximum`, a
            // coluna trava no teto e sobra uma faixa vazia do lado direito —
            // o mesmo bug de alinhamento já corrigido na grade da
            // Biblioteca (ver `BibliotecaHomeView.gradeDeConversas`). Sem
            // teto, o padrão do `GridItem.adaptive` (`maximum: .infinity`)
            // faz a coluna sempre esticar até preencher a linha inteira.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 270), spacing: PapagaioTema.Espaco.largo, alignment: .top)],
                spacing: PapagaioTema.Espaco.largo
            ) {
                // Não é `Button`: um `.dropDestination` encadeado direto
                // num botão nunca chegava a completar a transferência aqui —
                // o realce (`isTargeted`) acendia, mas o `urls` do fecho
                // vinha vazio e nada era salvo. `CartaoNovaConversa`, que
                // arrasta áudio para a biblioteca, segue o mesmo molde: o
                // clique vira `.onTapGesture` sobre uma view comum, não um
                // `Button` de verdade.
                VStack(spacing: PapagaioTema.Espaco.medio) {
                    Image(systemName: recebendoArraste ? "arrow.down.circle.fill" : "plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(recebendoArraste ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                        .frame(width: 54, height: 54)
                        .background(recebendoArraste ? PapagaioTema.destaqueSuave : PapagaioTema.superficieSuave, in: Circle())

                    VStack(spacing: PapagaioTema.Espaco.minimo) {
                        Text(recebendoArraste ? "Soltar para adicionar".localized : "Adicionar mídia".localized)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(PapagaioTema.texto)
                        Text("Foto, vídeo, áudio ou arquivo".localized)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(PapagaioTema.textoSecundario)
                        Text("Clique ou arraste do Finder".localized)
                            .font(.caption)
                            .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.8))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PapagaioTema.Espaco.largo)
                }
                // Só `minHeight`, sem `maxHeight`: `CartaoDeAnexoDeMidia`
                // (o vizinho na grade) cresce além de 318pt quando o nome do
                // anexo ou os selos precisam de mais espaço. Com este cartão
                // travado em 318, ele sobrava mais baixo que o vizinho na
                // mesma fileira — o "+" e o texto pareciam fora do lugar,
                // centralizados numa caixa mais curta que a real altura da
                // fileira. `maxHeight: .infinity` deixa este cartão esticar
                // e acompanhar; o conteúdo continua centralizado (alinhamento
                // padrão do `.frame`) dentro da altura que sobrar.
                .frame(maxWidth: .infinity, minHeight: 318, maxHeight: .infinity)
                .background(
                    recebendoArraste ? PapagaioTema.destaque.opacity(0.12) : PapagaioTema.superficie.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                        .stroke(
                            recebendoArraste ? PapagaioTema.destaque : PapagaioTema.borda,
                            style: StrokeStyle(lineWidth: recebendoArraste ? 3 : 2, dash: [7, 6])
                        )
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: aoAdicionar)
                .help("Adicionar mídia".localized)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Adicionar mídia".localized)
                .accessibilityHint("Foto, vídeo, áudio ou arquivo. Também aceita arrastar do Finder.".localized)
                // A área de soltar é o cartão tracejado inteiro, não só o
                // ícone — é ele que parece uma zona de entrada. Aceita
                // qualquer arquivo (a mesma mensagem do painel já diz "fotos,
                // vídeos, áudios, PDFs ou outros arquivos"), então não há
                // filtro de extensão aqui como há para áudio na biblioteca.
                //
                // `.onDrop` de baixo nível, e não `.dropDestination(for:
                // URL.self)`: este último só resolve itens que a origem
                // oferece como `Transferable` de URL — funciona vindo do
                // Finder, mas uma imagem arrastada de dentro de uma página
                // web, do Slack, do Mensagens etc. costuma vir só como bytes
                // de imagem, sem URL nenhuma por trás, e o arrasto era
                // aceito visualmente (o realce acendia) mas não soltava
                // nada. Aqui `carregar(_:)` tenta a URL primeiro (Finder,
                // Fotos, Preview, até a "promessa de arquivo" de um print
                // ainda não salvo) e cai para salvar os bytes crus num
                // arquivo temporário quando não há URL disponível.
                .onDrop(
                    of: Self.tiposAceitos,
                    isTargeted: Binding(
                        get: { recebendoArraste },
                        set: { novo in withAnimation(.snappy(duration: 0.16)) { recebendoArraste = novo } }
                    )
                ) { provedores in
                    guard !provedores.isEmpty else { return false }
                    provedores.forEach(carregar)
                    return true
                }

                ForEach(anexos) { anexo in
                    CartaoDeAnexoDeMidia(
                        anexo: anexo,
                        aoAbrir: { aoAbrir(anexo) },
                        aoRemover: { aoRemover(anexo) }
                    )
                }

                // O removido continua na grade, apagado, com restaurar e
                // apagar de vez. Sumir da tela obrigaria a pessoa a sair da
                // conversa e procurar a lixeira do app para desfazer um clique
                // de dois segundos atrás — e o arrependimento acontece aqui.
                ForEach(naLixeira) { item in
                    CartaoDeMidiaRemovida(
                        item: item,
                        aoRestaurar: { aoRestaurar(item) },
                        aoApagarDeVez: { aoApagarDeVez(item) }
                    )
                }
            }
            .animation(.snappy(duration: 0.22), value: naLixeira)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Contagem, ajuda e lixeira numa linha só, ao lado dos cartões.
    ///
    /// A explicação virou botão: é texto que se lê uma vez e depois só ocupa
    /// espaço. Atrás do "i", ela continua disponível para quem chega agora
    /// sem cobrar altura de quem já sabe o que a aba faz.
    private var resumoDaMidia: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            // O "i" mora dentro da pastilha: solto ao lado, virava um terceiro
            // objeto na linha para dizer algo sobre o primeiro.
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Text(anexos.count == 1 ? "1 arquivo".localized : "%d arquivos".localized(anexos.count))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                Text(tamanhoTotal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                botaoDeAjuda
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario)
            .padding(.leading, PapagaioTema.Espaco.medio)
            .padding(.trailing, PapagaioTema.Espaco.minimo)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(PapagaioTema.superficieSuave, in: Capsule())
        }
        .fixedSize()
    }

    private var botaoDeAjuda: some View {
        BotaoDeAjudaPapagaio(
            texto: "Fotos, vídeos, áudios, documentos e anexos salvos nesta conversa.".localized,
            ajuda: "O que cabe nesta aba".localized,
            largura: 280
        )
    }

    private var tamanhoTotal: String {
        formatoDeBytes(anexos.reduce(0) { $0 + $1.tamanho })
    }

    /// Tipos aceitos ao arrastar — não só arquivos do Finder: fotos do
    /// Fotos.app, imagens copiadas do Safari/Mensagens/Notas, PDFs, áudio e
    /// vídeo de qualquer app que os ofereça, mesmo sem um arquivo por trás.
    private static let tiposAceitos: [UTType] = [.fileURL, .image, .pdf, .movie, .audio, .data]

    /// Resolve um item arrastado e entrega para `aoSoltarArquivos` assim que
    /// pronto. Duas rotas, nesta ordem:
    ///
    /// 1. Como URL de arquivo de verdade — cobre o Finder, o Fotos.app, o
    ///    Preview, e até uma "promessa de arquivo" (o print recém-tirado que
    ///    ainda não foi salvo em disco: o Finder some com um arquivo mesmo
    ///    assim, via `NSFilePromiseReceiver` por baixo do pano).
    /// 2. Sem URL nenhuma disponível — uma imagem arrastada de dentro de uma
    ///    página web, de dentro do Mensagens, de um chat qualquer — os bytes
    ///    crus são salvos num arquivo temporário e tratados como se tivessem
    ///    vindo de um arquivo comum.
    private func carregar(_ provedor: NSItemProvider) {
        if provedor.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provedor.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // O item costuma chegar como `Data` (a URL codificada), não
                // como `URL` direto — jeito clássico de arrasto no macOS.
                let url: URL? = if let dados = item as? Data {
                    URL(dataRepresentation: dados, relativeTo: nil)
                } else {
                    item as? URL
                }
                guard let url else { return }
                DispatchQueue.main.async { aoSoltarArquivos([url]) }
            }
            return
        }

        guard let tipo = Self.tiposAceitos.first(where: { provedor.hasItemConformingToTypeIdentifier($0.identifier) })
        else { return }

        // O nome do arquivo temporário é o que a pessoa vai ver depois no
        // cartão do anexo (`MidiasDaConversa.anexo` usa `lastPathComponent`
        // como nome de exibição) — sem isto, tudo que chegasse sem URL virava
        // um "Arraste-<UUID>.png" ilegível.
        let nome = Self.nomeParaArquivoSemOrigem(sugerido: provedor.suggestedName, tipo: tipo)

        provedor.loadDataRepresentation(forTypeIdentifier: tipo.identifier) { dados, _ in
            guard let dados else { return }
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent(nome)
            do {
                try dados.write(to: destino)
            } catch {
                return
            }
            DispatchQueue.main.async { aoSoltarArquivos([destino]) }
        }
    }

    /// Um nome de arquivo legível para algo que chegou sem URL própria —
    /// uma imagem colada de dentro de uma página web, por exemplo.
    ///
    /// Prioriza o que a própria origem sugeriu (`NSItemProvider.suggestedName`
    /// — muitos apps mandam algo como "imagem.png" mesmo sem oferecer uma URL
    /// de arquivo de verdade); sem isso, cai num nome descritivo pelo tipo
    /// ("Imagem colada", "PDF colado"...) com data e hora para não colidir
    /// com o próximo.
    private static func nomeParaArquivoSemOrigem(sugerido: String?, tipo: UTType) -> String {
        let extensao = tipo.preferredFilenameExtension ?? "dat"

        if let sugerido, !sugerido.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: sugerido)
            return url.pathExtension.isEmpty
                ? url.appendingPathExtension(extensao).lastPathComponent
                : url.lastPathComponent
        }

        let rotulo: String
        if tipo.conforms(to: .image) {
            rotulo = "Imagem colada".localized
        } else if tipo.conforms(to: .pdf) {
            rotulo = "PDF colado".localized
        } else if tipo.conforms(to: .movie) {
            rotulo = "Vídeo colado".localized
        } else if tipo.conforms(to: .audio) {
            rotulo = "Áudio colado".localized
        } else {
            rotulo = "Arquivo colado".localized
        }

        let formatador = DateFormatter()
        // Sem barra nem dois-pontos: os dois quebram nome de arquivo no
        // Finder — "HH.mm.ss" no lugar de "HH:mm:ss".
        formatador.dateFormat = "dd-MM-yyyy 'at' HH.mm.ss"
        return "\(rotulo) \(formatador.string(from: Date())).\(extensao)"
    }
}
