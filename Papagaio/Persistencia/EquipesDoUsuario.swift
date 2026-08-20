import Foundation

enum EquipesDoUsuario {
    private static let chave = "equipesDoUsuario"

    /// Vazio é resposta legítima — quem nunca criou equipe não tem nenhuma.
    static func carregar() -> [EquipeDisponivel] {
        guard let dados = UserDefaults.standard.data(forKey: chave),
              let equipes = try? JSONDecoder().decode([EquipeDisponivel].self, from: dados)
        else { return [] }
        return equipes
    }

    static func salvar(_ equipes: [EquipeDisponivel]) {
        guard let dados = try? JSONEncoder().encode(equipes) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }

    static func incluirOuAtualizar(_ equipe: EquipeDisponivel) {
        var equipes = carregar()
        if let indice = equipes.firstIndex(where: { $0.id == equipe.id }) {
            equipes[indice] = equipe
        } else {
            equipes.append(equipe)
        }
        salvar(equipes)
    }

    static func remover() {
        UserDefaults.standard.removeObject(forKey: chave)
    }
}
