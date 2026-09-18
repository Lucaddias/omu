import SwiftUI

enum OrdenacaoDoPainelDeTarefas {
    case deadline
    case prioridade

    var titulo: String {
        switch self {
        case .deadline: "Data limite".localized
        case .prioridade: "Prioridade".localized
        }
    }

    var simbolo: String {
        switch self {
        case .deadline: "calendar"
        case .prioridade: "line.3.horizontal.decrease"
        }
    }
}

enum FiltroDeDeadlineTarefa: CaseIterable, Hashable {
    case todas
    case atrasadas
    case hoje
    case proximosSeteDias
    case semData

    var titulo: String {
        switch self {
        case .todas: "Data limite".localized
        case .atrasadas: "Atrasadas".localized
        case .hoje: "Hoje".localized
        case .proximosSeteDias: "Próximos 7 dias".localized
        case .semData: "Sem data".localized
        }
    }

    var simbolo: String {
        switch self {
        case .todas, .proximosSeteDias: "calendar"
        case .atrasadas: "calendar.badge.exclamationmark"
        case .hoje: "calendar.circle"
        case .semData: "calendar.badge.clock"
        }
    }

    func inclui(_ prazo: Date?) -> Bool {
        let calendario = Calendar.current
        let hoje = calendario.startOfDay(for: Date())

        switch self {
        case .todas:
            return true
        case .semData:
            return prazo == nil
        case .atrasadas:
            guard let prazo else { return false }
            return calendario.startOfDay(for: prazo) < hoje
        case .hoje:
            guard let prazo else { return false }
            return calendario.isDateInToday(prazo)
        case .proximosSeteDias:
            guard let prazo else { return false }
            let dia = calendario.startOfDay(for: prazo)
            let limite = calendario.date(byAdding: .day, value: 7, to: hoje) ?? hoje
            return dia >= hoje && dia <= limite
        }
    }
}

struct BotaoDeFiltroDeTarefaGeral: ButtonStyle {
    let ativo: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(ativo ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
            .padding(.horizontal, PapagaioTema.Espaco.medio)
            .frame(height: PapagaioTema.Altura.padrao)
            .background(
                ativo ? PapagaioTema.destaqueSuave.opacity(configuration.isPressed ? 0.95 : 0.62) : PapagaioTema.superficie,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(PapagaioTema.borda.opacity(0.95), lineWidth: 1)
            }
    }
}
