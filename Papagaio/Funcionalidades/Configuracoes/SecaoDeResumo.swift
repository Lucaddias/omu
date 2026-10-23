import PapagaioCore
import SwiftUI

/// Onde o resumo é gerado: no Mac (Qwen) ou na nuvem privada da Apple.
///
/// A escolha fica à vista com o que ela custa — o que sai do dispositivo e o
/// limite diário —, porque trocar o modo muda uma promessa do app: até aqui
/// nada da conversa saía do Mac.
struct SecaoDeResumo: View {
    let modelos: ModelosViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            Label("Resumo".localized, systemImage: "sparkles")
                .font(PapagaioTema.Tipo.tituloDeSecao)
                .foregroundStyle(PapagaioTema.destaqueEscuro)

            SeparadorPapagaio()

            if modelos.nuvemDisponivel || modelos.modo == .nuvemPrivada {
                Picker("Onde o resumo é gerado".localized, selection: modo) {
                    Text("Neste Mac".localized).tag(ModoDeResumo.local)
                    Text("Nuvem privada da Apple".localized).tag(ModoDeResumo.nuvemPrivada)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Onde o resumo é gerado".localized)

                Text(explicacao)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)

                if modelos.modo == .nuvemPrivada {
                    estadoDaCota
                    remocaoDoModeloLocal
                }
            } else {
                Text("O resumo é gerado neste Mac, pelo modelo local.".localized)
                    .font(PapagaioTema.Tipo.corpo.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)

                Text(modelos.motivoDaNuvemIndisponivel.localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let erro = modelos.erro {
                Label(erro.localized, systemImage: "xmark.octagon.fill")
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.perigo)
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartaoPapagaio()
    }

    private var modo: Binding<ModoDeResumo> {
        Binding(
            get: { modelos.modo },
            set: { modelos.escolherModo($0) }
        )
    }

    private var explicacao: String {
        switch modelos.modo {
        case .local:
            "Transcrição e resumo rodam inteiramente neste Mac. Exige o modelo de 6,2 GB em disco e 18 GB de memória.".localized
        case .nuvemPrivada:
            "A transcrição continua neste Mac. Para gerar o resumo, o texto da conversa é enviado ao Private Cloud Compute da Apple, que não o armazena. Sem internet ou com o limite diário atingido, o resumo espera e é gerado sozinho depois.".localized
        }
    }

    /// Rótulo permanente, não alerta: é o que a Apple pede para o limite de
    /// uso — a pessoa vê onde está sem ser interrompida.
    @ViewBuilder
    private var estadoDaCota: some View {
        let cota = NuvemPrivada.cota
        if cota.limiteAtingido || cota.proximaDoLimite {
            HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
                Label(
                    textoDaCota(cota),
                    systemImage: cota.limiteAtingido ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .font(PapagaioTema.Tipo.apoio.weight(.semibold))
                .foregroundStyle(cota.limiteAtingido ? PapagaioTema.perigo : PapagaioTema.laranja)
                .fixedSize(horizontal: false, vertical: true)

                if cota.podeAumentar {
                    Button("Ver opções".localized) { NuvemPrivada.mostrarOpcoesDeLimite() }
                        .buttonStyle(BotaoDeContornoPapagaio())
                }
            }
        }
    }

    private func textoDaCota(_ cota: CotaDaNuvemPrivada) -> String {
        guard cota.limiteAtingido else {
            return "Você está perto do limite diário do Apple Intelligence.".localized
        }
        guard let reinicia = cota.reiniciaEm else {
            return "Limite diário do Apple Intelligence atingido. Os resumos voltam quando ele for renovado.".localized
        }
        return "Limite diário do Apple Intelligence atingido. Os resumos voltam depois de %@.".localized(
            reinicia.formatted(
                date: Calendar.current.isDateInToday(reinicia) ? .omitted : .abbreviated,
                time: .shortened
            )
        )
    }

    @ViewBuilder
    private var remocaoDoModeloLocal: some View {
        if modelos.podeRemoverModeloLocal {
            HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
                Button("Remover modelo local (6,2 GB)".localized, action: modelos.removerModeloLocal)
                    .buttonStyle(BotaoDeContornoPapagaio())

                Text("Enquanto ele estiver no Mac, o Ōmu o usa quando a nuvem não puder gerar o resumo.".localized)
                    .font(PapagaioTema.Tipo.apoio)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
