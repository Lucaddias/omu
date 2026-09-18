import Foundation
import LlamaRuntime

/// A engine de sumarização do Papagaio. Não existe segunda engine ativa.
///
/// Passe único é o padrão: a janela de 32k do Qwen cabe uma reunião inteira de
/// até ~3 h. Map-reduce só entra acima disso — e é o que permite o resumo
/// conectar um assunto do início com a retomada dele no fim, que é justamente o
/// que um modelo de 4k não faz.
public struct QwenEngine: SummarizationEngine {
    /// Ver a nota em `WhisperEngine.identificador` — mesmo motivo.
    public static let identificador = "qwen3.5-9b-q4_k_m"

    public let identifier = QwenEngine.identificador

    private let contexto: ContextoLlama

    /// Tamanho do chunk no modo map-reduce. ~8.000 tokens deixa espaço para o
    /// resumo parcial na mesma janela.
    public static let tokensPorChunk = 8_000
    /// Um lote de tradução deixa folga para a resposta JSON no contexto e não
    /// depende do teto de 4.096 tokens de uma única geração.
    public static let tokensPorLoteDeTraducao = 2_000

    public init(modelo: URL) {
        self.contexto = ContextoLlama(modelo: modelo)
    }

    public init(contexto: ContextoLlama) {
        self.contexto = contexto
    }

    public func summarize(_ trechos: [Trecho]) async throws -> Resumo {
        try await summarize(trechos, idiomaDeSaida: nil)
    }

    public func summarize(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento? = nil
    ) async throws -> Resumo {
        guard !trechos.isEmpty else {
            throw NotImplemented("resumo de transcrição vazia", passo: 7)
        }

        let transcricao = Self.formatar(trechos)
        let tokens = try await contexto.contarTokens(transcricao)

        let bruto = tokens <= ContextoLlama.tetoDeEntrada
            ? try await passeUnico(transcricao, idiomaDeSaida: idiomaDeSaida)
            : try await mapReduce(trechos, idiomaDeSaida: idiomaDeSaida)

        // O modelo sugere; a transcrição decide. Sem esta passagem, o que
        // chega à tela é a lembrança que o Qwen tem da conversa — texto
        // parafraseado e `start` estimado, que leva o player para o lugar
        // errado. Ver `ValidacaoDeCitacoes`.
        return Resumo(
            titulo: bruto.titulo,
            visaoGeral: bruto.visaoGeral,
            temas: bruto.temas,
            citacoes: ValidacaoDeCitacoes.validar(bruto.citacoes, contra: trechos),
            proximosPassos: bruto.proximosPassos
        )
    }

    /// Traduz os textos dos trechos mantendo a linha do tempo e o canal de
    /// origem. As palavras do Whisper são removidas deliberadamente: depois da
    /// tradução elas não representam mais o texto mostrado e não podem servir
    /// de âncora de busca ou reprodução palavra a palavra.
    public func traduzir(
        _ trechos: [Trecho],
        para idioma: IdiomaDeProcessamento
    ) async throws -> [Trecho] {
        guard !trechos.isEmpty else { return [] }

        let lotes = try await particionarParaTraducao(trechos)
        var traduzidos: [Trecho] = []
        traduzidos.reserveCapacity(trechos.count)
        for lote in lotes {
            try Task.checkCancellation()
            traduzidos.append(contentsOf: try await traduzirLote(lote, para: idioma))
        }
        return traduzidos
    }

    private func traduzirLote(
        _ trechos: [Trecho],
        para idioma: IdiomaDeProcessamento
    ) async throws -> [Trecho] {
        let bruto = try await contexto.completar(
            prompt: Self.promptDeTraducao(trechos, para: idioma),
            gramatica: GramaticaDaTraducao.gbnf,
            maxTokens: 4_096
        )
        guard let traducoes = Self.decodificarTraducoes(bruto),
              traducoes.count == trechos.count,
              traducoes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw ErroLlama.gramaticaInvalida
        }

        return zip(trechos, traducoes).map { original, textoTraduzido in
            Trecho(
                id: original.id,
                start: original.start,
                end: original.end,
                texto: textoTraduzido,
                speaker: original.speaker,
                palavras: [],
                confianca: original.confianca,
                noSpeechProb: original.noSpeechProb
            )
        }
    }

    private func particionarParaTraducao(_ trechos: [Trecho]) async throws -> [[Trecho]] {
        let contagens = try await contexto.contarTokens(trechos.map(\.texto))
        var lotes: [[Trecho]] = []
        var loteAtual: [Trecho] = []
        var tokensAtuais = 0

        for (trecho, tokens) in zip(trechos, contagens) {
            if tokensAtuais + tokens > Self.tokensPorLoteDeTraducao,
               !loteAtual.isEmpty {
                lotes.append(loteAtual)
                loteAtual = []
                tokensAtuais = 0
            }
            loteAtual.append(trecho)
            tokensAtuais += tokens
        }
        if !loteAtual.isEmpty { lotes.append(loteAtual) }
        return lotes
    }

    // MARK: - Passe único

    private func passeUnico(
        _ transcricao: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) async throws -> Resumo {
        let prompt = Self.prompt(paraTranscricao: transcricao, idiomaDeSaida: idiomaDeSaida)
        return try await gerarComReprompt(prompt: prompt)
    }

    /// Gera com a gramática e, se mesmo assim o JSON não decodificar, tenta uma
    /// vez com a instrução de formato reforçada.
    ///
    /// A gramática já garante a sintaxe; o reprompt cobre o caso de a saída
    /// estar sintaticamente válida mas semanticamente incompleta (campo
    /// faltando por truncamento, por exemplo).
    private func gerarComReprompt(prompt: String) async throws -> Resumo {
        let bruto = try await contexto.completar(
            prompt: prompt,
            gramatica: GramaticaDoResumo.gbnf,
            maxTokens: 4_096
        )

        if let resumo = Self.decodificar(bruto) { return resumo }

        let corrigido = try await contexto.completar(
            prompt: Self.promptDeCorrecao(saidaInvalida: bruto),
            gramatica: GramaticaDoResumo.gbnf,
            maxTokens: 4_096
        )
        guard let resumo = Self.decodificar(corrigido) else {
            throw ErroLlama.gramaticaInvalida
        }
        return resumo
    }

    // MARK: - Map-reduce

    private func mapReduce(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento?
    ) async throws -> Resumo {
        let chunks = try await particionar(trechos)

        var parciais: [String] = []
        for chunk in chunks {
            // Sessão nova por chunk — o `completar` limpa a memória do contexto
            // ao final de cada chamada.
            let parcial = try await contexto.completar(
                prompt: Self.promptParcial(Self.formatar(chunk), idiomaDeSaida: idiomaDeSaida),
                gramatica: nil,
                maxTokens: 2_048
            )
            parciais.append(parcial)
        }

        let consolidado = parciais.enumerated()
            .map { "## Parte \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")

        return try await gerarComReprompt(
            prompt: Self.promptDeReducao(consolidado, idiomaDeSaida: idiomaDeSaida)
        )
    }

    private func particionar(_ trechos: [Trecho]) async throws -> [[Trecho]] {
        // Contagem em lote: um salto só para o ator, no lugar de um
        // round-trip por trecho — centenas a menos numa conversa longa.
        let contagens = try await contexto.contarTokens(trechos.map { Self.formatar([$0]) })

        var chunks: [[Trecho]] = []
        var atual: [Trecho] = []
        var tokensAtuais = 0

        for (trecho, tokens) in zip(trechos, contagens) {
            if tokensAtuais + tokens > Self.tokensPorChunk, !atual.isEmpty {
                chunks.append(atual)
                atual = []
                tokensAtuais = 0
            }
            atual.append(trecho)
            tokensAtuais += tokens
        }
        if !atual.isEmpty { chunks.append(atual) }
        return chunks
    }

    // MARK: - Prompts

    /// Cada linha carrega o tempo e o falante — é o que permite ao modelo
    /// preencher `start` nas citações e `responsavel` nos próximos passos.
    public static func formatar(_ trechos: [Trecho]) -> String {
        trechos.map { trecho in
            let minutos = Int(trecho.start) / 60
            let segundos = Int(trecho.start) % 60
            let quem = trecho.speaker ?? "desconhecido"
            return String(format: "[%02d:%02d] (%@) %@", minutos, segundos, quem, trecho.texto)
        }.joined(separator: "\n")
    }

    static func prompt(
        paraTranscricao transcricao: String,
        idiomaDeSaida: IdiomaDeProcessamento? = nil
    ) -> String {
        """
        <|im_start|>system
        Você é o "Ateiro Profissa", um analista sênior que transforma diálogos \
        caóticos e transcrições brutas em atas limpas, estratégicas e acionáveis \
        \(Self.instrucaoDeIdioma(idiomaDeSaida)). Regras: (1) seja fiel à transcrição, não invente \
        números, nomes nem decisões. (2) Sem termos corporativos vazios — nada de \
        "sinergia", "disrupção" ou "com base em nossos aprendizados". Seja direto \
        e realista. (3) Use os nomes EXATAMENTE como aparecem na transcrição, sem \
        alterar, corrigir nem inventar variações. Se o nome aparecer como "Dr. Nando", \
        use "Dr. Nando" em todo o resumo, nunca "Fernando" nem "Nando". (4) Produza \
        uma análise completa e detalhada, proporcional à duração da reunião.<|im_end|>
        <|im_start|>user
        Analise a reunião abaixo e produza uma ata profissional completa e detalhada. \
        Não comprima: cubra todos os assuntos e organize os temas com pontos e subpontos, \
        incluindo valores, datas, nomes, prazos e decisões quando estiverem na transcrição.

        \(GramaticaDoResumo.descricaoDoFormato)

        TRANSCRIÇÃO:
        \(transcricao)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>\n

        """
    }

    static func promptParcial(
        _ transcricao: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) -> String {
        """
        <|im_start|>system
        Você é o "Ateiro Profissa". Resume trechos de reunião de forma fiel, \
        detalhada e sem floreios. \(Self.instrucaoDeIdioma(idiomaDeSaida))<|im_end|>
        <|im_start|>user
        Resuma este trecho de forma completa e detalhada, preservando números, \
        nomes, decisões e argumentos de cada lado. Não comprima.

        \(transcricao)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>\n

        """
    }

    static func promptDeReducao(
        _ parciais: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) -> String {
        """
        <|im_start|>system
        Você é o "Ateiro Profissa". Consolida resumos parciais de uma mesma \
        reunião, conectando assuntos e classificando \
        cada tópico como Ponto Principal ou Secundário. Produza uma ata completa.<|im_end|>
        <|im_start|>user
        \(Self.instrucaoDeIdioma(idiomaDeSaida)) Os textos abaixo são resumos de partes consecutivas da MESMA reunião. \
        Consolide numa ata profissional completa e detalhada, conectando assuntos \
        que aparecem em partes diferentes. Cubra todos os tópicos discutidos.

        \(GramaticaDoResumo.descricaoDoFormato)

        \(parciais)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>\n

        """
    }

    /// `nil` preserva o idioma detectado na transcrição. Isso é diferente de
    /// "português por padrão": um sistema em inglês falando inglês não deve
    /// receber uma ata traduzida só porque o prompt foi escrito em português.
    private static func instrucaoDeIdioma(_ idioma: IdiomaDeProcessamento?) -> String {
        guard let idioma else {
            return "Escreva no mesmo idioma predominante da transcrição; não a traduza."
        }
        return "Escreva toda a resposta em \(idioma.nomeParaPrompt)."
    }

    private static func promptDeTraducao(
        _ trechos: [Trecho],
        para idioma: IdiomaDeProcessamento
    ) -> String {
        let entrada = trechos.enumerated().map { indice, trecho in
            "\(indice): \(trecho.texto)"
        }.joined(separator: "\n")
        return """
        <|im_start|>system
        You are a precise offline translator. Translate each input item into \(idioma.nomeParaPrompt). Preserve names, numbers, dates, acronyms and intent. Do not summarize, omit, merge or split items.<|im_end|>
        <|im_start|>user
        Return exactly one JSON object matching the requested grammar. Its `traducoes` array must contain exactly \(trechos.count) strings in the same order as the numbered inputs. No explanations.

        INPUTS:
        \(entrada)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
    }

    static func promptDeCorrecao(saidaInvalida: String) -> String {
        """
        <|im_start|>system
        Você corrige JSON malformado.<|im_end|>
        <|im_start|>user
        A saída abaixo deveria ser um JSON válido no formato pedido, mas não é. \
        Reescreva-a corretamente.

        \(GramaticaDoResumo.descricaoDoFormato)

        SAÍDA INVÁLIDA:
        \(saidaInvalida.prefix(4_000))<|im_end|>
        <|im_start|>assistant
        <think>

        </think>\n

        """
    }

    // MARK: - Decodificação

    static func decodificar(_ bruto: String) -> Resumo? {
        // O modelo pode emitir texto antes/depois do objeto mesmo com gramática
        // (por exemplo, se a gramática não foi aplicada). Recorta do primeiro
        // `{` ao último `}`.
        guard let inicio = bruto.firstIndex(of: "{"),
              let fim = bruto.lastIndex(of: "}"), inicio < fim
        else { return nil }
        let json = String(bruto[inicio...fim])
        return try? JSONDecoder().decode(Resumo.self, from: Data(json.utf8))
    }

    private static func decodificarTraducoes(_ bruto: String) -> [String]? {
        struct Resposta: Decodable { let traducoes: [String] }
        guard let inicio = bruto.firstIndex(of: "{"),
              let fim = bruto.lastIndex(of: "}"), inicio < fim
        else { return nil }
        let resposta = try? JSONDecoder().decode(
            Resposta.self,
            from: Data(String(bruto[inicio...fim]).utf8)
        )
        return resposta?.traducoes
    }

    public func preaquecer() async throws {
        try await contexto.carregar()
    }

    public func descarregar() async {
        await contexto.descarregar()
    }
}

extension ContextoLlama: CicloDeVidaDeModelos.Residente {
    public nonisolated var identificador: String { QwenEngine.identificador }
}
