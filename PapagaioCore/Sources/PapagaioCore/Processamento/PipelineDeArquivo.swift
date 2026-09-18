import Foundation

/// Leva uma gravação de áudio bruto até `Arquivo` salvo: transcreve, agrupa em
/// trechos, resume e persiste.
///
/// Isto existia só dentro do `main.swift` da CLI — era por isso que gravar pelo
/// app não produzia transcrição nem resumo. Aqui vira código de biblioteca,
/// testável com motores falsos, e a interface só chama.
///
/// Recebe closures em vez dos protocolos `TranscriptionEngine`/
/// `SummarizationEngine` por dois motivos: a transcrição precisa do parâmetro
/// `speaker`, que não está no contrato do Passo 1, e a alternância de carga
/// entre os dois modelos é responsabilidade de `MotoresLocais`.
public struct PipelineDeArquivo: Sendable {
    public enum Fase: Sendable, Equatable {
        case transcrevendo
        case diarizando
        case resolvendoFalantes
        case traduzindo
        case resumindo
        case salvando

        public var descricao: String {
            switch self {
            case .transcrevendo: "transcrevendo…"
            case .diarizando: "distinguindo falantes…"
            case .resolvendoFalantes: "resolvendo falantes pelo contexto…"
            case .traduzindo: "traduzindo…"
            case .resumindo: "resumindo…"
            case .salvando: "salvando…"
            }
        }
    }

    public typealias Transcrever = @Sendable (URL, String?) async throws -> [Trecho]
    public typealias Resumir = @Sendable ([Trecho]) async throws -> Resumo
    /// Variante que permite ao runtime pedir ao resumidor o idioma de saída.
    /// Mantemos `Resumir` para preservar os testes e os chamadores legados.
    public typealias ResumirNoIdioma = @Sendable ([Trecho], IdiomaDeProcessamento?) async throws -> Resumo
    /// Traduz a transcrição sem mudar a sua linha do tempo. A implementação
    /// local deve remover palavras do ASR, pois elas deixam de corresponder ao
    /// texto traduzido mostrado na interface.
    public typealias Traduzir = @Sendable ([Trecho], IdiomaDeProcessamento) async throws -> [Trecho]
    /// Diariza **um canal** de áudio e devolve quem falou quando.
    public typealias Diarizar = @Sendable (URL) async throws -> [SegmentoDeFalante]

    /// Resolve pelo contexto as falas que a diarização deixou sem falante.
    ///
    /// É o passo que carrega o modelo de linguagem (o mesmo do resumo): recebe
    /// o arquivo com as palavras marcadas e devolve o arquivo com os rótulos
    /// que o modelo conseguiu decidir — `nil` para pular.
    public typealias ResolverFalantes = @Sendable (Arquivo) async throws -> Arquivo

    private let armazenamento: Armazenamento
    private let transcrever: Transcrever
    private let resumir: Resumir
    private let resumirNoIdioma: ResumirNoIdioma?
    private let traducaoAutomatica: ConfiguracaoDeTraducaoAutomatica
    private let traduzir: Traduzir?
    private let diarizar: Diarizar?
    private let resolverFalantes: ResolverFalantes?
    private let repositorio: any ArquivoRepository
    private let idTranscricao: String
    private let idResumo: String

    public init(
        armazenamento: Armazenamento,
        repositorio: any ArquivoRepository,
        idTranscricao: String,
        idResumo: String,
        transcrever: @escaping Transcrever,
        resumir: @escaping Resumir,
        resumirNoIdioma: ResumirNoIdioma? = nil,
        traducaoAutomatica: ConfiguracaoDeTraducaoAutomatica = .init(
            habilitada: false,
            idiomaPadrao: .portugues
        ),
        traduzir: Traduzir? = nil,
        diarizar: Diarizar? = nil,
        resolverFalantes: ResolverFalantes? = nil
    ) {
        self.armazenamento = armazenamento
        self.repositorio = repositorio
        self.idTranscricao = idTranscricao
        self.idResumo = idResumo
        self.transcrever = transcrever
        self.resumir = resumir
        self.resumirNoIdioma = resumirNoIdioma
        self.traducaoAutomatica = traducaoAutomatica
        self.traduzir = traduzir
        self.diarizar = diarizar
        self.resolverFalantes = resolverFalantes
    }

    /// Processa e salva. Devolve o `Arquivo` atualizado.
    ///
    /// Salva **duas vezes**: uma com a transcrição pronta e outra com o resumo.
    /// O resumo é a parte lenta (dezenas de segundos), e perder a transcrição
    /// porque o Qwen falhou seria jogar fora a parte cara que já deu certo.
    @discardableResult
    public func processar(
        _ arquivo: Arquivo,
        aoProgredir: @Sendable (Fase) -> Void = { _ in }
    ) async throws -> Arquivo {
        var atualizado = arquivo

        // Pontos de desistência entre as fases.
        //
        // O whisper e o Qwen são blocos síncronos e longos: uma vez dentro
        // deles, nada os interrompe. Verificar aqui é o que permite ao app
        // largar o trabalho assim que a fase corrente termina, em vez de
        // seguir resumindo uma conversa que a pessoa acabou de apagar.
        try Task.checkCancellation()

        aoProgredir(.transcrevendo)
        atualizado.trechos = try await transcrever(arquivo)
        atualizado.engineTranscricao = idTranscricao

        try Task.checkCancellation()

        // A diarização é decorativa e **nunca** decide o destino da gravação:
        // falha de modelo, de áudio ou de alinhamento não sobe — o `try?` por
        // canal vira "sem falante acústico", que é o estado de sempre antes
        // desta feature. Transcrição e resumo não podem ser jogados fora por
        // causa da diarização.
        aoProgredir(.diarizando)
        atualizado = await aplicarDiarizacao(atualizado)

        // Resolução contextual das falas que ficaram sem falante. Carrega o
        // Qwen — o mesmo do resumo; a closure é do app (via MotoresLocais) e
        // mantém o contexto residente para a fase de resumo reusar.
        // Decorativa como a diarização: uma falha aqui não joga fora a
        // transcrição que já deu certo — as falas ficam "Voz desconhecida".
        if let resolverFalantes {
            try Task.checkCancellation()
            aoProgredir(.resolvendoFalantes)
            atualizado = (try? await resolverFalantes(atualizado)) ?? atualizado
        }

        try Task.checkCancellation()

        // A transcrição não é forçada ao idioma do sistema: o Whisper a
        // reconhece automaticamente. Só depois de detectar uma divergência é
        // que a preferência explícita pode pedir uma tradução local.
        let idiomaDetectado = DetectorDeIdiomaDaTranscricao.detectar(em: atualizado.trechos)
        let deveTraduzir = DetectorDeIdiomaDaTranscricao.deveTraduzir(
            idiomaDetectado: idiomaDetectado,
            configuracao: traducaoAutomatica
        )
        var traduziuComSucesso = false
        if deveTraduzir, let traduzir {
            aoProgredir(.traduzindo)
            atualizado.trechos = try await traduzir(
                atualizado.trechos,
                traducaoAutomatica.idiomaPadrao
            )
            traduziuComSucesso = true
        }

        try Task.checkCancellation()
        aoProgredir(.salvando)
        try await repositorio.salvar(atualizado)

        // Sem fala reconhecida não há o que resumir — e mandar transcrição
        // vazia para o Qwen produz um resumo inventado.
        guard !atualizado.trechos.isEmpty else { return atualizado }

        try Task.checkCancellation()

        aoProgredir(.resumindo)
        let idiomaDoResumo: IdiomaDeProcessamento? =
            traducaoAutomatica.habilitada && (
                traduziuComSucesso || DetectorDeIdiomaDaTranscricao.correspondeAoIdiomaPadrao(
                    idiomaDetectado: idiomaDetectado,
                    configuracao: traducaoAutomatica
                )
            )
            ? traducaoAutomatica.idiomaPadrao
            : nil
        if let resumirNoIdioma {
            atualizado.resumo = try await resumirNoIdioma(atualizado.trechos, idiomaDoResumo)
        } else {
            atualizado.resumo = try await resumir(atualizado.trechos)
        }
        atualizado.engineResumo = idResumo

        try Task.checkCancellation()
        aoProgredir(.salvando)
        try await repositorio.salvar(atualizado)
        return atualizado
    }

    /// Aplica **só** a diarização sobre uma transcrição já salva, sem
    /// re-transcrever nem resumir — o caminho leve para arquivos gravados
    /// antes da diarização existir: as palavras já têm timestamp, falta
    /// atribuir o falante.
    ///
    /// Nunca lança: mesma filosofia da diarização decorativa do `processar`.
    /// Sem modelos, sem fala ou sem palavras com timestamp, o arquivo volta
    /// como estava.
    ///
    /// A costura de vozes iguais entra sempre (sem custo). A resolução pelo
    /// contexto (Qwen) entra quando a closure `resolverFalantes` foi provida —
    /// é o caminho dos arquivos antigos no app: só então as falas entre
    /// vozes diferentes ganham falante.
    @discardableResult
    public func diarizarExistente(_ arquivo: Arquivo) async -> Arquivo {
        let diarizado = await aplicarDiarizacao(arquivo)
        guard let resolverFalantes else { return diarizado }
        return (try? await resolverFalantes(diarizado)) ?? diarizado
    }

    // MARK: - Escolha do insumo

    /// Transcreve pelo caminho que preserva o falante.
    ///
    /// Os WAVs por canal são o único insumo que separa "eu" de "interlocutor":
    /// a atribuição vem do canal de origem, não de diarização (skill
    /// `papagaio-speaker-attribution`). O `.m4a` já é a mixagem dos dois, então
    /// só serve quando os `.pcm` não existem — arquivo importado, ou gravação
    /// de uma versão anterior.
    private func transcrever(_ arquivo: Arquivo) async throws -> [Trecho] {
        let canais = canaisSeparados(do: arquivo)
        let temMicrofone = canais.microfone != nil
        let temSistema = canais.sistema != nil

        if temMicrofone {
            // Aplica AEC quando o usuário NÃO estava com fones e há áudio do
            // sistema — o eco do alto-falante vaza para o microfone e prejudica
            // a transcrição. Com fones, o eco não existe e o AEC é desnecessário.
            var urlMicrofone = canais.microfone!
            if arquivo.usavaFones == false, temSistema {
                let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
                urlMicrofone = try await aplicarAEC(
                    microfoneURL: canais.microfone!,
                    sistemaURL: canais.sistema!,
                    pasta: pasta
                )
            }
            let doMicrofone = try await transcrever(urlMicrofone, Speaker.eu)
            // O canal do sistema é acessório: se ele estiver corrompido — tap
            // que morreu no meio, arquivo só com cabeçalho — a conversa ainda
            // tem o microfone, que é o principal. Deixar o erro subir aqui
            // jogava fora uma gravação inteira por causa do canal secundário.
            var doSistema: [Trecho] = []
            if temSistema {
                doSistema = (try? await transcrever(canais.sistema!, Speaker.interlocutor)) ?? []
            }
            return Segmentacao.mesclarCanais(microfone: doMicrofone, sistema: doSistema)
        }

        let mixagem = Self.arquivoDeCanalUnico(em: armazenamento.resolver(relativo: arquivo.pastaRelativa))
        guard FileManager.default.fileExists(atPath: mixagem.path) else {
            throw ErroCaptura.arquivoInvalido("não há áudio em \(arquivo.pastaRelativa)")
        }
        // Canal único (mixagem legada ou importado): não dá para saber quem
        // falou. `nil` é honesto; inventar "eu" atribuiria as falas do
        // interlocutor ao usuário.
        return Segmentacao.agrupar(try await transcrever(mixagem, nil))
    }

    /// Diariza os canais separados e casa os falantes acústicos com as palavras.
    ///
    /// Nunca lança. Com canais separados, cada canal é diarizado no seu próprio
    /// áudio (a mixagem misturaria as vozes e o rótulo enganaria). **Sem canais
    /// separados** — importado ou gravação legada, que só têm a mixagem — a
    /// mixagem é o único insumo: diarizá-la perde o canal de origem (que já
    /// não existe no arquivo), mas separa as vozes acústicas, que é o que a
    /// interface de falas mostra. Canais sem conteúdo ou sem fala passam
    /// direto — palavras sem `falanteAcustico` são o estado normal.
    private func aplicarDiarizacao(_ arquivo: Arquivo) async -> Arquivo {
        guard let diarizar else { return arquivo }
        let canais = canaisSeparados(do: arquivo)

        let microfone: [SegmentoDeFalante]
        if let url = canais.microfone {
            microfone = (try? await diarizar(url)) ?? []
        } else {
            microfone = []
        }
        let sistema: [SegmentoDeFalante]
        if let url = canais.sistema {
            sistema = (try? await diarizar(url)) ?? []
        } else {
            sistema = []
        }
        let mixagem: [SegmentoDeFalante]
        if canais.microfone == nil, canais.sistema == nil {
            let url = Self.arquivoDeCanalUnico(em: armazenamento.resolver(relativo: arquivo.pastaRelativa))
            mixagem = (try? await diarizar(url)) ?? []
        } else {
            mixagem = []
        }

        guard !microfone.isEmpty || !sistema.isEmpty || !mixagem.isEmpty else { return arquivo }

        let trechos = arquivo.trechos.map { trecho -> Trecho in
            guard !trecho.palavras.isEmpty else { return trecho }
            let segmentosBrutos: [SegmentoDeFalante]
            let canalPrefixo: String?
            if let speaker = trecho.speaker {
                segmentosBrutos = speaker == Speaker.eu ? microfone : sistema
                canalPrefixo = speaker
            } else {
                // Sem canal de origem não há de onde escolher: as vozes da
                // mixagem são a única atribuição possível.
                segmentosBrutos = mixagem
                canalPrefixo = nil
            }
            guard !segmentosBrutos.isEmpty else { return trecho }
            // Namespacing: prefixa o falanteId com o canal de origem para que
            // labels independentes (S1 no microfone vs S1 no sistema) nunca
            // colidam. O microfone é sempre "eu"; o sistema é sempre
            // "interlocutor"; mixagem (canal único) fica sem prefixo.
            let segmentos = segmentosBrutos.map { seg in
                if let prefixo = canalPrefixo {
                    return SegmentoDeFalante(
                        falanteId: "\(prefixo)-\(seg.falanteId)",
                        inicio: seg.inicio,
                        fim: seg.fim
                    )
                }
                return seg
            }
            return trecho.comPalavras(
                AlinhamentoDeFalantes.atribuir(palavras: trecho.palavras, a: segmentos)
            )
        }
        var diarizado = arquivo
        diarizado.trechos = trechos
        // Costura de vozes iguais: fala duvidosa entre dois pedaços da MESMA
        // voz recebe o rótulo dela sem custo de modelo — é a leitura acústica
        // mais provável, e sem ela o "Voz desconhecida" aparecia entre dois
        // trechos da mesma voz. Sempre, em qualquer caminho: quem ficar entre
        // falantes diferentes segue para a resolução contextual (Qwen), que é
        // opcional e mora na closure `resolverFalantes`.
        return ResolvedorDeFalantes.costurarVozesIguais(diarizado)
    }

    /// Os caminhos dos canais separados com conteúdo, na convenção nova
    /// (`microfone.wav` + `sistema.m4a`) com fallback nos nomes legados.
    private func canaisSeparados(do arquivo: Arquivo) -> (microfone: URL?, sistema: URL?) {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        // Canais separados (nova convenção): `microfone.wav` + `sistema.m4a`.
        // Os nomes legados ficam na cadeia — wav do sistema, pcm, mixagem —
        // para a biblioteca existente continuar transcrevendo até sair.
        let microfone = Self.primeiroComConteudo(pasta, [
            Armazenamento.Nome.microfone,
            Armazenamento.Nome.pcmMicrofone,
        ])
        let sistema = Self.primeiroComConteudo(pasta, [
            Armazenamento.Nome.sistema,
            Armazenamento.Nome.sistemaM4ALegado,
            Armazenamento.Nome.wavSistema,
            Armazenamento.Nome.pcmSistema,
        ])
        return (
            Self.temConteudo(microfone) ? microfone : nil,
            Self.temConteudo(sistema) ? sistema : nil
        )
    }

    private static func temConteudo(_ url: URL) -> Bool {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
              let tamanho = atributos[.size] as? Int64
        else { return false }
        return tamanho > 0
    }

    /// Primeiro candidato que existe com conteúdo — a nova convenção primeiro,
    /// os legados como fallback natural. Sem nenhum, devolve o **primeiro**
    /// candidato: o `temConteudo` de quem chama transforma a ausência em `nil`.
    /// (Antes devolvia o último — enganoso: parecia um fallback com conteúdo.)
    private static func primeiroComConteudo(_ pasta: URL, _ candidatos: [String]) -> URL {
        for nome in candidatos {
            let url = pasta.appendingPathComponent(nome)
            if temConteudo(url) { return url }
        }
        return pasta.appendingPathComponent(candidatos.first ?? "")
    }

    /// O arquivo único quando não há canais separados: a mixagem legada
    /// (`gravacao.m4a`) ou o importado copiado como veio (`gravacao.<ext>`).
    private static func arquivoDeCanalUnico(em pasta: URL) -> URL {
        let mixagem = pasta.appendingPathComponent(Armazenamento.Nome.mixagem)
        if temConteudo(mixagem) { return mixagem }
        let conteudo = (try? FileManager.default.contentsOfDirectory(
            at: pasta, includingPropertiesForKeys: nil
        )) ?? []
        if let importado = conteudo.first(where: {
            $0.lastPathComponent.hasPrefix(Armazenamento.Nome.prefixoImportado + ".")
        }) {
            return importado
        }
        return mixagem
    }

    /// Aplica cancelamento de eco acústico no sinal do microfone usando o
    /// sinal do sistema como referência. Devolve a URL de um arquivo PCM
    /// temporário com o microfone limpo.
    private func aplicarAEC(
        microfoneURL: URL,
        sistemaURL: URL,
        pasta: URL
    ) async throws -> URL {
        let micAmostras = try await DecodificadorDeAudio.amostras(de: microfoneURL)
        let sisAmostras = try await DecodificadorDeAudio.amostras(de: sistemaURL)

        let cancelador = CanceladorDeEco(tamanhoBloco: 512, comprimentoFiltro: 4096)
        // Mantém a duração do microfone mesmo quando o tap termina antes.
        // O bloco final é completado só para o filtro; o padding não vai ao áudio.
        let limpa = cancelador.processar(microfone: micAmostras, sistema: sisAmostras)
        try Task.checkCancellation()

        let urlLimpa = pasta.appendingPathComponent("microfone_aec.pcm")
        let dados = limpa.withUnsafeBytes { Data($0) }
        try dados.write(to: urlLimpa, options: .atomic)
        return urlLimpa
    }
}
