import Foundation

/// Onde os arquivos vivem sob App Sandbox.
///
/// Tudo dentro do container do app. Nunca `~/Documents`, nunca caminho
/// absoluto fora do container — e no modelo guarda-se apenas o **caminho
/// relativo**, porque o UUID do container muda entre instalações.
///
/// É um valor com a raiz injetada, não um `enum` de estáticos: teste que
/// gravasse na Application Support de verdade sujaria a máquina de quem roda.
public struct Armazenamento: Sendable {
    public static let pastaRaiz = "Papagaio"
    public static let pastaGravacoes = "Gravacoes"
    public static let pastaModelos = "Models"

    /// Raiz absoluta: `<Application Support>/Papagaio` em produção,
    /// um diretório temporário nos testes.
    public let raiz: URL

    public init(raiz: URL) {
        self.raiz = raiz
    }

    /// `~/Library/Application Support/Papagaio` — dentro do container sob sandbox.
    public static func padrao(_ fm: FileManager = .default) throws -> Armazenamento {
        let suporte = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Armazenamento(raiz: suporte.appendingPathComponent(pastaRaiz, isDirectory: true))
    }

    /// Caminho relativo de uma gravação: `Gravacoes/<uuid>`.
    /// É isto que vai para `Arquivo.pastaRelativa`.
    public static func caminhoRelativo(id: UUID) -> String {
        "\(pastaGravacoes)/\(id.uuidString)"
    }

    /// Cria e devolve a pasta absoluta de uma gravação.
    @discardableResult
    public func criarPastaDaGravacao(id: UUID, _ fm: FileManager = .default) throws -> URL {
        let pasta = pastaDaGravacao(id: id)
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        return pasta
    }

    public func pastaDaGravacao(id: UUID) -> URL {
        raiz.appendingPathComponent(Self.caminhoRelativo(id: id), isDirectory: true)
    }

    /// Onde os pesos GGUF ficam: `<raiz>/Models`.
    ///
    /// Dentro do container, e não numa pasta do usuário: sob sandbox o app não
    /// alcança `~/Documents` sem que o usuário escolha a pasta. É também o que
    /// o downloader do Passo 3 preenche.
    public var pastaDeModelos: URL {
        raiz.appendingPathComponent(Self.pastaModelos, isDirectory: true)
    }

    /// Resolve um caminho relativo guardado no modelo para a URL absoluta de agora.
    public func resolver(relativo: String) -> URL {
        raiz.appendingPathComponent(relativo, isDirectory: true)
    }

    /// Como `resolver`, mas recusa o que não pode ser uma pasta dentro da
    /// raiz: string vazia (que resolveria para a própria raiz — é a marca de
    /// conversa sem áudio), caminho absoluto e componentes `.`/`..`.
    ///
    /// Quem vai **escrever, copiar ou apagar** a partir de um caminho
    /// persistido usa esta variante: um `pastaRelativa` vazio ou corrompido
    /// não pode virar operação de disco sobre a biblioteca inteira.
    public func resolverSeguro(relativo: String) throws -> URL {
        let partes = relativo.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativo.isEmpty,
              !relativo.hasPrefix("/"),
              !partes.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ErroArmazenamento.caminhoRelativoInvalido(relativo)
        }

        let base = raiz.standardizedFileURL.pathComponents
        let resolvido = resolver(relativo: relativo).standardizedFileURL
        let componentes = resolvido.pathComponents
        guard componentes.count > base.count,
              Array(componentes.prefix(base.count)) == base
        else {
            throw ErroArmazenamento.caminhoRelativoInvalido(relativo)
        }
        return resolvido
    }

    /// Cria a pasta da gravação e devolve a URL absoluta de um arquivo de
    /// áudio canônico dentro dela (`microfone.wav`, `sistema.caf`, …).
    @discardableResult
    public func criarArquivoDeAudio(
        id: UUID,
        nome: String,
        _ fm: FileManager = .default
    ) throws -> URL {
        let pasta = try criarPastaDaGravacao(id: id, fm)
        return pasta.appendingPathComponent(nome)
    }

    /// URL absoluta de um arquivo importado dentro da pasta da gravação, com
    /// a extensão do arquivo de origem preservada — copiamos do jeito que
    /// veio, sem re-encodar (mesma escolha do Eko).
    @discardableResult
    public func criarArquivoImportado(
        id: UUID,
        extensao: String,
        _ fm: FileManager = .default
    ) throws -> URL {
        let pasta = try criarPastaDaGravacao(id: id, fm)
        return pasta.appendingPathComponent("\(Self.Nome.prefixoImportado).\(extensao)")
    }

    /// Remove uma pasta de gravação somente quando o caminho persistido tem o
    /// formato canônico `Gravacoes/<algo>`, sem componentes de travessia. A
    /// exclusão definitiva não deve aceitar uma string arbitrária do banco
    /// como alvo no filesystem.
    ///
    /// Antes exigia que o segundo componente fosse um `UUID` — mas
    /// `renomearParaTitulo` passou a trocar esse componente pelo título da
    /// conversa, então a validação virou "é um nome de pasta só, sem `/`
    /// nem `..`", que é o que de fato importa para a exclusão ser segura.
    public func removerGravacao(
        relativa: String,
        _ fm: FileManager = .default
    ) throws {
        let partes = relativa.split(separator: "/", omittingEmptySubsequences: false)
        guard partes.count == 2,
              partes[0] == Substring(Self.pastaGravacoes),
              !partes[1].isEmpty,
              partes[1] != ".",
              partes[1] != ".."
        else {
            throw ErroArmazenamento.caminhoDeGravacaoInvalido(relativa)
        }

        let pasta = resolver(relativo: relativa)
        guard fm.fileExists(atPath: pasta.path) else { return }
        try fm.removeItem(at: pasta)
    }

    /// Move a pasta da gravação para um nome derivado do título da conversa,
    /// em vez do UUID cru — quem clica em "Mostrar no Finder" deve
    /// reconhecer a pasta pelo nome da entrevista, não por um identificador
    /// opaco.
    ///
    /// Silenciosa por natureza: se a pasta de origem não existir, se o
    /// caminho recebido não seguir o formato `Gravacoes/<algo>`, ou se a
    /// movimentação falhar, devolve `relativoAtual` sem alterações — quem
    /// chama decide o que fazer (normalmente: nada, o nome antigo continua
    /// válido). Duas conversas com o mesmo título ganham um sufixo numérico,
    /// como já acontece com anexos de mídia duplicados.
    public func renomearParaTitulo(
        relativoAtual: String,
        titulo: String,
        _ fm: FileManager = .default
    ) -> String {
        guard relativoAtual.hasPrefix("\(Self.pastaGravacoes)/") else { return relativoAtual }
        let origem = resolver(relativo: relativoAtual)
        guard fm.fileExists(atPath: origem.path) else { return relativoAtual }

        let base = Self.nomeDePastaSeguro(titulo)
        var candidato = base
        var indice = 2
        while true {
            let relativoCandidato = "\(Self.pastaGravacoes)/\(candidato)"
            if relativoCandidato == relativoAtual { return relativoAtual }
            if !fm.fileExists(atPath: raiz.appendingPathComponent(relativoCandidato).path) {
                let novoRelativo = relativoCandidato
                let destino = raiz.appendingPathComponent(novoRelativo, isDirectory: true)
                do {
                    try fm.moveItem(at: origem, to: destino)
                    return novoRelativo
                } catch {
                    return relativoAtual
                }
            }
            candidato = "\(base) \(indice)"
            indice += 1
        }
    }

    /// Troca só os caracteres que o Finder não aceita (`/`, `:`, `\`),
    /// preservando acentos e espaços — a pasta deve continuar legível como
    /// o título da entrevista.
    private static func nomeDePastaSeguro(_ texto: String) -> String {
        let ilegal = CharacterSet(charactersIn: "/:\\")
        var nome = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        nome = nome.components(separatedBy: ilegal).joined(separator: "-")
        if nome.count > 80 { nome = String(nome.prefix(80)) }
        return nome.isEmpty ? "Conversa" : nome
    }

    /// Remove todas as gravações deste container, inclusive pastas órfãs de
    /// uma captura que tenha sido interrompida antes de entrar no SwiftData.
    /// Os modelos ficam em `Models` e deliberadamente não fazem parte desta
    /// operação: são recursos do app, não dados da conta.
    public func removerTodasAsGravacoes(_ fm: FileManager = .default) throws {
        let gravacoes = raiz.appendingPathComponent(Self.pastaGravacoes, isDirectory: true)
        guard fm.fileExists(atPath: gravacoes.path) else { return }
        try fm.removeItem(at: gravacoes)
    }

    /// Nomes canônicos dentro da pasta de uma gravação.
    ///
    /// O backend de áudio agora segue o Eko: sem mixagem prévia em disco.
    /// Microfone e sistema são arquivos separados, e a reprodução junta os
    /// dois **só no playback** — tocar uma mixagem AAC mono de 16 kHz foi o
    /// que deixou o áudio "abafado" e a reprodução quebrada. Os nomes antigos
    /// continuam aqui como leitura de gravações legadas.
    public enum Nome {
        /// WAV do microfone gravado pelo `AVAudioRecorder` — 16 kHz mono,
        /// 16 bits. É o canal "eu" e o insumo da transcrição.
        public static let microfone = "microfone.wav"
        /// CAF PCM do áudio do sistema no formato nativo do tap. É o canal
        /// "interlocutor" — ver `SystemAudioTap`.
        public static let sistema = "sistema.caf"
        /// Nome usado pela implementação anterior, mantido apenas para ler
        /// gravações já existentes.
        public static let sistemaM4ALegado = "sistema.m4a"
        /// Prefixo do arquivo importado: está sempre em `gravacao.<extensão>`
        /// porque só o nome canônico permite que a `Biblioteca` resolva o
        /// áudio guardando apenas a pasta relativa no modelo.
        public static let prefixoImportado = "gravacao"
        /// WAV canônico do áudio do sistema — nome legado (pré-Eko).
        public static let wavSistema = "sistema.wav"
        /// PCM canônico legado do microfone, mantido apenas para ler gravações
        /// feitas antes da migração para WAV.
        public static let pcmMicrofone = "microfone.pcm"
        /// PCM canônico legado do áudio do sistema.
        public static let pcmSistema = "sistema.pcm"
        /// Arquivamento legado: mixagem dos dois canais em AAC mono 16 kHz.
        public static let mixagem = "gravacao.m4a"
    }
}

public enum ErroArmazenamento: LocalizedError {
    case caminhoDeGravacaoInvalido(String)
    case caminhoRelativoInvalido(String)

    public var errorDescription: String? {
        switch self {
        case let .caminhoDeGravacaoInvalido(caminho):
            "O caminho da gravação não é seguro para excluir: \(caminho)"
        case let .caminhoRelativoInvalido(caminho):
            "O caminho guardado para esta conversa não aponta para uma pasta da biblioteca: \"\(caminho)\""
        }
    }
}
