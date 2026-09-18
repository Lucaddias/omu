import SwiftUI

struct ListaDeNotificacoesDoApp: View {
    let notificacoes: [NotificacaoDoApp]
    let processandoBiblioteca: Bool
    let gravando: Bool
    let aoLimpar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Notificações".localized)
                    .font(.headline)
                    .foregroundStyle(PapagaioTema.texto)

                Spacer()


                Button("Limpar".localized, systemImage: "trash", action: aoLimpar)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .disabled(notificacoes.isEmpty)
            }


            if gravando || processandoBiblioteca {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                    if gravando {
                        LinhaDeNotificacaoTemporaria(
                            simbolo: "mic.fill",
                            titulo: "Gravação ativa".localized,
                            mensagem: "Ao finalizar, a conversa será salva na biblioteca.".localized
                        )
                    }

                    if processandoBiblioteca {
                        LinhaDeNotificacaoTemporaria(
                            simbolo: "waveform.badge.magnifyingglass",
                            titulo: "Processando conversa".localized,
                            mensagem: "Você será avisado quando a transcrição terminar.".localized
                        )
                    }
                }
            }

            if notificacoes.isEmpty {
                Text("Nenhum aviso ainda.".localized)
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: PapagaioTema.Espaco.curto) {
                        ForEach(notificacoes) { notificacao in
                            LinhaDeNotificacaoDoApp(notificacao: notificacao)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(PapagaioTema.Espaco.medio)
        .frame(width: 340, alignment: .leading)
        .background(PapagaioTema.fundo)
    }
}

struct LinhaDeNotificacaoDoApp: View {
    let notificacao: NotificacaoDoApp

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: notificacao.simbolo)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(cor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(notificacao.titulo.localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(notificacao.mensagem.localized)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)

                Text(notificacao.data.formatted(.dateTime.hour().minute()))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.72))
            }

            Spacer(minLength: 0)
        }
        .padding(PapagaioTema.Espaco.curto)
        .background(
            notificacao.lida ? PapagaioTema.superficie : PapagaioTema.destaqueSuave.opacity(0.65),
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda.opacity(0.75), lineWidth: 1)
        }
    }

    private var cor: Color {
        switch notificacao.tipo {
        case .sucesso: PapagaioTema.sucesso
        case .aviso: PapagaioTema.aviso
        case .erro: PapagaioTema.perigo
        }
    }
}

struct LinhaDeNotificacaoTemporaria: View {
    let simbolo: String
    let titulo: String
    let mensagem: String

    var body: some View {
        HStack(alignment: .top, spacing: PapagaioTema.Espaco.curto) {
            Image(systemName: simbolo)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PapagaioTema.destaqueEscuro)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                Text(titulo.localized)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(mensagem.localized)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(PapagaioTema.Espaco.curto)
        .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
    }
}
