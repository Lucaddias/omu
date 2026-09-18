import Foundation

/// Para onde uma tarefa vai ao ser arrastada — só o status, nunca a prioridade.
///
/// Já foi as duas coisas juntas: arrastar para a coluna "Prioridade alta"
/// também sobrescrevia a prioridade da tarefa para Alta, então prioridade e
/// coluna eram o mesmo dado escondido atrás de dois controles diferentes. Uma
/// tarefa de prioridade Baixa que alguém movia para lá virava Alta sem que
/// ninguém tivesse pedido isso. Prioridade agora é só uma etiqueta, escolhida
/// à parte; mover uma tarefa entre colunas muda só onde ela está no fluxo.
enum DestinoDeTarefa {
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

    var status: StatusDaTarefa {
        switch self {
        case .naoIniciado: .naoIniciado
        case .emAndamento: .emAndamento
        case .concluida: .concluida
        }
    }
}

extension DestinoDeTarefa: CaseIterable, Hashable {}
