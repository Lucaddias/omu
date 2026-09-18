import Foundation

enum ContextoDaConta: String {
    case perfil
    case equipe

    // Os rótulos de conta vêm de quem conhece a equipe ativa —
    // `BarraSuperiorPapagaioView.tituloDaContaAtiva` e `SeletorDeContextoDaConta`.
    // O `titulo` que existia aqui era morto e trazia um nome de equipe fixo.

    var titulo: String {
        switch self {
        case .perfil: "Pessoal".localized
        case .equipe: "Equipe".localized
        }
    }

    /// Sem glifo circular: o avatar já recorta e contorna em círculo, e
    /// `person.crop.circle` desenhava um segundo anel dentro do primeiro.
    var simbolo: String {
        switch self {
        case .perfil: "person.fill"
        case .equipe: "person.3"
        }
    }
}
