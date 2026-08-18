import SwiftUI

enum StatusDaEquipe: String, CaseIterable, Identifiable, Codable {
    case ativo = "Ativo"
    case offline = "Offline"
    case ocupado = "Ocupado"

    var id: Self { self }
    var cor: Color {
        switch self {
        case .ativo: PapagaioTema.sucesso
        case .offline: PapagaioTema.textoSecundario.opacity(0.55)
        case .ocupado: PapagaioTema.perigo
        }
    }
}

struct MembroDaEquipe: Identifiable, Equatable, Codable {
    var id = UUID()
    var nome: String
    var email: String
    var cargo: String
    var status: StatusDaEquipe
    var atual: Bool = false

    var iniciais: String { Papagaio.iniciais(de: nome, vazio: "M") }

}
