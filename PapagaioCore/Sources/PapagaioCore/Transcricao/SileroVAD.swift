import Foundation
import OnnxApi

/// VAD neural de fala — modelo `silero_vad.onnx` (2,3 MB) rodando no ONNX
/// Runtime (M.1), no lugar da antiga heurística de energia/achatamento
/// espectral. O modelo distingue fala real de tom, DC e ruído — coisas que só
/// a energia não separa.
///
/// Padrão do `ContextoWhisper`: ator (a sessão ONNX **não é thread-safe**),
/// modelo residente entre chamadas, `descarregar()` sob pressão de memória
/// (`CicloDeVidaDeModelos`).
///
/// Contrato de entrada (verificado contra `utils_vad.py` do silero-vad):
/// - quadro de **512 amostras** (32 ms @ 16 kHz);
/// - contexto: as últimas 64 amostras do quadro anterior (memória de frase);
/// - estado interno `[2,1,128]` carregado entre quadros;
/// - saída: probabilidade de fala no intervalo [0,1] — limiar 0,5 validado
///   empiricamente (fala TTS chega a 1,0; DC/tom/ruído ficam abaixo de 0,2).
///
/// A inferência é bloqueante, mas minúscula: ~0,07 ms por quadro nesta máquina.
public actor SileroVAD: CicloDeVidaDeModelos.Residente {
#if OMU_PERF
    public typealias RegistradorDeEventoPerf = @Sendable (String, String, TimeInterval?) -> Void
#endif
    /// Um só lugar para o identificador (ver `WhisperEngine.identificador`).
    public static let identificador = "silero-vad"

    /// O modelo espera exatamente este tamanho de quadro — 512 amostras,
    /// 32 ms @ 16 kHz. O `DetectorDeAtividadeDeVoz` adota 0,032 s por padrão.
    public static let amostrasPorQuadro = 512
    public static let contextoEmAmostras = 64

    public nonisolated var identificador: String { SileroVAD.identificador }

    /// Resource `silero_vad.onnx` no bundle do PapagaioCore (processado pelo
    /// SwiftPM). Exposto para a CLI de bench medir o caminho neural real.
    public static var urlDoModeloPadrao: URL {
        Bundle.module.url(forResource: "silero_vad", withExtension: "onnx")
            ?? URL(fileURLWithPath: "/inexistente/silero_vad.onnx")
    }

    private let caminhoDoModelo: URL
    private let sessao: SessaoOnnx
    private var contexto = [Float](repeating: 0, count: SileroVAD.contextoEmAmostras)
    private var estado = [Float](repeating: 0, count: 2 * 1 * 128)
    private var modeloVerificado = false

    /// - Parameter modelo: caminho do `silero_vad.onnx` (resource do bundle).
#if OMU_PERF
    public init(modelo: URL, registrarEventoPerf: RegistradorDeEventoPerf? = nil) {
        self.caminhoDoModelo = modelo
        let callbackOnnx: SessaoOnnx.RegistradorDeEventoPerf?
        if let registrarEventoPerf {
            callbackOnnx = { evento, duracao in registrarEventoPerf(evento, Self.identificador, duracao) }
        } else {
            callbackOnnx = nil
        }
        self.sessao = SessaoOnnx(modelo: modelo, registrarEventoPerf: callbackOnnx)
    }
#else
    public init(modelo: URL) {
        self.caminhoDoModelo = modelo
        self.sessao = SessaoOnnx(modelo: modelo)
    }
#endif

    /// O `.onnx` está no lugar? Sem ele a inferência lança `modeloAusente` —
    /// quem chama usa isto para degradar com aviso em vez de falhar.
    public func modeloDisponivel() -> Bool {
        FileManager.default.fileExists(atPath: caminhoDoModelo.path)
    }

    /// Começa uma sequência nova (um arquivo de áudio novo): zera o contexto e
    /// o estado. Chamar sem isso com outro arquivo vazaria a "memória" da fala
    /// anterior.
    public func novaSequencia() {
        contexto = [Float](repeating: 0, count: SileroVAD.contextoEmAmostras)
        estado = [Float](repeating: 0, count: 2 * 1 * 128)
    }

    /// Probabilidade de fala de um lote de quadros, na mesma ordem.
    ///
    /// Um salto para o ator por quadro eram dezenas de milhares de idas e
    /// vindas numa hora de áudio; o lote corta para um salto por arquivo.
    /// A ordem das saídas é a das entradas.
    public func probabilidadesDeFala(quadros: [[Float]]) async throws -> [Float] {
        var probabilidades: [Float] = []
        probabilidades.reserveCapacity(quadros.count)
        for quadro in quadros {
            probabilidades.append(try await probabilidadeDeFala(quadro: quadro))
        }
        return probabilidades
    }

    /// Probabilidade de fala de um quadro. Quadros menores que 512 amostras
    /// (fim de arquivo) são completados com zero; quadros maiores são
    /// processados em fatias de 512, devolvendo a maior probabilidade.
    public func probabilidadeDeFala(quadro: [Float]) async throws -> Float {
        guard !quadro.isEmpty else { return 0 }
        if !modeloVerificado {
            guard FileManager.default.fileExists(atPath: caminhoDoModelo.path) else {
                throw ErroSilero.modeloAusente
            }
            modeloVerificado = true
        }

        var maxima: Float = 0
        var inicio = 0
        while inicio < quadro.count {
            let fim = min(inicio + SileroVAD.amostrasPorQuadro, quadro.count)
            var janela = Array(quadro[inicio..<fim])
            if janela.count < SileroVAD.amostrasPorQuadro {
                janela.append(
                    contentsOf: [Float](
                        repeating: 0,
                        count: SileroVAD.amostrasPorQuadro - janela.count
                    )
                )
            }
            maxima = max(maxima, try await inferir(janela: janela))
            inicio = fim
        }
        return maxima
    }

    /// Uma inferência de 512 amostras com o contexto de 64 da esquerda.
    private func inferir(janela: [Float]) async throws -> Float {
        var entrada = contexto
        entrada.append(contentsOf: janela) // 64 + 512 = 576
        defer { contexto = Array(entrada.suffix(SileroVAD.contextoEmAmostras)) }

        let resultado: [String: DadosTensorOnnx]
        do {
            resultado = try await sessao.rodar(
                entradas: [
                    "input": .flutuante(entrada, dimensoes: [1, 576]),
                    "state": .flutuante(estado, dimensoes: [2, 1, 128]),
                    "sr": .inteiro([16_000], dimensoes: [1]),
                ],
                saidas: ["output", "stateN"]
            )
        } catch let erro as ErroOnnx {
            throw ErroSilero.erroOnnx(erro)
        }

        guard case let .flutuante(probabilidades, _)? = resultado["output"],
            case let .flutuante(estadoNovo, _)? = resultado["stateN"],
            let probabilidade = probabilidades.first
        else {
            throw ErroSilero.saidaInvalida
        }
        estado = estadoNovo
        return probabilidade
    }

    /// Libera o modelo. Chamado sob pressão de memória.
    public func descarregar() async {
        await sessao.descarregar()
    }
}

/// Erros do Silero VAD. O `ErroOnnx` embutido carrega a mensagem do runtime.
public enum ErroSilero: Error, CustomStringConvertible, Sendable {
    case modeloAusente
    case saidaInvalida
    case erroOnnx(ErroOnnx)

    public var description: String {
        switch self {
        case .modeloAusente:
            "Silero VAD: silero_vad.onnx não encontrado no bundle"
        case .saidaInvalida:
            "Silero VAD: saída do modelo com forma inesperada"
        case let .erroOnnx(erro):
            "\(erro)"
        }
    }
}
