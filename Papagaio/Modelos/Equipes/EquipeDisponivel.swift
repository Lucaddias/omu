import Foundation

/// Uma equipe do usuário.
///
/// Não existe equipe padrão: um app recém-instalado não tem equipe nenhuma até
/// que a pessoa crie a primeira. Por isso todo consumidor trata `EquipeDisponivel?`
/// em vez de assumir que sempre há uma ativa.
struct EquipeDisponivel: Identifiable, Hashable, Codable {
    let id: String
    let nome: String
    let papel: String
    var quantidadeDeMembros: Int

    /// Referência do workspace compartilhado. Equipes criadas antes do
    /// CloudKit continuam locais até serem publicadas explicitamente.
    var zonaCloudKit: String?
    var compartilhamentoCloudKit: String?

    init(
        id: String,
        nome: String,
        papel: String,
        quantidadeDeMembros: Int,
        zonaCloudKit: String? = nil,
        compartilhamentoCloudKit: String? = nil
    ) {
        self.id = id
        self.nome = nome
        self.papel = papel
        self.quantidadeDeMembros = quantidadeDeMembros
        self.zonaCloudKit = zonaCloudKit
        self.compartilhamentoCloudKit = compartilhamentoCloudKit
    }
}
