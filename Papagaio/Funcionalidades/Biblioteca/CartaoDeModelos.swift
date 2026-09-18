import SwiftUI


/// Aviso de pesos ausentes, preservando as garantias de sandbox do seletor de
/// pasta. A mudança visual não pode antecipar o fim do acesso security-scoped.
struct CartaoDeModelos: View {
    let modelos: ModelosViewModel
    let aoEscolherPasta: (URL) -> Void
    let aoUsarPastaDoApp: () -> Void
    @State private var escolhendoPasta = false

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Image(systemName: modelos.resultado?.bloqueia == true ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(modelos.resultado?.bloqueia == true ? PapagaioTema.perigo : PapagaioTema.destaqueEscuro)
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text("Modelos locais".localized)
                        .font(.headline)
                        .foregroundStyle(PapagaioTema.texto)
                    Text((modelos.resultado?.mensagem ?? "Verificando os modelos…").localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            }

            if let progresso = modelos.progresso {
                ProgressView(value: progresso.fracao) {
                    Text(progresso.peso.nomeArquivo)
                        .font(.caption.weight(.medium))
                } currentValueLabel: {
                    HStack {
                        Text("%@ de %@".localized(gb(progresso.bytesRecebidos), gb(progresso.bytesTotais)))

                        if let restante = modelos.restanteDoDownload {
                            Spacer()
                            // Baixar modelos grandes sem previsão nenhuma é o tipo de
                            // espera que faz a pessoa achar que travou.
                            Text(tempoRestante(restante))
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
                .tint(PapagaioTema.destaque)
            }

            if let erro = modelos.erro {
                Label(erro.localized, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.perigo)
            }

            if modelos.resultado?.bloqueia == false, !modelos.faltando.isEmpty {
                HStack(spacing: PapagaioTema.Espaco.curto) {
                    if modelos.baixando {
                        Button("Cancelar".localized, action: modelos.cancelar)
                            .buttonStyle(BotaoDeContornoPapagaio())
                        Text("O download continua de onde parou se a conexão cair.".localized)
                            .font(.caption)
                            .foregroundStyle(PapagaioTema.textoSecundario)
                    } else {
                        if modelos.pastaEscolhida == nil {
                            Button("Baixar modelos (%@)".localized(gb(totalFaltando)), action: modelos.baixar)
                                .buttonStyle(BotaoPrincipalPapagaio())
                        }
                        Button("Escolher pasta…".localized) { escolhendoPasta = true }
                            .buttonStyle(BotaoDeContornoPapagaio())
                        if modelos.pastaEscolhida != nil {
                            Button("Usar pasta do app".localized, action: aoUsarPastaDoApp)
                                .buttonStyle(BotaoDeContornoPapagaio())
                        }
                    }
                }

                Text(descricaoDaPasta)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.middle)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .cartaoPapagaio()
        .fileImporter(
            isPresented: $escolhendoPasta,
            allowedContentTypes: [.folder]
        ) { resultado in
            guard case let .success(url) = resultado,
                  url.startAccessingSecurityScopedResource()
            else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            aoEscolherPasta(url)
        }
    }

    private var totalFaltando: Int64 {
        modelos.faltando.reduce(0) { $0 + $1.bytes }
    }

    private var descricaoDaPasta: String {
        if let escolhida = modelos.pastaEscolhida {
            return "Pasta ativa: %@".localized(escolhida.path)
        }
        return "Você também pode apontar uma pasta que já tenha os modelos GGUF.".localized
    }

    /// Arredonda para a unidade que a pessoa consegue usar: ninguém planeja a
    /// tarde com base em "faltam 2.847 segundos".
    private func tempoRestante(_ segundos: TimeInterval) -> String {
        if segundos < 60 { return "menos de 1 min".localized }
        let minutos = Int((segundos / 60).rounded())
        if minutos < 60 { return "cerca de %d min".localized(minutos) }
        let horas = segundos / 3600
        return "cerca de %.1f h".localized(horas)
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
