import Foundation
import WhisperRuntime

private actor AcumuladorDeTrechos {
    private var trechos: [Trecho] = []

    func incluir(
        _ segmentos: [SegmentoWhisper],
        na janela: DetectorDeAtividadeDeVoz.JanelaEmFluxo,
        speaker: String?
    ) {
        trechos.append(contentsOf: segmentos.map { segmento in
            let palavras = segmento.palavras.map {
                Palavra(
                    start: $0.start + janela.inicio,
                    end: $0.end + janela.inicio,
                    texto: $0.texto,
                    confianca: $0.confianca,
                    noSpeechProb: $0.noSpeechProb,
                    falanteAcustico: nil
                )
            }
            return Trecho(
                start: segmento.start + janela.inicio,
                end: segmento.end + janela.inicio,
                texto: segmento.texto,
                speaker: speaker,
                palavras: palavras,
                confianca: Trecho.confiancaMedia(palavras) ?? segmento.confianca,
                noSpeechProb: segmento.noSpeechProb
            )
        })
    }

    func todos() -> [Trecho] { trechos }
}

/// A engine de transcrição do Papagaio. Não existe segunda (D-0.5).
///
/// Chama o `whisper.cpp` **in-process**, pela biblioteca linkada no Passo 3.
/// Nenhum `Process()`, nenhum binário do Homebrew — é o que permite manter
/// estes pesos e a Mac App Store ao mesmo tempo (D-0.6).
public struct WhisperEngine: TranscriptionEngine {
    /// Um só lugar para o identificador: ele vai para `Arquivo.engineTranscricao`
    /// e para o registro no `CicloDeVidaDeModelos`, e os três divergirem seria
    /// um bug silencioso nos metadados.
    public static let identificador = "whisper-large-v3"

    public let identifier = WhisperEngine.identificador

    private let contexto: ContextoWhisper

    /// - Parameter modelo: caminho do `ggml-large-v3.bin`.
    public init(modelo: URL) {
        self.contexto = ContextoWhisper(modelo: modelo)
    }

    /// Reaproveita um contexto já carregado — é o que mantém os 3 GB residentes
    /// entre transcrições.
    public init(contexto: ContextoWhisper) {
        self.contexto = contexto
    }

    public func transcribe(_ url: URL) async throws -> [Trecho] {
        try await transcribe(url, speaker: nil)
    }

    /// Transcreve atribuindo o falante pelo **canal de origem**.
    ///
    /// Não há modelo de diarização: microfone é `"eu"`, tap do sistema é
    /// `"interlocutor"`, e arquivo importado é `nil` — ver skill
    /// `papagaio-speaker-attribution`.
    ///
    /// Decodifica, detecta fala e chama o Whisper em fluxo: o arquivo inteiro
    /// nunca vira um único vetor em RAM e silêncio longo não chega ao decoder.
    public func transcribe(
        _ url: URL,
        speaker: String?,
        idioma: String? = nil,
        initialPrompt: String? = nil
    ) async throws -> [Trecho] {
        let sessao = DetectorDeAtividadeDeVoz.SessaoEmFluxo()
        let acumulador = AcumuladorDeTrechos()

        func transcrever(_ janelas: [DetectorDeAtividadeDeVoz.JanelaEmFluxo]) async throws {
            for janela in janelas where !janela.amostras.isEmpty {
                try Task.checkCancellation()
                let segmentosBrutos = try await contexto.transcrever(
                    amostras: janela.amostras,
                    idioma: idioma,
                    initialPrompt: initialPrompt
                )
                // Remove palavras que são puramente emoji (alucinação do
                // Whisper em silêncio/ruído) e descarta segmentos que ficaram
                // vazios depois da limpeza.
                let segmentos = segmentosBrutos.compactMap { seg -> SegmentoWhisper? in
                    let palavrasFiltradas = seg.palavras.filter { !$0.texto.ehSomenteEmoji }
                    guard !palavrasFiltradas.isEmpty else { return nil }
                    let textoLimpo = seg.texto.removendoEmojis()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !textoLimpo.isEmpty else { return nil }
                    return SegmentoWhisper(
                        start: seg.start,
                        end: seg.end,
                        texto: textoLimpo,
                        palavras: palavrasFiltradas,
                        confianca: seg.confianca,
                        noSpeechProb: seg.noSpeechProb
                    )
                }
                // O Whisper devolve t0/t1 relativos ao início da janela.
                await acumulador.incluir(segmentos, na: janela, speaker: speaker)
            }
        }

        try Task.checkCancellation()
        await sessao.iniciar()
        do {
            try await DecodificadorDeAudio.processarEmBlocos(de: url) { bloco in
                try Task.checkCancellation()
                try await transcrever(await sessao.receber(bloco))
            }
            try await transcrever(await sessao.finalizar())
        } catch {
            await sessao.cancelar()
            throw error
        }

        // Em uma reunião de dois canais, um deles pode estar em silêncio.
        // Devolver vazio preserva o outro canal e evita um resumo inventado.
        return await acumulador.todos()
    }

    /// Carrega o modelo antecipadamente, para a primeira transcrição não pagar
    /// os segundos de carga.
    public func preaquecer() async throws {
        try await contexto.carregar()
    }

    public func descarregar() async {
        await contexto.descarregar()
    }
}

extension ContextoWhisper: CicloDeVidaDeModelos.Residente {
    public nonisolated var identificador: String { WhisperEngine.identificador }
}
