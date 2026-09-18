import SwiftUI

struct CartaoReuniaoPendente: View {
    let pendente: ReuniaoPendenteCalendar
    let aoGravar: () -> Void
    let aoImportar: () -> Void
    let aoIgnorar: () -> Void

    private var status: ReuniaoPendenteCalendar.Status { pendente.status }

    private var statusCor: Color {
        switch status {
        case .futura: PapagaioTema.destaque
        case .emAndamento: PapagaioTema.sucesso
        case .pendenteExpirada: PapagaioTema.perigo
        case .expirada: PapagaioTema.textoSecundario
        }
    }

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
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(statusCor)
                    .frame(width: 28, height: 28)
                    .background(statusCor.opacity(0.15), in: Circle())

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
                    .font(.caption2)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                    if status == .emAndamento {
                        Text("AO VIVO".localized)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PapagaioTema.sucesso, in: Capsule())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if status == .pendenteExpirada {
                        Text("pendente".localized)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PapagaioTema.perigo, in: Capsule())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            // Ações circulares, só ícone: os rótulos vivem no tooltip e na
            // acessibilidade — três botões com texto não caberiam num cartão
            // compacto sem hifenizar.
            HStack(spacing: PapagaioTema.Espaco.medio) {
                BotaoCircularReuniao(
                    simbolo: "mic.fill",
                    preenchido: true,
                    ajuda: "Gravar".localized,
                    acao: aoGravar
                )
                BotaoCircularReuniao(
                    simbolo: "arrow.down.doc",
                    ajuda: "Importar".localized,
                    acao: aoImportar
                )
                BotaoCircularReuniao(
                    simbolo: "trash",
                    ajuda: "Ignorar".localized,
                    acao: aoIgnorar
                )
                Spacer(minLength: 0)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(width: 240, height: 130)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(
                    status == .pendenteExpirada ? PapagaioTema.perigo.opacity(0.5) : PapagaioTema.borda,
                    lineWidth: status == .pendenteExpirada ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
    }
}

/// Botão circular de ação da reunião pendente. Preenchido, é o mesmo
/// preenchimento primário do "Gravar" do cartão de nova conversa; em
/// contorno, o mesmo traço dos botões secundários do tema.
private struct BotaoCircularReuniao: View {
    let simbolo: String
    var preenchido = false
    let ajuda: String
    let acao: () -> Void

    @State private var pairando = false

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(preenchido ? PapagaioTema.textoSobrePrimario : PapagaioTema.destaqueEscuro)
                .frame(width: 38, height: 38)
                .background(
                    preenchido ? AnyShapeStyle(PapagaioTema.preenchimentoPrimario) : AnyShapeStyle(PapagaioTema.superficie),
                    in: Circle()
                )
                .overlay {
                    if !preenchido {
                        Circle().stroke(PapagaioTema.borda, lineWidth: 1)
                    }
                }
                .opacity(pairando ? 0.82 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(pairando ? 1.06 : 1)
        .animation(.snappy(duration: 0.14), value: pairando)
        .onHover { pairando = $0 }
        .help(ajuda)
        .accessibilityLabel(ajuda)
    }
}
