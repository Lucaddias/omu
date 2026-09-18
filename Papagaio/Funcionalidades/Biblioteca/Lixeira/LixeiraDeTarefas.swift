import PapagaioCore
import SwiftUI

enum LixeiraDeTarefas {
    static func itens() -> [TarefaNaLixeira] {
        guard let dados = UserDefaults.standard.data(forKey: chave),
              let itens = try? JSONDecoder().decode([TarefaNaLixeira].self, from: dados)
        else { return [] }
        return itens.sorted { $0.apagadoEm > $1.apagadoEm }
    }

    static func mover(_ tarefa: TarefaDaConversa, arquivoID: ArquivoID, conversaTitulo: String) {
        var atuais = itens()
        guard !atuais.contains(where: { $0.arquivoID == arquivoID && $0.tarefa.id == tarefa.id }) else { return }
        atuais.append(TarefaNaLixeira(arquivoID: arquivoID, conversaTitulo: conversaTitulo, tarefa: tarefa))
        salvar(atuais)
    }

    static func restaurar(_ item: TarefaNaLixeira, arquivos: [Arquivo]) {
        guard let arquivo = arquivos.first(where: { $0.id == item.arquivoID }) else { return }
        var tarefas = TarefasGeraisStore.carregar(arquivo)
        if !tarefas.contains(where: { $0.id == item.tarefa.id }) {
            tarefas.append(item.tarefa)
            TarefasGeraisStore.salvar(tarefas, para: item.arquivoID)
        }
        remover(item)
    }

    static func remover(_ item: TarefaNaLixeira) {
        salvar(itens().filter { $0.id != item.id })
    }

    static func restaurarTudo(arquivos: [Arquivo]) {
        itens().forEach { restaurar($0, arquivos: arquivos) }
    }

    static func esvaziar(em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave)
    }

    static func removerRegistros(
        do arquivoID: ArquivoID,
        em defaults: UserDefaults = .standard
    ) {
        guard let dados = defaults.data(forKey: chave),
              let atuais = try? JSONDecoder().decode([TarefaNaLixeira].self, from: dados),
              let novos = try? JSONEncoder().encode(atuais.filter { $0.arquivoID != arquivoID })
        else { return }
        defaults.set(novos, forKey: chave)
    }

    private static func salvar(_ itens: [TarefaNaLixeira]) {
        guard let dados = try? JSONEncoder().encode(itens) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }

    private static let chave = "tarefasNaLixeira"
}

struct CartaoDaTarefaNaLixeira: View {
    let item: TarefaNaLixeira
    let aoRestaurar: () -> Void
    let aoApagarDefinitivamente: () -> Void

    private var prazoDeExclusao: String {
        guard let limite = Calendar.current.date(byAdding: .day, value: 30, to: item.apagadoEm) else {
            return "Exclui em 30 dias".localized
        }
        let dias = Calendar.current.dateComponents([.day], from: Date(), to: limite).day ?? 0
        if dias <= 0 { return "Exclui hoje".localized }
        if dias == 1 { return "Exclui em 1 dia".localized }
        return String(format: "Exclui em %d dias".localized, dias)
    }

    private var dataCurta: String {
        return (item.tarefa.prazo ?? item.apagadoEm)
            .formatted(.dateTime.locale(LocalizacaoDoApp.localeAtual).day().month(.abbreviated))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                Label("TAREFA".localized, systemImage: "list.clipboard")
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
                    .help("Restaurar tarefa".localized)

                    Button(role: .destructive, action: aoApagarDefinitivamente) {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PapagaioTema.perigo)
                    .help("Apagar tarefa definitivamente".localized)
                }
            }

            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
                // Sem `.lineLimit` — mesmo ajuste de `CartaoDaLixeira`: o
                // título da tarefa e o nome da conversa vêm de dados reais,
                // sem tamanho garantido. `.fixedSize` garante que o texto
                // puxa a altura do cartão consigo (só tem `minHeight`, não
                // `maxHeight`) em vez de ser espremido.
                Text(item.tarefa.titulo)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(PapagaioTema.textoSecundario.opacity(0.68))
                    .strikethrough(true, color: PapagaioTema.textoSecundario.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(format: "Tarefa removida de %@. Restaure para voltar ao painel de tarefas dessa conversa.".localized, item.conversaTitulo))
                    .font(.body)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            SeparadorPapagaio()

            HStack(spacing: PapagaioTema.Espaco.largo) {
                Label(dataCurta, systemImage: "calendar")
                Label(item.tarefa.responsavel?.isEmpty == false ? item.tarefa.responsavel! : "SEM RESPONSÁVEL".localized, systemImage: "person")

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
