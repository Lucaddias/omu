import Foundation
import Darwin
import LlamaRuntime
import PapagaioCore
import WhisperRuntime

// Casos de micro-benchmark — funções puras/determinísticas do PapagaioCore.
// Não carregam pesos; rodam em milissegundos e servem de baseline estável.

enum CasosDeMicroBench {
    static func rodar(iteracoes: Int) async -> [ResultadoBench] {
        var resultados: [ResultadoBench] = []

        // 1. Segmentação — agrupar segmentos do Whisper em trechos navegáveis
        let brutos = GeradorDeDados.segmentosSinteticos(quantidade: 500)
        resultados.append(Medidor.medir(
            nome: "segmentacao.agrupar",
            iteracoes: iteracoes,
            unidade: "500 segmentos"
        ) {
            _ = Segmentacao.agrupar(brutos)
        })

        // 2. Mescla de canais (eco + merge)
        let mic = GeradorDeDados.segmentosSinteticos(quantidade: 250)
        let sis = GeradorDeDados.segmentosSinteticos(quantidade: 250)
            .map { t in
                Trecho(
                    start: t.start + 0.1, end: t.end + 0.1,
                    texto: t.texto, palavras: t.palavras
                )
            }
        resultados.append(Medidor.medir(
            nome: "segmentacao.mesclarCanais",
            iteracoes: iteracoes,
            unidade: "250+250 segmentos"
        ) {
            _ = Segmentacao.mesclarCanais(microfone: mic, sistema: sis)
        })

        // 3. Alinhamento de falantes — O(palavras × segmentos)
        let trechos = GeradorDeDados.segmentosSinteticos(quantidade: 200)
        let falas = GeradorDeDados.segmentosDeFala(quantidade: 400)
        resultados.append(Medidor.medir(
            nome: "alinhamento.atribuir",
            iteracoes: iteracoes,
            unidade: "200 trechos × 400 segmentos"
        ) {
            for t in trechos {
                _ = AlinhamentoDeFalantes.atribuir(palavras: t.palavras, a: falas)
            }
        })

        // 4. Filtro de repetição
        let comRepeticao = (0..<300).map { i in
            Trecho(
                start: Double(i) * 3, end: Double(i) * 3 + 2.5,
                texto: i % 5 == 0
                    ? "isto é uma repetição. isto é uma repetição. isto é uma repetição."
                    : "texto normal número \(i) aqui.",
                palavras: []
            )
        }
        resultados.append(Medidor.medir(
            nome: "filtroRepeticao.remover",
            iteracoes: iteracoes,
            unidade: "300 trechos"
        ) {
            _ = FiltroDeRepeticao.remover(comRepeticao)
        })

        // 5. Agrupamento de falas
        let trechosDiarizados = trechos.map { t in
            Trecho(
                id: t.id, start: t.start, end: t.end, texto: t.texto,
                speaker: t.speaker,
                palavras: t.palavras.map { p in
                    Palavra(
                        id: p.id, start: p.start, end: p.end, texto: p.texto,
                        confianca: p.confianca,
                        falanteAcustico: "S\(Int(p.start) % 3 + 1)"
                    )
                }
            )
        }
        resultados.append(Medidor.medir(
            nome: "falas.agrupar",
            iteracoes: iteracoes,
            unidade: "200 trechos"
        ) {
            _ = FalasDaConversa.agrupar(trechosDiarizados)
        })

        // 6. Navegação por trecho (busca binária)
        let ordenados = trechos.sorted { $0.start < $1.start }
        resultados.append(Medidor.medir(
            nome: "navegacao.indiceAtivo",
            iteracoes: max(iteracoes, 50),
            unidade: "200 trechos, 10k buscas"
        ) {
            for i in 0..<10_000 {
                _ = NavegacaoPorTrecho.indiceAtivo(
                    em: Double(i) * 0.05, trechos: ordenados
                )
            }
        })

        // 7. Exportação Markdown
        let arquivo = Arquivo(
            titulo: "Reunião de teste",
            pastaRelativa: "teste",
            espaco: EspacoID(),
            trechos: trechosDiarizados
        )
        resultados.append(Medidor.medir(
            nome: "exportacao.markdown",
            iteracoes: iteracoes,
            unidade: "200 trechos"
        ) {
            _ = ExportacaoMarkdown.gerar(arquivo: arquivo)
        })

        // 8. Cancelador de eco (AEC) — o mais pesado dos micro
        resultados.append(rodarAEC(iteracoes: iteracoes))

        // 9. Detecção de atividade de voz (VAD)
        // Sem Silero no bundle do CLI o caminho cai na energia; com o modelo
        // no Resources do PapagaioCore o Silero roda de verdade.
        let audioLongo = GeradorDeDados.amostras(quantidade: 16_000 * 30) // 30 s
        do {
            let silero = SileroVAD(modelo: SileroVAD.urlDoModeloPadrao)
            let comSilero = await silero.modeloDisponivel()
            let r = try await Medidor.medirAsync(
                nome: "vad.janelasDeFala",
                iteracoes: max(1, iteracoes - 2),
                unidade: "30 s de áudio",
                detalhes: ["silero": comSilero ? "sim" : "nao"]
            ) {
                _ = try await DetectorDeAtividadeDeVoz.janelasDeFala(nas: audioLongo)
            }
            resultados.append(r)
        } catch {
            print("AVISO: falha no VAD: \(error)")
        }

        // 9b. Só a inferência Silero (quadros com energia), quando o modelo existe.
        do {
            let silero = SileroVAD(modelo: SileroVAD.urlDoModeloPadrao)
            if await silero.modeloDisponivel() {
                let quadros = (0..<600).map { _ in
                    GeradorDeDados.amostras(quantidade: SileroVAD.amostrasPorQuadro)
                }
                let r = try await Medidor.medirAsync(
                    nome: "vad.silero.lote",
                    iteracoes: max(1, iteracoes - 2),
                    unidade: "600 quadros de 512 amostras"
                ) {
                    await silero.novaSequencia()
                    _ = try await silero.probabilidadesDeFala(quadros: quadros)
                }
                resultados.append(r)
                await silero.descarregar()
            }
        } catch {
            print("AVISO: falha no Silero: \(error)")
        }

        // 10. Detecção de idioma
        let textoLongo = String(repeating: "Esta é uma reunião de equipe. ", count: 2000)
        resultados.append(Medidor.medir(
            nome: "idioma.detectar",
            iteracoes: iteracoes,
            unidade: "~60k caracteres"
        ) {
            _ = DetectorDeIdiomaDaTranscricao.detectar(em: textoLongo)
        })

        return resultados
    }

    /// Mede o caminho de blocos do AEC sobre eco sintético atrasado em 120 ms.
    /// `erle_db` usa os 2 s finais, depois da adaptação inicial do filtro.
    static func rodarAEC(iteracoes: Int) -> ResultadoBench {
        let taxa = 16_000
        let atraso = 120 * taxa / 1_000
        let quantidade = taxa * 5
        let sistema = sinalDeReferencia(quantidade: quantidade)
        var microfone = [Float](repeating: 0, count: quantidade)
        for indice in atraso..<quantidade {
            microfone[indice] = sistema[indice - atraso] * 0.35
        }

        var ultimaSaida: [Float] = []
        let resultado = Medidor.medir(
            nome: "aec.processarBlocos",
            iteracoes: max(1, iteracoes - 2),
            unidade: "5 s de áudio; eco atrasado 120 ms"
        ) {
            let cancelador = CanceladorDeEco(
                tamanhoBloco: 512, comprimentoFiltro: 4096
            )
            ultimaSaida = Self.processarBlocos(
                cancelador: cancelador,
                microfone: microfone,
                sistema: sistema
            )
        }

        let faixaAposAdaptacao = max(0, microfone.count - 2 * taxa)..<microfone.count
        let energiaEntrada = faixaAposAdaptacao.reduce(0.0) { soma, indice in
            soma + Double(microfone[indice] * microfone[indice])
        }
        let energiaResidual = faixaAposAdaptacao.reduce(0.0) { soma, indice in
            guard ultimaSaida.indices.contains(indice) else { return soma }
            let amostra = Double(ultimaSaida[indice])
            return soma + amostra * amostra
        }
        let erleDB = 10 * log10(max(energiaEntrada, 1e-20) / max(energiaResidual, 1e-20))
        var detalhes = resultado.detalhes ?? [:]
        detalhes["erle_db"] = String(erleDB)
        detalhes["echo_delay_ms"] = "120"
        detalhes["sample_rate_hz"] = String(taxa)
        detalhes["peak_rss_bytes"] = String(Self.memoriaDePico())

        return ResultadoBench(
            nome: resultado.nome,
            iteracoes: resultado.iteracoes,
            segundosMinimo: resultado.segundosMinimo,
            segundosMedio: resultado.segundosMedio,
            segundosMediano: resultado.segundosMediano,
            segundosP90: resultado.segundosP90,
            segundosMAD: resultado.segundosMAD,
            amostrasSegundos: resultado.amostrasSegundos,
            unidade: resultado.unidade,
            detalhes: detalhes
        )
    }

    private static func sinalDeReferencia(quantidade: Int) -> [Float] {
        var estado: UInt32 = 0x51A7_E123
        return (0..<quantidade).map { _ in
            estado = estado &* 1_664_525 &+ 1_013_904_223
            let normalizado = Float(estado >> 8) / Float(0x00FF_FFFF)
            return (normalizado * 2 - 1) * 0.25
        }
    }

    private static func processarBlocos(
        cancelador: CanceladorDeEco,
        microfone: [Float],
        sistema: [Float]
    ) -> [Float] {
        let bloco = cancelador.tamanhoBloco
        var resultado: [Float] = []
        resultado.reserveCapacity(microfone.count)
        var inicio = 0
        while inicio < microfone.count {
            let fim = min(inicio + bloco, microfone.count)
            var mic = Array(microfone[inicio..<fim])
            var referencia = Array(sistema[inicio..<min(fim, sistema.count)])
            mic.append(contentsOf: repeatElement(0, count: bloco - mic.count))
            referencia.append(contentsOf: repeatElement(0, count: bloco - referencia.count))
            resultado.append(contentsOf: cancelador.processar(
                blocoMicrofone: mic,
                blocoSistema: referencia
            ).prefix(fim - inicio))
            inicio += bloco
        }
        return resultado
    }

    private static func memoriaDePico() -> Int64 {
        var uso = rusage()
        guard getrusage(RUSAGE_SELF, &uso) == 0 else { return 0 }
        return Int64(uso.ru_maxrss)
    }
}
