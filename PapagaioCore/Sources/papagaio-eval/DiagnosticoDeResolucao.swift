import Foundation
import LlamaRuntime
import PapagaioCore
import WhisperRuntime

/// `papagaio-eval resolver`: reproduz o caminho completo da atribuição de
/// falantes — transcrever → diarizar → alinhar → costurar vozes iguais →
/// casos → Qwen (com a resposta CRUA impressa) → aplicar — e no fim imprime
/// o destino de cada fala que começou "Voz desconhecida". Com
/// `--no-dispositivo` quem responde é o modelo on-device da Apple, para
/// comparar os dois na mesma conversa.
///
/// Serve para caçar onde as falas curtas ficam sem dono: a costura não agiu?
/// O caso não foi selecionado? O modelo disse "indeterminado"? A chamada
/// falhou? Cada etapa é impressa.
enum DiagnosticoDeResolucao {
    struct Opcoes {
        var audio: URL?
        var fixture: URL?
        var pastaDeModelos: URL
        var pastaDeDiarizacao: URL?
        /// Sem a chamada ao Qwen (só costura + seleção de casos).
        var semModelo: Bool
        /// Resolve com o modelo on-device da Apple no lugar do Qwen — o
        /// caminho do app quando o resumo vai pela nuvem privada.
        var noDispositivo = false
    }

    static func rodar(_ opcoes: Opcoes) async {
        let modelos = opcoes.pastaDeModelos

        // 1. Transcrição: do áudio real ou da fixture textual.
        let trechos: [Trecho]
        if let audio = opcoes.audio {
            print("## 1. Transcrição")
            print("áudio: \(audio.lastPathComponent)")
            let engine = WhisperEngine(
                modelo: modelos.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo)
            )
            let brutos: [Trecho]
            do {
                brutos = try await engine.transcribe(audio, speaker: nil)
            } catch {
                print("ERRO na transcrição: \(error)")
                return
            }
            await engine.descarregar()
            trechos = Segmentacao.agrupar(brutos)
            print("segmentos brutos: \(brutos.count) → trechos agrupados: \(trechos.count)")
        } else if let fixture = opcoes.fixture {
            print("## 1. Fixture")
            trechos = trechosDaFixture(fixture)
            print("\(trechos.count) trechos carregados de \(fixture.lastPathComponent)")
        } else {
            print("uso: papagaio-eval resolver <audio> [--pasta <dir>] [--modelos <dir>] [--sem-modelo] [--no-dispositivo]")
            return
        }

        // 2. Diarização acústica (só no áudio real; a fixture já rotula).
        var segmentos: [SegmentoDeFalante] = []
        if let audio = opcoes.audio {
            print("\n## 2. Diarização")
            let gerente: GerenciadorDeModelosDeDiarizacao
            if let pasta = opcoes.pastaDeDiarizacao {
                gerente = GerenciadorDeModelosDeDiarizacao(diretorio: pasta)
            } else {
                gerente = .embutido()
            }
            guard gerente.disponivel else {
                print("modelos de diarização não estagiados. Rode Scripts/bootstrap-runtimes.sh ou use --pasta.")
                return
            }
            do {
                segmentos = try await gerente.diarizar(audio)
            } catch {
                print("ERRO na diarização: \(error)")
                return
            }
            let porFalante = Dictionary(grouping: segmentos, by: \.falanteId)
                .map { "\($0.key): \($0.value.count)" }
                .joined(separator: ", ")
            print("segmentos: \(segmentos.count)  [\(porFalante)]")
        }

        // 3. Alinhamento: réplica do `PipelineDeArquivo.aplicarDiarizacao`
        // para insumo de canal único (o m4a importado não tem canais).
        print("\n## 3. Alinhamento")
        let alinhados: [Trecho] = trechos.map { trecho in
            guard !trecho.palavras.isEmpty, !segmentos.isEmpty else { return trecho }
            return trecho.comPalavras(
                AlinhamentoDeFalantes.atribuir(palavras: trecho.palavras, a: segmentos)
            )
        }
        let arquivo = Arquivo(
            titulo: opcoes.audio?.lastPathComponent ?? "fixture",
            pastaRelativa: "diagnostico",
            espaco: EspacoID(),
            trechos: alinhados
        )

        let antes = FalasDaConversa.agrupar(arquivo.trechos)
        guard let falasAntes = antes else {
            print("nenhuma palavra com falante — nada a diagnosticar (sem diarização?)")
            return
        }
        let desconhecidasAntes = falasAntes.filter { $0.falanteAcustico == nil }
        print("falas: \(falasAntes.count) · desconhecidas: \(desconhecidasAntes.count)")

        // 4. Costura de vozes iguais (determinística, sem modelo).
        print("\n## 4. Costura de vozes iguais")
        let costurado = ResolvedorDeFalantes.costurarVozesIguais(arquivo)
        let aposCostura = FalasDaConversa.agrupar(costurado.trechos) ?? []
        let costuradas = desconhecidasAntes.filter { fala in
            fala.palavras.contains { palavra in
                aposCostura.contains { $0.palavras.contains { $0.palavra.id == palavra.palavra.id } }
            } && fala.palavras.contains { palavra in
                let falaFinal = aposCostura.first { $0.palavras.contains { $0.palavra.id == palavra.palavra.id } }
                return falaFinal?.falanteAcustico != nil
            }
        }
        print("costuradas: \(costuradas.count) de \(desconhecidasAntes.count)")

        // 5. Casos elegíveis para o Qwen.
        print("\n## 5. Casos elegíveis")
        let casos = ResolvedorDeFalantes.casosElegiveis(falas: aposCostura)
        print("casos: \(casos.count) (teto por chamada: \(ResolvedorDeFalantes.maxCasosPorChamada))")
        for (i, caso) in casos.enumerated() {
            let resumoDoContexto = caso.contextoAnterior.split(separator: " ").suffix(6).joined(separator: " ")
            let resumoDepois = caso.contextoSeguinte.split(separator: " ").prefix(6).joined(separator: " ")
            print("  caso \(String(format: "%2d", i + 1)) · \"\(caso.texto)\" · anterior=\(caso.falanteAnterior) · seguinte=\(caso.falanteSeguinte)")
            print("        …\(resumoDoContexto) → [????] → \(resumoDepois)…")
        }

        // 6. Resposta crua do modelo e aplicação.
        var final = costurado
        var resolucoes: [UUID: String] = [:]
        if casos.isEmpty {
            print("\n## 6. Sem casos — Qwen não é chamado")
        } else if opcoes.semModelo {
            print("\n## 6. --sem-modelo: pulando a chamada ao Qwen")
        } else if opcoes.noDispositivo {
            let tamanho = ResolvedorDeFalantesNoDispositivo.casosPorChamada
            print("\n## 6. Modelo on-device da Apple (resposta crua, lotes de \(tamanho))")
            guard ResolvedorDeFalantesNoDispositivo.disponivel else {
                print("modelo on-device indisponível: ative o Apple Intelligence e espere o modelo baixar (confira com `fm available`).")
                return
            }
            let relogio = ContinuousClock()
            let inicio = relogio.now
            for primeiro in stride(from: 0, to: casos.count, by: tamanho) {
                let lote = Array(casos[primeiro..<min(primeiro + tamanho, casos.count)])
                let numero = primeiro / tamanho + 1
                do {
                    let bruto = try await ResolvedorDeFalantesNoDispositivo.responder(lote)
                    print("lote \(numero): \(bruto)")
                    resolucoes.merge(ResolvedorDeFalantes.decodificar(bruto, casos: lote)) { _, novo in novo }
                } catch {
                    // No app o lote que falha fica sem resposta e os outros seguem.
                    print("lote \(numero): ERRO \(error)")
                }
            }
            print("decodificadas: \(resolucoes.count) de \(casos.count) · tempo: \(relogio.now - inicio)")
            final = ResolvedorDeFalantes.aplicar(resolucoes, casos: casos, em: costurado)
        } else {
            print("\n## 6. Qwen (resposta crua)")
            let contexto = ContextoLlama(
                modelo: modelos.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
            )
            let bruto: String
            do {
                bruto = try await contexto.completar(
                    prompt: ResolvedorDeFalantes.prompt(para: casos),
                    gramatica: ResolvedorDeFalantes.gramatica(para: casos),
                    maxTokens: 1_024
                )
            } catch {
                print("ERRO na chamada ao Qwen: \(error)")
                print("\n### Destino das falas desconhecidas (chamada falhou):")
                imprimirDestino(
                    falasAntes,
                    falasFinais: aposCostura,
                    casos: casos,
                    resolucoes: [:]
                )
                return
            }
            print("```")
            print(bruto)
            print("```")
            resolucoes = ResolvedorDeFalantes.decodificar(bruto, casos: casos)
            print("decodificadas: \(resolucoes.count) de \(casos.count)")
            final = ResolvedorDeFalantes.aplicar(resolucoes, casos: casos, em: costurado)
        }

        // 7. Destino de cada fala que começou desconhecida.
        print("\n## 7. Destino das falas desconhecidas")
        imprimirDestino(
            falasAntes,
            falasFinais: FalasDaConversa.agrupar(final.trechos) ?? [],
            casos: casos,
            resolucoes: resolucoes
        )

        // Resumo final.
        let falasFinais = FalasDaConversa.agrupar(final.trechos) ?? []
        let aindaDesconhecidas = falasFinais.filter { $0.falanteAcustico == nil }
        print("\n## Resultado")
        print("desconhecidas: \(desconhecidasAntes.count) → \(aindaDesconhecidas.count)")
    }

    /// Uma linha por fala que começou sem falante: o que aconteceu com ela.
    private static func imprimirDestino(
        _ falasAntes: [FalaDeFalante],
        falasFinais: [FalaDeFalante],
        casos: [ResolvedorDeFalantes.Caso],
        resolucoes: [UUID: String]
    ) {
        var casosPorId: [UUID: ResolvedorDeFalantes.Caso] = [:]
        for caso in casos { casosPorId[caso.id] = caso }
        // Depois da costura, `agrupar` funde a fala costurada com o vizinho e o
        // id dela muda (vira o da primeira palavra). Casar por palavra: cada
        // palavra das falas finais leva à fala que a contém.
        var falaPorPalavra: [UUID: FalaDeFalante] = [:]
        for fala in falasFinais {
            for palavra in fala.palavras {
                falaPorPalavra[palavra.palavra.id] = fala
            }
        }

        for fala in falasAntes where fala.falanteAcustico == nil {
            let falaFinal = fala.palavras.compactMap { falaPorPalavra[$0.palavra.id] }.first
            let rotuloFinal = falaFinal?.falanteAcustico
            let marcador = rotuloFinal != nil ? "✓" : "✗"
            let mecanismo: String
            if rotuloFinal == nil {
                if casosPorId[fala.id] != nil {
                    mecanismo = "modelo respondeu indeterminado (ou chamada falhou)"
                } else {
                    mecanismo = "não virou caso nem costura"
                }
            } else if casosPorId[fala.id] == nil {
                mecanismo = "costura de vozes iguais"
            } else if resolucoes[fala.id] != nil {
                mecanismo = "modelo (\(resolucoes[fala.id]!))"
            } else {
                mecanismo = "??"
            }
            let indice = falasAntes.firstIndex(where: { $0.id == fala.id }) ?? -1
            print("  \(marcador) fala \(String(format: "%2d", indice)) @ \(String(format: "%6.1f", fala.inicio))s · \(String(fala.texto.prefix(38))) → \(rotuloFinal ?? "sem dono (\(mecanismo))")")
        }
    }

    /// Carrega a fixture textual: `[{"rotulo": "S1"|null, "texto": "..."}]`,
    /// uma fala por item, palavras com 1 s cada.
    private static func trechosDaFixture(_ url: URL) -> [Trecho] {
        guard let dados = try? Data(contentsOf: url),
              let itens = try? JSONDecoder().decode([ItemDaFixture].self, from: dados)
        else {
            print("ERRO: fixture inválida — esperado [{\"rotulo\": ..., \"texto\": ...}]")
            exit(3)
        }
        var t = 0.0
        return itens.map { item in
            let palavras = item.texto.split(separator: " ").map { pedaco in
                defer { t += 1 }
                return Palavra(
                    start: t,
                    end: t + 1,
                    texto: String(pedaco),
                    falanteAcustico: item.rotulo
                )
            }
            let trecho = Trecho(
                start: palavras.first?.start ?? t,
                end: palavras.last?.end ?? t,
                texto: item.texto,
                palavras: palavras
            )
            t = trecho.end
            return trecho
        }
    }

    private struct ItemDaFixture: Decodable {
        let rotulo: String?
        let texto: String
    }
}
