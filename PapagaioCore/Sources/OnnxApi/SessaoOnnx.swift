import Foundation
#if OMU_PERF
import Dispatch
#endif
// `internal`: o módulo C do onnxruntime não vaza para quem importa este
// target — mesma regra de isolamento de `WhisperRuntime`/`LlamaRuntime`
// (D-3.2). Só a API C atravessa esta fronteira.
internal import onnxruntime

public enum ErroOnnx: Error, CustomStringConvertible, LocalizedError, Sendable {
    /// `localizedDescription` é o que chega à tela e às notificações; sem
    /// isto ela devolvia "The operation couldn't be completed (… error N)".
    public var errorDescription: String? { description }

    case falha(String)

    public var description: String {
        switch self {
        case let .falha(mensagem): "ONNX Runtime: \(mensagem)"
        }
    }
}

/// Um tensor pronto para o `SessaoOnnx`: valores em Float32 ou Int64, com as
/// dimensões explícitas.
public enum DadosTensorOnnx: Sendable {
    case flutuante([Float], dimensoes: [Int64])
    case inteiro([Int64], dimensoes: [Int64])
}

/// Envolve uma sessão do ONNX Runtime num ator — o mesmo padrão do
/// `ContextoWhisper`: **`OrtSession` não é thread-safe**, um ator por sessão,
/// modelo residente entre chamadas e `descarregar()` sob pressão de memória.
///
/// A API é mínima de propósito: `rodar(entradas:saidas:)` é o que o Silero VAD
/// precisa, nada mais. A inferência é bloqueante e roda na CPU (o modelo de
/// VAD é minúsculo: ~0,07 ms por quadro de 32 ms medido nesta máquina).
public actor SessaoOnnx {
#if OMU_PERF
    public typealias RegistradorDeEventoPerf = @Sendable (String, TimeInterval?) -> Void
#endif
    /// Caixa em volta dos ponteiros C, pelo mesmo motivo do `ContextoWhisper`:
    /// um `deinit` não isolado não pode tocar propriedade isolada do ator.
    private final class Caixa: @unchecked Sendable {
        var api: OrtApi?
        var env: OpaquePointer?
        var opcoes: OpaquePointer?
        var memoria: OpaquePointer?
        var sessao: OpaquePointer?

        func liberar() {
            guard api != nil || env != nil else { return }
            if let sessao { api?.ReleaseSession(sessao) }
            if let opcoes { api?.ReleaseSessionOptions(opcoes) }
            if let memoria { api?.ReleaseMemoryInfo(memoria) }
            if let env { api?.ReleaseEnv(env) }
            api = nil
            env = nil
            opcoes = nil
            memoria = nil
            sessao = nil
        }

        deinit { liberar() }
    }

    private let caixa = Caixa()
    private let caminhoDoModelo: URL
#if OMU_PERF
    private let registrarEventoPerf: RegistradorDeEventoPerf?
#endif

#if OMU_PERF
    public init(modelo: URL, registrarEventoPerf: RegistradorDeEventoPerf? = nil) {
        self.caminhoDoModelo = modelo
        self.registrarEventoPerf = registrarEventoPerf
    }
#else
    public init(modelo: URL) {
        self.caminhoDoModelo = modelo
    }
#endif

    public var carregado: Bool { caixa.sessao != nil }

    /// Cria o ambiente e carrega o modelo. Idempotente.
    public func carregar() throws {
        guard caixa.sessao == nil else { return }
#if OMU_PERF
        let inicio = registrarEventoPerf == nil ? nil : DispatchTime.now().uptimeNanoseconds
        if inicio != nil { registrarEventoPerf?("model.load.start", nil) }
        var sucesso = false
        defer {
            if let inicio {
                let duracao = Double(DispatchTime.now().uptimeNanoseconds &- inicio) / 1_000_000_000
                registrarEventoPerf?(sucesso ? "model.load.end" : "model.load.error", duracao)
            }
        }
#endif

        guard let base = OrtGetApiBase(), let apiPtr = base.pointee.GetApi(24) else {
            throw ErroOnnx.falha("não foi possível obter a API 24 do ONNX Runtime")
        }
        let api = apiPtr.pointee

        var env: OpaquePointer?
        var opcoes: OpaquePointer?
        var memoria: OpaquePointer?
        // Qualquer falha daqui até a sessão existir tem de devolver o que já
        // foi criado: antes, um modelo ilegível vazava os três a cada tentativa.
        var entregue = false
        defer {
            if !entregue {
                if let opcoes { api.ReleaseSessionOptions(opcoes) }
                if let memoria { api.ReleaseMemoryInfo(memoria) }
                if let env { api.ReleaseEnv(env) }
            }
        }
        try Self.verificar(api, api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "papagaio", &env))
        try Self.verificar(api, api.CreateSessionOptions(&opcoes))
        // O modelo tem 2 MB e roda ~112 mil vezes por hora de áudio: o pool
        // padrão de threads intra-op custa mais em coordenação do que rende.
        try Self.verificar(api, api.SetIntraOpNumThreads(opcoes, 1))
        try Self.verificar(api, api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeCPU, &memoria))

        var sessao: OpaquePointer?
        var status: OpaquePointer?
        caminhoDoModelo.path.withCString { caminho in
            status = api.CreateSession(env, caminho, opcoes, &sessao)
        }
        if let status {
            let mensagem = Self.mensagemDoStatus(api, status)
            api.ReleaseStatus(status)
            throw ErroOnnx.falha(mensagem)
        }

        caixa.api = api
        caixa.env = env
        caixa.opcoes = opcoes
        caixa.memoria = memoria
        caixa.sessao = sessao
        entregue = true
#if OMU_PERF
        sucesso = true
#endif
    }

    /// Libera o modelo. Chamado sob pressão de memória — ver
    /// `CicloDeVidaDeModelos`.
    public func descarregar() {
#if OMU_PERF
        let estavaCarregada = caixa.sessao != nil
        let inicio = estavaCarregada && registrarEventoPerf != nil ? DispatchTime.now().uptimeNanoseconds : nil
        if estavaCarregada { registrarEventoPerf?("model.unload.start", nil) }
#endif
        caixa.liberar()
#if OMU_PERF
        if let inicio {
            registrarEventoPerf?(
                "model.unload.end",
                Double(DispatchTime.now().uptimeNanoseconds &- inicio) / 1_000_000_000
            )
        }
#endif
    }

    /// Roda uma inferência com os tensores dados, devolvendo os tensores de
    /// saída pedidos em `saidas` (nomes), na ordem do modelo.
    ///
    /// O `ONNX Runtime` não copia os dados de entrada: os buffers têm que
    /// sobreviver até o `Run` terminar. Aqui eles são copiados para memória
    /// própria, mantida viva pelo `defer`, e liberados no retorno.
    public func rodar(
        entradas: [String: DadosTensorOnnx],
        saidas: [String]
    ) throws -> [String: DadosTensorOnnx] {
        try carregar()
        guard let sessao = caixa.sessao, let api = caixa.api, let memoria = caixa.memoria else {
            throw ErroOnnx.falha("sessão não carregada")
        }

        var buffers: [UnsafeMutableRawPointer] = []
        var valores: [OpaquePointer?] = []
        var nomesDeEntrada: [UnsafeMutablePointer<CChar>?] = []
        var nomesDeSaida: [UnsafeMutablePointer<CChar>?] = []
        defer {
            buffers.forEach { $0.deallocate() }
            nomesDeEntrada.forEach { free($0) }
            nomesDeSaida.forEach { free($0) }
            valores.forEach { api.ReleaseValue($0) }
        }

        for (nome, tensores) in entradas {
            nomesDeEntrada.append(nome.withCString { strdup($0) })
            var valor: OpaquePointer?
            switch tensores {
            case let .flutuante(dados, dimensoes):
                let bruto = UnsafeMutableRawPointer.allocate(byteCount: dados.count * 4, alignment: 4)
                dados.withUnsafeBytes { bruto.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                buffers.append(bruto)
                try Self.verificar(api, api.CreateTensorWithDataAsOrtValue(
                    memoria, bruto, dados.count * 4, dimensoes, dimensoes.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &valor
                ))
            case let .inteiro(dados, dimensoes):
                let bruto = UnsafeMutableRawPointer.allocate(byteCount: dados.count * 8, alignment: 8)
                dados.withUnsafeBytes { bruto.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                buffers.append(bruto)
                try Self.verificar(api, api.CreateTensorWithDataAsOrtValue(
                    memoria, bruto, dados.count * 8, dimensoes, dimensoes.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &valor
                ))
            }
            valores.append(valor)
        }

        for nome in saidas {
            nomesDeSaida.append(nome.withCString { strdup($0) })
        }

        var resultados = [OpaquePointer?](repeating: nil, count: saidas.count)
        var status: OpaquePointer?
        let nomesEntradaConst: [UnsafePointer<CChar>?] = nomesDeEntrada.map { UnsafePointer($0) }
        let nomesSaidaConst: [UnsafePointer<CChar>?] = nomesDeSaida.map { UnsafePointer($0) }
        valores.withUnsafeMutableBufferPointer { valoresBrutos in
            nomesEntradaConst.withUnsafeBufferPointer { nomesE in
                nomesSaidaConst.withUnsafeBufferPointer { nomesS in
                    status = api.Run(
                        sessao, nil,
                        nomesE.baseAddress, valoresBrutos.baseAddress, valoresBrutos.count,
                        nomesS.baseAddress, nomesS.count,
                        &resultados
                    )
                }
            }
        }
        if let status {
            let mensagem = Self.mensagemDoStatus(api, status)
            api.ReleaseStatus(status)
            throw ErroOnnx.falha(mensagem)
        }
        defer { resultados.forEach { api.ReleaseValue($0) } }

        var saida: [String: DadosTensorOnnx] = [:]
        for (nome, resultado) in zip(saidas, resultados) {
            guard let resultado else { continue }
            var info: OpaquePointer?
            try Self.verificar(api, api.GetTensorTypeAndShape(resultado, &info))
            defer { api.ReleaseTensorTypeAndShapeInfo(info) }

            var tipo: ONNXTensorElementDataType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try Self.verificar(api, api.GetTensorElementType(info, &tipo))
            var quantidade: Int = 0
            try Self.verificar(api, api.GetTensorShapeElementCount(info, &quantidade))

            var dados: UnsafeMutableRawPointer?
            try Self.verificar(api, api.GetTensorMutableData(resultado, &dados))

            if tipo == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT {
                let flutuantes = Array(
                    UnsafeBufferPointer(
                        start: dados?.assumingMemoryBound(to: Float.self), count: quantidade
                    )
                )
                saida[nome] = .flutuante(flutuantes, dimensoes: [])
            } else if tipo == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 {
                let inteiros = Array(
                    UnsafeBufferPointer(
                        start: dados?.assumingMemoryBound(to: Int64.self), count: quantidade
                    )
                )
                saida[nome] = .inteiro(inteiros, dimensoes: [])
            }
        }
        return saida
    }

    private static func verificar(_ api: OrtApi, _ status: OpaquePointer?) throws {
        if let status {
            let mensagem = mensagemDoStatus(api, status)
            api.ReleaseStatus(status)
            throw ErroOnnx.falha(mensagem)
        }
    }

    private static func mensagemDoStatus(_ api: OrtApi, _ status: OpaquePointer) -> String {
        api.GetErrorMessage(status).map { String(cString: $0) } ?? "erro desconhecido"
    }
}
