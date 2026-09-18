import PapagaioCore
import SwiftUI

struct CartaoDeMidiaNaLixeira: View {
    let item: MidiaNaLixeira
    let aoRestaurar: () -> Void
    let aoApagarDefinitivamente: () -> Void
    let aoRevelarNoFinder: () -> Void

    private var prazoDeExclusao: String {
        guard let limite = Calendar.current.date(byAdding: .day, value: 30, to: item.apagadoEm) else {
            return "Exclui em 30 dias".localized
        }
        let dias = Calendar.current.dateComponents([.day], from: Date(), to: limite).day ?? 0
        if dias <= 0 { return "Exclui hoje".localized }
        if dias == 1 { return "Exclui em 1 dia".localized }
        return String(format: "Exclui em %d dias".localized, dias)
    }

    private var simbolo: String {
        switch item.tipo {
        case "Imagem": "photo"
        case "Vídeo": "film"
        case "PDF": "doc.richtext"
        case "Áudio": "waveform"
        default: "doc"
        }
    }

    private var descricao: String {
        item.daGravacao
            ? String(format: "Áudio da gravação de %@. A transcrição e o resumo continuam na conversa; restaure para poder ouvir de novo.".localized, item.conversaTitulo)
            : String(format: "Anexo removido da mídia de %@. Restaure para voltar à aba Mídia dessa conversa.".localized, item.conversaTitulo)
    }

    private var tamanhoCurto: String {
        let formatador = ByteCountFormatter()
        formatador.allowedUnits = [.useKB, .useMB, .useGB]
        formatador.countStyle = .file
        return formatador.string(fromByteCount: item.tamanho).uppercased()
    }

    private var dataCurta: String {
        return item.apagadoEm
            .formatted(.dateTime.locale(LocalizacaoDoApp.localeAtual).day().month(.abbreviated))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Label(item.tipo.localized.uppercased(), systemImage: simbolo)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSobrePrimario)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, PapagaioTema.Espaco.medio)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.preenchimentoPrimario, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))

                Spacer(minLength: 8)

                HStack(spacing: PapagaioTema.Espaco.largo) {
                    Button(action: aoRestaurar) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                    .help("Restaurar arquivo".localized)
                    .accessibilityLabel(String(format: "Restaurar %@".localized, item.nome))

                    Button(action: aoRevelarNoFinder) {
                        Image(systemName: "folder")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .help("Mostrar no Finder".localized)
                    .accessibilityLabel(String(format: "Mostrar %@ no Finder".localized, item.nome))

                    Button(role: .destructive, action: aoApagarDefinitivamente) {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.perigo)
                    .help("Apagar definitivamente".localized)
                    .accessibilityLabel(String(format: "Apagar definitivamente %@".localized, item.nome))
                }
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                // Sem `.lineLimit` — mesmo ajuste de `CartaoDaLixeira`: nome
                // e descrição vêm de dados reais (nome do arquivo, título da
                // conversa), sem tamanho garantido. O cartão não tem
                // `maxHeight`, só `minHeight`, então deixar o texto crescer
                // não corta nada.
                Text(item.nome)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.68))
                    .strikethrough(true, color: PapagaioTema.textoSecundario.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                Text(descricao)
                    .font(.body)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            SeparadorPapagaio()

            HStack(spacing: PapagaioTema.Espaco.largo) {
                Label(dataCurta, systemImage: "calendar")
                Label(tamanhoCurto, systemImage: "externaldrive")

                Spacer(minLength: 8)

                Text(prazoDeExclusao)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(PapagaioTema.perigo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.62))
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
        .cartaoPapagaio()
        .accessibilityElement(children: .contain)
    }
}
