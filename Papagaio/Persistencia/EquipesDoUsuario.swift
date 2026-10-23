import Foundation
import PapagaioCore

enum EquipesDoUsuario {
    private static let chave = "equipesDoUsuario"
    /// Onde fica a lista que não pôde ser lida, para não se perder.
    private static let chaveDaQuarentena = "equipesDoUsuario.ilegivel"

    /// Vazio é resposta legítima — quem nunca criou equipe não tem nenhuma.
    static func carregar(em defaults: UserDefaults = .standard) -> [EquipeDisponivel] {
        guard let dados = defaults.data(forKey: chave) else { return [] }
        guard let equipes = try? JSONDecoder().decode([EquipeDisponivel].self, from: dados) else {
            // "Sem dados" e "dados ilegíveis" não são a mesma coisa: devolver
            // vazio aqui fazia o próximo `salvar` gravar a lista vazia por
            // cima das equipes. O original fica guardado à parte.
            if defaults.data(forKey: chaveDaQuarentena) == nil {
                defaults.set(dados, forKey: chaveDaQuarentena)
            }
            return []
        }
        return equipes
    }

    static func salvar(_ equipes: [EquipeDisponivel], em defaults: UserDefaults = .standard) {
        guard let dados = try? JSONEncoder().encode(equipes) else { return }
        defaults.set(dados, forKey: chave)
    }

    /// Inclui a equipe, ou atualiza a entrada dela.
    ///
    /// - Returns: `false` quando o convite foi recusado por reivindicar a
    ///   identidade de outra equipe (ver `conflita`). Nada é gravado.
    @MainActor
    @discardableResult
    static func incluirOuAtualizar(
        _ equipe: EquipeDisponivel,
        em defaults: UserDefaults = .standard
    ) -> Bool {
        var equipes = carregar(em: defaults)
        guard !conflita(equipe, com: equipes, espacoPessoal: Biblioteca.espacoPessoal(em: defaults)) else {
            return false
        }
        if let indice = equipes.firstIndex(where: { $0.id == equipe.id }) {
            equipes[indice] = equipe
        } else {
            equipes.append(equipe)
        }
        salvar(equipes, em: defaults)
        return true
    }

    /// Um convite não pode tomar o lugar de uma equipe que este Mac já tem.
    ///
    /// O `id` e o `espacoID` vêm do registro da equipe, que quem cria a zona
    /// escreve como quiser. Aceitar um convite com o `id` de uma equipe
    /// existente substituía a entrada dela, e com o `espacoID` de outra (ou
    /// do espaço pessoal) fazia as conversas desse espaço passarem a
    /// sincronizar com a zona de quem mandou o convite.
    static func conflita(
        _ nova: EquipeDisponivel,
        com existentes: [EquipeDisponivel],
        espacoPessoal: EspacoID
    ) -> Bool {
        if let espaco = nova.espacoID.flatMap(UUID.init(uuidString:)), espaco == espacoPessoal.rawValue {
            return true
        }
        return existentes.contains { outra in
            let mesmoEspaco = outra.espacoID != nil
                && outra.espacoID?.lowercased() == nova.espacoID?.lowercased()
            guard outra.id == nova.id || mesmoEspaco else { return false }
            // Mesma zona, do mesmo dono: é a própria equipe sendo atualizada
            // (reentrada com um código novo, por exemplo).
            let mesmaZona = outra.zonaCloudKit == nova.zonaCloudKit
                && outra.donoDaZonaCloudKit == nova.donoDaZonaCloudKit
            // Entrada antiga, que ainda não guardava o dono da zona: o nome
            // da zona basta, desde que as duas estejam no mesmo banco.
            let legadaCompativel = outra.zonaCloudKit == nova.zonaCloudKit
                && outra.donoDaZonaCloudKit == nil
                && outra.bancoCloudKit == nova.bancoCloudKit
            // Equipe que ainda nem foi publicada: não há zona a conflitar.
            let aindaLocal = outra.zonaCloudKit == nil && outra.id == nova.id
            return !(mesmaZona || legadaCompativel || aindaLocal)
        }
    }

    static func remover(em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave)
    }
}
