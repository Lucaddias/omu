import Foundation
import LlamaRuntime
import PapagaioCore
import WhisperRuntime

// Harness de medição do Papagaio — o `papagaio-eval run` do Passo 6.
//
// Roda micro-benchmarks (funções puras do PapagaioCore) e macro-benchmarks
// (pipeline real com Whisper/Qwen quando os pesos existem), grava baseline
// JSON e compara com tolerância. Não toca na biblioteca: tudo vive aqui.

// MARK: - Resultado

struct ResultadoBench: Codable {
    let nome: String
    let iteracoes: Int
    let segundosMinimo: Double
    let segundosMedio: Double
    let segundosMediano: Double
    let unidade: String?          // ex.: "s/segundo de áudio", "op/s"
    let detalhes: [String: String]?

    var porSegundo: Double {
        guard segundosMedio > 0 else { return 0 }
        return 1.0 / segundosMedio
    }
}

struct RelatorioBench: Codable {
    let versao: String
    let data: String
    let maquina: String
    let whisper: String
    let llama: String
    let metal: Bool
    let resultados: [ResultadoBench]
}

// MARK: - Medição

enum Medidor {
    /// Executa `corpo` `iteracoes` vezes e devolve estatísticas.
    /// A primeira execução é descartada (warm-up).
    static func medir(
        nome: String,
        iteracoes: Int = 5,
        unidade: String? = nil,
        detalhes: [String: String]? = nil,
        _ corpo: () throws -> Void
    ) rethrows -> ResultadoBench {
        var tempos: [Double] = []
        tempos.reserveCapacity(iteracoes)

        // Warm-up (descartado)
        try corpo()

        for _ in 0..<iteracoes {
            let relogio = ContinuousClock()
            let inicio = relogio.now
            try corpo()
            let gasto = relogio.now - inicio
            tempos.append(Double(gasto.components.seconds)
                + Double(gasto.components.attoseconds) / 1e18)
        }

        let ordenados = tempos.sorted()
        let medio = tempos.reduce(0, +) / Double(tempos.count)
        let mediano = ordenados[ordenados.count / 2]

        return ResultadoBench(
            nome: nome,
            iteracoes: iteracoes,
            segundosMinimo: ordenados.first ?? 0,
            segundosMedio: medio,
            segundosMediano: mediano,
            unidade: unidade,
            detalhes: detalhes
        )
    }

    /// Versão assíncrona para pipelines.
    static func medirAsync(
        nome: String,
        iteracoes: Int = 3,
        unidade: String? = nil,
        detalhes: [String: String]? = nil,
        _ corpo: () async throws -> Void
    ) async rethrows -> ResultadoBench {
        var tempos: [Double] = []
        tempos.reserveCapacity(iteracoes)

        try await corpo() // warm-up

        for _ in 0..<iteracoes {
            let relogio = ContinuousClock()
            let inicio = relogio.now
            try await corpo()
            let gasto = relogio.now - inicio
            tempos.append(Double(gasto.components.seconds)
                + Double(gasto.components.attoseconds) / 1e18)
        }

        let ordenados = tempos.sorted()
        let medio = tempos.reduce(0, +) / Double(tempos.count)
        let mediano = ordenados[ordenados.count / 2]

        return ResultadoBench(
            nome: nome,
            iteracoes: iteracoes,
            segundosMinimo: ordenados.first ?? 0,
            segundosMedio: medio,
            segundosMediano: mediano,
            unidade: unidade,
            detalhes: detalhes
        )
    }
}

// MARK: - Utilidades de dados de teste

enum GeradorDeDados {
    /// Segmentos sintéticos ordenados por tempo, como o Whisper devolve.
    static func segmentosSinteticos(quantidade: Int) -> [Trecho] {
        (0..<quantidade).map { i in
            let start = Double(i) * 5.0
            let palavras = (0..<8).map { j in
                Palavra(
                    start: start + Double(j) * 0.4,
                    end: start + Double(j) * 0.4 + 0.35,
                    texto: "palavra\(i)_\(j)",
                    confianca: 0.9
                )
            }
            return Trecho(
                start: start,
                end: start + 4.5,
                texto: palavras.map(\.texto).joined(separator: " "),
                palavras: palavras
            )
        }
    }

    /// Segmentos de diarização sintéticos.
    static func segmentosDeFala(quantidade: Int) -> [SegmentoDeFalante] {
        (0..<quantidade).map { i in
            let inicio = Double(i) * 8.0
            return SegmentoDeFalante(
                falanteId: "S\(i % 3 + 1)",
                inicio: inicio,
                fim: inicio + 7.0
            )
        }
    }

    /// Amostras de áudio sintéticas (seno + ruído leve).
    static func amostras(quantidade: Int) -> [Float] {
        (0..<quantidade).map { i in
            let t = Double(i) / 16000.0
            return Float(sin(2.0 * .pi * 440.0 * t)) * 0.3
        }
    }
}

// MARK: - Relatório

enum EscritorDeRelatorio {
    static func imprimir(_ resultados: [ResultadoBench]) {
        print("\n=== RESULTADOS ===")
        for r in resultados {
            let min = String(format: "%.6f", r.segundosMinimo)
            let med = String(format: "%.6f", r.segundosMedio)
            let p50 = String(format: "%.6f", r.segundosMediano)
            var linha = String(
                format: "%-40s  min=%@  medio=%@  mediano=%@  (n=%d)",
                (r.nome as NSString).utf8String!, min, med, p50, r.iteracoes
            )
            if let u = r.unidade {
                linha += "  [\(u)]"
            }
            print(linha)
            if let d = r.detalhes {
                for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                    print("    \(k): \(v)")
                }
            }
        }
    }

    static func gravar(
        _ resultados: [ResultadoBench],
        em caminho: String
    ) throws {
        let info = RuntimeInfo.coletar()
        let relatorio = RelatorioBench(
            versao: "1.0",
            data: ISO8601DateFormatter().string(from: Date()),
            maquina: HostInfo.descricao,
            whisper: info.whisperSystemInfo,
            llama: info.llamaSystemInfo,
            metal: info.metalDisponivel,
            resultados: resultados
        )
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dados = try codificador.encode(relatorio)
        try dados.write(to: URL(fileURLWithPath: caminho))
        print("\nRelatório gravado em: \(caminho)")
    }

    static func carregarBaseline(caminho: String) -> RelatorioBench? {
        guard let dados = try? Data(contentsOf: URL(fileURLWithPath: caminho)) else {
            return nil
        }
        return try? JSONDecoder().decode(RelatorioBench.self, from: dados)
    }

    static func comparar(
        atual: [ResultadoBench],
        baseline: RelatorioBench,
        tolerancia: Double = 0.15
    ) {
        print("\n=== COMPARAÇÃO COM BASELINE (tolerância \(Int(tolerancia * 100))%) ===")
        var piorou = 0
        var melhorou = 0
        var igual = 0
        var ausente = 0

        for r in atual {
            guard let b = baseline.resultados.first(where: { $0.nome == r.nome }) else {
                print("  [NOVO] \(r.nome)")
                ausente += 1
                continue
            }
            let razao = r.segundosMedio / max(b.segundosMedio, 1e-9)
            let delta = (razao - 1.0) * 100.0
            let marca: String
            if razao > 1.0 + tolerancia {
                marca = "✗ PIOROU"
                piorou += 1
            } else if razao < 1.0 - tolerancia {
                marca = "✓ MELHOROU"
                melhorou += 1
            } else {
                marca = "· igual"
                igual += 1
            }
            print(String(
                format: "  %@  %-40s  %.1f%%  (baseline=%.6fs → atual=%.6fs)",
                marca, (r.nome as NSString).utf8String!,
                delta, b.segundosMedio, r.segundosMedio
            ))
        }
        print("\n  Resumo: \(melhorou) melhoraram, \(igual) iguais, \(piorou) pioraram, \(ausente) novos")
    }
}

enum HostInfo {
    static var descricao: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var cpu = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &cpu, &size, nil, 0)
        let marca = String(cString: cpu)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return "\(marca) (\(cores) cores)"
    }
}
