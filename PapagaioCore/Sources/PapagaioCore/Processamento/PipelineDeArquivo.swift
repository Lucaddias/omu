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
        case resumindo
        case salvando

        public var descricao: String {
            switch self {
            case .transcrevendo: "transcrevendo…"
            case .resumindo: "resumindo…"
            case .salvando: "salvando…"
            }
        }
    }

    public typealias Transcrever = @Sendable (URL, String?) async throws -> [Trecho]
    public typealias Resumir = @Sendable ([Trecho]) async throws -> Resumo

    private let armazenamento: Armazenamento
    private let transcrever: Transcrever
    private let resumir: Resumir
    private let repositorio: any ArquivoRepository
    private let idTranscricao: String
    private let idResumo: String

    public init(
        armazenamento: Armazenamento,
        repositorio: any ArquivoRepository,
        idTranscricao: String,
        idResumo: String,
        transcrever: @escaping Transcrever,
        resumir: @escaping Resumir
    ) {
        self.armazenamento = armazenamento
        self.repositorio = repositorio
        self.idTranscricao = idTranscricao
        self.idResumo = idResumo
        self.transcrever = transcrever
        self.resumir = resumir
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

        aoProgredir(.transcrevendo)
        atualizado.trechos = try await transcrever(arquivo)
        atualizado.engineTranscricao = idTranscricao

        aoProgredir(.salvando)
        try await repositorio.salvar(atualizado)

        // Sem fala reconhecida não há o que resumir — e mandar transcrição
        // vazia para o Qwen produz um resumo inventado.
        guard !atualizado.trechos.isEmpty else { return atualizado }

        aoProgredir(.resumindo)
        atualizado.resumo = try await resumir(atualizado.trechos)
        atualizado.engineResumo = idResumo

        aoProgredir(.salvando)
        try await repositorio.salvar(atualizado)
        return atualizado
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
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        // Canais separados (nova convenção): `microfone.wav` + `sistema.m4a`.
        // Os nomes legados ficam na cadeia — wav do sistema, pcm, mixagem —
        // para a biblioteca existente continuar transcrevendo até sair.
        let microfone = Self.primeiroComConteudo(pasta, [
            Armazenamento.Nome.microfone,
            Armazenamento.Nome.wavMicrofone,
            Armazenamento.Nome.pcmMicrofone,
        ])
        let sistema = Self.primeiroComConteudo(pasta, [
            Armazenamento.Nome.sistema,
            Armazenamento.Nome.wavSistema,
            Armazenamento.Nome.pcmSistema,
        ])

        let temMicrofone = Self.temConteudo(microfone)
        let temSistema = Self.temConteudo(sistema)

        if temMicrofone {
            let doMicrofone = try await transcrever(microfone, Speaker.eu)
            // O canal do sistema é acessório: se ele estiver corrompido — tap
            // que morreu no meio, arquivo só com cabeçalho — a conversa ainda
            // tem o microfone, que é o principal. Deixar o erro subir aqui
            // jogava fora uma gravação inteira por causa do canal secundário.
            var doSistema: [Trecho] = []
            if temSistema {
                doSistema = (try? await transcrever(sistema, Speaker.interlocutor)) ?? []
            }
            return Segmentacao.mesclarCanais(microfone: doMicrofone, sistema: doSistema)
        }

        let mixagem = Self.arquivoDeCanalUnico(em: pasta)
        guard FileManager.default.fileExists(atPath: mixagem.path) else {
            throw ErroCaptura.arquivoInvalido("não há áudio em \(arquivo.pastaRelativa)")
        }
        // Canal único (mixagem legada ou importado): não dá para saber quem
        // falou. `nil` é honesto; inventar "eu" atribuiria as falas do
        // interlocutor ao usuário.
        return Segmentacao.agrupar(try await transcrever(mixagem, nil))
    }

    private static func temConteudo(_ url: URL) -> Bool {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
              let tamanho = atributos[.size] as? Int64
        else { return false }
        return tamanho > 0
    }

    /// Primeiro candidato que existe com conteúdo — a nova convenção primeiro,
    /// os legados como fallback natural.
    private static func primeiroComConteudo(_ pasta: URL, _ candidatos: [String]) -> URL {
        for nome in candidatos {
            let url = pasta.appendingPathComponent(nome)
            if temConteudo(url) { return url }
        }
        return pasta.appendingPathComponent(candidatos.last ?? "")
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
}
