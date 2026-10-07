import Foundation
import PapagaioCore

enum FalantePreservadoParaTrecho {
    private static func chave(_ arquivo: ArquivoID) -> String {
        "falantePreservado.\(arquivo.rawValue.uuidString)"
    }

    /// Esquece todos os falantes preservados de uma conversa apagada. Sem
    /// isto, cada conversa excluída deixava um mapa de nomes no Mac.
    static func limpar(_ arquivo: ArquivoID, em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave(arquivo))
    }

    static func definir(_ falante: String?, para trecho: UUID, arquivo: ArquivoID) {
        var mapa = carregar(arquivo: arquivo)
        let k = trecho.uuidString
        if let falante, !falante.isEmpty {
            mapa[k] = falante
        } else {
            mapa.removeValue(forKey: k)
        }
        salvar(mapa, arquivo: arquivo)
    }

    static func obter(para trecho: UUID, arquivo: ArquivoID) -> String? {
        carregar(arquivo: arquivo)[trecho.uuidString]
    }

    static func remover(para trecho: UUID, arquivo: ArquivoID) {
        var mapa = carregar(arquivo: arquivo)
        mapa.removeValue(forKey: trecho.uuidString)
        salvar(mapa, arquivo: arquivo)
    }

    private static func carregar(arquivo: ArquivoID) -> [String: String] {
        guard let dados = UserDefaults.standard.data(forKey: chave(arquivo)),
              let mapa = try? JSONDecoder().decode([String: String].self, from: dados)
        else { return [:] }
        return mapa
    }

    private static func salvar(_ mapa: [String: String], arquivo: ArquivoID) {
        if mapa.isEmpty {
            UserDefaults.standard.removeObject(forKey: chave(arquivo))
        } else if let dados = try? JSONEncoder().encode(mapa) {
            UserDefaults.standard.set(dados, forKey: chave(arquivo))
        }
    }

    static func limpar(arquivo: ArquivoID) {
        UserDefaults.standard.removeObject(forKey: chave(arquivo))
    }
}
