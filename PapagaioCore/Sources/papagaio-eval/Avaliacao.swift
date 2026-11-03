import Foundation
import LlamaRuntime
import MetricasDeAvaliacao
import PapagaioCore

/// `papagaio-eval run`: mede a **qualidade** do pipeline do app, não o tempo de
/// cada peça (isso é o `bench`).
///
/// Roda o mesmo caminho de um arquivo importado no app — Whisper com VAD,
/// filtro de repetição, agrupamento em trechos, diarização com alinhamento por
/// palavra e o resumo do Qwen com validação de citações — e compara o
/// resultado com uma referência conhecida. Os dados vêm de
/// `Scripts/avaliacao/preparar-dados.py`; ver a seção "Avaliação" do README.
enum Avaliacao {
    enum Suite: String, CaseIterable, Codable {
        /// Falas isoladas com transcrição de referência: WER, CER e velocidade.
        case transcricao
        /// Conversas com turnos conhecidos: DER e acerto de falante por palavra.
        case falantes
        /// Reuniões roteirizadas: fatos preservados no resumo e citações.
        case resumo
    }

    struct Opcoes {
        var dados: URL
        var modelos: URL
        var saida: URL
        /// Teto de itens por suíte, para uma rodada rápida de conferência.
        var limite: Int?
        var suites: Set<Suite> = Set(Suite.allCases)
    }

    // MARK: - Manifesto

    struct Manifesto: Decodable {
        struct Fala: Decodable {
            let id: String
            let audio: String
            let duracao: Double
            let referencia: String
        }

        struct Conversa: Decodable {
            let id: String
            let audio: String
            let duracao: Double
            let referencia: String
            let turnos: [IntervaloDeFala]
            /// Só nas reuniões.
            let fatos: [CoberturaDeFatos.Fato]?
        }

        let fontes: [String: String]
        let transcricao: [Fala]
        let conversas: [Conversa]
        let reunioes: [Conversa]
    }

    // MARK: - Relatório

    struct ItemDeTranscricao: Codable {
        let id: String
        let duracao: Double
        let segundos: Double
        let wer: ContagemDeErros
        let cer: ContagemDeErros
        let referencia: String
        let hipotese: String
    }

    struct ResultadoDeTranscricao: Codable {
        let wer: ContagemDeErros
        let cer: ContagemDeErros
        let duracaoDoAudio: Double
        let segundosDeProcessamento: Double
        /// Segundos de áudio por segundo de processamento (maior é melhor).
        let vezesTempoReal: Double
        let segundosDeCargaDoModelo: Double
        let itens: [ItemDeTranscricao]
    }

    struct ItemDeFalantes: Codable {
        let id: String
        let duracao: Double
        let segundosDeDiarizacao: Double
        let diarizacao: ResultadoDeDiarizacao
        let porPalavra: AcertoDeFalantePorPalavra
    }

    struct ResultadoDeFalantes: Codable {
        let diarizacao: ResultadoDeDiarizacao
        let porPalavra: AcertoDeFalantePorPalavra
        /// Conversas em que a diarização achou exatamente o número de falantes.
        let numeroDeFalantesCorreto: Int
        let itens: [ItemDeFalantes]
    }

    struct FatoAvaliado: Codable {
        let descricao: String
        let coberto: Bool
    }

    struct ItemDeResumo: Codable {
        let id: String
        let duracao: Double
        let werDaTranscricao: ContagemDeErros
        let tokensDeEntrada: Int
        let segundosDeResumo: Double
        let fatos: [FatoAvaliado]
        let citacoesSugeridas: Int
        /// Sugestões que passariam sozinhas pela `ValidacaoDeCitacoes`: texto
        /// achado literalmente na transcrição e de 8 a 32 palavras.
        let citacoesValidas: Int
        let resumo: Resumo
    }

    struct ResultadoDeResumo: Codable {
        let fatosCobertos: Int
        let fatosTotal: Int
        let citacoesSugeridas: Int
        let citacoesValidas: Int
        let werDaTranscricao: ContagemDeErros
        let itens: [ItemDeResumo]
    }

    struct Relatorio: Codable {
        let data: Date
        let maquina: String
        let modelos: [String]
        let fontes: [String: String]
        var transcricao: ResultadoDeTranscricao?
        var falantes: ResultadoDeFalantes?
        var resumo: ResultadoDeResumo?
    }

    // MARK: - Execução

    static func rodar(_ opcoes: Opcoes) async throws -> Relatorio {
        let manifesto = try JSONDecoder().decode(
            Manifesto.self,
            from: Data(contentsOf: opcoes.dados.appendingPathComponent("manifesto.json"))
        )
        func limitar<T>(_ itens: [T]) -> [T] { opcoes.limite.map { Array(itens.prefix($0)) } ?? itens }

        var relatorio = Relatorio(
            data: Date(),
            maquina: HostInfo.descricao,
            modelos: [Pesos.whisperLargeV3.nomeArquivo, Pesos.qwen35_9B.nomeArquivo, GerenciadorDeModelosDeDiarizacao.identificador],
            fontes: manifesto.fontes
        )

        let whisper = WhisperEngine(modelo: opcoes.modelos.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo))
        let carga = try await cronometrar { try await whisper.preaquecer() }.segundos

        if opcoes.suites.contains(.transcricao) {
            print("\n--- transcrição: \(limitar(manifesto.transcricao).count) falas ---")
            relatorio.transcricao = try await avaliarTranscricao(
                limitar(manifesto.transcricao), dados: opcoes.dados, whisper: whisper, carga: carga
            )
        }

        if opcoes.suites.contains(.falantes) {
            print("\n--- falantes: \(limitar(manifesto.conversas).count) conversas ---")
            relatorio.falantes = try await avaliarFalantes(
                limitar(manifesto.conversas), dados: opcoes.dados, whisper: whisper
            )
        }

        // O resumo transcreve primeiro e só então troca o Whisper pelo Qwen:
        // os dois juntos não cabem com folga em 24 GB, e é a mesma alternância
        // que o `MotoresLocais` faz no app.
        var transcricoesDasReunioes: [(reuniao: Manifesto.Conversa, trechos: [Trecho])] = []
        if opcoes.suites.contains(.resumo) {
            print("\n--- resumo: \(limitar(manifesto.reunioes).count) reuniões ---")
            for reuniao in limitar(manifesto.reunioes) {
                let trechos = try await transcrever(opcoes.dados.appendingPathComponent(reuniao.audio), whisper).valor
                transcricoesDasReunioes.append((reuniao, trechos))
            }
        }
        await whisper.descarregar()

        if !transcricoesDasReunioes.isEmpty {
            relatorio.resumo = try await avaliarResumos(
                transcricoesDasReunioes,
                modelo: opcoes.modelos.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
            )
        }

        return relatorio
    }

    // MARK: - Suítes

    private static func avaliarTranscricao(
        _ falas: [Manifesto.Fala],
        dados: URL,
        whisper: WhisperEngine,
        carga: Double
    ) async throws -> ResultadoDeTranscricao {
        var itens: [ItemDeTranscricao] = []
        for (indice, fala) in falas.enumerated() {
            let (trechos, segundos) = try await transcrever(dados.appendingPathComponent(fala.audio), whisper)
            let hipotese = texto(de: trechos)
            let item = ItemDeTranscricao(
                id: fala.id,
                duracao: fala.duracao,
                segundos: segundos,
                wer: DistanciaDeEdicao.wer(referencia: fala.referencia, hipotese: hipotese),
                cer: DistanciaDeEdicao.cer(referencia: fala.referencia, hipotese: hipotese),
                referencia: fala.referencia,
                hipotese: hipotese
            )
            itens.append(item)
            print(String(format: "  [%3d/%d] %@  WER %5.1f%%", indice + 1, falas.count, fala.id, item.wer.taxa * 100))
        }
        let duracao = itens.map(\.duracao).reduce(0, +)
        let processamento = itens.map(\.segundos).reduce(0, +)
        return ResultadoDeTranscricao(
            wer: itens.map(\.wer).reduce(ContagemDeErros(), +),
            cer: itens.map(\.cer).reduce(ContagemDeErros(), +),
            duracaoDoAudio: duracao,
            segundosDeProcessamento: processamento,
            vezesTempoReal: processamento > 0 ? duracao / processamento : 0,
            segundosDeCargaDoModelo: carga,
            itens: itens
        )
    }

    private static func avaliarFalantes(
        _ conversas: [Manifesto.Conversa],
        dados: URL,
        whisper: WhisperEngine
    ) async throws -> ResultadoDeFalantes? {
        let diarizador = GerenciadorDeModelosDeDiarizacao.embutido()
        guard diarizador.disponivel else {
            print("AVISO: modelos de diarização ausentes — rode Scripts/bootstrap-runtimes.sh. Pulando falantes.")
            return nil
        }

        var itens: [ItemDeFalantes] = []
        for conversa in conversas {
            let audio = dados.appendingPathComponent(conversa.audio)
            let trechos = try await transcrever(audio, whisper).valor
            let (segmentos, segundos) = try await cronometrar { try await diarizador.diarizar(audio) }

            let diarizacao = ErroDeDiarizacao.avaliar(
                referencia: conversa.turnos,
                hipotese: segmentos.map { IntervaloDeFala(falante: $0.falanteId, inicio: $0.inicio, fim: $0.fim) }
            )

            // O caminho do app para um arquivo de canal único: atribui cada
            // palavra ao segmento acústico e costura as vozes iguais. A
            // resolução pelo contexto (Qwen) fica de fora — ela é opcional no
            // app e mediria o Qwen, não a diarização.
            let alinhados = trechos.map { trecho in
                trecho.palavras.isEmpty
                    ? trecho
                    : trecho.comPalavras(AlinhamentoDeFalantes.atribuir(palavras: trecho.palavras, a: segmentos))
            }
            let costurado = ResolvedorDeFalantes.costurarVozesIguais(
                Arquivo(titulo: conversa.id, pastaRelativa: "", espaco: EspacoID(), trechos: alinhados)
            )
            let porPalavra = AcertoDeFalantePorPalavra.avaliar(
                palavras: costurado.trechos.flatMap(\.palavras).map {
                    PalavraAtribuida(inicio: $0.start, fim: $0.end, falante: $0.falanteAcustico)
                },
                referencia: conversa.turnos
            )

            itens.append(ItemDeFalantes(
                id: conversa.id,
                duracao: conversa.duracao,
                segundosDeDiarizacao: segundos,
                diarizacao: diarizacao,
                porPalavra: porPalavra
            ))
            print(String(
                format: "  %@  DER %5.1f%%  falantes %d/%d  palavras certas %5.1f%%",
                conversa.id, diarizacao.der * 100, diarizacao.falantesNaHipotese,
                diarizacao.falantesNaReferencia, porPalavra.acuracia * 100
            ))
        }
        await diarizador.descarregar()

        return ResultadoDeFalantes(
            diarizacao: itens.map(\.diarizacao).reduce(ResultadoDeDiarizacao(), +),
            porPalavra: itens.map(\.porPalavra).reduce(AcertoDeFalantePorPalavra(), +),
            numeroDeFalantesCorreto: itens.filter {
                $0.diarizacao.falantesNaHipotese == $0.diarizacao.falantesNaReferencia
            }.count,
            itens: itens
        )
    }

    private static func avaliarResumos(
        _ reunioes: [(reuniao: Manifesto.Conversa, trechos: [Trecho])],
        modelo: URL
    ) async throws -> ResultadoDeResumo {
        let contexto = ContextoLlama(modelo: modelo)
        let qwen = QwenEngine(contexto: contexto)
        try await qwen.preaquecer()

        var itens: [ItemDeResumo] = []
        for (reuniao, trechos) in reunioes {
            let tokens = try await contexto.contarTokens(QwenEngine.formatar(trechos))
            let ((resumo, sugeridas), segundos) = try await cronometrar {
                try await qwen.summarizeComCitacoesSugeridas(trechos)
            }

            // O que a pessoa lê no resumo. As citações ficam de fora: elas são
            // fala literal, e contá-las daria crédito ao resumo por um fato que
            // só foi copiado da transcrição.
            let textoDoResumo = (
                [resumo.titulo, resumo.visaoGeral]
                    + resumo.temas.flatMap { [$0.titulo, $0.detalhe] }
                    + resumo.proximosPassos.flatMap { [$0.descricao, $0.responsavel ?? ""] }
            ).joined(separator: "\n")
            let fatos = (reuniao.fatos ?? []).map {
                FatoAvaliado(descricao: $0.descricao, coberto: CoberturaDeFatos.cobre($0, texto: textoDoResumo))
            }
            let validas = sugeridas.filter { !ValidacaoDeCitacoes.validar([$0], contra: trechos).isEmpty }.count

            itens.append(ItemDeResumo(
                id: reuniao.id,
                duracao: reuniao.duracao,
                werDaTranscricao: DistanciaDeEdicao.wer(referencia: reuniao.referencia, hipotese: texto(de: trechos)),
                tokensDeEntrada: tokens,
                segundosDeResumo: segundos,
                fatos: fatos,
                citacoesSugeridas: sugeridas.count,
                citacoesValidas: validas,
                resumo: resumo
            ))
            print(String(
                format: "  %@  fatos %d/%d  citações válidas %d/%d  %.0f s",
                reuniao.id, fatos.filter(\.coberto).count, fatos.count, validas, sugeridas.count, segundos
            ))
        }
        await qwen.descarregar()

        return ResultadoDeResumo(
            fatosCobertos: itens.flatMap(\.fatos).filter(\.coberto).count,
            fatosTotal: itens.flatMap(\.fatos).count,
            citacoesSugeridas: itens.map(\.citacoesSugeridas).reduce(0, +),
            citacoesValidas: itens.map(\.citacoesValidas).reduce(0, +),
            werDaTranscricao: itens.map(\.werDaTranscricao).reduce(ContagemDeErros(), +),
            itens: itens
        )
    }

    // MARK: - Apoio

    /// O caminho de um arquivo importado no `PipelineDeArquivo`: sem canal de
    /// origem, então sem falante, e com o filtro de repetição antes do agrupamento.
    private static func transcrever(
        _ audio: URL,
        _ whisper: WhisperEngine
    ) async throws -> (valor: [Trecho], segundos: Double) {
        try await cronometrar {
            Segmentacao.agrupar(FiltroDeRepeticao.remover(try await whisper.transcribe(audio, speaker: nil)))
        }
    }

    private static func texto(de trechos: [Trecho]) -> String {
        trechos.map(\.texto).joined(separator: " ")
    }

    private static func cronometrar<T>(_ trabalho: () async throws -> T) async throws -> (valor: T, segundos: Double) {
        let relogio = ContinuousClock()
        let inicio = relogio.now
        let valor = try await trabalho()
        let gasto = relogio.now - inicio
        return (valor, Double(gasto.components.seconds) + Double(gasto.components.attoseconds) / 1e18)
    }

    // MARK: - Saída

    static func gravar(_ relatorio: Relatorio, em url: URL) throws {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        codificador.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try codificador.encode(relatorio).write(to: url, options: .atomic)
    }

    static func imprimir(_ relatorio: Relatorio) {
        print("\n=== avaliação — \(relatorio.maquina) ===")
        if let t = relatorio.transcricao {
            print(String(
                format: "transcrição  WER %.1f%%  CER %.1f%%  (%d falas, %.1f min de áudio, %.1fx tempo real)",
                t.wer.taxa * 100, t.cer.taxa * 100, t.itens.count, t.duracaoDoAudio / 60, t.vezesTempoReal
            ))
        }
        if let f = relatorio.falantes {
            print(String(
                format: "falantes     DER %.1f%%  palavras com o falante certo %.1f%%  nº de falantes certo %d/%d",
                f.diarizacao.der * 100, f.porPalavra.acuracia * 100, f.numeroDeFalantesCorreto, f.itens.count
            ))
        }
        if let r = relatorio.resumo {
            print(String(
                format: "resumo       fatos %d/%d  citações válidas %d/%d  WER da transcrição %.1f%%",
                r.fatosCobertos, r.fatosTotal, r.citacoesValidas, r.citacoesSugeridas, r.werDaTranscricao.taxa * 100
            ))
        }
    }
}
