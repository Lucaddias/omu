import AppKit
import Foundation
import PapagaioCore

enum PreferenciasVisuaisDoArquivo {
    /// `UserDefaults` não publica mudanças para as views que já estão na tela.
    /// Este aviso mantém cartão, ficha e detalhe sincronizados assim que a
    /// entrevista é salva — sem depender de abrir o editor novamente.
    static let metadadosDidChange = Notification.Name("PreferenciasVisuaisDoArquivo.metadadosDidChange")
    private static let prefixoFavorito = "arquivoFavorito."
    private static let prefixoPasta = "arquivoPasta."
    private static let prefixoCapa = "arquivoCapa."
    private static let prefixoMetadados = "arquivoMetadados."
    private static let prefixoNomesDeVoz = "arquivoNomesDeVoz."

    /// Avisa a aba de Transcrição para reler os nomes das vozes — mesmo
    /// motivo de `metadadosDidChange`: `UserDefaults` não empurra a mudança
    /// sozinho para quem já está na tela.
    static let nomesDeVozDidChange = Notification.Name("PreferenciasVisuaisDoArquivo.nomesDeVozDidChange")

    /// Capas já resolvidas e decodificadas.
    ///
    /// Sem isto, `NSImage(contentsOf:)` rodava **a cada avaliação de body** do
    /// cartão, e a resolução do bookmark (que toca o filesystem) rodava junto.
    /// Com a fila ativa a biblioteca recompõe a cada mudança de fase, então
    /// isso era leitura de disco por cartão por atualização.
    ///
    /// `@MainActor` aqui e nas funções de capa porque `NSCache` não é
    /// `Sendable`. Confinar ao ator principal é honesto e não custa nada: tudo
    /// que mexe em capa é chamado de dentro de views.
    @MainActor private static let capasDecodificadas = NSCache<NSString, NSImage>()

    static func favorito(_ id: ArquivoID) -> Bool {
        UserDefaults.standard.bool(forKey: prefixoFavorito + id.rawValue.uuidString)
    }

    static func definirFavorito(_ favorito: Bool, para id: ArquivoID) {
        let chave = prefixoFavorito + id.rawValue.uuidString
        if favorito {
            UserDefaults.standard.set(true, forKey: chave)
        } else {
            UserDefaults.standard.removeObject(forKey: chave)
        }
    }

    static func pasta(_ id: ArquivoID) -> String? {
        UserDefaults.standard.string(forKey: prefixoPasta + id.rawValue.uuidString)
    }

    static func definirPasta(_ pasta: String?, para id: ArquivoID) {
        let chave = prefixoPasta + id.rawValue.uuidString
        if let pasta {
            criarPasta(pasta)
            UserDefaults.standard.set(pasta, forKey: chave)
        } else {
            UserDefaults.standard.removeObject(forKey: chave)
        }
    }

    static func criarPasta(_ pasta: String) {
        let nome = pasta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nome.isEmpty else { return }
        let chave = "pastasDaBiblioteca"
        var pastas = UserDefaults.standard.stringArray(forKey: chave) ?? []
        guard !pastas.contains(where: { $0.localizedCaseInsensitiveCompare(nome) == .orderedSame }) else { return }
        pastas.append(nome)
        pastas.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(pastas, forKey: chave)
        AparenciaDasPastas.registrarCriacao(de: nome)
    }

    /// Tira a pasta da lista e o rótulo de quem o carregava, guardando o
    /// retrato na lixeira de pastas.
    ///
    /// Esta função cuida só do rótulo. Quem apaga uma pasta pela interface
    /// passa por `PastasDaBiblioteca.apagar`, que **antes** move as conversas
    /// dela para a lixeira — é isso que a confirmação da tela anuncia. Limpar
    /// o rótulo evita conversas apontando para uma pasta que não existe mais,
    /// invisíveis em "Pastas" e marcadas com um nome fantasma no cartão.
    @MainActor
    static func apagarPasta(_ pasta: String) {
        let padroes = UserDefaults.standard

        // Antes de apagar qualquer coisa: guarda quem estava dentro e como a
        // pasta era. É esse retrato que a lixeira devolve depois.
        var conversas: [UUID] = []
        for (chave, valor) in padroes.dictionaryRepresentation()
        where chave.hasPrefix(prefixoPasta) && (valor as? String) == pasta {
            if let id = UUID(uuidString: String(chave.dropFirst(prefixoPasta.count))) {
                conversas.append(id)
            }
            padroes.removeObject(forKey: chave)
        }

        LixeiraDePastas.guardar(
            PastaNaLixeira(
                nome: pasta,
                conversas: conversas,
                aparencia: AparenciaDasPastas.estado(de: pasta)
            )
        )

        var pastas = padroes.stringArray(forKey: "pastasDaBiblioteca") ?? []
        pastas.removeAll { $0.localizedCaseInsensitiveCompare(pasta) == .orderedSame }
        padroes.set(pastas, forKey: "pastasDaBiblioteca")

        AparenciaDasPastas.esquecer(pasta)
    }

    /// Renomeia a pasta e leva junto tudo o que aponta para o nome antigo.
    ///
    /// O nome **é** a identidade da pasta aqui — não há id. Trocar só a entrada
    /// da lista deixaria as conversas rotuladas com o nome velho, órfãs de uma
    /// pasta que não existe mais, e a aparência presa ao nome anterior.
    @MainActor
    static func renomearPasta(_ antigo: String, para novo: String) {
        let limpo = novo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, limpo != antigo else { return }

        let padroes = UserDefaults.standard
        var pastas = padroes.stringArray(forKey: "pastasDaBiblioteca") ?? []
        // Já existe uma pasta com o nome novo: renomear as fundiria em silêncio.
        guard !pastas.contains(where: { $0.localizedCaseInsensitiveCompare(limpo) == .orderedSame })
        else { return }

        pastas.removeAll { $0 == antigo }
        pastas.append(limpo)
        pastas.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        padroes.set(pastas, forKey: "pastasDaBiblioteca")

        for (chave, valor) in padroes.dictionaryRepresentation()
        where chave.hasPrefix(prefixoPasta) && (valor as? String) == antigo {
            padroes.set(limpo, forKey: chave)
        }

        AparenciaDasPastas.renomear(de: antigo, para: limpo)
    }

    static func pastas() -> [String] {
        UserDefaults.standard.stringArray(forKey: "pastasDaBiblioteca") ?? []
    }

    @MainActor
    static func capa(_ id: ArquivoID) -> URL? {
        let chave = prefixoCapa + id.rawValue.uuidString
        guard let dados = UserDefaults.standard.data(forKey: chave) else { return nil }
        var obsoleto = false
        guard let url = try? URL(
            resolvingBookmarkData: dados,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &obsoleto
        ) else {
            UserDefaults.standard.removeObject(forKey: chave)
            return nil
        }
        if obsoleto { try? definirCapa(url, para: id) }
        return url
    }

    @MainActor
    static func definirCapa(_ url: URL, para id: ArquivoID) throws {
        let dados = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(dados, forKey: prefixoCapa + id.rawValue.uuidString)
        capasDecodificadas.removeObject(forKey: id.rawValue.uuidString as NSString)
    }

    /// Imagem de capa pronta para desenhar, decodificada no máximo uma vez.
    @MainActor
    static func imagemDaCapa(_ id: ArquivoID) -> NSImage? {
        let chave = id.rawValue.uuidString as NSString
        if let guardada = capasDecodificadas.object(forKey: chave) { return guardada }

        guard let url = capa(id) else { return nil }
        let acessou = url.startAccessingSecurityScopedResource()
        defer { if acessou { url.stopAccessingSecurityScopedResource() } }

        guard let imagem = NSImage(contentsOf: url) else { return nil }
        capasDecodificadas.setObject(imagem, forKey: chave)
        return imagem
    }

    static func metadados(_ id: ArquivoID) -> MetadadosVisuaisDoArquivo {
        guard let dados = UserDefaults.standard.data(forKey: prefixoMetadados + id.rawValue.uuidString),
              let metadados = try? JSONDecoder().decode(MetadadosVisuaisDoArquivo.self, from: dados)
        else { return MetadadosVisuaisDoArquivo() }
        return metadados
    }

    static func definirMetadados(_ metadados: MetadadosVisuaisDoArquivo, para id: ArquivoID) {
        guard let dados = try? JSONEncoder().encode(metadados) else { return }
        UserDefaults.standard.set(dados, forKey: prefixoMetadados + id.rawValue.uuidString)
        NotificationCenter.default.post(name: metadadosDidChange, object: id.rawValue)
    }

    /// Nomes escolhidos para as vozes da diarização deste arquivo, chaveados
    /// pelo rótulo acústico bruto ("S1", "S2"...) que vem do diarizador — não
    /// por "Voz 1", que é só como ele aparece quando ninguém ainda deu nome.
    ///
    /// Fica em `UserDefaults`, e não em `Trecho.palavras[].falanteAcustico`
    /// (SwiftData): o rótulo acústico é um dado de domínio, comparado
    /// internamente para saber "quem é quem" dentro da gravação — sobrescrever
    /// com o nome digitado mudaria esse contrato e reescreveria todos os
    /// trechos do arquivo a cada renomeação. Isto aqui é só a etiqueta de
    /// exibição, no mesmo espírito de `favorito`/`pasta`/`metadados`.
    static func nomesDeVoz(_ id: ArquivoID) -> [String: String] {
        guard let dados = UserDefaults.standard.data(forKey: prefixoNomesDeVoz + id.rawValue.uuidString),
              let mapa = try? JSONDecoder().decode([String: String].self, from: dados)
        else { return [:] }
        return mapa
    }

    static func definirNomesDeVoz(_ mapa: [String: String], para id: ArquivoID) {
        let chave = prefixoNomesDeVoz + id.rawValue.uuidString
        guard let dados = try? JSONEncoder().encode(mapa) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
        NotificationCenter.default.post(name: nomesDeVozDidChange, object: id.rawValue)
    }

    static func copiar(de origem: ArquivoID, para destino: ArquivoID) {
        definirFavorito(favorito(origem), para: destino)
        definirPasta(pasta(origem), para: destino)

        let chaveNomesDeVozOrigem = prefixoNomesDeVoz + origem.rawValue.uuidString
        let chaveNomesDeVozDestino = prefixoNomesDeVoz + destino.rawValue.uuidString
        if let dados = UserDefaults.standard.data(forKey: chaveNomesDeVozOrigem) {
            UserDefaults.standard.set(dados, forKey: chaveNomesDeVozDestino)
        } else {
            UserDefaults.standard.removeObject(forKey: chaveNomesDeVozDestino)
        }

        let chaveOrigem = prefixoCapa + origem.rawValue.uuidString
        let chaveDestino = prefixoCapa + destino.rawValue.uuidString
        if let dados = UserDefaults.standard.data(forKey: chaveOrigem) {
            UserDefaults.standard.set(dados, forKey: chaveDestino)
        } else {
            UserDefaults.standard.removeObject(forKey: chaveDestino)
        }

        let chaveMetadadosOrigem = prefixoMetadados + origem.rawValue.uuidString
        let chaveMetadadosDestino = prefixoMetadados + destino.rawValue.uuidString
        if let dados = UserDefaults.standard.data(forKey: chaveMetadadosOrigem) {
            UserDefaults.standard.set(dados, forKey: chaveMetadadosDestino)
        } else {
            UserDefaults.standard.removeObject(forKey: chaveMetadadosDestino)
        }
    }

    /// Esquece tudo que pertence a um arquivo só: favorito, pasta, capa,
    /// metadados e nomes das vozes.
    @MainActor
    static func remover(_ id: ArquivoID, em defaults: UserDefaults = .standard) {
        let sufixo = id.rawValue.uuidString
        defaults.removeObject(forKey: prefixoFavorito + sufixo)
        defaults.removeObject(forKey: prefixoPasta + sufixo)
        defaults.removeObject(forKey: prefixoCapa + sufixo)
        defaults.removeObject(forKey: prefixoMetadados + sufixo)
        defaults.removeObject(forKey: prefixoNomesDeVoz + sufixo)
        capasDecodificadas.removeObject(forKey: sufixo as NSString)
    }

    @MainActor
    static func removerTodas(em defaults: UserDefaults = .standard) {
        let prefixos = [prefixoFavorito, prefixoPasta, prefixoCapa, prefixoMetadados, prefixoNomesDeVoz]
        for chave in defaults.dictionaryRepresentation().keys where prefixos.contains(where: chave.hasPrefix) {
            defaults.removeObject(forKey: chave)
        }
        defaults.removeObject(forKey: "pastasDaBiblioteca")
        capasDecodificadas.removeAllObjects()
    }
}
