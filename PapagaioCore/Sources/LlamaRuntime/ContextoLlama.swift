import Foundation
// `internal`: o módulo C não vaza para quem importa este target. Ver D-3.2.
internal import llama

public enum ErroLlama: Error, CustomStringConvertible {
    case modeloNaoCarregou(String)
    case contextoNaoCriado
    case gramaticaInvalida
    case falhaNoDecode(Int32)
    case promptGrandeDemais(tokens: Int, limite: Int)
    case limiteDeSaidaInvalido(Int)

    public var description: String {
        switch self {
        case let .modeloNaoCarregou(caminho):
            "não foi possível carregar o modelo em \(caminho)"
        case .contextoNaoCriado:
            "não foi possível criar o contexto do llama"
        case .gramaticaInvalida:
            "a gramática GBNF foi recusada pelo llama.cpp"
        case let .falhaNoDecode(codigo):
            "llama_decode falhou (código \(codigo))"
        case let .limiteDeSaidaInvalido(limite):
            "limite de saída inválido: \(limite)"
        case let .promptGrandeDemais(tokens, limite):
            "prompt de \(tokens) tokens excede o limite de \(limite)"
        }
    }
}

/// Envolve um `llama_context` num ator.
///
/// **`llama_context` não é thread-safe** — mesmo cuidado do `ContextoWhisper`.
/// O modelo fica residente entre resumos: são ~6,2 GB, e recarregar leva
/// 10–30 s.
public actor ContextoLlama {
    /// Caixa em volta dos ponteiros C, pelo mesmo motivo do `ContextoWhisper`:
    /// `deinit` não isolado não pode tocar propriedade isolada do ator.
    private final class Caixa: @unchecked Sendable {
        var modelo: OpaquePointer?
        var contexto: OpaquePointer?
        deinit {
            if let contexto { llama_free(contexto) }
            if let modelo { llama_model_free(modelo) }
        }
    }

    private var caixa = Caixa()
    private let caminhoDoModelo: URL
    private let janela: UInt32

    /// Janela operacional de 32k do Qwen3.5-9B. Passe único é o padrão até ~28k de entrada,
    /// deixando margem para a saída dentro dos 32k.
    public static let janelaPadrao: UInt32 = 32_768
    public static let tetoDeEntrada = 28_000

    /// Teto de tokens por chamada a `llama_decode`.
    ///
    /// `llama_decode` tem `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` — um
    /// prompt maior que isso **aborta o processo**, não devolve erro. Como o
    /// passe único vai até 28k tokens, o prefill é obrigatoriamente fatiado.
    public static let tokensPorLote = 2_048

    public init(modelo: URL, janela: UInt32 = ContextoLlama.janelaPadrao) {
        self.caminhoDoModelo = modelo
        self.janela = janela
    }

    public var carregado: Bool { caixa.contexto != nil }

    public func carregar() throws {
        guard caixa.contexto == nil else { return }

        llama_backend_init()

        var paramsModelo = llama_model_default_params()
        paramsModelo.n_gpu_layers = 999  // tudo na GPU via Metal

        let modelo = caminhoDoModelo.path.withCString { caminho in
            llama_model_load_from_file(caminho, paramsModelo)
        }
        guard let modelo else { throw ErroLlama.modeloNaoCarregou(caminhoDoModelo.path) }

        var paramsContexto = llama_context_default_params()
        paramsContexto.n_ctx = janela
        paramsContexto.n_batch = UInt32(Self.tokensPorLote)
        paramsContexto.n_ubatch = 512
        let nucleos = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        paramsContexto.n_threads = nucleos
        paramsContexto.n_threads_batch = nucleos

        guard let contexto = llama_init_from_model(modelo, paramsContexto) else {
            llama_model_free(modelo)
            throw ErroLlama.contextoNaoCriado
        }

        caixa.modelo = modelo
        caixa.contexto = contexto
    }

    public func descarregar() {
        if let contexto = caixa.contexto { llama_free(contexto) }
        if let modelo = caixa.modelo { llama_model_free(modelo) }
        caixa.contexto = nil
        caixa.modelo = nil
    }

    /// Conta tokens sem gerar nada — é o que decide passe único vs. map-reduce.
    public func contarTokens(_ texto: String) throws -> Int {
        try carregar()
        guard let modelo = caixa.modelo else { throw ErroLlama.contextoNaoCriado }
        let vocab = llama_model_get_vocab(modelo)
        return Self.tokenizar(texto, vocab: vocab, adicionarEspeciais: true).count
    }

    /// Conta vários textos numa chamada só.
    ///
    /// Um salto para o ator por texto era o custo do `particionar` da engine
    /// de resumo numa transcrição longa — centenas de idas e vindas. Aqui a
    /// tokenização roda em lote e volta de uma vez.
    public func contarTokens(_ textos: [String]) throws -> [Int] {
        try carregar()
        guard let modelo = caixa.modelo else { throw ErroLlama.contextoNaoCriado }
        let vocab = llama_model_get_vocab(modelo)
        return textos.map {
            Self.tokenizar($0, vocab: vocab, adicionarEspeciais: true).count
        }
    }

    /// Gera texto a partir de um prompt, opcionalmente restringindo a saída a
    /// uma gramática GBNF.
    ///
    /// A gramática é o que torna a saída estruturada **confiável**: em vez de
    /// pedir JSON no prompt e torcer, o decodificador só pode emitir tokens que
    /// a gramática aceita. `@Generable` do `FoundationModels` não existe aqui.
    public func completar(
        prompt: String,
        gramatica: String? = nil,
        maxTokens: Int = 2_048
    ) throws -> String {
        guard maxTokens > 0, maxTokens < Int(janela) else {
            throw ErroLlama.limiteDeSaidaInvalido(maxTokens)
        }
        try Task.checkCancellation()
        try carregar()
        guard let contexto = caixa.contexto, let modelo = caixa.modelo else {
            throw ErroLlama.contextoNaoCriado
        }
        let vocab = llama_model_get_vocab(modelo)

        // Também limpa em erro/cancelamento: o próximo prompt não pode herdar
        // um prefill parcial da chamada anterior.
        llama_memory_clear(llama_get_memory(contexto), true)
        defer { llama_memory_clear(llama_get_memory(contexto), true) }
        var tokens = Self.tokenizar(prompt, vocab: vocab, adicionarEspeciais: true)
        guard tokens.count < Int(janela) - maxTokens else {
            throw ErroLlama.promptGrandeDemais(
                tokens: tokens.count, limite: Int(janela) - maxTokens
            )
        }

        // Cadeia de amostragem: gramática primeiro (restringe o espaço), greedy
        // depois. Determinístico — resumo não é lugar para variação aleatória.
        let cadeia = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(cadeia) }

        if let gramatica {
            let amostrador = gramatica.withCString { g in
                "root".withCString { raiz in
                    llama_sampler_init_grammar(vocab, g, raiz)
                }
            }
            guard let amostrador else { throw ErroLlama.gramaticaInvalida }
            llama_sampler_chain_add(cadeia, amostrador)
        }
        llama_sampler_chain_add(cadeia, llama_sampler_init_greedy())

        // Prefill em fatias de `tokensPorLote`. As posições avançam sozinhas
        // entre chamadas consecutivas de `llama_decode`.
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            let fim = min(offset + Self.tokensPorLote, tokens.count)
            let codigo: Int32 = tokens.withUnsafeMutableBufferPointer { buffer in
                let fatia = buffer.baseAddress! + offset
                return llama_decode(contexto, llama_batch_get_one(fatia, Int32(fim - offset)))
            }
            guard codigo == 0 else { throw ErroLlama.falhaNoDecode(codigo) }
            offset = fim
        }

        // Decode token a token.
        var saida: [UInt8] = []
        var gerados = 0
        var proximo = llama_sampler_sample(cadeia, contexto, -1)

        while gerados < maxTokens, !llama_vocab_is_eog(vocab, proximo) {
            try Task.checkCancellation()
            saida.append(contentsOf: Self.pedaco(de: proximo, vocab: vocab))
            // Nada de `llama_sampler_accept` aqui: `llama_sampler_sample` é
            // "sample **and accept**" — aceitar de novo avança a pilha da
            // gramática duas vezes e mata o processo com
            // "Unexpected empty grammar stack after accepting piece".
            var unico = proximo
            let passo = withUnsafeMutablePointer(to: &unico) {
                llama_decode(contexto, llama_batch_get_one($0, 1))
            }
            guard passo == 0 else { throw ErroLlama.falhaNoDecode(passo) }

            proximo = llama_sampler_sample(cadeia, contexto, -1)
            gerados += 1
        }

        // Sessão nova a cada chamada: no modo map-reduce, o contexto de um
        // chunk não pode vazar para o próximo.
        // Tokens são fragmentos de bytes; um acento pode atravessar dois.
        // Decodificar antes de reuni-los produz U+FFFD irreversível.
        return String(decoding: saida, as: UTF8.self)
    }

    // MARK: - Ponte de tokens

    private static func tokenizar(
        _ texto: String,
        vocab: OpaquePointer?,
        adicionarEspeciais: Bool
    ) -> [llama_token] {
        let utf8 = texto.utf8CString
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        func preencher() -> Int32 {
            utf8.withUnsafeBufferPointer { entrada in
                tokens.withUnsafeMutableBufferPointer { saida in
                    llama_tokenize(
                        vocab, entrada.baseAddress, Int32(utf8.count - 1),
                        saida.baseAddress, Int32(saida.count),
                        adicionarEspeciais, true
                    )
                }
            }
        }
        var total = preencher()
        if total < 0 {
            tokens = [llama_token](repeating: 0, count: -Int(total))
            total = preencher()
        }
        guard total > 0 else { return [] }
        return Array(tokens.prefix(Int(total)))
    }

    private static func pedaco(de token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        func preencher() -> Int32 {
            buffer.withUnsafeMutableBufferPointer { destino in
                llama_token_to_piece(vocab, token, destino.baseAddress, Int32(destino.count), 0, false)
            }
        }
        var total = preencher()
        if total < 0 {
            buffer = [CChar](repeating: 0, count: -Int(total))
            total = preencher()
        }
        guard total > 0 else { return [] }
        return buffer.prefix(Int(total)).map { UInt8(bitPattern: $0) }
    }
}
