import SwiftUI

struct SeloDePrioridade: View {
    let prioridade: PrioridadeDaTarefa

    var body: some View {
        Text(prioridade.rawValue.localized)
            .font(.caption.weight(.bold))
            .foregroundStyle(cor)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(cor.opacity(0.12), in: Capsule())
    }

    private var cor: Color {
        prioridade.cor
    }
}

struct SeloDeStatusDaTarefa: View {
    let status: StatusDaTarefa

    var body: some View {
        Text(status.titulo.localized)
            .font(.caption.weight(.bold))
            .foregroundStyle(cor)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, PapagaioTema.Espaco.curto)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(cor.opacity(0.12), in: Capsule())
    }

    private var cor: Color { status.cor }
}
