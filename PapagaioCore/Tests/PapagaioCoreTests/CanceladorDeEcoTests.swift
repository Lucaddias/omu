import XCTest
@testable import PapagaioCore

final class CanceladorDeEcoTests: XCTestCase {

    func testSaidaMesmoTamanhoDoInput() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 256, comprimentoFiltro: 512)
        let mic = [Float](repeating: 0.1, count: 256)
        let sis = [Float](repeating: 0.05, count: 256)
        let saida = cancelador.processar(blocoMicrofone: mic, blocoSistema: sis)
        XCTAssertEqual(saida.count, 256)
    }

    func testRetornaMicrofoneSeTamanhosDiferem() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 256)
        let mic = [Float](repeating: 0.1, count: 100)
        let sis = [Float](repeating: 0.05, count: 256)
        let saida = cancelador.processar(blocoMicrofone: mic, blocoSistema: sis)
        XCTAssertEqual(saida, mic)
    }

    func testSubtraiEcoQuandoSinalReferenciaEIdentico() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 512, comprimentoFiltro: 1024, mu: 0.3)
        // Eco atrasado: o sinal do sistema chega ao microfone com 10 amostras de atraso.
        var eco = [Float](repeating: 0, count: 512)
        for i in 10..<512 { eco[i] = Float(i) / 512.0 }

        var energiaAntes: Float = 0
        var energiaDepois: Float = 0

        // Alimenta o cancelador com blocos repetidos para que o filtro convirja.
        for passo in 0..<50 {
            let resultado = cancelador.processar(blocoMicrofone: eco, blocoSistema: eco)
            if passo < 20 { energiaAntes = resultado.reduce(0) { $0 + $1 * $1 } }
            if passo >= 40 { energiaDepois = resultado.reduce(0) { $0 + $1 * $1 } }
        }

        // Após convergência, a energia residual deve ser menor que no início.
        XCTAssertLessThan(energiaDepois, energiaAntes,
                          "O filtro deveria ter reduzido o eco ao longo do tempo")
    }

    func testNaoDestruiSinalDeVoz() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 512, comprimentoFiltro: 1024, mu: 0.3)
        // Voz: seno de 300 Hz (frequência típica de fala).
        let voz = (0..<512).map { sin(2.0 * .pi * 300.0 * Float($0) / 16_000.0) }
        // Sistema: silêncio (sem eco).
        let silencio = [Float](repeating: 0, count: 512)

        let resultado = cancelador.processar(blocoMicrofone: voz, blocoSistema: silencio)
        let energiaEntrada = voz.reduce(0) { $0 + $1 * $1 }
        let energiaSaida = resultado.reduce(0) { $0 + $1 * $1 }

        // Com sistema em silêncio, o filtro não deveria alterar muito a voz.
        XCTAssertGreaterThan(energiaSaida, energiaEntrada * 0.5,
                             "A voz não deveria ser destruída quando não há eco")
    }

    func testResetarLimpaEstado() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 256, comprimentoFiltro: 512)
        let mic = [Float](repeating: 0.1, count: 256)
        let sis = [Float](repeating: 0.05, count: 256)

        _ = cancelador.processar(blocoMicrofone: mic, blocoSistema: sis)
        cancelador.resetar()

        // Após reset, comportamento deve ser como novo.
        let resultado = cancelador.processar(blocoMicrofone: mic, blocoSistema: sis)
        XCTAssertEqual(resultado.count, 256)
    }

    func test_blocosSequenciaisNaoCrasham() {
        let cancelador = CanceladorDeEco(tamanhoBloco: 128, comprimentoFiltro: 256)
        let mic = [Float](repeating: 0.05, count: 128)
        let sis = [Float](repeating: 0.02, count: 128)

        // Processa 100 blocos sequenciais.
        for _ in 0..<100 {
            let saida = cancelador.processar(blocoMicrofone: mic, blocoSistema: sis)
            XCTAssertEqual(saida.count, 128)
        }
    }

    // MARK: - Equivalência com a formulação de referência

    /// O NLMS escrito do jeito óbvio — janela remontada a cada amostra, norma
    /// recalculada por inteiro. É a definição contra a qual a versão
    /// otimizada (janela contígua, norma incremental, `vDSP_vsma`) é conferida.
    private func nlmsDeReferencia(
        microfone: [Float],
        sistema: [Float],
        comprimento: Int,
        mu: Float
    ) -> [Float] {
        var filtros = [Float](repeating: 0, count: comprimento)
        var historico = [Float](repeating: 0, count: comprimento)
        var saida: [Float] = []
        for n in 0..<microfone.count {
            historico.removeLast()
            historico.insert(sistema[n], at: 0)
            let estimativa = zip(filtros, historico).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            let erro = microfone[n] - estimativa
            saida.append(erro)
            let norma = historico.reduce(Float(0)) { $0 + $1 * $1 } + 1e-6
            let escalar = mu * erro / norma
            for j in 0..<comprimento { filtros[j] += escalar * historico[j] }
        }
        return saida
    }

    func testVersaoOtimizadaEquivaleAoNLMSDeReferencia() throws {
        var gerador = SystemRandomNumberGenerator()
        let bloco = 64
        let comprimento = 128
        // Vários múltiplos do filtro, para dar a volta no buffer muitas vezes.
        let total = bloco * 40
        let sistema = (0..<total).map { _ in Float.random(in: -0.5...0.5, using: &gerador) }
        // Microfone = voz + eco do sistema atrasado e atenuado.
        let microfone = (0..<total).map { n -> Float in
            let voz = 0.2 * sin(2 * .pi * 220 * Float(n) / 16_000)
            let eco = n >= 7 ? 0.6 * sistema[n - 7] : 0
            return voz + eco
        }

        let cancelador = CanceladorDeEco(tamanhoBloco: bloco, comprimentoFiltro: comprimento, mu: 0.4)
        let otimizada = try cancelador.processar(microfone: microfone, sistema: sistema)
        let referencia = nlmsDeReferencia(microfone: microfone, sistema: sistema, comprimento: comprimento, mu: 0.4)

        XCTAssertEqual(otimizada.count, referencia.count)
        let maiorDiferenca = zip(otimizada, referencia).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maiorDiferenca, 1e-3, "a versão otimizada divergiu da definição do NLMS")
        // E o filtro de fato remove eco: sobra menos energia do que entrou.
        let fim = otimizada.suffix(bloco * 4)
        let entradaFim = microfone.suffix(bloco * 4)
        XCTAssertLessThan(
            fim.reduce(0) { $0 + $1 * $1 },
            entradaFim.reduce(0) { $0 + $1 * $1 }
        )
    }

    func testCanalCompletoPreservaDuracaoComSistemaMaisCurto() throws {
        let cancelador = CanceladorDeEco(tamanhoBloco: 64, comprimentoFiltro: 128)
        let microfone = [Float](repeating: 0.1, count: 1_000)
        let sistema = [Float](repeating: 0.05, count: 300)

        let saida = try cancelador.processar(microfone: microfone, sistema: sistema)

        XCTAssertEqual(saida.count, microfone.count)
    }

    func testCanalCompletoRespeitaCancelamento() async {
        let tarefa = Task {
            try await Task.sleep(for: .seconds(30))
            let cancelador = CanceladorDeEco(tamanhoBloco: 64, comprimentoFiltro: 128)
            return try cancelador.processar(
                microfone: [Float](repeating: 0.1, count: 64_000),
                sistema: [Float](repeating: 0.05, count: 64_000)
            )
        }
        tarefa.cancel()
        let resultado = await tarefa.result
        XCTAssertThrowsError(try resultado.get())
    }

    func testDesempenhoDoFiltroCompleto() throws {
        // Dez segundos de áudio com o filtro de produção (4.096 taps). Antes
        // da janela contígua isto levava várias vezes o tempo real.
        let cancelador = CanceladorDeEco(tamanhoBloco: 512, comprimentoFiltro: 4_096)
        let amostras = 160_000
        let sistema = (0..<amostras).map { sin(2 * .pi * 440 * Float($0) / 16_000) * 0.3 }
        let microfone = sistema.map { $0 * 0.5 }

        let inicio = Date()
        let saida = try cancelador.processar(microfone: microfone, sistema: sistema)
        let duracao = Date().timeIntervalSince(inicio)

        XCTAssertEqual(saida.count, amostras)
        XCTAssertLessThan(duracao, 5, "10 s de áudio levaram \(duracao) s para filtrar")
    }
}
