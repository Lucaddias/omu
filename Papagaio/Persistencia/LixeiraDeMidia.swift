import AppKit
import Foundation
import PapagaioCore

enum LixeiraDeMidia {
    enum Erro: LocalizedError {
        case caminhoForaDasGravacoes
        case falhaAoEsvaziar(Int)
        case falhaAoReverterMovimento

        var errorDescription: String? {
            switch self {
            case .caminhoForaDasGravacoes:
                "O anexo não está dentro da pasta de gravações e não foi alterado.".localized
            case let .falhaAoEsvaziar(quantidade):
                quantidade == 1
                    ? "Um anexo não pôde ser apagado e continua na lixeira.".localized
                    : "%d anexos não puderam ser apagados e continuam na lixeira.".localized(quantidade)
            case .falhaAoReverterMovimento:
                "O anexo foi movido para a lixeira, mas a lista da conversa não pôde ser atualizada. Ele continua na lixeira para não ser perdido.".localized
            }
        }
    }

    static func itens(em defaults: UserDefaults = .standard) -> [MidiaNaLixeira] {
        guard let dados = defaults.data(forKey: chave),
              let itens = try? JSONDecoder().decode([MidiaNaLixeira].self, from: dados)
        else { return [] }
        return itens.sorted { $0.apagadoEm > $1.apagadoEm }
    }

    /// Move o arquivo para a subpasta de lixeira da conversa e registra o item.
    static func mover(
        url: URL,
        nome: String,
        tamanho: Int64,
        tipo: String,
        daGravacao: Bool,
        arquivoID: ArquivoID,
        conversaTitulo: String,
        pastaDaConversa: URL,
        em defaults: UserDefaults = .standard,
        aposMover: () throws -> Void = {}
    ) throws {
        try validarOrigem(url, naPastaDaConversa: pastaDaConversa)
        let pasta = pastaDaConversa.appendingPathComponent(
            "\(NomeDeArquivoSeguro.gerar(de: conversaTitulo)) (excluídos)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)

        // Prefixo com UUID: dois "gravacao.m4a" apagados em momentos
        // diferentes não podem se sobrescrever dentro da lixeira.
        let identificador = UUID()
        let destino = pasta.appendingPathComponent("\(identificador.uuidString)-\(nome)")
        try FileManager.default.moveItem(at: url, to: destino)

        let item = MidiaNaLixeira(
            id: identificador,
            arquivoID: arquivoID,
            conversaTitulo: conversaTitulo,
            nome: nome,
            tamanho: tamanho,
            tipo: tipo,
            daGravacao: daGravacao,
            caminhoOriginal: url.path,
            caminhoNaLixeira: destino.path
        )
        var atuais = itens(em: defaults)
        atuais.append(item)
        salvar(atuais, em: defaults)

        do {
            try aposMover()
        } catch {
            // A conversa ainda guarda o bookmark para o caminho de origem.
            // Se a persistência dessa lista falhar, devolver o arquivo evita
            // que ela fique apontando para um caminho que não existe.
            do {
                try FileManager.default.moveItem(at: destino, to: url)
                descartarRegistro(item, em: defaults)
            } catch {
                // A reversão também pode falhar (por exemplo, se outro
                // processo ocupou o nome original). Nesse caso o registro na
                // lixeira permanece como caminho recuperável.
                throw Erro.falhaAoReverterMovimento
            }
            throw error
        }
    }

    /// Devolve o arquivo ao lugar e ao **nome** de origem.
    ///
    /// O nome importa: o app procura o áudio por nome exato
    /// (`microfone.wav`, `sistema.caf`, `gravacao.<ext>`). Na lixeira o arquivo
    /// ganha um prefixo com UUID para dois homônimos não se sobrescreverem, e
    /// é aqui que esse prefixo sai. Restaurar por fora, arrastando no Finder,
    /// deixaria o prefixo e o player não acharia nada.
    @discardableResult
    static func restaurar(
        _ item: MidiaNaLixeira,
        em defaults: UserDefaults = .standard,
        armazenamento: Armazenamento? = nil
    ) -> Bool {
        let origem = URL(fileURLWithPath: item.caminhoNaLixeira)
        let destino = URL(fileURLWithPath: item.caminhoOriginal)

        guard let armazenamento = try? armazenamento ?? Armazenamento.padrao(),
              (try? validarCaminhos(do: item, armazenamento: armazenamento)) != nil
        else { return false }

        guard FileManager.default.fileExists(atPath: origem.path) else {
            descartarRegistro(item, em: defaults)
            return false
        }

        // O mesmo nome pode pertencer a outro arquivo adicionado depois da
        // remoção. Restaurar não autoriza apagar nenhuma das duas cópias.
        guard !FileManager.default.fileExists(atPath: destino.path) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: destino.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: origem, to: destino)
            do {
                try registrarAnexoRestaurado(item, em: destino, defaults: defaults)
            } catch {
                // O arquivo voltou para a conversa, mas o bookmark não
                // pôde ser salvo. Reverte o move para a lixeira, que é o
                // único estado em que o item segue recuperável.
                try? FileManager.default.moveItem(at: destino, to: origem)
                throw error
            }
        } catch {
            return false
        }

        descartarRegistro(item, em: defaults)
        return true
    }

    /// Reabre no Finder a pasta onde o arquivo está — para quem quiser ver
    /// onde as coisas moram sem caçar dentro do container do app.
    static func revelarNoFinder(_ item: MidiaNaLixeira) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.caminhoNaLixeira)])
        #endif
    }

    /// Apaga o arquivo antes de descartar o registro. Se o filesystem recusar
    /// a operação, o cartão permanece na lixeira para permitir nova tentativa.
    static func remover(
        _ item: MidiaNaLixeira,
        em defaults: UserDefaults = .standard,
        armazenamento: Armazenamento? = nil
    ) throws {
        let armazenamento = try armazenamento ?? Armazenamento.padrao()
        try apagarArquivo(do: item, armazenamento: armazenamento)
        descartarRegistro(item, em: defaults)
    }

    @discardableResult
    static func restaurarTudo() -> Bool {
        var restaurouTudo = true
        for item in itens() where !restaurar(item) {
            restaurouTudo = false
        }
        return restaurouTudo
    }

    /// Tenta todos os itens, mas preserva os registros cujos arquivos não
    /// puderam ser removidos. Assim uma falha não vira sucesso falso nem
    /// deixa lixo inacessível no disco.
    static func esvaziar(
        em defaults: UserDefaults = .standard,
        armazenamento: Armazenamento? = nil
    ) throws {
        let armazenamento = try armazenamento ?? Armazenamento.padrao()
        var falhas: [MidiaNaLixeira] = []
        for item in itens(em: defaults) {
            do {
                try apagarArquivo(do: item, armazenamento: armazenamento)
            } catch {
                falhas.append(item)
            }
        }
        salvar(falhas, em: defaults)
        if !falhas.isEmpty { throw Erro.falhaAoEsvaziar(falhas.count) }
    }

    /// A biblioteca já removeu a pasta de gravações inteira. Aqui descartamos
    /// só os metadados, sem seguir caminhos absolutos fora do container.
    static func limparRegistros(em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave)
    }

    /// Descarta referências a mídias de uma conversa cuja pasta já foi
    /// removida pela exclusão definitiva.
    static func removerRegistros(
        do arquivoID: ArquivoID,
        em defaults: UserDefaults = .standard
    ) {
        guard let dados = defaults.data(forKey: chave),
              let atuais = try? JSONDecoder().decode([MidiaNaLixeira].self, from: dados),
              let novos = try? JSONEncoder().encode(atuais.filter { $0.arquivoID != arquivoID })
        else { return }
        defaults.set(novos, forKey: chave)
    }

    private static func descartarRegistro(
        _ item: MidiaNaLixeira,
        em defaults: UserDefaults
    ) {
        salvar(itens(em: defaults).filter { $0.id != item.id }, em: defaults)
    }

    private static func apagarArquivo(
        do item: MidiaNaLixeira,
        armazenamento: Armazenamento,
        _ fm: FileManager = .default
    ) throws {
        let caminho = try validarCaminhos(do: item, armazenamento: armazenamento)
        guard fm.fileExists(atPath: caminho.path) else { return }
        try fm.removeItem(at: caminho)
    }

    /// A lista de anexos vem de bookmarks persistidos. Antes de mover, ela não
    /// pode conceder a um bookmark legado/corrompido poder de retirar um
    /// arquivo de fora da conversa.
    private static func validarOrigem(
        _ origem: URL,
        naPastaDaConversa pastaDaConversa: URL
    ) throws {
        let origemCanonica = origem.standardizedFileURL.resolvingSymlinksInPath()
        let pastaCanonica = pastaDaConversa.standardizedFileURL.resolvingSymlinksInPath()
        let componentesDaPasta = pastaCanonica.pathComponents
        let componentesDaOrigem = origemCanonica.pathComponents
        guard componentesDaOrigem.count > componentesDaPasta.count,
              Array(componentesDaOrigem.prefix(componentesDaPasta.count)) == componentesDaPasta
        else { throw Erro.caminhoForaDasGravacoes }
    }

    /// Áudio canônico da gravação é descoberto diretamente na pasta da
    /// conversa. Anexos, por outro lado, existem na interface apenas quando
    /// seu bookmark está em `MidiasDaConversa`; restaurar só o arquivo os
    /// deixaria invisíveis no próximo carregamento.
    private static func registrarAnexoRestaurado(
        _ item: MidiaNaLixeira,
        em destino: URL,
        defaults: UserDefaults
    ) throws {
        guard !item.daGravacao else { return }
        let anexo = try MidiasDaConversa.anexo(para: destino)
        var anexos = MidiasDaConversa.carregar(item.arquivoID, em: defaults)
        guard !anexos.contains(where: {
            $0.url.standardizedFileURL == destino.standardizedFileURL
        }) else { return }
        anexos.append(anexo)
        try MidiasDaConversa.salvar(anexos, para: item.arquivoID, em: defaults)
    }

    /// Os dois caminhos vêm de UserDefaults e não podem ganhar autoridade
    /// para mover ou apagar algo fora de `Gravacoes/<conversa>`. A comparação
    /// por componentes canônicos também bloqueia prefixos irmãos e symlinks.
    private static func validarCaminhos(
        do item: MidiaNaLixeira,
        armazenamento: Armazenamento
    ) throws -> URL {
        let gravacoes = armazenamento.raiz
            .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let lixeira = URL(fileURLWithPath: item.caminhoNaLixeira)
            .standardizedFileURL.resolvingSymlinksInPath()
        let original = URL(fileURLWithPath: item.caminhoOriginal)
            .standardizedFileURL.resolvingSymlinksInPath()
        let pastaDaConversa = lixeira.deletingLastPathComponent().deletingLastPathComponent()
        let pastaDaLixeira = lixeira.deletingLastPathComponent()

        let componentesDasGravacoes = gravacoes.pathComponents
        let componentesDaConversa = pastaDaConversa.pathComponents
        let componentesDaPastaDaLixeira = pastaDaLixeira.pathComponents
        let componentesDaLixeira = lixeira.pathComponents
        let componentesDoOriginal = original.pathComponents
        guard componentesDaConversa.count == componentesDasGravacoes.count + 1,
              Array(componentesDaConversa.prefix(componentesDasGravacoes.count)) == componentesDasGravacoes,
              componentesDaLixeira.count > componentesDaConversa.count,
              Array(componentesDaLixeira.prefix(componentesDaConversa.count)) == componentesDaConversa,
              componentesDoOriginal.count > componentesDaConversa.count,
              Array(componentesDoOriginal.prefix(componentesDaConversa.count)) == componentesDaConversa,
              // O destino restaurado pode viver em qualquer lugar legítimo da
              // conversa, mas nunca dentro da própria pasta de lixeira.
              // Um registro corrompido não pode tratar um arquivo ainda
              // excluído como destino legítimo de restauração.
              !componentesDoOriginal.starts(with: componentesDaPastaDaLixeira)
        else { throw Erro.caminhoForaDasGravacoes }

        return lixeira
    }

    private static func salvar(
        _ itens: [MidiaNaLixeira],
        em defaults: UserDefaults = .standard
    ) {
        guard let dados = try? JSONEncoder().encode(itens) else { return }
        defaults.set(dados, forKey: chave)
    }

    private static let chave = "midiaNaLixeira"
}
