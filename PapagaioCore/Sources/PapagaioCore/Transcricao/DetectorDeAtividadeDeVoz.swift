import Foundation
import os

/// VAD — corta silêncio **dentro** do áudio antes de mandar para o Whisper,
/// não só decide se o arquivo inteiro tem fala ou não.
///
/// ═══════════════════════════════════════════════════════════════════════
/// ATUALIZAÇÃO: a versão anterior só fazia `contemFala(nas:)` — um portão de
/// tudo-ou-nada para o arquivo inteiro. Isso NÃO evita o que o diagrama
/// original chama de "obrigatório: whisper alucina em silêncio": um arquivo
/// de 40 minutos com fala real passava no portão (`contemFala == true`) e
/// então ia inteiro, silêncios longos inclusos, para uma ÚNICA chamada de
/// `whisper_full`. É exatamente esse o cenário clássico de alucinação e
/// repetição em cascata do Whisper — o modelo tem que decodificar "alguma
/// coisa" para os trechos sem fala, erra, e (mesmo com `no_context = true`
/// entre janelas do whisper.cpp) o padrão degenerado de repetição acontece
/// DENTRO da própria janela deslizante interna do whisper.cpp, que
/// `no_context` não alcança.
///
/// A correção: identificar as janelas de fala dentro do áudio e mandar cada
/// uma para o Whisper separadamente — silêncio nunca chega ao decoder. Ver
/// `WhisperEngine.transcribe`, que agora itera essas janelas.
///
/// SEGUNDA ATUALIZAÇÃO: o gate por quadro era só energia — qualquer sinal
/// com energia sustenta passa (DC, tom, ruído). A energia foi mantida como
/// filtro rápido e barato, mas a decisão agora é do Silero VAD (M.1), que
/// distingue fala real de tom/DC/ruído. Ver `SileroVAD`.
/// ═══════════════════════════════════════════════════════════════════════
public enum DetectorDeAtividadeDeVoz {
#if OMU_PERF
    public typealias RegistradorDeEventoPerf = @Sendable (String, String, TimeInterval?) -> Void

    private final class RegistroPerf: @unchecked Sendable {
        private let trava = NSLock()
        private var callback: RegistradorDeEventoPerf?

        func configurar(_ novo: RegistradorDeEventoPerf?) {
            trava.lock()
            callback = novo
            trava.unlock()
        }

        func enviar(_ evento: String, modelo: String, duracao: TimeInterval?) {
            trava.lock()
            let copia = callback
            trava.unlock()
            copia?(evento, modelo, duracao)
        }
    }

    private static let registroPerf = RegistroPerf()

    public static func configurarRegistroPerf(_ callback: RegistradorDeEventoPerf?) {
        registroPerf.configurar(callback)
    }

    private static func callbackPerfSilero() -> SileroVAD.RegistradorDeEventoPerf? {
        { evento, modelo, duracao in registroPerf.enviar(evento, modelo: modelo, duracao: duracao) }
    }
#endif

    /// Limite de cópias de áudio temporárias por chamada ao Silero. Uma hora
    /// inteira de áudio com energia não pode virar uma segunda cópia de centenas
    /// de megabytes só para a inferência; o estado do modelo é preservado entre
    /// lotes, então a classificação continua exatamente na ordem original.
    static let quadrosPorLoteDoSilero = 128

    public struct JanelaDeFala: Sendable, Equatable {
        public let inicio: TimeInterval
        public let fim: TimeInterval
    }

    /// Janela pronta para seguir ao Whisper, já com sua posição na linha do
    /// tempo original. Nunca contém mais de `limiteDaJanela` de fala contínua,
    /// para que uma apresentação sem pausas não volte a crescer sem limite na
    /// memória.
    struct JanelaEmFluxo: Sendable {
        let inicio: TimeInterval
        let amostras: [Float]
    }

    /// Instância compartilhada do Silero: o modelo de 2,3 MB fica residente
    /// entre arquivos. O caminho inexistente é proposital — `SessaoOnnx`
    /// devolve erro de carga em vez de crashar se o resource faltar.
#if OMU_PERF
    private static let sileroVAD = SileroVAD(
        modelo: SileroVAD.urlDoModeloPadrao,
        registrarEventoPerf: callbackPerfSilero()
    )
#else
    private static let sileroVAD = SileroVAD(modelo: SileroVAD.urlDoModeloPadrao)
#endif

    /// Exclusividade de sessão inteira. O ator do Silero serializa chamadas,
    /// mas cada `await` do laço de quadros reentra nele: dois arquivos
    /// concorrentes intercalariam `novaSequencia` e quadros, corrompendo o
    /// `contexto`/`estado` um do outro. A fila garante uma sessão por vez.
    private static let filaDoSilero = FilaEstrita()

    /// Modo degradado (modelo ausente) precisa ser visível, não silencioso.
    private static let logger = Logger(subsystem: "PapagaioCore", category: "VAD")

    /// Mantém o estado do VAD entre blocos decodificados. A sessão segura a
    /// fila do Silero do início ao fim do arquivo: intercalar duas sequências
    /// corromperia o estado recorrente do modelo entre blocos.
    final class SessaoEmFluxo {
        private let taxa: Double
        private let tamanhoDoQuadro: Int
        private let limiarDeEnergia: Float
        private let limiarDeFala: Float
        private let silencioParaCortar: Int
        private let margemEmAmostras: Int
        private let limiteDaJanela: Int

        private var usaSilero = false
        private var iniciou = false
        private var preRoll: [Float] = []
        private var amostrasDaJanela: [Float] = []
        private var inicioDaJanela: Int?
        private var fimDaUltimaFala = 0
        private var proximaAmostra = 0
        /// Depois de um corte forçado, a nova janela começa com um overlap que
        /// já foi entregue. Ela só deve seguir ao Whisper se receber fala nova;
        /// caso contrário, transcreveríamos novamente apenas a cauda anterior.
        private var temFalaNovaNaJanela = false

        init(
            taxa: Double = FormatoAudio.taxaCanonica,
            duracaoDoQuadro: TimeInterval = 0.032,
            limiarDeEnergia: Float = 0.008,
            limiarDeFala: Float = 0.5,
            silencioMinimoParaCortar: TimeInterval = 0.6,
            margem: TimeInterval = 0.2,
            limiteDaJanela: TimeInterval = 60
        ) {
            self.taxa = taxa
            self.tamanhoDoQuadro = max(1, Int(duracaoDoQuadro * taxa))
            self.limiarDeEnergia = limiarDeEnergia
            self.limiarDeFala = limiarDeFala
            self.silencioParaCortar = max(1, Int(silencioMinimoParaCortar * taxa))
            self.margemEmAmostras = max(0, Int(margem * taxa))
            self.limiteDaJanela = max(1, Int(limiteDaJanela * taxa))
        }

        func iniciar() async {
            guard !iniciou else { return }
            usaSilero = await DetectorDeAtividadeDeVoz.sileroVAD.modeloDisponivel()
            if !usaSilero {
                DetectorDeAtividadeDeVoz.logger.warning("Silero VAD ausente — janelas de fala pelo portão de energia (modo degradado).")
            }
            await DetectorDeAtividadeDeVoz.filaDoSilero.entrar()
            await DetectorDeAtividadeDeVoz.sileroVAD.novaSequencia()
            iniciou = true
        }

        func receber(_ bloco: DecodificadorDeAudio.Bloco) async throws -> [JanelaEmFluxo] {
            precondition(iniciou)
            guard !bloco.amostras.isEmpty else { return [] }

            // A origem sempre entrega 16 kHz mono. Recalcular a posição a cada
            // bloco elimina deriva de ponto flutuante em gravações longas.
            proximaAmostra = Int((bloco.inicio * taxa).rounded())
            let quantidadeDeQuadros = (bloco.amostras.count + tamanhoDoQuadro - 1) / tamanhoDoQuadro
            var falaPorQuadro = Array(repeating: false, count: quantidadeDeQuadros)
            var indicesComEnergia: [Int] = []

            for indice in 0..<quantidadeDeQuadros {
                let inicio = indice * tamanhoDoQuadro
                let fim = min(inicio + tamanhoDoQuadro, bloco.amostras.count)
                let quadro = bloco.amostras[inicio..<fim]
                let energia = sqrt(quadro.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, quadro.count)))
                if energia >= limiarDeEnergia {
                    falaPorQuadro[indice] = true
                    indicesComEnergia.append(indice)
                }
            }

            if usaSilero, !indicesComEnergia.isEmpty {
                var inicioDoLote = 0
                while inicioDoLote < indicesComEnergia.count {
                    let fimDoLote = min(
                        inicioDoLote + DetectorDeAtividadeDeVoz.quadrosPorLoteDoSilero,
                        indicesComEnergia.count
                    )
                    let indices = indicesComEnergia[inicioDoLote..<fimDoLote]
                    let candidatos = indices.map { indice in
                        let inicio = indice * tamanhoDoQuadro
                        return Array(bloco.amostras[inicio..<min(inicio + tamanhoDoQuadro, bloco.amostras.count)])
                    }
                    let probabilidades = try await DetectorDeAtividadeDeVoz.sileroVAD
                        .probabilidadesDeFala(quadros: candidatos)
                    for (indice, probabilidade) in zip(indices, probabilidades) {
                        falaPorQuadro[indice] = probabilidade >= limiarDeFala
                    }
                    inicioDoLote = fimDoLote
                }
            }

            var prontas: [JanelaEmFluxo] = []
            for indice in 0..<quantidadeDeQuadros {
                let inicio = indice * tamanhoDoQuadro
                let fim = min(inicio + tamanhoDoQuadro, bloco.amostras.count)
                let quadro = Array(bloco.amostras[inicio..<fim])
                prontas.append(contentsOf: processar(
                    quadro, temFala: falaPorQuadro[indice], inicioAbsoluto: proximaAmostra
                ))
                proximaAmostra += quadro.count
            }
            return prontas
        }

        func finalizar() async -> [JanelaEmFluxo] {
            defer {
                preRoll.removeAll(keepingCapacity: false)
                amostrasDaJanela.removeAll(keepingCapacity: false)
                inicioDaJanela = nil
            }
            guard iniciou else { return [] }
            let janelas = fecharJanela(incluindoMargem: true)
            await DetectorDeAtividadeDeVoz.filaDoSilero.sair()
            iniciou = false
            return janelas
        }

        func cancelar() async {
            guard iniciou else { return }
            await DetectorDeAtividadeDeVoz.filaDoSilero.sair()
            iniciou = false
            preRoll.removeAll(keepingCapacity: false)
            amostrasDaJanela.removeAll(keepingCapacity: false)
            inicioDaJanela = nil
        }

        private func processar(
            _ quadro: [Float], temFala: Bool, inicioAbsoluto: Int
        ) -> [JanelaEmFluxo] {
            var prontas: [JanelaEmFluxo] = []
            if inicioDaJanela == nil {
                if temFala {
                    inicioDaJanela = inicioAbsoluto - preRoll.count
                    amostrasDaJanela = preRoll
                    amostrasDaJanela.append(contentsOf: quadro)
                    fimDaUltimaFala = inicioAbsoluto + quadro.count
                    temFalaNovaNaJanela = true
                    preRoll.removeAll(keepingCapacity: true)
                } else {
                    acrescentarAoPreRoll(quadro)
                }
                return prontas
            }

            amostrasDaJanela.append(contentsOf: quadro)
            if temFala {
                fimDaUltimaFala = inicioAbsoluto + quadro.count
                temFalaNovaNaJanela = true
            } else if inicioAbsoluto + quadro.count - fimDaUltimaFala > silencioParaCortar {
                prontas.append(contentsOf: fecharJanela(incluindoMargem: true))
                return prontas
            }

            // Não existe um limite prático confiável no arquivo de entrada:
            // alguém pode falar sem pausar por horas. O overlap curto preserva
            // a fronteira acústica sem deixar a janela crescer indefinidamente.
            if amostrasDaJanela.count >= limiteDaJanela {
                prontas.append(contentsOf: fecharJanela(incluindoMargem: false, manterSobreposicao: true))
            }
            return prontas
        }

        private func acrescentarAoPreRoll(_ quadro: [Float]) {
            preRoll.append(contentsOf: quadro)
            if preRoll.count > margemEmAmostras {
                preRoll.removeFirst(preRoll.count - margemEmAmostras)
            }
        }

        private func fecharJanela(
            incluindoMargem: Bool,
            manterSobreposicao: Bool = false
        ) -> [JanelaEmFluxo] {
            guard let inicio = inicioDaJanela, !amostrasDaJanela.isEmpty else { return [] }
            let fimDaFalaRelativo = max(0, fimDaUltimaFala - inicio)
            let limite = incluindoMargem
                ? min(amostrasDaJanela.count, fimDaFalaRelativo + margemEmAmostras)
                : amostrasDaJanela.count
            let prontas: [JanelaEmFluxo]
            if temFalaNovaNaJanela {
                prontas = [JanelaEmFluxo(
                    inicio: TimeInterval(inicio) / taxa,
                    amostras: Array(amostrasDaJanela.prefix(limite))
                )]
            } else {
                prontas = []
            }

            if manterSobreposicao {
                let sobreposicao = Array(amostrasDaJanela.suffix(margemEmAmostras))
                inicioDaJanela = inicio + amostrasDaJanela.count - sobreposicao.count
                amostrasDaJanela = sobreposicao
                temFalaNovaNaJanela = false
            } else {
                preRoll = Array(amostrasDaJanela.suffix(margemEmAmostras))
                amostrasDaJanela.removeAll(keepingCapacity: true)
                inicioDaJanela = nil
                temFalaNovaNaJanela = false
            }
            return prontas
        }
    }

    /// Portão de arquivo inteiro — mantido só para quem ainda chama esta API
    /// (ex.: testes). Prefira `janelasDeFala` para transcrição de verdade.
    public static func contemFala(
        nas amostras: [Float],
        taxa: Double = FormatoAudio.taxaCanonica
    ) async throws -> Bool {
        try await !janelasDeFala(nas: amostras, taxa: taxa).isEmpty
    }

    /// Identifica as janelas com fala dentro do áudio, tolerando pausas
    /// curtas (respiração, hesitação natural) sem fragmentar a frase, e
    /// devolve com uma margem de segurança antes/depois de cada janela para
    /// não cortar o início/fim de uma palavra.
    ///
    /// - Parameters:
    ///   - duracaoDoQuadro: 32 ms por padrão — é o quadro do Silero VAD
    ///     (512 amostras @ 16 kHz). Trocar exige trocar o tamanho esperado
    ///     pelo `SileroVAD` também.
    ///   - limiarDeEnergia: filtro rápido antes do Silero — energia RMS do
    ///     quadro abaixo disso nunca é fala (silêncio digital não passa pelo
    ///     modelo neural à toa).
    ///   - limiarDeFala: probabilidade mínima de fala do Silero, validada
    ///     empiricamente em 0,5 (fala real chega a ~1,0; DC/tom/ruído ficam
    ///     abaixo de 0,2).
    public static func janelasDeFala(
        nas amostras: [Float],
        taxa: Double = FormatoAudio.taxaCanonica,
        duracaoDoQuadro: TimeInterval = 0.032,
        limiarDeEnergia: Float = 0.008,
        limiarDeFala: Float = 0.5,
        silencioMinimoParaCortar: TimeInterval = 0.6,
        margem: TimeInterval = 0.2
    ) async throws -> [JanelaDeFala] {
        guard !amostras.isEmpty else { return [] }
        let tamanhoDoQuadro = max(1, Int(duracaoDoQuadro * taxa))

        // Modelo ausente degrada para o portão de energia: um resource de
        // 2,3 MB fora do bundle não pode transformar toda transcrição em
        // erro. O portão de energia é mais fraco (não separa fala de
        // tom/ruído), mas ainda corta o silêncio digital — e avisa.
        let usaSilero = await sileroVAD.modeloDisponivel()
        if !usaSilero {
            Self.logger.warning("Silero VAD ausente — janelas de fala pelo portão de energia (modo degradado).")
        }

        // Sequência nova = contexto e estado do Silero zerados. Sem isto, a
        // "memória" de fala de um arquivo vazaria para o seguinte. Tudo entre
        // o `entrar` e o `sair` é de uma sessão só (ver `filaDoSilero`).
        await filaDoSilero.entrar()
        let quadroTemFala: [Bool]
        do {
            await sileroVAD.novaSequencia()

            var quadros: [Bool] = []
            quadros.reserveCapacity(amostras.count / tamanhoDoQuadro + 1)
            // Energia primeiro em todos os quadros (filtro barato). Os que
            // passam seguem para o Silero em lotes limitados: um lote com 128
            // quadros ocupa no máximo ~256 KiB, em vez de duplicar todos os
            // candidatos de uma hora de áudio na memória.
            var indicesComEnergia: [Int] = []
            var inicio = 0
            while inicio < amostras.count {
                let fim = min(inicio + tamanhoDoQuadro, amostras.count)
                let quadro = amostras[inicio..<fim]
                let energia = sqrt(quadro.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, quadro.count)))
                let temFala = energia >= limiarDeEnergia
                quadros.append(temFala)
                if temFala { indicesComEnergia.append(quadros.count - 1) }
                inicio = fim
            }
            if usaSilero, !indicesComEnergia.isEmpty {
                var inicioDoLote = 0
                while inicioDoLote < indicesComEnergia.count {
                    let fimDoLote = min(
                        inicioDoLote + quadrosPorLoteDoSilero,
                        indicesComEnergia.count
                    )
                    let indicesDoLote = indicesComEnergia[inicioDoLote..<fimDoLote]
                    let candidatos = indicesDoLote.map {
                        let ini = $0 * tamanhoDoQuadro
                        return Array(amostras[ini..<min(ini + tamanhoDoQuadro, amostras.count)])
                    }
                    let probabilidades = try await sileroVAD.probabilidadesDeFala(quadros: candidatos)
                    for (indice, probabilidade) in zip(indicesDoLote, probabilidades) {
                        quadros[indice] = probabilidade >= limiarDeFala
                    }
                    inicioDoLote = fimDoLote
                }
            }
            quadroTemFala = quadros
            await filaDoSilero.sair()
        } catch {
            await filaDoSilero.sair()
            throw error
        }

        var janelas: [JanelaDeFala] = []
        var inicioDaJanela: Int?
        var ultimoQuadroComFala = -1
        let quadrosDeSilencioParaCortar = max(1, Int(silencioMinimoParaCortar / duracaoDoQuadro))

        func fechar(ateQuadro fimQuadro: Int) {
            guard let inicioQuadro = inicioDaJanela else { return }
            let duracaoTotal = Double(amostras.count) / taxa
            let comecoSegundos = max(0, Double(inicioQuadro) * duracaoDoQuadro - margem)
            let fimSegundos = min(duracaoTotal, Double(fimQuadro + 1) * duracaoDoQuadro + margem)
            if fimSegundos > comecoSegundos {
                janelas.append(JanelaDeFala(inicio: comecoSegundos, fim: fimSegundos))
            }
        }

        for (indice, temFala) in quadroTemFala.enumerated() {
            if temFala {
                if inicioDaJanela == nil { inicioDaJanela = indice }
                ultimoQuadroComFala = indice
            } else if inicioDaJanela != nil, indice - ultimoQuadroComFala > quadrosDeSilencioParaCortar {
                fechar(ateQuadro: ultimoQuadroComFala)
                inicioDaJanela = nil
            }
        }
        if inicioDaJanela != nil {
            fechar(ateQuadro: ultimoQuadroComFala)
        }

        return janelas
    }

    /// Recorta as amostras de uma janela específica.
    public static func amostras(
        de amostras: [Float],
        na janela: JanelaDeFala,
        taxa: Double = FormatoAudio.taxaCanonica
    ) -> [Float] {
        let inicio = max(0, Int(janela.inicio * taxa))
        let fim = min(amostras.count, Int(janela.fim * taxa))
        guard inicio < fim else { return [] }
        return Array(amostras[inicio..<fim])
    }
}
