import SwiftUI

struct CartaoReuniaoPendenteLixeira: View {
    let pendente: ReuniaoPendenteCalendar
    let aoRestaurar: () -> Void
    let aoApagarDefinitivamente: () -> Void

    private var status: ReuniaoPendenteCalendar.Status { pendente.status }

    private var horarioFormatado: String {
        pendente.dataHora.formatted(date: .omitted, time: .shortened)
    }

    private var dataFormatada: String {
        let formatador = DateFormatter()
        formatador.locale = LocalizacaoDoApp.localeAtual
        formatador.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        return formatador.string(from: pendente.dataHora)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(PapagaioTema.aviso)
                    .frame(width: 32, height: 32)
                    .background(PapagaioTema.aviso.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(pendente.titulo)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PapagaioTema.texto)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    HStack(spacing: 4) {
                        Text(dataFormatada)
                        Text("·")
                        Text(horarioFormatado)
                    }
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                    if status == .pendenteExpirada {
                        Text("pendente".localized)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PapagaioTema.perigo, in: Capsule())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if status == .expirada {
                        Text("expirada".localized)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PapagaioTema.textoSecundario, in: Capsule())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: PapagaioTema.Espaco.curto) {
                Button(action: aoRestaurar) {
                    Label("Restaurar".localized, systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BotaoPrincipalPapagaio())

                Button(action: aoApagarDefinitivamente) {
                    Label("Apagar".localized, systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BotaoDeContornoPapagaio())
                .tint(PapagaioTema.perigo)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(width: 260, height: 130)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
    }
}
