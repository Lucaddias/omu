import Accelerate

/// Cancelador de eco acústico (AEC) em software.
///
/// Quando o usuário **não** está com fones, o áudio do sistema vaza para o
/// microfone: o som dos alto-falantes é capturado junto com a voz. Este
/// cancelador usa um filtro adaptativo NLMS (Normalized Least Mean Squares)
/// para estimar e subtrair o sinal de eco do microfone.
///
/// **Pré-condições de uso:**
/// - Ambos os sinais (microfone e sistema) devem estar em 16 kHz mono.
/// - O sinal do sistema é o *reference*; o do microfone é o *input*.
public final class CanceladorDeEco {

    /// Tamanho do bloco processado por chamada.
    public let tamanhoBloco: Int

    /// Comprimento do filtro adaptativo em amostras. 4096 taps ≈ 256 ms a 16 kHz.
    public let comprimentoFiltro: Int

    /// Passo (learning rate) do NLMS.
    private let mu: Float

    /// Coeficientes do filtro adaptativo.
    private var filtros: [Float]

    /// Últimas amostras de referência (sistema), guardadas **em dobro** e da
    /// mais recente para a mais antiga: `refBuffer[posicao ..< posicao + L]`
    /// é sempre a janela do filtro, contígua.
    ///
    /// Antes a janela era remontada a cada amostra, com 4.096 leituras de um
    /// buffer circular e um `%` em cada uma — era isso que fazia uma hora de
    /// áudio custar centenas de bilhões de iterações escalares.
    private var refBuffer: [Float]

    /// Onde está a amostra mais recente dentro da primeira metade do buffer.
    private var posicao: Int = 0

    /// ‖x‖² da janela atual, mantida de forma incremental.
    private var normaQuadrada: Float = 0

    // MARK: - Init

    /// - Parameters:
    ///   - tamanhoBloco: Número de amostras por chamada de `processar()`.
    ///   - comprimentoFiltro: Número de taps do filtro adaptativo.
    ///   - mu: Passo do NLMS (0 < μ ≤ 1).
    public init(
        tamanhoBloco: Int = 512,
        comprimentoFiltro: Int = 4096,
        mu: Float = 0.5
    ) {
        precondition(tamanhoBloco > 0)
        precondition(comprimentoFiltro >= tamanhoBloco)
        precondition(mu > 0 && mu <= 1)

        self.tamanhoBloco = tamanhoBloco
        self.comprimentoFiltro = comprimentoFiltro
        self.mu = mu
        self.filtros = [Float](repeating: 0, count: comprimentoFiltro)
        self.refBuffer = [Float](repeating: 0, count: comprimentoFiltro * 2)
    }

    // MARK: - API pública

    /// Processa um bloco de microfone e retorna o sinal com eco reduzido.
    public func processar(
        blocoMicrofone: [Float],
        blocoSistema: [Float]
    ) -> [Float] {
        guard blocoMicrofone.count == tamanhoBloco,
              blocoSistema.count == tamanhoBloco else {
            return blocoMicrofone
        }

        var saida = [Float](repeating: 0, count: tamanhoBloco)
        let comprimento = comprimentoFiltro
        let tamanho = vDSP_Length(comprimento)
        let passo = mu

        filtros.withUnsafeMutableBufferPointer { filtro in
            refBuffer.withUnsafeMutableBufferPointer { referencia in
                guard let w = filtro.baseAddress, let ref = referencia.baseAddress else { return }

                // A norma incremental acumula erro de arredondamento; uma
                // soma exata por bloco o mantém limitado.
                vDSP_svesq(ref + posicao, 1, &normaQuadrada, tamanho)

                for i in 0..<tamanhoBloco {
                    // Avança a janela: a amostra nova entra na frente e a
                    // mais antiga (que ocupava esta posição) sai.
                    posicao = (posicao == 0 ? comprimento : posicao) - 1
                    let nova = blocoSistema[i]
                    let antiga = ref[posicao]
                    ref[posicao] = nova
                    ref[posicao + comprimento] = nova
                    normaQuadrada = max(0, normaQuadrada + nova * nova - antiga * antiga)
                    let x = ref + posicao

                    // Saída do filtro: y = w^T · x
                    var estimativaEcho: Float = 0
                    vDSP_dotpr(w, 1, x, 1, &estimativaEcho, tamanho)

                    let erro = blocoMicrofone[i] - estimativaEcho
                    saida[i] = erro

                    // NLMS: w = w + μ · e · x / (‖x‖² + δ)
                    let norma = normaQuadrada + 1e-6
                    guard norma.isFinite, erro.isFinite else { continue }
                    var escalar = passo * erro / norma
                    vDSP_vsma(x, 1, &escalar, w, 1, w, 1, tamanho)
                }
            }
        }

        return saida
    }

    /// Processa um canal completo sem perder a cauda ou o último bloco parcial.
    /// A referência ausente equivale a silêncio, preservando a memória do filtro.
    ///
    /// Confere o cancelamento da tarefa a cada bloco: uma hora de gravação
    /// são dezenas de segundos de filtro, e mover a conversa para a lixeira
    /// não pode esperar isso terminar.
    func processar(microfone: [Float], sistema: [Float]) throws -> [Float] {
        var saida: [Float] = []
        saida.reserveCapacity(microfone.count)
        for inicio in stride(from: 0, to: microfone.count, by: tamanhoBloco) {
            try Task.checkCancellation()
            let fim = min(inicio + tamanhoBloco, microfone.count)
            var mic = Array(microfone[inicio..<fim])
            mic.append(contentsOf: repeatElement(0, count: tamanhoBloco - mic.count))
            var referencia = [Float](repeating: 0, count: tamanhoBloco)
            if inicio < sistema.count {
                let fimReferencia = min(inicio + tamanhoBloco, sistema.count)
                referencia.replaceSubrange(0..<(fimReferencia - inicio), with: sistema[inicio..<fimReferencia])
            }
            saida.append(contentsOf: processar(blocoMicrofone: mic, blocoSistema: referencia).prefix(fim - inicio))
        }
        return saida
    }

    /// Redefine o estado interno do cancelador.
    public func resetar() {
        filtros = [Float](repeating: 0, count: comprimentoFiltro)
        refBuffer = [Float](repeating: 0, count: comprimentoFiltro * 2)
        posicao = 0
        normaQuadrada = 0
    }
}
