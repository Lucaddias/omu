import Foundation
import os
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// Uma resposta do modelo de servidor, com o que ela custou de entrada.
///
/// `tokensDeEntrada` é a única contagem real que existe: o modelo de servidor
/// não conta tokens antes do envio, então a engine aprende a proporção com
/// cada resposta (ver `OrcamentoDeTokens`).
public struct RespostaDaNuvem<Conteudo: Sendable>: Sendable {
    public let conteudo: Conteudo
    public let tokensDeEntrada: Int?

    public init(_ conteudo: Conteudo, tokensDeEntrada: Int? = nil) {
        self.conteudo = conteudo
        self.tokensDeEntrada = tokensDeEntrada
    }
}

/// O que a engine precisa do modelo de servidor: uma ata estruturada e texto
/// livre. Cada chamada é **uma requisição** contra o limite diário de quem
/// usa — por isso a engine conta chamadas, não tokens.
///
/// Existe como protocolo para os testes trocarem a rede por um falso.
public protocol GeradorDaNuvemPrivada: Sendable {
    func resumoEstruturado(_ mensagens: PromptsDoResumo.Mensagens) async throws -> RespostaDaNuvem<Resumo>
    func texto(_ mensagens: PromptsDoResumo.Mensagens) async throws -> RespostaDaNuvem<String>
}

/// Estimativa de tokens sem tokenizador, calibrada pelo uso real.
///
/// Começa conservadora e corrige com o que a Apple devolve: a contagem de
/// entrada de cada resposta bem-sucedida e a contagem do erro de janela
/// excedida. Errar para mais custa um map-reduce desnecessário (três
/// requisições no lugar de uma); errar para menos custa uma requisição
/// recusada. A margem de 10% pende para o primeiro.
public struct OrcamentoDeTokens: Sendable, Equatable {
    public static let bytesPorTokenInicial = 3.0
    static let faixa = 1.5...6.0
    static let margem = 0.9

    /// Bytes UTF-8 de texto por token.
    public private(set) var bytesPorToken: Double

    public init(bytesPorToken: Double? = nil) {
        self.bytesPorToken = Self.limitar(bytesPorToken ?? Self.bytesPorTokenInicial)
    }

    public func estimar(_ texto: String) -> Int {
        Int((Double(texto.utf8.count) / bytesPorToken).rounded(.up))
    }

    /// Ajusta a proporção pela contagem real de um texto enviado.
    public mutating func calibrar(texto: String, tokensReais: Int) {
        guard tokensReais > 0, !texto.isEmpty else { return }
        bytesPorToken = Self.limitar(Double(texto.utf8.count) / Double(tokensReais) * Self.margem)
    }

    private static func limitar(_ valor: Double) -> Double {
        min(max(valor, faixa.lowerBound), faixa.upperBound)
    }
}

/// Resumo pelo modelo de servidor do Apple Intelligence (Private Cloud
/// Compute). Mesmo contrato e mesma ata do `QwenEngine`, sem peso para baixar.
///
/// O que muda em relação ao Qwen:
/// - **não há tokenizador**: o tamanho da entrada é estimado, e a janela
///   excedida vira o gatilho do map-reduce;
/// - **cada chamada gasta o limite diário de quem usa**: passe único sempre
///   que couber, e chunks grandes quando não couber;
/// - **o formato vem de geração guiada**, não de gramática GBNF nem de
///   reprompt.
///
/// O que não muda: o modelo sugere, a transcrição decide
/// (`ValidacaoDeCitacoes`).
public struct NuvemPrivadaEngine: SummarizationEngine {
    public static let identificador = "apple-pcc"

    public let identifier = NuvemPrivadaEngine.identificador

    /// Janela do modelo de servidor — a mesma do Qwen.
    public static let janela = 32_768
    /// Reserva para a ata gerada.
    public static let tokensDeSaida = 6_000
    /// Reserva para o resumo livre de uma parte.
    public static let tokensDeSaidaParcial = 3_000
    /// Passe único até aqui, pela estimativa. Sobra a saída e uma folga para
    /// o erro da estimativa e para o esquema que a Apple acrescenta.
    public static let tetoDeEntrada = 24_000
    /// Chunk do map-reduce. Bem maior que os 8 mil do Qwen de propósito:
    /// menos partes, menos requisições.
    public static let tokensPorChunk = 20_000
    /// Quantas vezes uma parte pode ser recortada depois de exceder a janela.
    static let recalibragensMaximas = 3

    /// Onde a proporção aprendida fica guardada entre execuções.
    public struct Calibragem: Sendable {
        public var ler: @Sendable () -> Double?
        public var gravar: @Sendable (Double) -> Void

        public init(
            ler: @escaping @Sendable () -> Double?,
            gravar: @escaping @Sendable (Double) -> Void
        ) {
            self.ler = ler
            self.gravar = gravar
        }

        public static let chave = "nuvemPrivada.bytesPorToken"

        public static let preferencias = Calibragem(
            ler: {
                let valor = UserDefaults.standard.double(forKey: chave)
                return valor > 0 ? valor : nil
            },
            gravar: { UserDefaults.standard.set($0, forKey: chave) }
        )

        public static let nenhuma = Calibragem(ler: { nil }, gravar: { _ in })
    }

    private let gerador: (any GeradorDaNuvemPrivada)?
    private let calibragem: Calibragem

    /// A engine de produção. Sem a nuvem disponível, `summarize` lança
    /// `ErroDaNuvemPrivada.indisponivel` com o motivo.
    public init(calibragem: Calibragem = .preferencias) {
        self.gerador = Self.geradorDoSistema()
        self.calibragem = calibragem
    }

    public init(gerador: any GeradorDaNuvemPrivada, calibragem: Calibragem = .nenhuma) {
        self.gerador = gerador
        self.calibragem = calibragem
    }

    public func summarize(_ trechos: [Trecho]) async throws -> Resumo {
        try await summarize(trechos, idiomaDeSaida: nil)
    }

    public func summarize(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento? = nil
    ) async throws -> Resumo {
        guard !trechos.isEmpty else { throw ErroDeResumo.transcricaoVazia }
        guard let gerador else {
            throw ErroDaNuvemPrivada.indisponivel(NuvemPrivada.disponibilidade)
        }

        var orcamento = OrcamentoDeTokens(bytesPorToken: calibragem.ler())
        var bruto: Resumo?

        let ata = PromptsDoResumo.ata(
            transcricao: QwenEngine.formatar(trechos),
            idiomaDeSaida: idiomaDeSaida
        )
        if orcamento.estimar(ata.texto) <= Self.tetoDeEntrada {
            do {
                let resposta = try await gerador.resumoEstruturado(ata)
                aprender(com: resposta.tokensDeEntrada, de: ata, em: &orcamento)
                bruto = resposta.conteudo
            } catch let ErroDaNuvemPrivada.contextoExcedido(tokens, _) {
                // A estimativa errou para menos. A contagem real corrige a
                // proporção e a conversa segue em partes.
                aprender(com: tokens, de: ata, em: &orcamento)
            }
        }

        let resumo: Resumo
        if let bruto {
            resumo = bruto
        } else {
            resumo = try await mapReduce(
                trechos, idiomaDeSaida: idiomaDeSaida, orcamento: orcamento, gerador: gerador
            )
        }

        return Resumo(
            titulo: resumo.titulo,
            visaoGeral: resumo.visaoGeral,
            temas: resumo.temas,
            citacoes: ValidacaoDeCitacoes.validar(resumo.citacoes, contra: trechos),
            proximosPassos: resumo.proximosPassos
        )
    }

    // MARK: - Map-reduce

    private func mapReduce(
        _ trechos: [Trecho],
        idiomaDeSaida: IdiomaDeProcessamento?,
        orcamento inicial: OrcamentoDeTokens,
        gerador: any GeradorDaNuvemPrivada
    ) async throws -> Resumo {
        var orcamento = inicial
        var restantes = trechos[...]
        var parciais: [String] = []
        var recalibragens = 0

        while !restantes.isEmpty {
            try Task.checkCancellation()
            let chunk = Self.proximoChunk(de: restantes, orcamento: orcamento)
            let mensagens = PromptsDoResumo.parcial(
                transcricao: QwenEngine.formatar(Array(chunk)),
                idiomaDeSaida: idiomaDeSaida
            )
            do {
                let resposta = try await gerador.texto(mensagens)
                aprender(com: resposta.tokensDeEntrada, de: mensagens, em: &orcamento)
                parciais.append(resposta.conteudo)
                restantes = restantes.dropFirst(chunk.count)
            } catch let ErroDaNuvemPrivada.contextoExcedido(tokens, limite) {
                // Só esta parte é recortada: as anteriores já custaram uma
                // requisição cada e continuam valendo.
                guard chunk.count > 1, recalibragens < Self.recalibragensMaximas else {
                    throw ErroDaNuvemPrivada.contextoExcedido(tokens: tokens, limite: limite)
                }
                recalibragens += 1
                aprender(com: tokens, de: mensagens, em: &orcamento)
            }
        }

        let consolidado = parciais.enumerated()
            .map { "## Parte \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
        let reducao = PromptsDoResumo.reducao(parciais: consolidado, idiomaDeSaida: idiomaDeSaida)
        let resposta = try await gerador.resumoEstruturado(reducao)
        aprender(com: resposta.tokensDeEntrada, de: reducao, em: &orcamento)
        return resposta.conteudo
    }

    /// Os próximos trechos que cabem num chunk, pela estimativa. Nunca vazio:
    /// um trecho sozinho maior que o chunk vai inteiro, e a janela decide.
    static func proximoChunk(
        de trechos: ArraySlice<Trecho>,
        orcamento: OrcamentoDeTokens
    ) -> ArraySlice<Trecho> {
        var tokens = 0
        var fim = trechos.startIndex
        for indice in trechos.indices {
            let custo = orcamento.estimar(QwenEngine.formatar([trechos[indice]])) + 1
            if tokens + custo > tokensPorChunk, fim > trechos.startIndex { break }
            tokens += custo
            fim = indice + 1
        }
        return trechos[trechos.startIndex..<fim]
    }

    private func aprender(
        com tokens: Int?,
        de mensagens: PromptsDoResumo.Mensagens,
        em orcamento: inout OrcamentoDeTokens
    ) {
        guard let tokens else { return }
        orcamento.calibrar(texto: mensagens.texto, tokensReais: tokens)
        calibragem.gravar(orcamento.bytesPorToken)
    }

    private static func geradorDoSistema() -> (any GeradorDaNuvemPrivada)? {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(macOS 27.0, *), NuvemPrivada.disponibilidade == .disponivel else { return nil }
        return GeradorPCC()
#else
        return nil
#endif
    }
}

#if compiler(>=6.4) && canImport(FoundationModels)

// MARK: - Formato da ata

/// O `Resumo` como a geração guiada da Apple o produz. As regras de conteúdo
/// de cada campo estão em `GramaticaDoResumo.descricaoDoFormato`, que vai no
/// prompt; aqui fica só a forma.
@Generable
struct ResumoGerado {
    @Guide(description: "Nome claro e direto do encontro, sem prefixos como \"Ata:\"")
    var titulo: String
    @Guide(description: "Resumo completo da reunião em 4 a 6 frases")
    var visaoGeral: String
    @Guide(description: "Assuntos discutidos")
    var temas: [TemaGerado]
    @Guide(description: "No máximo 3 falas marcantes copiadas literalmente da transcrição")
    var citacoes: [CitacaoGerada]
    @Guide(description: "Todos os compromissos, tarefas e ações mencionados")
    var proximosPassos: [PassoGerado]

    var comoResumo: Resumo {
        Resumo(
            titulo: titulo,
            visaoGeral: visaoGeral,
            temas: temas.map { Tema(titulo: $0.titulo, detalhe: $0.detalhe) },
            citacoes: citacoes.map {
                Citacao(texto: $0.texto, speaker: $0.speaker.semNuloEscrito, start: $0.start)
            },
            proximosPassos: proximosPassos.map {
                ProximoPasso(descricao: $0.descricao, responsavel: $0.responsavel.semNuloEscrito)
            }
        )
    }
}

@Generable
struct TemaGerado {
    @Guide(description: "Assunto objetivo e curto")
    var titulo: String
    @Guide(description: "Uma frase de no máximo 30 palavras com a conclusão ou decisão principal")
    var detalhe: String
}

@Generable
struct CitacaoGerada {
    @Guide(description: "A fala, palavra por palavra")
    var texto: String
    @Guide(description: "Quem falou, como aparece na transcrição")
    var speaker: String?
    @Guide(description: "Instante da fala, em segundos")
    var start: Double?
}

@Generable
struct PassoGerado {
    var descricao: String
    @Guide(description: "Dono da tarefa, quando a transcrição disser")
    var responsavel: String?
}

private extension Optional where Wrapped == String {
    /// O prompt compartilhado com o Qwen pede `"null"` para o que não se
    /// sabe; com campos opcionais de verdade, um modelo ainda pode escrever a
    /// palavra. Na tela ela viraria um responsável chamado "null".
    var semNuloEscrito: String? {
        guard let texto = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !texto.isEmpty, texto.lowercased() != "null"
        else { return nil }
        return texto
    }
}

// MARK: - Modelo de servidor

@available(macOS 27.0, *)
struct GeradorPCC: GeradorDaNuvemPrivada {
    private static let logger = Logger(subsystem: "PapagaioCore", category: "NuvemPrivada")

    func resumoEstruturado(
        _ mensagens: PromptsDoResumo.Mensagens
    ) async throws -> RespostaDaNuvem<Resumo> {
        try await TradutorDeErrosDaNuvem.executando {
            var opcoes = GenerationOptions()
            opcoes.maximumResponseTokens = NuvemPrivadaEngine.tokensDeSaida
            let resposta = try await Self.sessao(mensagens).respond(
                to: mensagens.usuario,
                generating: ResumoGerado.self,
                options: opcoes,
                contextOptions: ContextOptions(includeSchemaInPrompt: true)
            )
            Self.registrar(resposta.usage, de: "ata")
            return RespostaDaNuvem(
                resposta.content.comoResumo,
                tokensDeEntrada: resposta.usage.input.totalTokenCount
            )
        }
    }

    func texto(
        _ mensagens: PromptsDoResumo.Mensagens
    ) async throws -> RespostaDaNuvem<String> {
        try await TradutorDeErrosDaNuvem.executando {
            var opcoes = GenerationOptions()
            opcoes.maximumResponseTokens = NuvemPrivadaEngine.tokensDeSaidaParcial
            let resposta = try await Self.sessao(mensagens).respond(
                to: mensagens.usuario,
                options: opcoes,
                contextOptions: ContextOptions()
            )
            Self.registrar(resposta.usage, de: "parte")
            return RespostaDaNuvem(
                resposta.content,
                tokensDeEntrada: resposta.usage.input.totalTokenCount
            )
        }
    }

    /// Sessão nova por requisição: nada do pedido anterior ocupa a janela.
    private static func sessao(_ mensagens: PromptsDoResumo.Mensagens) -> LanguageModelSession {
        LanguageModelSession(
            model: ModeloDeServidor.compartilhado,
            instructions: mensagens.sistema
        )
    }

    private static func registrar(_ uso: LanguageModelSession.Usage, de etapa: String) {
        logger.info(
            "Nuvem privada (\(etapa, privacy: .public)): \(uso.input.totalTokenCount) tokens de entrada, \(uso.output.totalTokenCount) de saída"
        )
    }
}

/// Converte os erros da Apple nos casos que o Ōmu sabe tratar.
@available(macOS 27.0, *)
enum TradutorDeErrosDaNuvem {
    static func executando<T>(_ operacao: () async throws -> T) async throws -> T {
        do {
            return try await operacao()
        } catch {
            throw traduzir(error)
        }
    }

    static func traduzir(_ erro: any Error) -> any Error {
        switch erro {
        case is CancellationError, is ErroDaNuvemPrivada:
            return erro
        case let erro as PrivateCloudComputeLanguageModel.Error:
            switch erro {
            case .networkFailure:
                return ErroDaNuvemPrivada.semConexao
            case let .quotaLimitReached(detalhe):
                return ErroDaNuvemPrivada.cotaEsgotada(reiniciaEm: detalhe.resetDate)
            case .serviceUnavailable:
                return ErroDaNuvemPrivada.servicoIndisponivel
            @unknown default:
                return ErroDaNuvemPrivada.falha(erro.localizedDescription)
            }
        case let erro as LanguageModelError:
            switch erro {
            case let .contextSizeExceeded(detalhe):
                return ErroDaNuvemPrivada.contextoExcedido(
                    tokens: detalhe.tokenCount, limite: detalhe.contextSize
                )
            case .rateLimited, .timeout:
                return ErroDaNuvemPrivada.servicoIndisponivel
            case .guardrailViolation, .refusal:
                return ErroDaNuvemPrivada.conteudoRecusado
            case .unsupportedLanguageOrLocale:
                return ErroDaNuvemPrivada.idiomaNaoSuportado
            default:
                return ErroDaNuvemPrivada.falha(erro.localizedDescription)
            }
        case let erro as URLError where erro.code != .cancelled:
            return ErroDaNuvemPrivada.semConexao
        default:
            return ErroDaNuvemPrivada.falha(erro.localizedDescription)
        }
    }
}

#endif
