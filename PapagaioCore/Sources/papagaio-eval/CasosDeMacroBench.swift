import AVFoundation
import Foundation
import LlamaRuntime
import PapagaioCore
import WhisperRuntime

// Macro-benchmarks: pipeline real com pesos Whisper/Qwen.
// Só roda quando os arquivos de modelo existem; caso contrário pula com aviso.

enum CasosDeMacroBench {
    struct Opcoes {
        var pastaDeModelos: URL
        var audio: URL?
        var iteracoes: Int = 1
        var incluirResumo: Bool = true
        var incluirTraducao: Bool = true
        var incluirDiarizacao: Bool = false
    }

    /// Abre o arquivo em leitura: `fileExists` é true até no container do
    /// sandbox, mas o `open` de lá falha com EPERM para processos fora do app.
    private static func legivel(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func pastaPadraoDeModelos() -> URL {
        // O CLI roda fora do sandbox: prefere a Application Support legível
        // (fora do container) e só cai no container se os pesos forem abríveis.
        let candidatas = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Papagaio/Models"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/InterviewLab/Models"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(
                    "Library/Containers/com.papagaio.Papagaio/Data/Library/Application Support/Papagaio/Models"
                ),
        ]
        for p in candidatas where legivel(modeloWhisper(p)) {
            return p
        }
        for p in candidatas where FileManager.default.fileExists(atPath: p.path) {
            return p
        }
        return candidatas[0]
    }

    static func modeloWhisper(_ pasta: URL) -> URL {
        pasta.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo)
    }

    static func modeloQwen(_ pasta: URL) -> URL {
        pasta.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    }

    static func temModelos(_ pasta: URL) -> Bool {
        legivel(modeloWhisper(pasta))
    }

    static func temQwen(_ pasta: URL) -> Bool {
        legivel(modeloQwen(pasta))
    }

    static func rodar(_ opcoes: Opcoes) async -> [ResultadoBench] {
        var resultados: [ResultadoBench] = []
        let pasta = opcoes.pastaDeModelos

        guard temModelos(pasta) else {
            print("AVISO: Whisper não encontrado em \(pasta.path) — pulando macro-benchmarks.")
            print("       Rode Scripts/bootstrap-runtimes.sh ou baixe os pesos.")
            return resultados
        }

        // —— Carga/descarga do Whisper (o custo que a fila paga por arquivo) ——
        do {
            let r = try await Medidor.medirAsync(
                nome: "macro.whisper.cicloCargaDescarga",
                iteracoes: 2,
                unidade: "carga+unload do large-v3"
            ) {
                let engine = WhisperEngine(modelo: modeloWhisper(pasta))
                try await engine.preaquecer()
                await engine.descarregar()
            }
            resultados.append(r)
        } catch {
            print("AVISO: falha no ciclo Whisper: \(error)")
        }

        // —— Transcrição de áudio real (se fornecido) ——
        if let audio = opcoes.audio,
           FileManager.default.fileExists(atPath: audio.path) {
            do {
                let duracao = try await duracaoDoAudio(audio)
                let engine = WhisperEngine(modelo: modeloWhisper(pasta))
                let r = try await Medidor.medirAsync(
                    nome: "macro.whisper.transcrever",
                    iteracoes: opcoes.iteracoes,
                    unidade: "RTF (duração/tempo)",
                    detalhes: [
                        "audio": audio.lastPathComponent,
                        "duracao_s": String(format: "%.1f", duracao),
                    ]
                ) {
                    _ = try await engine.transcribe(audio, speaker: nil)
                }
                // RTF canônico = tempo_de_processamento / duração_do_áudio (menor é melhor).
                let rtf = max(r.segundosMedio, 1e-9) / max(duracao, 1e-9)
                resultados.append(ResultadoBench(
                    nome: r.nome,
                    iteracoes: r.iteracoes,
                    segundosMinimo: r.segundosMinimo,
                    segundosMedio: r.segundosMedio,
                    segundosMediano: r.segundosMediano,
                    unidade: String(format: "RTF=%.2f (menor é melhor; 1.0 = tempo real)", rtf),
                    detalhes: r.detalhes
                ))
                await engine.descarregar()
            } catch {
                print("AVISO: falha na transcrição: \(error)")
            }
        } else {
            print("AVISO: nenhum áudio fornecido — pulando transcrição real.")
        }

        // —— Ciclo de carga/descarga do Qwen (custo que a fila paga por arquivo) ——
        if temQwen(pasta) {
            do {
                let r = try await Medidor.medirAsync(
                    nome: "macro.qwen.cicloCargaDescarga",
                    iteracoes: 2,
                    unidade: "carga+unload do Qwen3.5-9B"
                ) {
                    let engine = QwenEngine(modelo: modeloQwen(pasta))
                    try await engine.preaquecer()
                    await engine.descarregar()
                }
                resultados.append(r)
            } catch {
                print("AVISO: falha no ciclo Qwen: \(error)")
            }
        }

        // —— Sumarização Qwen ——
        if opcoes.incluirResumo, temQwen(pasta) {
            // Gera trechos sintéticos longos o suficiente para forçar o prefill.
            let trechos = sintetizarTrechos(quantidade: 400)
            do {
                let contexto = ContextoLlama(modelo: modeloQwen(pasta))
                let engine = QwenEngine(contexto: contexto)
                let transcricao = QwenEngine.formatar(trechos)
                let tokens = try await contexto.contarTokens(transcricao)
                let r = try await Medidor.medirAsync(
                    nome: "macro.qwen.resumir",
                    iteracoes: 1, // resumo é caro; 1 iteração + warm-up é suficiente
                    unidade: "400 trechos sintéticos",
                    detalhes: [
                        "tokens_entrada": String(tokens),
                        "modo": tokens <= ContextoLlama.tetoDeEntrada ? "passe-unico" : "map-reduce",
                    ]
                ) {
                    _ = try await engine.summarize(trechos)
                }
                resultados.append(r)
                await engine.descarregar()
            } catch {
                print("AVISO: falha na sumarização: \(error)")
            }
        }

        // —— Tradução local (mesmo Qwen; só quando há divergência de idioma) ——
        if opcoes.incluirTraducao, temQwen(pasta) {
            // Lote curto: a gramática GBNF de tradução exige JSON com exatamente
            // N saídas; 200 trechos sintéticos longos estouram maxTokens e o
            // llama.cpp recusa a gramática. 40 trechos cabe no teto de 4096.
            let trechos = sintetizarTrechos(quantidade: 40)
            do {
                let engine = QwenEngine(modelo: modeloQwen(pasta))
                let r = try await Medidor.medirAsync(
                    nome: "macro.qwen.traduzir",
                    iteracoes: 1,
                    unidade: "40 trechos pt→en",
                    detalhes: ["lotes_tokens": String(QwenEngine.tokensPorLoteDeTraducao)]
                ) {
                    _ = try await engine.traduzir(trechos, para: .ingles)
                }
                resultados.append(r)
                await engine.descarregar()
            } catch {
                print("AVISO: falha na tradução: \(error)")
            }
        }

        return resultados
    }

    private static func sintetizarTrechos(quantidade: Int) -> [Trecho] {
        (0..<quantidade).map { i in
            let start = Double(i) * 40
            let texto = """
            Bem, acho que precisamos revisar o orçamento do trimestre. \
            O João disse que o custo subiu 15 por cento e a Maria discordou. \
            Vamos marcar uma reunião na sexta para decidir. \
            Ponto número dois: o prazo do projeto Alpha foi adiado. \
            Todos concordaram em reavaliar na próxima semana.
            """
            let palavras = texto.split(separator: " ").enumerated().map { j, w in
                Palavra(
                    start: start + Double(j) * 0.3,
                    end: start + Double(j) * 0.3 + 0.25,
                    texto: String(w),
                    confianca: 0.85 + Float(j % 10) * 0.01
                )
            }
            return Trecho(
                start: start,
                end: start + 38,
                texto: texto,
                speaker: i % 2 == 0 ? "eu" : "interlocutor",
                palavras: palavras
            )
        }
    }

    private static func duracaoDoAudio(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duracao = try await asset.load(.duration)
        return duracao.seconds
    }
}
