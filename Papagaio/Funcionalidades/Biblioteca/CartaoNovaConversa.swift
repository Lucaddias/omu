import SwiftUI

struct CartaoNovaConversa: View {
    let gravando: Bool
    let bloqueado: Bool
    let prontoParaEntrada: Bool
    let aoAlternarGravacao: () async -> Void
    let aoImportar: () -> Void
    let aoSoltarArquivos: ([URL]) -> Void
    /// Volta para a tela de captura. Só usado enquanto `gravando`.
    let aoVoltarParaGravacao: () -> Void

    /// Realce enquanto o arquivo paira sobre o cartão. Sem ele, arrastar até
    /// aqui é um chute: nada na tela confirma que soltar vai funcionar.
    @State private var recebendoArraste = false

    private static let formatosAceitos: Set<String> = [
        "m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov",
    ]

    var body: some View {
        if gravando {
            Button(action: aoVoltarParaGravacao) {
                corpo
            }
            .buttonStyle(.plain)
            .help("Voltar para a gravação em andamento".localized)
        } else {
            corpo
        }
    }

    private var corpo: some View {
        VStack(spacing: PapagaioTema.Espaco.largo) {
            Image(systemName: gravando ? "mic.fill" : "plus")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(gravando ? PapagaioTema.perigo : PapagaioTema.destaqueEscuro)
                .frame(width: 64, height: 64)
                .background(PapagaioTema.destaqueSuave, in: Circle())

            VStack(spacing: PapagaioTema.Espaco.minimo) {
                Text(gravando ? "Gravação em andamento".localized : "Gerar nova conversa".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(
                    gravando
                        ? "Clique para voltar à tela de gravação.".localized
                        : "Grave áudio, importe um arquivo ou arraste aqui do Finder.".localized
                )
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            }

            if !prontoParaEntrada {
                SeloDeStatus(
                    texto: "Preparando biblioteca".localized,
                    simbolo: "arrow.triangle.2.circlepath",
                    estilo: .neutro
                )
                .accessibilityLabel("Preparando a biblioteca. Gravar e importar estarão disponíveis em instantes.".localized)
            }

            if bloqueado {
                SeloDeStatus(
                    texto: "Preparando áudio".localized,
                    simbolo: "waveform",
                    estilo: .destaque
                )
            }

            // Gravando, os dois botões somem. Começar outra gravação não é
            // possível, e importar no meio de uma captura é pedir para a
            // pessoa dividir a atenção — o cartão passa a ter uma função só,
            // que é levar de volta para a tela de captura.
            if gravando {
                Label("Voltar para a gravação".localized, systemImage: "waveform")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                // Em coluna estreita os dois botões lado a lado eram espremidos
                // até o rótulo hifenizar ("Impor-tar"). Empilhar é melhor que
                // quebrar a palavra.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        botoes
                    }

                    VStack(spacing: PapagaioTema.Espaco.curto) {
                        botoes
                    }
                }
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .contentShape(Rectangle())
        // A área de soltar é o cartão inteiro, não só os botões: quem arrasta
        // mira no retângulo tracejado, que é o que parece uma zona de entrada.
        .dropDestination(for: URL.self) { urls, _ in
            let aceitos = urls.filter {
                Self.formatosAceitos.contains($0.pathExtension.lowercased())
            }
            guard !aceitos.isEmpty else { return false }
            aoSoltarArquivos(aceitos)
            return true
        } isTargeted: { pairando in
            withAnimation(.snappy(duration: 0.16)) { recebendoArraste = pairando }
        }
        // A mesma altura dos cartões de conversa, e não `maxHeight: .infinity`:
        // como este cartão é o mais alto por conteúdo próprio, deixá-lo esticar
        // fazia a primeira fileira ficar mais alta que as de baixo sempre que
        // os cartões vizinhos encolhiam.
        //
        // `.center`, e não `.top`: o conteúdo (ícone, título, botões) é bem
        // mais baixo que os 336pt do cartão, e ancorado no topo sobrava uma
        // faixa vazia enorme embaixo — pedido para centralizar.
        .frame(
            maxWidth: .infinity,
            minHeight: CartaoDeConversa.alturaDoCartao,
            maxHeight: CartaoDeConversa.alturaDoCartao,
            alignment: .center
        )
        .background(
            recebendoArraste
                ? PapagaioTema.destaque.opacity(0.12)
                : PapagaioTema.superficie.opacity(0.55),
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            // `.strokeBorder`, e não `.stroke`: `.stroke` centraliza a linha
            // em cima do contorno e deixa metade da espessura vazar pra fora
            // da forma — com 2-3pt de espessura (bem mais grossa que o 1pt do
            // `cartaoPapagaio` dos outros cartões), esse vazamento bastava
            // pra este cartão parecer mais largo que os de baixo, mesmo os
            // dois ocupando exatamente a mesma coluna da grade.
            // `.strokeBorder` desenha inteira por dentro da forma, então a
            // borda tracejada fica no mesmo contorno que o `.background`
            // logo acima — as bordas dos dois tipos de cartão terminam no
            // mesmo pixel.
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .strokeBorder(
                    recebendoArraste ? PapagaioTema.destaque : PapagaioTema.borda,
                    style: StrokeStyle(lineWidth: recebendoArraste ? 3 : 2, dash: [7, 6])
                )
        }
        // Gravando, o cartão inteiro vira um botão de volta — e é `Button` de
        // verdade, não `onTapGesture`: assim ele responde a Enter e à
        // navegação por teclado, e o cursor vira mãozinha, avisando que dá
        // para clicar em qualquer ponto.
        .accessibilityElement(children: .contain)
    }

    private var botoes: some View {
        Group {
            Button("Gravar".localized, systemImage: "mic.fill") {
                Task { await aoAlternarGravacao() }
            }
            .buttonStyle(BotaoPrincipalPapagaio())
            .disabled(bloqueado || !prontoParaEntrada)

            Button("Importar".localized, systemImage: "arrow.down.doc") {
                aoImportar()
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .disabled(bloqueado || !prontoParaEntrada)
        }
    }
}
