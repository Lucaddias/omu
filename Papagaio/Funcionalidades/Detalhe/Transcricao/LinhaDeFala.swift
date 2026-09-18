import PapagaioCore
import SwiftUI

/// Linha de uma fala da conversa — a unidade de leitura quando a diarização
/// atribuiu vozes às palavras.
///
/// Substitui a linha por trecho no modo com falas: a fala atravessa trechos
/// (a voz não respeita a janela de 40 s), então o timestamp é o da fala e a
/// palavra ativa é casada pela âncora `(trechoId, indiceNoTrecho)` do player.
struct LinhaDeFala: View {
    let fala: FalaDeFalante
    let ativo: Bool
    /// Palavra sendo tocada, com a âncora no trecho de origem — `nil` quando
    /// nada toca ou a fala é legada (sem palavras).
    let palavraAtiva: PalavraDeFala?
    /// Animação do destaque de palavra, vinda do container.
    let animacao: Animation?
    /// Nomes escolhidos para as vozes desta conversa ("S1" → "João"...) — ver
    /// `RotuloDeVoz`. Vazio quando ninguém ainda renomeou nada, e a fala volta
    /// a mostrar "Voz N".
    let nomesDeVoz: [String: String]
    let aoTocarFala: () -> Void
    let aoTocarPalavra: (Palavra) -> Void
    /// Corrige o texto desta fala. Fica ao lado direito do parágrafo,
    /// centralizado na altura dele — nem preso só à linha do cabeçalho (fica
    /// solto demais lá em cima), nem flutuando fora de qualquer texto.
    let aoEditar: () -> Void
    /// Termo da busca na transcrição — destaca palavras que casam.
    var termoDeBusca: String = ""
    /// Palavra da ocorrência atual do Cmd+F — destaque mais forte.
    var idOcorrenciaAtual: UUID? = nil
    /// Falante preservado para falas editadas (quando `fala.falanteAcustico` virou nil)
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

    private var isBaixaConfiancaFala: Bool {
        guard mostrarConfianca, let c = fala.confianca else { return false }
        if let nsp = fala.palavras.first?.palavra.noSpeechProb, nsp > 0.6 { return false }
        return c < 0.6
    }

    private var corDeFundoFala: Color {
        if isBaixaConfiancaFala { return Color.yellow.opacity(0.22) }
        if ativo { return PapagaioTema.destaqueSuave.opacity(0.76) }
        return PapagaioTema.superficie
    }

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
            Text(fala.inicio.comoRelogio)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(ativo ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
                .frame(width: 52, alignment: .trailing)

            HStack(alignment: .center, spacing: PapagaioTema.Espaco.medio) {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    cabecalhoDaFala

                    if estaEditando {
                        EditorInlineDaTranscricao(
                            texto: $textoEditado,
                            aoSalvar: aoSalvarEdicao,
                            aoCancelar: aoCancelarEdicao
                        )
                    } else {
                        corpoDaFala
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
            corDeFundoFala,
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
            aoTocarFala()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction {
            aoTocarFala()
        }
        .accessibilityHint("Inicia a reprodução a partir de %@.".localized(fala.inicio.faladoPorExtenso))
        .accessibilityAddTraits(ativo ? [.isSelected] : [])
    }

    /// O canal identifica a origem da fala; a voz acústica entra como
    /// complemento. Os dois rótulos nunca são fundidos.
    @ViewBuilder
    private var cabecalhoDaFala: some View {
        let exibido = fala.falanteAcustico ?? falantePreservado
        HStack(spacing: PapagaioTema.Espaco.minimo) {
            Text(Self.rotuloDoCanal(fala.speaker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)
            if let acustico = exibido {
                Text(RotuloDeVoz.exibicao(acustico, nomes: nomesDeVoz))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, PapagaioTema.Espaco.minimo)
                    .padding(.vertical, 1)
                    .background(PapagaioTema.destaqueSuave, in: Capsule())
            }
            if mostrarConfianca && mostrarPorcentagemConfianca, let c = fala.confianca {
                Text(String(format: "%.0f%%", c * 100))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(c < 0.6 ? Color.red : (c < 0.85 ? Color.orange : PapagaioTema.textoSecundario))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((c < 0.6 ? Color.red.opacity(0.12) : Color.clear), in: Capsule())
                    .overlay { Capsule().stroke((c < 0.6 ? Color.red.opacity(0.3) : Color.clear), lineWidth: 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.identidadeAcessivel(fala, falantePreservado: falantePreservado, nomesDeVoz: nomesDeVoz))
    }

    static func rotuloDoCanal(_ speaker: String?) -> String {
        switch speaker {
        case Speaker.eu: "Eu · microfone".localized
        case Speaker.interlocutor: "Interlocutor · áudio do sistema".localized
        default: "Canal misto ou desconhecido".localized
        }
    }

    static func identidadeAcessivel(
        _ fala: FalaDeFalante,
        falantePreservado: String?,
        nomesDeVoz: [String: String]
    ) -> String {
        let canal = rotuloDoCanal(fala.speaker)
        guard let acustico = fala.falanteAcustico ?? falantePreservado else { return canal }
        return "\(canal), \(RotuloDeVoz.exibicao(acustico, nomes: nomesDeVoz))"
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
        .help("Corrigir o texto desta fala".localized)
        .accessibilityLabel("Corrigir o texto desta fala".localized)
    }

    @ViewBuilder
    private var corpoDaFala: some View {
        if !fala.palavras.isEmpty {
            LayoutDeFluxo(espacoHorizontal: 1, espacoVertical: 3, justificado: true) {
                ForEach(Array(fala.palavras.enumerated()), id: \.element.palavra.id) { _, item in
                    let buscaDestacada = !termoDeBusca.isEmpty && item.palavra.texto.casaComBusca(termoDeBusca)
                    let ehAtual = buscaDestacada && idOcorrenciaAtual == item.palavra.id
                    let isBaixa = mostrarConfianca && (item.palavra.confianca ?? 1) <= 0.50 && (item.palavra.noSpeechProb ?? 0) < 0.6
                    BotaoDePalavra(
                        palavra: item.palavra,
                        ativa: item.trechoId == palavraAtiva?.trechoId
                            && item.indiceNoTrecho == palavraAtiva?.indiceNoTrecho,
                        destacadoPelaBusca: buscaDestacada,
                        ehOcorrenciaAtual: ehAtual,
                        isBaixaConfianca: isBaixa,
                        mostrarConfianca: mostrarConfianca,
                        mostrarPorcentagemConfianca: mostrarPorcentagemConfianca,
                        animacao: animacao,
                        acao: { aoTocarPalavra(item.palavra) }
                    )
                }
            }
        } else {
            let destaca = !termoDeBusca.isEmpty && fala.texto.casaComBusca(termoDeBusca)
            let ehAtual = destaca && idOcorrenciaAtual == fala.id
            Text(fala.texto)
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
