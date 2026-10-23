import AppKit
import Foundation

/// A foto de cada pessoa, guardada pelo **nome**.
///
/// Pelo nome, e não por conversa: quem entrevista as mesmas pessoas em várias
/// sessões escolhe a foto uma vez e ela aparece em todas. É também o que faz a
/// grade ficar reconhecível — o mesmo rosto no mesmo lugar, conversa após
/// conversa.
///
/// A chave é o nome normalizado (sem acento, sem caixa, espaços colapsados)
/// para que "ana silva" e "Ana  Silva" não virem duas pessoas.
enum FotosDePessoas {
    private static let prefixo = "fotoDaPessoa."

    /// Quem muda a cada foto guardada, removida ou renomeada.
    ///
    /// A foto mora fora de qualquer `@State` — é `UserDefaults` lido por nome.
    /// Sem um sinal observável, um avatar em outra parte da árvore de views
    /// (o cartão na grade, por exemplo, enquanto se edita a foto no formulário
    /// de um outro cartão) não tinha motivo para o SwiftUI recalcular o corpo
    /// dele, e continuava mostrando as iniciais até algo não relacionado
    /// forçar um redesenho.
    @MainActor final class Aviso: ObservableObject {
        @Published fileprivate(set) var versao = 0
    }

    @MainActor static let aviso = Aviso()

    @MainActor private static let decodificadas = NSCache<NSString, NSImage>()

    /// Bookmarks já resolvidos, incluindo os ausentes — que é o caso da
    /// maioria das pessoas. Sem isto, cada avatar batia no `UserDefaults` a
    /// cada avaliação de `body`, e há um avatar por participante por cartão.
    @MainActor private static var urlsResolvidas: [String: URL?] = [:]

    static func chave(de nome: String) -> String {
        nome
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    @MainActor
    static func url(de nome: String) -> URL? {
        let chaveCompleta = prefixo + chave(de: nome)
        if let guardada = urlsResolvidas[chaveCompleta] { return guardada }

        guard let dados = UserDefaults.standard.data(forKey: chaveCompleta) else {
            urlsResolvidas[chaveCompleta] = URL?.none
            return nil
        }

        var obsoleto = false
        guard let url = try? URL(
            resolvingBookmarkData: dados,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &obsoleto
        ) else {
            UserDefaults.standard.removeObject(forKey: chaveCompleta)
            urlsResolvidas[chaveCompleta] = URL?.none
            return nil
        }
        if obsoleto { try? definir(url, para: nome) }
        urlsResolvidas[chaveCompleta] = url
        return url
    }

    @MainActor
    static func definir(_ url: URL, para nome: String) throws {
        let dados = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(dados, forKey: prefixo + chave(de: nome))
        urlsResolvidas[prefixo + chave(de: nome)] = nil
        decodificadas.removeObject(forKey: chave(de: nome) as NSString)
        CorDominanteDeImagem.esquecer("pessoa." + chave(de: nome))
        aviso.versao += 1
    }

    @MainActor
    static func remover(de nome: String) {
        UserDefaults.standard.removeObject(forKey: prefixo + chave(de: nome))
        urlsResolvidas[prefixo + chave(de: nome)] = nil
        decodificadas.removeObject(forKey: chave(de: nome) as NSString)
        CorDominanteDeImagem.esquecer("pessoa." + chave(de: nome))
        aviso.versao += 1
    }

    /// Leva a foto de um nome para outro — chamar ao salvar uma edição de
    /// nome, antes de sobrescrever os metadados antigos.
    ///
    /// Sem isto, a foto ficava presa na chave antiga: corrigir um nome
    /// digitado errado ("Joao" → "João Silva") fazia o avatar voltar para as
    /// iniciais, porque a busca passou a procurar por uma chave que nunca
    /// recebeu foto nenhuma. A foto antiga sobrava esquecida no
    /// `UserDefaults`, sem ninguém que a lesse de novo.
    @MainActor
    static func renomear(de nomeAntigo: String, para nomeNovo: String) {
        let chaveAntiga = chave(de: nomeAntigo)
        let chaveNova = chave(de: nomeNovo)
        guard chaveAntiga != chaveNova,
              let dados = UserDefaults.standard.data(forKey: prefixo + chaveAntiga),
              // A foto é guardada por nome e vale em todas as conversas: o
              // destino já ter uma significa que é outra pessoa, e o rosto
              // dela não pode ser trocado por uma edição de ficha.
              UserDefaults.standard.data(forKey: prefixo + chaveNova) == nil
        else { return }

        UserDefaults.standard.set(dados, forKey: prefixo + chaveNova)
        UserDefaults.standard.removeObject(forKey: prefixo + chaveAntiga)
        urlsResolvidas[prefixo + chaveAntiga] = nil
        urlsResolvidas[prefixo + chaveNova] = nil
        if let imagem = decodificadas.object(forKey: chaveAntiga as NSString) {
            decodificadas.setObject(imagem, forKey: chaveNova as NSString)
        }
        decodificadas.removeObject(forKey: chaveAntiga as NSString)
        CorDominanteDeImagem.esquecer("pessoa." + chaveAntiga)
        aviso.versao += 1
    }

    /// Migra as fotos de quem teve o nome editado na ficha.
    @MainActor
    static func migrarAoEditarNomes(de antigos: String, para novos: String) {
        for (antigo, novo) in renomeacoes(de: antigos, para: novos) {
            renomear(de: antigo, para: novo)
        }
    }

    /// As linhas que foram **renomeadas** entre duas versões da lista de
    /// nomes (uma pessoa por linha).
    ///
    /// Comparar posição a posição só faz sentido quando ninguém entrou nem
    /// saiu: ao remover a pessoa do meio, [Ana, Bruno, Carla] → [Ana, Carla]
    /// casava "Bruno" com "Carla" e a foto do Bruno ia parar na Carla. Por
    /// isso só vale quando a quantidade de linhas é a mesma, e a linha
    /// alterada tem de ser um nome que saiu trocado por um nome que entrou —
    /// reordenar a lista não é renomear ninguém.
    static func renomeacoes(de antigos: String, para novos: String) -> [(de: String, para: String)] {
        func linhas(_ texto: String) -> [String] {
            texto
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let antes = linhas(antigos)
        let depois = linhas(novos)
        guard antes.count == depois.count else { return [] }

        let chavesDeAntes = Set(antes.map(chave(de:)))
        let chavesDeDepois = Set(depois.map(chave(de:)))
        return zip(antes, depois).compactMap { antigo, novo in
            let chaveAntiga = chave(de: antigo)
            let chaveNova = chave(de: novo)
            guard chaveAntiga != chaveNova,
                  !chavesDeDepois.contains(chaveAntiga),
                  !chavesDeAntes.contains(chaveNova)
            else { return nil }
            return (de: antigo, para: novo)
        }
    }

    /// Imagem pronta para desenhar, decodificada no máximo uma vez.
    ///
    /// Sem o cache isto rodaria a cada avaliação de body de cada cartão da
    /// grade — leitura de disco por participante, por atualização.
    @MainActor
    static func imagem(de nome: String) -> NSImage? {
        let chaveDoCache = chave(de: nome) as NSString
        if let guardada = decodificadas.object(forKey: chaveDoCache) { return guardada }

        guard let url = url(de: nome) else { return nil }
        let acessou = url.startAccessingSecurityScopedResource()
        defer { if acessou { url.stopAccessingSecurityScopedResource() } }

        guard let original = NSImage(contentsOf: url) else { return nil }
        let imagem = MiniaturaDeImagem.reduzir(original)
        decodificadas.setObject(imagem, forKey: chaveDoCache)
        return imagem
    }

    /// Remove fotos ligadas às pessoas das conversas da conta atual.
    @MainActor
    static func removerTodas(em defaults: UserDefaults = .standard) {
        for chave in defaults.dictionaryRepresentation().keys where chave.hasPrefix(prefixo) {
            defaults.removeObject(forKey: chave)
        }
        urlsResolvidas.removeAll()
        decodificadas.removeAllObjects()
        CorDominanteDeImagem.esquecerTudo()
        aviso.versao += 1
    }

    /// Abre o seletor e guarda a escolha. Devolve `true` quando trocou.
    @MainActor
    @discardableResult
    static func escolherImagem(para nome: String) -> Bool {
        let painel = NSOpenPanel()
        painel.title = "Escolha uma foto para %@".localized(nome)
        painel.prompt = "Usar foto".localized
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = false
        painel.allowedContentTypes = [.image]

        guard painel.runModal() == .OK,
              let url = painel.url,
              url.startAccessingSecurityScopedResource()
        else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        try? definir(url, para: nome)
        return true
    }
}
