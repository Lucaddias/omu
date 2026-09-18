import Foundation

enum FiltroDeTarefas: String, CaseIterable, Identifiable {
    case tudo = "Tudo"
    case naoIniciado = "Não iniciado"
    case emAndamento = "Em andamento"
    case concluidas = "Concluídas"
    // Recorte, não status — mesmo conceito da coluna "Atrasada" do Painel
    // de Tarefas geral (ver `TarefasView.tarefasAtrasadas`). Por último,
    // depois de "Concluídas".
    case atrasadas = "Atrasadas"

    var titulo: String {
        switch self {
        case .tudo: "Tudo".localized
        case .naoIniciado: "Não iniciado".localized
        case .emAndamento: "Em andamento".localized
        case .concluidas: "Concluídas".localized
        case .atrasadas: "Atrasadas".localized
        }
    }

    var id: Self { self }
}
