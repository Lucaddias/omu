import PapagaioCore
import SwiftUI

/// Linha interativa da transcrição. As ações de tocar pertencem ao container;
/// assim a célula continua puramente visual e pode ser usada dentro de um
/// `Button` sem duplicar lógica de AVFoundation.
struct LinhaDeTranscricao: View {
    let trecho: Trecho
    let ativo: Bool
    /// Palavra destacada dentro do trecho — `nil` quando o trecho está inativo
    /// ou é legado (sem `palavras`).
    let indiceDePalavraAtiva: Int?
    /// Animação do destaque de palavra, vinda do container (respeita o modo de
    /// reduzir movimento).
    let animacao: Animation?
    /// Nomes escolhidos para as vozes desta conversa — ver `RotuloDeVoz`.
    let nomesDeVoz: [String: String]
    let aoTocarLinha: () -> Void
    let aoTocarPalavra: (Palavra) -> Void
    /// Corrige o texto deste trecho. Fica ao lado direito do parágrafo,
    /// centralizado na altura dele — nem preso só à linha do cabeçalho, nem
    /// flutuando fora de qualquer texto.
    let aoEditar: () -> Void
    var termoDeBusca: String = ""
    var idOcorrenciaAtual: UUID? = nil
    var falantePreservado: String? = nil
    var mostrarConfianca: Bool = false
    var mostrarPorcentagemConfianca: Bool = true
    /// Indica se está em modo de edição inline
    var estaEditando: Bool = false
    /// Texto sendo editado inline
    @Binding var textoEditado: String
    /// Callback ao salvar edição inline
    var aoSalvarEdicao: () -> Void = {}
    /// Callback ao cancelar edição inline
    var aoCancelarEdicao: () -> Void = {}

    private var isBaixaConfiancaTrecho: Bool {
        guard mostrarConfianca, let c = trecho.confianca else { return false }
        if let nsp = trecho.noSpeechProb, nsp > 0.6 { return false }
        return c < 0.6
    }

    private var corDeFundoTrecho: Color {
        if isBaixaConfiancaTrecho { return Color.yellow.opacity(0.22) }
        if ativo { return PapagaioTema.destaqueSuave.opacity(0.76) }
        return PapagaioTema.superficie
    }

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
            Text(trecho.start.comoRelogio)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(ativo ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                .frame(width: 52, alignment: .trailing)

            HStack(alignment: .center, spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    let falanteParaExibir: String? = {
                        if trecho.temVozesDistintas, let d = trecho.falanteAcusticoDominante { return d }
                        if let p = falantePreservado, !p.isEmpty { return p }
                        return nil
                    }()
                    HStack(spacing: 6) {
                        Text(LinhaDeFala.rotuloDoCanal(trecho.speaker))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PapagaioTema.textoSecundario)
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: true, vertical: false)
                        if let acustico = falanteParaExibir {
                            Text(RotuloDeVoz.exibicao(acustico, nomes: nomesDeVoz))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PapagaioTema.destaqueEscuro)
                                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, PapagaioTema.Espaco.minimo)
                                .padding(.vertical, 1)
                                .background(
                                    PapagaioTema.destaqueSuave,
                                    in: Capsule()
                                )
                        }
                        if mostrarConfianca && mostrarPorcentagemConfianca, let c = trecho.confianca, (trecho.noSpeechProb ?? 0) < 0.6 {
                            Text(String(format: "%.0f%%", c * 100))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(c < 0.6 ? Color.red : (c < 0.85 ? Color.orange : PapagaioTema.textoSecundario))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((c < 0.6 ? Color.red.opacity(0.12) : Color.clear), in: Capsule())
                                .overlay { Capsule().stroke((c < 0.6 ? Color.red.opacity(0.3) : Color.clear), lineWidth: 1) }
                        }
                    }

                    if estaEditando {
                        EditorInlineDaTranscricao(
                            texto: $textoEditado,
                            aoSalvar: aoSalvarEdicao,
                            aoCancelar: aoCancelarEdicao
                        )
                    } else {
                        corpoDaTranscricao
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                botaoEditar
            }
        }
        .padding(.vertical, PapagaioTema.Espaco.medio)
        .padding(.horizontal, PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            corDeFundoTrecho,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ativo ? PapagaioTema.destaque : .clear)
                .frame(width: 4)
                .padding(.vertical, PapagaioTema.Espaco.curto)
        }
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(ativo ? PapagaioTema.borda : PapagaioTema.borda.opacity(0.58), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            aoTocarLinha()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction {
            aoTocarLinha()
        }
        .accessibilityHint("Inicia a reprodução a partir de %@.".localized(trecho.start.faladoPorExtenso))
        .accessibilityAddTraits(ativo ? [.isSelected] : [])
    }

    private var botaoEditar: some View {
        Button(action: {
            aoEditar()
        }) {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 26, height: 26)
                .background(PapagaioTema.destaqueSuave, in: Circle())
                .overlay {
                    Circle().stroke(PapagaioTema.destaque.opacity(0.4), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("Corrigir o texto deste trecho".localized)
        .accessibilityLabel("Corrigir o texto deste trecho".localized)
    }

    @ViewBuilder
    private var corpoDaTranscricao: some View {
        if !trecho.palavras.isEmpty {
            LayoutDeFluxo(espacoHorizontal: 1, espacoVertical: 3, justificado: true) {
                ForEach(Array(trecho.palavras.enumerated()), id: \.element.id) { indice, palavra in
                    let buscaDestacada = !termoDeBusca.isEmpty && palavra.texto.casaComBusca(termoDeBusca)
                    let ehAtual = buscaDestacada && idOcorrenciaAtual == palavra.id
                    let isBaixa = mostrarConfianca && (palavra.confianca ?? 1) <= 0.50 && (palavra.noSpeechProb ?? 0) < 0.6
                    BotaoDePalavra(
                        palavra: palavra,
                        ativa: indice == indiceDePalavraAtiva,
                        destacadoPelaBusca: buscaDestacada,
                        ehOcorrenciaAtual: ehAtual,
                        isBaixaConfianca: isBaixa,
                        mostrarConfianca: mostrarConfianca,
                        mostrarPorcentagemConfianca: mostrarPorcentagemConfianca,
                        animacao: animacao,
                        acao: { aoTocarPalavra(palavra) }
                    )
                }
            }
        } else {
            let destaca = !termoDeBusca.isEmpty && trecho.texto.casaComBusca(termoDeBusca)
            let ehAtual = destaca && idOcorrenciaAtual == trecho.id
            Text(trecho.texto)
                .font(.body)
                .fontWeight(ativo ? .medium : .regular)
                .foregroundStyle(PapagaioTema.texto)
                .padding(.horizontal, destaca ? 4 : 0)
                .padding(.vertical, destaca ? 1 : 0)
                .padding(.vertical, PapagaioTema.Espaco.minimo)
                .background(
                    ehAtual ? PapagaioTema.destaque : (destaca ? Color.yellow.opacity(0.45) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(ehAtual ? .white : PapagaioTema.texto)
                .multilineTextAlignment(.leading)
        }
    }
}

/// Uma palavra clicável do parágrafo corrido. O tap salta o áudio para o
/// timestamp próprio dela; o destaque segue `indiceDePalavraAtiva` do trecho.
struct BotaoDePalavra: View {
    let palavra: Palavra
    let ativa: Bool
    var destacadoPelaBusca: Bool = false
    var ehOcorrenciaAtual: Bool = false
    var isBaixaConfianca: Bool = false
    var mostrarConfianca: Bool = false
    var mostrarPorcentagemConfianca: Bool = true
    let animacao: Animation?
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(spacing: 0) {
                Text(palavra.texto)
                    .font(.body)
                if mostrarConfianca && mostrarPorcentagemConfianca {
                    Text(palavra.confianca.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(confidenceColor)
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.vertical, 1.5)
            .padding(.horizontal, PapagaioTema.Espaco.minimo)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
            )
            .overlay {
                if ehOcorrenciaAtual {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        .stroke(PapagaioTema.destaque, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(animacao, value: ativa)
        .animation(animacao, value: destacadoPelaBusca)
        .animation(animacao, value: ehOcorrenciaAtual)
        .animation(animacao, value: isBaixaConfianca)
        .help(helpText)
        .accessibilityLabel(palavra.texto)
        .accessibilityHint("Salta o áudio para o instante desta palavra.".localized)
        .accessibilityAddTraits(ativa ? [.isSelected] : [])
    }

    private var helpText: String {
        if isBaixaConfianca, let c = palavra.confianca {
            return "Confiança %.0f%% — baixa".localized(c * 100)
        }
        return "Ouvir a partir desta palavra".localized
    }

    private var foregroundColor: Color {
        if ehOcorrenciaAtual { return .white }
        if ativa { return PapagaioTema.destaqueEscuro }
        return PapagaioTema.texto
    }

    private var confidenceColor: Color {
        guard let c = palavra.confianca else { return PapagaioTema.textoSecundario }
        if c <= 0.30 { return .red }
        if c <= 0.50 { return .yellow }
        return PapagaioTema.textoSecundario
    }

    private var backgroundColor: Color {
        if ehOcorrenciaAtual { return PapagaioTema.destaque }
        if isBaixaConfianca {
            if let c = palavra.confianca, c <= 0.30 { return Color.red.opacity(0.18) }
            return Color.yellow.opacity(0.28)
        }
        if destacadoPelaBusca { return Color.yellow.opacity(0.45) }
        if ativa { return PapagaioTema.destaqueSuave }
        return Color.clear
    }
}
