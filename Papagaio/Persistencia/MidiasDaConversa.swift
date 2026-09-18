import AppKit
import Foundation
import PapagaioCore

enum MidiasDaConversa {
    enum Erro: LocalizedError {
        case arquivoForaDaConversa
        case falhaAoReverterCopia

        var errorDescription: String? {
            switch self {
            case .arquivoForaDaConversa:
                "O arquivo não pertence à pasta desta conversa e não foi apagado."
            case .falhaAoReverterCopia:
                "A cópia do anexo não pôde ser registrada e ficou na pasta da conversa para não ser apagada incorretamente."
            }
        }
    }

    private struct Registro: Codable {
        let id: UUID
        let nome: String
        let tamanho: Int64
        let data: Date
        let bookmark: Data
    }

    static func carregar(_ arquivoID: ArquivoID, em defaults: UserDefaults = .standard) -> [AnexoDeMidiaDaConversa] {
        guard let dados = defaults.data(forKey: chave(arquivoID)),
              let registros = try? JSONDecoder().decode([Registro].self, from: dados)
        else { return [] }

        return registros.compactMap { registro in
            var obsoleto = false
            guard let url = try? URL(
                resolvingBookmarkData: registro.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &obsoleto
            ) else { return nil }

            return AnexoDeMidiaDaConversa(
                id: registro.id,
                nome: registro.nome,
                tamanho: registro.tamanho,
                data: registro.data,
                url: url
            )
        }
    }

    static func anexo(para url: URL) throws -> AnexoDeMidiaDaConversa {
        let valores = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return AnexoDeMidiaDaConversa(
            id: UUID(),
            nome: url.lastPathComponent,
            tamanho: Int64(valores.fileSize ?? 0),
            data: valores.contentModificationDate ?? Date(),
            url: url
        )
    }

    /// Constrói novos bookmarks para os anexos que já foram copiados junto
    /// com a pasta da conversa. Bookmarks são ligados ao caminho original;
    /// reutilizá-los faria a cópia apontar para os arquivos da conversa mãe.
    static func anexosCopiados(
        de arquivoID: ArquivoID,
        da pastaOriginal: URL,
        para pastaDaCopia: URL
    ) throws -> [AnexoDeMidiaDaConversa] {
        let origem = pastaOriginal.standardizedFileURL.resolvingSymlinksInPath()
        let componentesDaOrigem = origem.pathComponents

        return try carregar(arquivoID).map { anexo in
            let urlOriginal = anexo.url.standardizedFileURL.resolvingSymlinksInPath()
            let componentesDoAnexo = urlOriginal.pathComponents
            guard componentesDoAnexo.count > componentesDaOrigem.count,
                  Array(componentesDoAnexo.prefix(componentesDaOrigem.count)) == componentesDaOrigem
            else { throw Erro.arquivoForaDaConversa }

            let destino = componentesDoAnexo
                .dropFirst(componentesDaOrigem.count)
                .reduce(pastaDaCopia) { parcial, componente in
                    parcial.appendingPathComponent(componente)
                }
            return try Self.anexo(para: destino)
        }
    }

    /// Copia o anexo para dentro de uma subpasta nomeada com o título da
    /// conversa — não "Midia" genérico — para que quem abrir "Mostrar no
    /// Finder" reconheça a pasta de cara, sem cair num UUID sem sentido.
    static func copiar(_ origem: URL, para pastaDaConversa: URL, tituloDaConversa: String) throws -> URL {
        let pastaDeMidia = pastaDaConversa.appendingPathComponent(
            NomeDeArquivoSeguro.gerar(de: tituloDaConversa),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: pastaDeMidia, withIntermediateDirectories: true)

        let nomeUnico = nomeDisponivel(para: origem.lastPathComponent, em: pastaDeMidia)
        let destino = pastaDeMidia.appendingPathComponent(nomeUnico)
        try FileManager.default.copyItem(at: origem, to: destino)
        return destino
    }

    /// Copia e só mantém o arquivo se o estado que vai referenciá-lo também
    /// for gravado. A cópia mora dentro do container do app, portanto uma
    /// falha posterior não pode deixá-la invisível e ocupando disco.
    @discardableResult
    static func copiar(
        _ origem: URL,
        para pastaDaConversa: URL,
        tituloDaConversa: String,
        aposCopiar: (URL) throws -> Void
    ) throws -> URL {
        let destino = try copiar(origem, para: pastaDaConversa, tituloDaConversa: tituloDaConversa)
        do {
            try aposCopiar(destino)
            return destino
        } catch {
            do {
                try FileManager.default.removeItem(at: destino)
            } catch {
                // Se até a limpeza falhar, a cópia continua fisicamente
                // presente. Não escondemos esse estado como se a importação
                // tivesse sido totalmente revertida.
                throw Erro.falhaAoReverterCopia
            }
            throw error
        }
    }

    static func apagarArquivoSalvo(_ anexo: AnexoDeMidiaDaConversa, pastaDaConversa: URL) throws {
        // Comparar prefixos de texto aceitaria `/Conversa-antiga` como filha
        // de `/Conversa`. Componentes canônicos também impedem que um symlink
        // dentro da pasta aponte para um arquivo externo.
        let destino = anexo.url.standardizedFileURL.resolvingSymlinksInPath()
        let pasta = pastaDaConversa.standardizedFileURL.resolvingSymlinksInPath()
        let componentesDaPasta = pasta.pathComponents
        let componentesDoDestino = destino.pathComponents
        guard componentesDoDestino.count > componentesDaPasta.count,
              Array(componentesDoDestino.prefix(componentesDaPasta.count)) == componentesDaPasta
        else { throw Erro.arquivoForaDaConversa }

        if FileManager.default.fileExists(atPath: anexo.url.path) {
            try FileManager.default.removeItem(at: anexo.url)
        }
    }

    static func salvar(_ anexos: [AnexoDeMidiaDaConversa], para arquivoID: ArquivoID, em defaults: UserDefaults = .standard) throws {
        let registros = try anexos.map { anexo in
            let bookmark = try anexo.url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return Registro(
                id: anexo.id,
                nome: anexo.nome,
                tamanho: anexo.tamanho,
                data: anexo.data,
                bookmark: bookmark
            )
        }
        let dados = try JSONEncoder().encode(registros)
        defaults.set(dados, forKey: chave(arquivoID))
    }

    static func removerTodas(em defaults: UserDefaults = .standard) {
        for chave in defaults.dictionaryRepresentation().keys where chave.hasPrefix("midiasDaConversa.") {
            defaults.removeObject(forKey: chave)
        }
    }

    static func remover(_ arquivoID: ArquivoID, em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave(arquivoID))
    }

    private static func chave(_ arquivoID: ArquivoID) -> String {
        "midiasDaConversa.\(arquivoID.rawValue.uuidString)"
    }

    private static func nomeDisponivel(para nomeOriginal: String, em pasta: URL) -> String {
        let original = nomeOriginal.isEmpty ? "arquivo" : nomeOriginal
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var candidato = original
        var indice = 2

        while FileManager.default.fileExists(atPath: pasta.appendingPathComponent(candidato).path) {
            candidato = ext.isEmpty ? "\(base) \(indice)" : "\(base) \(indice).\(ext)"
            indice += 1
        }

        return candidato
    }
}
