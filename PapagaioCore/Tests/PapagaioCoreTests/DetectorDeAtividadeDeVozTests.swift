import Foundation
import Testing
@testable import PapagaioCore

/// Conta entradas simultâneas numa seção crítica de teste.
private actor GuardaDeSobreposicao {
    private var dentro = 0
    private(set) var sobreposicoes = 0
    private(set) var visitas = 0

    func entrar() {
        dentro += 1
        visitas += 1
        if dentro > 1 { sobreposicoes += 1 }
    }

    func sair() {
        dentro -= 1
    }
}

/// VAD por Silero (M.1): distingue fala real de sinais que só têm energia.
/// Fala real tem que passar; DC, tom, ruído branco e rosa têm que ser
/// rejeitados mesmo com energia acima do limiar — é exatamente a garantia
/// que a heurística de energia não dava.
///
/// A frase de fala vem de uma fixture commitada (gerada **uma vez** por
/// Tests/PapagaioCoreTests/Fixtures/gerar_fixture.sh via `say`), para o teste
/// rodar sempre — sem depender de `say`/voz instalada na hora do teste.
///
/// Serializado de propósito: o `DetectorDeAtividadeDeVoz` compartilha uma
/// única instância do Silero (design de produção — modelo residente). Os
/// testes desta suite rodarem em paralelo zeraria o contexto/estado do VAD
/// uns dos outros no meio da inferência (a "memória" de frase vaza entre
/// arquivos) e a decisão sobre ruído rosa passa a depender da ordem de
/// entrelaçamento.
@Suite("Detector de atividade de voz com Silero", .serialized)
struct DetectorDeAtividadeDeVozTests {
    private func carregarFixture(_ nome: String) async throws -> [Float] {
        let pasta = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return try await DecodificadorDeAudio.amostras(
            de: pasta.appendingPathComponent(nome)
        )
    }

    @Test("Lote do Silero é limitado para não duplicar o áudio inteiro")
    func loteDoSileroTemLimiteDeMemoria() {
        #expect(DetectorDeAtividadeDeVoz.quadrosPorLoteDoSilero > 0)
        #expect(DetectorDeAtividadeDeVoz.quadrosPorLoteDoSilero <= 128)
    }

    // MARK: - Aceitação: fala real

    @Test("Aceita fala real da fixture (TTS)")
    func aceitaFalaReal() async throws {
        let amostras = try await carregarFixture("fala_ola_mundo.wav")
        // Sanidade: a fixture tem ~4 s de áudio.
        #expect(amostras.count > 16_000 * 3)
        let temFala = try await DetectorDeAtividadeDeVoz.contemFala(nas: amostras)
        #expect(temFala)
    }

    // MARK: - Rejeição: sinais que só a energia deixa passar

    @Test("Rejeita silêncio")
    func rejeitaSilencio() async throws {
        let silencio = [Float](repeating: 0, count: 16_000 * 2)
        #expect(!(try await DetectorDeAtividadeDeVoz.contemFala(nas: silencio)))
    }

    @Test("Rejeita sinal constante (engana só a energia)")
    func rejeitaSinalConstante() async throws {
        let dc = [Float](repeating: 0.02, count: 16_000 * 2)
        #expect(!(try await DetectorDeAtividadeDeVoz.contemFala(nas: dc)))
    }

    @Test("Rejeita tom puro esteja com energia")
    func rejeitaTom() async throws {
        let tom = (0..<(16_000 * 2)).map {
            Float(0.05 * sin(2 * Double.pi * 440 * Double($0) / 16_000))
        }
        #expect(!(try await DetectorDeAtividadeDeVoz.contemFala(nas: tom)))
    }

    @Test("Rejeita ruído branco em nível de fala")
    func rejeitaRuidoBranco() async throws {
        var ruido = RuidoDeterministico(seed: 42)
        let branco = ruido.branco(16_000 * 2, alvoRms: 0.02)
        #expect(!(try await DetectorDeAtividadeDeVoz.contemFala(nas: branco)))
    }

    @Test("Rejeita ruído rosa em nível de fala")
    func rejeitaRuidoRosa() async throws {
        var ruido = RuidoDeterministico(seed: 42)
        let rosa = ruido.rosa(16_000 * 2, alvoRms: 0.02)
        #expect(!(try await DetectorDeAtividadeDeVoz.contemFala(nas: rosa)))
    }

}

/// Isolamento de sessões concorrentes do VAD.
///
/// **Fora** da suíte `.serialized` acima de propósito: os testes daqui só
/// provam alguma coisa se o swift-testing rodá-los em paralelo com os outros
/// testes do Silero — é a concorrência real que o entrelaçamento de quadros
/// precisa para acontecer.
@Suite("Isolamento de sessões do VAD")
struct IsolamentoDeSessoesDoVADTests {
    private func carregarFixture(_ nome: String) async throws -> [Float] {
        let pasta = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return try await DecodificadorDeAudio.amostras(
            de: pasta.appendingPathComponent(nome)
        )
    }

    @Test("Fila do VAD nunca deixa duas sessões ao mesmo tempo")
    func filaDoVADSerializaSessoes() async {
        // Regressão: o Silero é um ator só com estado de sequência
        // (`contexto`, `estado`); duas sessões concorrentes se entrelaçam
        // nas esperas e corrompem o estado uma da outra. A fila tem que
        // garantir exclusão mútua da sessão inteira.
        let fila = FilaEstrita()
        let guarda = GuardaDeSobreposicao()

        await withTaskGroup(of: Void.self) { grupo in
            for _ in 0..<8 {
                grupo.addTask {
                    await fila.entrar()
                    await guarda.entrar()
                    try? await Task.sleep(for: .milliseconds(2))
                    await guarda.sair()
                    await fila.sair()
                }
            }
        }

        #expect(await guarda.sobreposicoes == 0)
        #expect(await guarda.visitas == 8)
    }

    @Test("Sessões de VAD concorrentes dão o mesmo resultado que sequenciais")
    func sessoesConcorrentesNaoSeCorrompem() async throws {
        let fala = try await carregarFixture("fala_ola_mundo.wav")
        // Segunda entrada: repetições da fala emendadas — passa no portão de
        // energia e rende dezenas de consultas ao Silero, para as duas
        // sessões disputarem o estado do modelo de verdade.
        var sobrecarga: [Float] = []
        for _ in 0..<6 { sobrecarga.append(contentsOf: fala) }

        let base = try await DetectorDeAtividadeDeVoz.janelasDeFala(nas: fala)
        let baseSobrecarga = try await DetectorDeAtividadeDeVoz.janelasDeFala(nas: sobrecarga)
        #expect(!base.isEmpty)

        // Várias rodadas com as duas entradas ao mesmo tempo: o resultado de
        // cada uma precisa ser o do processamento isolado. Sem a fila, o
        // `novaSequencia` e os quadros de uma sessão zeram/alteram o estado
        // da outra no meio.
        for _ in 0..<4 {
            async let concorrenteA = DetectorDeAtividadeDeVoz.janelasDeFala(nas: fala)
            async let concorrenteB = DetectorDeAtividadeDeVoz.janelasDeFala(nas: sobrecarga)
            let (resultadoA, resultadoB) = try await (concorrenteA, concorrenteB)
            #expect(resultadoA == base)
            #expect(resultadoB == baseSobrecarga)
        }
    }
}

@Suite("VAD em fluxo")
struct VADEmFluxoTests {
    @Test("Mantém a mesma fala através de pausas naturais de até três segundos")
    func pausaNaturalNaoFragmentaFala() async throws {
        let fala = [Float](repeating: 0.02, count: 16_000)
        let silencio = [Float](repeating: 0, count: 32_000)
        let amostras = fala + silencio + fala

        let emLote = try await DetectorDeAtividadeDeVoz.janelasDeFala(
            nas: amostras,
            limiarDeFala: -1
        )
        #expect(emLote.count == 1)
        #expect(emLote[0].inicio == 0)
        #expect(emLote[0].fim == 4)

        let sessao = DetectorDeAtividadeDeVoz.SessaoEmFluxo(
            limiarDeFala: -1,
            margem: 0
        )
        await sessao.iniciar()
        var emFluxo = try await sessao.receber(.init(inicio: 0, amostras: amostras))
        emFluxo += await sessao.finalizar()
        #expect(emFluxo.count == 1)
        #expect(emFluxo[0].inicio == 0)
        #expect(Double(emFluxo[0].amostras.count) / 16_000 == 4)
    }

    @Test("Corte forçado não cria uma segunda janela só com overlap e silêncio")
    func overlapSemFalaNovaEhDescartado() async throws {
        let sessao = DetectorDeAtividadeDeVoz.SessaoEmFluxo(
            limiarDeFala: -1,
            silencioMinimoParaCortar: 0.6,
            margem: 0.2,
            limiteDaJanela: 1
        )
        await sessao.iniciar()

        // 0,85 s com energia e 1 s de silêncio. O limite de 1 s corta antes
        // dos 0,6 s necessários para o corte natural; a janela seguinte fica
        // apenas com o overlap já entregue e precisa desaparecer.
        let fala = [Float](repeating: 0.02, count: 13_600)
        let silencio = [Float](repeating: 0, count: 16_000)
        let prontas = try await sessao.receber(.init(
            inicio: 0, amostras: fala + silencio
        ))
        let finais = await sessao.finalizar()

        #expect((prontas + finais).count == 1)
    }

    @Test("Fala contínua é limitada e mantém timestamps crescentes")
    func falaContinuaTemJanelasLimitadas() async throws {
        let sessao = DetectorDeAtividadeDeVoz.SessaoEmFluxo(
            limiarDeFala: -1,
            margem: 0.2,
            limiteDaJanela: 1
        )
        await sessao.iniciar()

        var janelas = try await sessao.receber(.init(
            inicio: 0,
            amostras: [Float](repeating: 0.02, count: 16_000 * 2)
        ))
        janelas += await sessao.finalizar()

        #expect(janelas.count >= 2)
        #expect(janelas.allSatisfy { $0.amostras.count <= 16_000 + 512 })
        #expect(zip(janelas, janelas.dropFirst()).allSatisfy { $0.inicio < $1.inicio })
    }
}

/// Fontes de ruído **determinísticas** (LCG de 64 bits): os testes não podem
/// depender do `random()` do sistema — CI e máquina local têm que ver a mesma
/// sequência.
private struct RuidoDeterministico {
    private var rng: UInt64

    init(seed: UInt64) {
        self.rng = seed
    }

    /// Próximo valor pseudo-aleatório em [−0,5, 0,5). Divisor por potência de
    /// dois, sem reinterpretação de sinal — o gerador é simétrico em zero, sem
    /// viés de DC.
    mutating func proximo() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(rng >> 33) / 2_147_483_648 - 0.5
    }

    /// Ruído branco escalado para um RMS alvo (acima do limiar de energia do
    /// detector, para provar que a rejeição vem do Silero e não da porta de
    /// energia).
    mutating func branco(_ quantidade: Int, alvoRms: Float) -> [Float] {
        let cru = (0..<quantidade).map { _ in proximo() }
        let escala = alvoRms / rms(cru)
        return cru.map { $0 * escala }
    }

    /// Ruído rosa (posto Voss–McCartney de 16 pólos, mesmos coeficientes
    /// validados no scratch).
    mutating func rosa(_ quantidade: Int, alvoRms: Float) -> [Float] {
        var b = [Float](repeating: 0, count: 16)
        var saida = [Float](repeating: 0, count: quantidade)
        for i in 0..<quantidade {
            let w = proximo()
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3016212
            b[4] = 0.46650 * b[4] + w * 0.3072508
            b[5] = w * 0.4953918
            saida[i] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.011
            b[6] = w * 0.125
        }
        let escala = alvoRms / rms(saida)
        return saida.map { $0 * escala }
    }

    private func rms(_ amostras: [Float]) -> Float {
        sqrt(amostras.reduce(Float.zero) { $0 + $1 * $1 } / Float(amostras.count))
    }
}

@Test("Com o Silero, a energia só veta o piso de ruído digital (T-01)")
func limiarDeEnergiaCedeAoSilero() {
    // Voz baixa/distante (≈ −45 dBFS → RMS ≈ 0,0056) ficava abaixo de 0,008 e
    // era vetada mesmo com o Silero dizendo que era fala.
    let vozBaixa: Float = 0.0056
    let comSilero = DetectorDeAtividadeDeVoz.limiarEfetivoDeEnergia(0.008, usaSilero: true)
    #expect(comSilero == DetectorDeAtividadeDeVoz.pisoDeRuidoDigital)
    #expect(vozBaixa >= comSilero)

    // Sem o Silero a energia é o único critério: o limiar pedido vale.
    #expect(DetectorDeAtividadeDeVoz.limiarEfetivoDeEnergia(0.008, usaSilero: false) == 0.008)
    // Um limiar pedido ainda mais baixo que o piso é respeitado.
    #expect(DetectorDeAtividadeDeVoz.limiarEfetivoDeEnergia(0.0005, usaSilero: true) == 0.0005)
}
