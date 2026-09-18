import Foundation
import SwiftUI

enum StatusDaTarefa: String, Codable {
    case naoIniciado
    case emAndamento
    case concluida

    var titulo: String {
        switch self {
        case .naoIniciado: "Não iniciado".localized
        case .emAndamento: "Em andamento".localized
        case .concluida: "Concluída".localized
        }
    }

    /// Uma cor por status, única fonte para colunas, selos e tarjas — antes
    /// cada lugar repetia o mesmo switch, e um dia iam discordar.
    var cor: Color {
        switch self {
        case .naoIniciado: PapagaioTema.amarelo
        case .emAndamento: PapagaioTema.laranja
        case .concluida: PapagaioTema.sucesso
        }
    }
}

extension StatusDaTarefa: CaseIterable {}
