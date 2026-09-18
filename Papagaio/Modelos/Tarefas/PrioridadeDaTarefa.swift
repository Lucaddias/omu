import SwiftUI

enum PrioridadeDaTarefa: String, Codable, CaseIterable {
    case alta = "Alta"
    case media = "Média"
    case baixa = "Baixa"

    var titulo: String {
        switch self {
        case .alta: "Alta".localized
        case .media: "Média".localized
        case .baixa: "Baixa".localized
        }
    }

    var cor: Color {
        switch self {
        case .alta: PapagaioTema.perigo
        case .media: PapagaioTema.textoSecundario
        case .baixa: PapagaioTema.sucesso
        }
    }

}
