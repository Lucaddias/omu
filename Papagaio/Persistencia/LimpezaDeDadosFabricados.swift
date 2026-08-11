import Foundation

/// Apaga, uma única vez, os dados de exemplo que as versões antigas gravavam.
///
/// Até o commit que tirou os mocks, `MembrosDasEquipes.carregar` não apenas
/// inventava as pessoas: ele as **salvava**. As três equipes de exemplo eram
/// persistidas junto assim que a tela de equipe abria. Tirar o código que
/// inventava não desfaz o que já está no disco — por isso esta limpeza existe.
///
/// Ela é cirúrgica de propósito: remove só as chaves cujo conteúdo é
/// reconhecidamente fabricado, e nunca toca em equipe que a pessoa tenha criado.
enum LimpezaDeDadosFabricados {
    private static let chaveDeControle = "limpezaDeDadosFabricados.v1"

    /// IDs das equipes de exemplo. Eram fixos no código, então identificam com
    /// segurança o que era semente e o que é do usuário.
    private static let equipesFabricadas: Set<String> = ["creative-flow", "scribeflow", "design-lab"]

    private static let nomeFabricado = "Alexandre Silva"
    private static let emailFabricado = "alexandre.silva@creativeflow.com"

    static func executarUmaVez(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: chaveDeControle) else { return }
        defaults.set(true, forKey: chaveDeControle)

        // Os membros moram numa chave por equipe. Some junto com a equipe: quem
        // convidou alguém para uma equipe de exemplo convidou para algo que não
        // existia de verdade.
        for id in equipesFabricadas {
            defaults.removeObject(forKey: "membrosDaEquipe.\(id)")
        }

        if let dados = defaults.data(forKey: "equipesDoUsuario"),
           let equipes = try? JSONDecoder().decode([EquipeDisponivel].self, from: dados) {
            let reais = equipes.filter { !equipesFabricadas.contains($0.id) }
            if reais.isEmpty {
                defaults.removeObject(forKey: "equipesDoUsuario")
            } else if reais.count != equipes.count, let novos = try? JSONEncoder().encode(reais) {
                defaults.set(novos, forKey: "equipesDoUsuario")
            }
        }

        if let ativa = defaults.string(forKey: "equipeAtiva"), equipesFabricadas.contains(ativa) {
            defaults.removeObject(forKey: "equipeAtiva")
        }

        // Só apaga o perfil se ele ainda for exatamente o de exemplo — quem
        // editou o nome escreveu algo seu, e isso fica.
        if defaults.string(forKey: "perfil.nome") == nomeFabricado {
            defaults.removeObject(forKey: "perfil.nome")
        }
        if defaults.string(forKey: "perfil.email") == emailFabricado {
            defaults.removeObject(forKey: "perfil.email")
        }
    }
}
