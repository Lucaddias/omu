import Foundation
import LlamaRuntime
import WhisperRuntime

/// Os dois modelos locais, com a garantia de que **nunca ficam residentes ao
/// mesmo tempo**.
///
/// Whisper large-v3 ocupa ~3 GB e o Qwen3.5 Q4_K_M ~6,2 GB. Mesmo assim,
/// manter os dois carregados durante um
/// processamento é o caminho mais curto para o jetsam matar o app no meio da
/// transcrição. Por isso `resumir` descarrega o Whisper antes de carregar o
/// Qwen, e `transcrever` faz o contrário.
///
/// É um ator porque a alternância entre os dois é justamente a invariante que
/// não pode ser corrida por duas chamadas concorrentes.
public actor MotoresLocais {
    public let pastaDeModelos: URL

    private var contextoWhisper: ContextoWhisper?
    private var contextoLlama: ContextoLlama?
    private let fila = FilaEstrita()
    private let ciclo: CicloDeVidaDeModelos?

    public init(pastaDeModelos: URL, ciclo: CicloDeVidaDeModelos? = nil) {
        self.pastaDeModelos = pastaDeModelos
        self.ciclo = ciclo
    }

    public var pesoDaTranscricao: URL {
        pastaDeModelos.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo)
    }

    public var pesoDoResumo: URL {
        pastaDeModelos.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    }

    // MARK: - Uso

    private func transcreverSemFila(
        _ audio: URL,
        speaker: String?,
        idioma: String? = nil,
        initialPrompt: String? = nil
    ) async throws -> [Trecho] {
        await descarregarResumoSemFila()
        let contexto = contextoWhisper ?? ContextoWhisper(modelo: pesoDaTranscricao)
        contextoWhisper = contexto
        await ciclo?.registrar(contexto)
        return try await WhisperEngine(contexto: contexto).transcribe(
            audio,
            speaker: speaker,
            idioma: idioma,
            initialPrompt: initialPrompt
        )
    }

    private func resumirSemFila(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento?
    ) async throws -> Resumo {
        await descarregarTranscricaoSemFila()
        let contexto = contextoLlama ?? ContextoLlama(modelo: pesoDoResumo)
        contextoLlama = contexto
        await ciclo?.registrar(contexto)
        return try await QwenEngine(contexto: contexto).summarize(
            trechos,
            idiomaDeSaida: idiomaDeSaida
        )
    }

    private func traduzirSemFila(
        _ trechos: [Trecho],
        para idioma: IdiomaDeProcessamento
    ) async throws -> [Trecho] {
        await descarregarTranscricaoSemFila()
        let contexto = contextoLlama ?? ContextoLlama(modelo: pesoDoResumo)
        contextoLlama = contexto
        await ciclo?.registrar(contexto)
        return try await QwenEngine(contexto: contexto).traduzir(trechos, para: idioma)
    }

    /// Resolve pelo contexto as falas que a diarização deixou sem falante.
    ///
    /// Primeiro a costura de vozes iguais (`ResolvedorDeFalantes
    /// .costurarVozesIguais`): fala duvidosa entre dois vizinhos do MESMO
    /// falante recebe o rótulo deles sem custo de modelo. O Qwen só entra
    /// quando sobram casos — fala curta entre falantes DIFERENTES — e nem aí
    /// é obrigatório: sem casos, o arquivo volta costurado e nada carrega.
    ///
    /// Usa o MESMO contexto do Qwen do resumo: se a fase de resumo vier logo
    /// atrás (como no `PipelineDeArquivo`), o modelo já está residente e não há
    /// carga dupla. Invariante de memória preservada: descarrega o Whisper
    /// antes de carregar o Qwen, como o `resumir`.
    private func resolverFalantesSemFila(_ arquivo: Arquivo) async throws -> Arquivo {
        let costurado = ResolvedorDeFalantes.costurarVozesIguais(arquivo)
        guard let falas = FalasDaConversa.agrupar(costurado.trechos) else { return costurado }
        let casos = ResolvedorDeFalantes.casosElegiveis(falas: falas)
        guard !casos.isEmpty else { return costurado }

        await descarregarTranscricaoSemFila()
        let contexto = contextoLlama ?? ContextoLlama(modelo: pesoDoResumo)
        contextoLlama = contexto
        await ciclo?.registrar(contexto)

        var resolucoes: [UUID: String] = [:]
        for lote in stride(from: 0, to: casos.count, by: ResolvedorDeFalantes.maxCasosPorChamada) {
            let casosDoLote = Array(
                casos[lote..<min(lote + ResolvedorDeFalantes.maxCasosPorChamada, casos.count)]
            )
            let bruto = try await contexto.completar(
                prompt: ResolvedorDeFalantes.prompt(para: casosDoLote),
                gramatica: ResolvedorDeFalantes.gramatica(para: casosDoLote),
                maxTokens: 1_024
            )
            resolucoes.merge(
                ResolvedorDeFalantes.decodificar(bruto, casos: casosDoLote)
            ) { _, novo in novo }
        }
        return ResolvedorDeFalantes.aplicar(resolucoes, casos: casos, em: costurado)
    }

    // MARK: - Descarga

    private func descarregarTranscricaoSemFila() async {
        guard let contexto = contextoWhisper else { return }
        await contexto.descarregar()
        await ciclo?.remover(contexto.identificador)
        contextoWhisper = nil
    }

    private func descarregarResumoSemFila() async {
        guard let contexto = contextoLlama else { return }
        await contexto.descarregar()
        await ciclo?.remover(contexto.identificador)
        contextoLlama = nil
    }

    public func transcrever(
        _ audio: URL,
        speaker: String?,
        idioma: String? = nil,
        initialPrompt: String? = nil
    ) async throws -> [Trecho] {
        try await comExclusividade {
            try await self.transcreverSemFila(
                audio,
                speaker: speaker,
                idioma: idioma,
                initialPrompt: initialPrompt
            )
        }
    }

    public func resumir(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento? = nil
    ) async throws -> Resumo {
        try await comExclusividade {
            try await self.resumirSemFila(trechos, idiomaDeSaida: idiomaDeSaida)
        }
    }

    /// Tradução estritamente local pelo mesmo Qwen do resumo. A chamada está
    /// na fila exclusiva porque o contexto não é thread-safe e porque Whisper
    /// e Qwen nunca podem ficar residentes juntos.
    public func traduzir(
        _ trechos: [Trecho],
        para idioma: IdiomaDeProcessamento
    ) async throws -> [Trecho] {
        try await comExclusividade {
            try await self.traduzirSemFila(trechos, para: idioma)
        }
    }

    public func resolverFalantes(_ arquivo: Arquivo) async throws -> Arquivo {
        try await comExclusividade { try await self.resolverFalantesSemFila(arquivo) }
    }

    /// A posse cobre também os awaits da engine: o ator sozinho permite
    /// alternar os modelos enquanto a operação anterior ainda precisa deles.
    private func comExclusividade<T: Sendable>(
        _ operacao: () async throws -> T
    ) async throws -> T {
        await fila.entrar()
        do {
            try Task.checkCancellation()
            let resultado = try await operacao()
            await fila.sair()
            return resultado
        } catch {
            await fila.sair()
            throw error
        }
    }

    public func descarregarTranscricao() async {
        await fila.entrar()
        await descarregarTranscricaoSemFila()
        await fila.sair()
    }

    public func descarregarResumo() async {
        await fila.entrar()
        await descarregarResumoSemFila()
        await fila.sair()
    }

    public func descarregarTudo() async {
        await fila.entrar()
        await descarregarTranscricaoSemFila()
        await descarregarResumoSemFila()
        await fila.sair()
    }
}
