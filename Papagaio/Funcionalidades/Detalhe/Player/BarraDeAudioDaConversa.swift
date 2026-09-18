import PapagaioCore
import SwiftUI

/// Player compacto e fixado na parte inferior. Ele só expõe as funções de uma
/// conversa: tocar/pausar e navegar pela posição; não simula recursos de um
/// app de música que não pertencem ao produto.
struct BarraDeAudioDaConversa: View {
    let titulo: String
    let data: Date
    let reprodutor: ReprodutorDeArquivo
    @Binding var tempoEmEdicao: TimeInterval?
    let aoConcluirEdicao: () -> Void
    let compacto: Bool

    @State private var pairandoNoIcone = false
    @State private var pairandoNaRegua = false

    /// Aberta enquanto o ponteiro estiver no ícone **ou** na própria régua.
    private var pairandoNoVolume: Bool { pairandoNoIcone || pairandoNaRegua }
    /// Nível de antes do mudo, para o clique seguinte devolvê-lo.
    @State private var volumeAntesDoMudo: Float = 1

    var body: some View {
        Group {
            if compacto {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    blocoDoArquivo
                    controlesCentrais
                        .frame(maxWidth: .infinity, alignment: .center)
                    progresso
                    volumeEVelocidade
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                HStack(spacing: PapagaioTema.Espaco.secao) {
                    blocoDoArquivo
                    controlesCentrais
                    progresso
                    volumeEVelocidade
                }
            }
        }
        .padding(.horizontal, PapagaioTema.Espaco.secao)
        .padding(.vertical, compacto ? PapagaioTema.Espaco.medio : PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, minHeight: compacto ? nil : 88)
        // A tela estreita propõe toda a altura restante ao overlay. Um
        // `minHeight` sozinho aceitava essa proposta e virava uma faixa
        // enorme — daí o `208` fixo que existia aqui antes. Só que 208 é
        // maior do que os controles pedem quando o título cabe numa linha
        // só (a barra sobrava vazia em volta deles, parecendo grande demais
        // à toa). `.fixedSize(vertical:)` resolve as duas pontas de uma vez:
        // ignora a proposta de altura do overlay (nunca mais vira uma faixa
        // enorme) e usa exatamente o que o conteúdo pede (nunca mais sobra
        // nem falta espaço).
        .fixedSize(horizontal: false, vertical: compacto)
        .background(PapagaioTema.superficie)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PapagaioTema.borda.opacity(0.75))
                .frame(height: 1)
        }
    }

    private var blocoDoArquivo: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 48, height: 48)
                .background(PapagaioTema.destaqueSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(titulo)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DataDigitada.textoComHora(de: data))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
            .frame(minWidth: 130, idealWidth: 210, maxWidth: 230, alignment: .leading)
        }
    }

    private var controlesCentrais: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            BotaoCircularDoPlayer(simbolo: "gobackward.10", tamanho: 18, destaque: false) {
                Task { await reprodutor.voltar(10) }
            }
            .help("Voltar 10 segundos".localized)

            BotaoCircularDoPlayer(
                simbolo: reprodutor.tocando ? "pause.fill" : "play.fill",
                tamanho: 20,
                destaque: true
            ) {
                reprodutor.alternar()
            }
            .help(reprodutor.tocando ? "Pausar".localized : "Reproduzir".localized)
            .accessibilityLabel(reprodutor.tocando ? "Pausar".localized : "Reproduzir".localized)

            BotaoCircularDoPlayer(simbolo: "goforward.10", tamanho: 18, destaque: false) {
                Task { await reprodutor.avancar(10) }
            }
            .help("Avançar 10 segundos".localized)
        }
    }

    private var progresso: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            Text(posicaoAtual.comoRelogio)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(PapagaioTema.texto)
                .monospacedDigit()
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 48, alignment: .trailing)

            Slider(
                value: posicao,
                in: 0...max(reprodutor.duracao, 0.1),
                onEditingChanged: { editando in
                    if editando {
                        tempoEmEdicao = reprodutor.tempo
                    } else {
                        aoConcluirEdicao()
                    }
                }
            )
            .tint(PapagaioTema.destaque)
            .accessibilityLabel("Posição do áudio".localized)
            .accessibilityValue("%@ de %@".localized(posicaoAtual.faladoPorExtenso, reprodutor.duracao.faladoPorExtenso))

            Text(reprodutor.duracao.comoRelogio)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(PapagaioTema.texto)
                .monospacedDigit()
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 48, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// Volume ao estilo do YouTube: o alto-falante silencia no clique e a
    /// barra só cresce quando o mouse chega perto.
    ///
    /// Parada, ela ocupava mais largura que a própria barra de progresso —
    /// um controle secundário maior que o principal. Agora o repouso é só o
    /// ícone, e a régua aparece quando alguém demonstra interesse nela.
    private var volumeEVelocidade: some View {
        HStack(spacing: PapagaioTema.Espaco.curto) {
            Button {
                alternarMudo()
            } label: {
                Image(systemName: simboloDoVolume)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(
                        pairandoNoVolume ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario
                    )
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(reprodutor.volume == 0 ? "Reativar som".localized : "Silenciar".localized)
            .onHover { ativo in
                withAnimation(.easeOut(duration: 0.14)) { pairandoNoIcone = ativo }
            }

            // A régua abre à **direita** do alto-falante, e é a velocidade que
            // anda para o lado. O alto-falante fica onde está porque o grupo
            // inteiro tem largura fixa e é ancorado à esquerda: crescer por
            // dentro não move o começo dele.
            if pairandoNoVolume {
                // Num só `HStack` para o `onHover` ter uma view onde morar: o
                // fim de um `if` dentro de `ViewBuilder` não é uma view, e não
                // aceita modificador.
                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Slider(value: volume, in: 0...1)
                        .tint(PapagaioTema.destaqueEscuro)
                        .frame(width: 90)
                        .accessibilityLabel("Volume".localized)

                    Text("\(Int((reprodutor.volume * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                        .frame(width: 36, alignment: .leading)
                }
                // A régua também segura a abertura: sem isto ela sumiria assim
                // que o ponteiro saísse do ícone para arrastá-la.
                .onHover { ativo in
                    withAnimation(.easeOut(duration: 0.14)) { pairandoNaRegua = ativo }
                }
            }

            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { velocidade in
                    Button(String(format: "%.2gx", velocidade)) {
                        reprodutor.definirVelocidade(Float(velocidade))
                    }
                }
            } label: {
                Text(textoDaVelocidade)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.superficieSuave, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Velocidade".localized)
        }
        // O hover é do alto-falante e da régua, e **não** da linha inteira:
        // pegando a linha toda, passar o mouse na velocidade — ou clicar nela,
        // que exige passar por cima — abria a régua sem que ninguém pedisse.
        .contentShape(Rectangle())
        // Roda do mouse sobre a área ajusta o volume sem precisar mirar na
        // régua — é o gesto que a pessoa já usa no resto do sistema, e
        // funciona mesmo com a régua invisível.
        .rodaDoMouse { delta in
            let novo = min(max(reprodutor.volume + Float(delta) * 0.02, 0), 1)
            reprodutor.volume = novo
            if novo > 0 { volumeAntesDoMudo = novo }
        }
        // Largura da versão aberta, sempre — alto-falante, régua, porcentagem
        // e velocidade. Ancorado à esquerda, o alto-falante começa no mesmo
        // ponto com ou sem a régua; o que muda é só quanto do espaço interno
        // está ocupado. Sem a largura fixa, o grupo encolheria e, encostado na
        // borda direita, arrastaria o alto-falante junto.
        .frame(width: 238, alignment: .leading)
    }

    private var simboloDoVolume: String {
        switch reprodutor.volume {
        case 0: "speaker.slash"
        case ..<0.5: "speaker.wave.1"
        default: "speaker.wave.2"
        }
    }

    /// Guarda o nível anterior para o clique seguinte devolvê-lo. Sem isso,
    /// reativar o som traria o volume no máximo, e não onde a pessoa deixou.
    private func alternarMudo() {
        if reprodutor.volume > 0 {
            volumeAntesDoMudo = reprodutor.volume
            reprodutor.volume = 0
        } else {
            reprodutor.volume = volumeAntesDoMudo
        }
    }

    private var posicaoAtual: TimeInterval {
        tempoEmEdicao ?? reprodutor.tempo
    }

    private var posicao: Binding<TimeInterval> {
        Binding(
            get: { posicaoAtual },
            set: { tempoEmEdicao = $0 }
        )
    }

    private var volume: Binding<Float> {
        Binding(
            get: { reprodutor.volume },
            set: { reprodutor.volume = $0 }
        )
    }

    private var textoDaVelocidade: String {
        String(format: "%.1fx", reprodutor.velocidade)
    }

    private func alternarVelocidade() {
        let opcoes: [Float] = [0.75, 1, 1.25, 1.5, 2]
        let atual = reprodutor.velocidade
        let proxima = opcoes.first { $0 > atual + 0.01 } ?? opcoes[0]
        reprodutor.velocidade = proxima
    }
}

struct BotaoCircularDoPlayer: View {
    let simbolo: String
    let tamanho: CGFloat
    let destaque: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: tamanho, weight: .semibold))
                .foregroundStyle(destaque ? PapagaioTema.textoSobrePrimario : PapagaioTema.textoSecundario)
                .frame(width: destaque ? 48 : 34, height: destaque ? 48 : 34)
                .background(destaque ? PapagaioTema.destaqueEscuro : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
