import Foundation

enum TelaPrincipal {
    case biblioteca
    case tarefas
    case midias
    case configuracoes
    case perfil
    case equipe

    var titulo: String {
        switch self {
        case .biblioteca: "Biblioteca".localized
        case .tarefas: "Tarefas".localized
        case .midias: "Mídias".localized
        case .configuracoes: "Configurações".localized
        case .perfil: "Perfil".localized
        case .equipe: "Equipe".localized
        }
    }
}
