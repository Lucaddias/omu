import Foundation
// `internal`: o módulo C não vaza para quem importa este target. Ver D-3.2.
internal import whisper

/// Uma palavra com timestamps reais do Whisper (`token_timestamps`).
///
/// Os tempos vêm em centésimos de segundo, como os do segmento. O agrupamento
/// dos tokens em palavras é do `ContextoWhisper` — aqui só viaja o valor.
public struct PalavraWhisper: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let texto: String
    public let confianca: Float?
    public let noSpeechProb: Float?

    public init(start: TimeInterval, end: TimeInterval, texto: String, confianca: Float? = nil, noSpeechProb: Float? = nil) {
        self.start = start
        self.end = end
        self.texto = texto
        self.confianca = confianca
        self.noSpeechProb = noSpeechProb
    }
}

/// Um segmento nativo do Whisper. Tipo Swift puro — nenhum tipo do ggml
/// atravessa a fronteira deste target, que é o que permite o `internal import`.
public struct SegmentoWhisper: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let texto: String
    /// Palavras com timestamps próprios, na ordem da fala.
    public let palavras: [PalavraWhisper]
    public let confianca: Float?
    public let noSpeechProb: Float?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        texto: String,
        palavras: [PalavraWhisper] = [],
        confianca: Float? = nil,
        noSpeechProb: Float? = nil
    ) {
        self.start = start
        self.end = end
        self.texto = texto
        self.palavras = palavras
        self.confianca = confianca
        self.noSpeechProb = noSpeechProb
    }
}

public enum ErroWhisper: Error, CustomStringConvertible {
    case modeloNaoCarregou(String)
    case falhaNaTranscricao(Int32)
    case audioVazio
    case semFalaDetectada

    public var description: String {
        switch self {
        case let .modeloNaoCarregou(caminho):
            "não foi possível carregar o modelo em \(caminho)"
        case let .falhaNaTranscricao(codigo):
            "whisper_full falhou (código \(codigo))"
        case .audioVazio:
            "áudio sem amostras"
        case .semFalaDetectada:
            "não foi detectada fala suficiente neste áudio"
        }
    }
}

/// Envolve um `whisper_context` num ator.
///
/// **`whisper_context` não é thread-safe.** Um ator por contexto, e nunca duas
/// chamadas concorrentes ao mesmo. É por isso que a carga do modelo e a
/// transcrição vivem aqui dentro, e não numa struct qualquer.
///
/// O modelo fica **residente** entre transcrições: carregar 3 GB do disco leva
/// segundos, e recarregar a cada chamada tornaria a transcrição de um trecho
/// curto mais lenta que o próprio áudio.
public actor ContextoWhisper {
    /// Caixa em volta do ponteiro C.
    ///
    /// Existe por uma restrição do Swift 6: um `deinit` não isolado não pode
    /// tocar propriedade isolada do ator. Com a caixa, quem libera o
    /// `whisper_context` é o `deinit` dela, que roda quando o ator morre.
    private final class Caixa: @unchecked Sendable {
        var ponteiro: OpaquePointer?
        init(_ ponteiro: OpaquePointer? = nil) { self.ponteiro = ponteiro }
        deinit { if let ponteiro { whisper_free(ponteiro) } }
    }

    private var caixa = Caixa()
    private var contexto: OpaquePointer? { caixa.ponteiro }
    private let caminhoDoModelo: URL

    /// Amostras esperadas: PCM Float32 **mono 16 kHz** — o formato canônico do
    /// `FormatoAudio`. O Whisper não reamostra por conta própria.
    public static let taxaEsperada: Double = 16_000

    public init(modelo: URL) {
        self.caminhoDoModelo = modelo
    }

    public var carregado: Bool { contexto != nil }

    /// Carrega o peso GGUF na memória (e na GPU, via Metal).
    public func carregar() throws {
        guard contexto == nil else { return }

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        let ponteiro = caminhoDoModelo.path.withCString { caminho in
            whisper_init_from_file_with_params(caminho, params)
        }
        guard let ponteiro else {
            throw ErroWhisper.modeloNaoCarregou(caminhoDoModelo.path)
        }
        caixa.ponteiro = ponteiro
    }

    /// Libera o modelo. Chamado sob pressão de memória — ver `CicloDeVidaDeModelos`.
    public func descarregar() {
        if let ponteiro = caixa.ponteiro { whisper_free(ponteiro) }
        caixa.ponteiro = nil
    }

    /// Transcreve amostras PCM Float32 mono 16 kHz.
    ///
    /// - Parameter idioma: código ISO-639-1 opcional. `nil` usa a detecção
    ///   automática do próprio Whisper; nunca deve receber o idioma da
    ///   interface como se fosse o idioma falado. O peso large-v3 é
    ///   multilíngue e não exige asset de locale separado.
    public func transcrever(
        amostras: [Float],
        idioma: String? = nil,
        initialPrompt: String? = nil,
        threads: Int32 = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    ) throws -> [SegmentoWhisper] {
        guard !amostras.isEmpty else { throw ErroWhisper.audioVazio }
        try carregar()
        guard let contexto else { throw ErroWhisper.modeloNaoCarregou(caminhoDoModelo.path) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = false
        params.single_segment = false
        // Nada de imprimir: a saída do whisper.cpp vai para stdout e polui a UI
        // e os logs do app.
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_blank = true
        // Uma hipótese ruim não pode contaminar janelas posteriores e virar
        // repetição em cascata durante silêncio ou ruído.
        params.no_context = true
        // Timestamps por token: é o que permite destacar a palavra exata que
        // está tocando (a UI não cai em divisão do tempo do trecho). O large-v3
        // foi treinado com timestamps de palavra, então o `t0`/`t1` dos tokens
        // é medido, não estimado por distribuição.
        params.token_timestamps = true
        let lingua = (idioma != nil && !idioma!.isEmpty) ? idioma! : "auto"
        let codigo = comCStringOpcional(initialPrompt) { prompt in
            lingua.withCString { ponteiroIdioma in
                params.initial_prompt = prompt
                params.language = ponteiroIdioma
                params.detect_language = false
                return amostras.withUnsafeBufferPointer { buffer in
                    whisper_full(contexto, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard codigo == 0 else { throw ErroWhisper.falhaNaTranscricao(codigo) }

        let total = whisper_full_n_segments(contexto)
        var segmentos: [SegmentoWhisper] = []
        segmentos.reserveCapacity(Int(total))

        for indice in 0..<total {
            guard let cTexto = whisper_full_get_segment_text(contexto, indice) else { continue }
            let texto = String(cString: cTexto).trimmingCharacters(in: .whitespaces)
            guard !texto.isEmpty else { continue }

            // Os timestamps vêm em centésimos de segundo.
            let t0 = TimeInterval(whisper_full_get_segment_t0(contexto, indice)) / 100
            let t1 = TimeInterval(whisper_full_get_segment_t1(contexto, indice)) / 100
            let noSpeech = whisper_full_get_segment_no_speech_prob(contexto, indice)
            let palavras = palavrasDoSegmento(indice)
            let confSeg: Float? = {
                let vals = palavras.compactMap(\.confianca)
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Float(vals.count)
            }()

            segmentos.append(SegmentoWhisper(
                start: t0,
                end: t1,
                texto: texto,
                palavras: palavras,
                confianca: confSeg,
                noSpeechProb: noSpeech
            ))
        }
        return segmentos
    }

    /// Executa um bloco garantindo que o ponteiro C opcional permaneça válido durante a chamada.
    private func comCStringOpcional<R>(_ string: String?, _ corpo: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string, !string.isEmpty else { return corpo(nil) }
        return string.withCString { corpo($0) }
    }

    /// Agrupa os tokens do segmento em palavras, na ordem da fala.
    ///
    /// O tokenizer do Whisper prefixa o espaço à token que **abre** uma palavra
    /// (`" olá"`, `" mundo"`); as tokens seguintes sem espaço (`"lá"`) são
    /// fragmentos da mesma palavra (BPE). Combinar um espaço à frente →
    /// palavra nova reproduz o desmembramento de frase do próprio whisper.cpp.
    ///
    /// `t0`/`t1` de cada token são medidos em centésimos: a palavra herda o
    /// início da primeira token e o fim da última.
    ///
    /// **Acumula bytes, não `String`.** O vocabulário do Whisper é BPE de
    /// bytes: um caractere multibyte — `é`, `ç`, `ã` — pode ser partido entre
    /// dois tokens, cada um carregando metade da sequência UTF-8. Decodificar
    /// token a token com `String(cString:)` faz o Swift trocar cada metade
    /// inválida por U+FFFD, e o caractere original se perde antes da junção:
    /// a palavra virava `êêêêê…` na tela. O texto do **segmento** nunca teve o
    /// problema porque o whisper.cpp o monta em C, byte a byte — era por isso
    /// que a mesma fala aparecia certa na folha de correção e errada na
    /// transcrição. Juntando os bytes e decodificando uma vez no fim, a
    /// sequência chega inteira ao decoder.
    private func palavrasDoSegmento(_ indice: Int32) -> [PalavraWhisper] {
        let total = whisper_full_n_tokens(contexto, indice)
        guard total > 0 else { return [] }

        var palavras: [PalavraWhisper] = []
        palavras.reserveCapacity(Int(total))
        var bytesDaPalavra: [UInt8] = []
        var inicioDaPalavra: TimeInterval = 0
        var fimDaPalavra: TimeInterval = 0
        var confiancasDaPalavra: [Float] = []
        let noSpeech = whisper_full_get_segment_no_speech_prob(contexto, indice)

        func fecharPalavra() {
            guard !bytesDaPalavra.isEmpty else { return }
            let texto = String(decoding: bytesDaPalavra, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            bytesDaPalavra.removeAll(keepingCapacity: true)
            let conf: Float? = confiancasDaPalavra.isEmpty ? nil : confiancasDaPalavra.reduce(0, +) / Float(confiancasDaPalavra.count)
            confiancasDaPalavra.removeAll(keepingCapacity: true)
            guard !texto.isEmpty else { return }
            // O Whisper gera caracteres de emoji (💕, 😊, 🎵) como texto
            // quando processa silêncio ou ruído de fundo. Descarta palavras
            // que são puramente emoji.
            guard !palavraEhSomenteEmoji(texto) else { return }
            palavras.append(PalavraWhisper(
                start: inicioDaPalavra,
                end: fimDaPalavra,
                texto: texto,
                confianca: conf,
                noSpeechProb: noSpeech
            ))
        }

        for token in 0..<total {
            let dados = whisper_full_get_token_data(contexto, indice, token)

            // Tokens especiais não são fala — timestamps, controle (`<|SOT|>`),
            // idiomas, etc. Todos têm id a partir do `eot`. Filtra-se por **id**,
            // nunca pelo texto: este build do whisper.cpp os renderiza como
            // `[_BEG_]` e `[_TT_88]`, sem o `<|` do vocabulário, e o filtro de
            // texto da primeira tentativa os vazou para as palavras mostradas.
            guard dados.id < whisper_token_eot(contexto) else { continue }

            guard let cToken = whisper_full_get_token_text(contexto, indice, token) else { continue }
            let bytesDoToken = Array(UnsafeBufferPointer(
                start: UnsafeRawPointer(cToken).assumingMemoryBound(to: UInt8.self),
                count: strlen(cToken)
            ))
            guard !bytesDoToken.isEmpty else { continue }

            let t0 = TimeInterval(dados.t0) / 100
            let t1 = TimeInterval(dados.t1) / 100
            // Usa a API específica de probabilidade. Ela é a fonte pública
            // do valor `p` do token e continua funcionando mesmo quando a
            // struct retornada por `whisper_full_get_token_data` muda entre
            // versões do binding.
            let confiancaDoToken = whisper_full_get_token_p(contexto, indice, token)

            // O espaço é sempre 0x20 em UTF-8 e nunca aparece dentro de uma
            // sequência multibyte, então testar o primeiro byte é seguro sem
            // decodificar nada.
            if bytesDoToken[0] == 0x20 {
                fecharPalavra()
                bytesDaPalavra = Array(bytesDoToken.dropFirst())
                inicioDaPalavra = t0
                fimDaPalavra = t1
                confiancasDaPalavra = [confiancaDoToken]
            } else {
                if bytesDaPalavra.isEmpty {
                    inicioDaPalavra = t0
                }
                bytesDaPalavra.append(contentsOf: bytesDoToken)
                fimDaPalavra = t1
                confiancasDaPalavra.append(confiancaDoToken)
            }
        }
        fecharPalavra()
        return palavras
    }

    /// Verifica se um texto é composto exclusivamente por caracteres de emoji.
    ///
    /// Usado para descartar palavras hallucinadas pelo Whisper em silêncio ou
    /// ruído (💕, 😊, 🎵 etc.). Não importa `PapagaioCore` para ter acesso
    /// ao `Character.ehEmoji`, então replica a lógica de ranges Unicode.
    private nonisolated func palavraEhSomenteEmoji(_ texto: String) -> Bool {
        for caracter in texto {
            guard caracter.unicodeScalars.allSatisfy({ scalar in
                let b = scalar.value
                return (0x1F600...0x1F64F).contains(b) ||
                    (0x1F300...0x1F5FF).contains(b) ||
                    (0x1F680...0x1F6FF).contains(b) ||
                    (0x1F1E0...0x1F1FF).contains(b) ||
                    (0x1F900...0x1F9FF).contains(b) ||
                    (0x1FA00...0x1FA6F).contains(b) ||
                    (0x1FA70...0x1FAFF).contains(b) ||
                    (0x2600...0x26FF).contains(b) ||
                    (0x2700...0x27BF).contains(b) ||
                    (0xFE00...0xFE0F).contains(b) ||
                    b == 0x200D ||
                    b == 0x20E3 ||
                    (0xE0020...0xE007F).contains(b)
            }) else { return false }
        }
        return !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Capacidades do build, para diagnóstico.
    public nonisolated var systemInfo: String { WhisperRuntime.systemInfo }
}
