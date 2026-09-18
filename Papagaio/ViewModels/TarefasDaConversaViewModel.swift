import Foundation
import Observation
import PapagaioCore

/// As tarefas de uma conversa, mais o formulário que cria e edita uma delas.
///
/// A tela de detalhe carregava dez `@State` só para este formulário. Junte a
/// isso a regra de prazo (que promove a prioridade e dispara notificação) e a
/// gravação em disco, e a `View` estava tomando decisões de domínio.
@MainActor
@Observable
final class TarefasDaConversaViewModel {
    private(set) var tarefas: [TarefaDaConversa] = []
    var filtro: FiltroDeTarefas = .tudo

    /// Sugestões extraídas da transcrição, ainda não revisadas — aparecem
    /// numa seção à parte, nunca misturadas nas colunas do quadro (ver
    /// `tarefasAceitas`).
    var sugestoes: [TarefaDaConversa] { tarefas.filter(\.pendenteDeRevisao) }

    /// O que de fato entra no quadro desta conversa (e, por consequência, no
    /// geral) — tudo que não está mais esperando revisão.
    var tarefasAceitas: [TarefaDaConversa] { tarefas.filter { !$0.pendenteDeRevisao } }

    var mostrandoCriacao = false
    var mostrandoEdicao = false

    // O formulário é o mesmo para criar e editar; o que muda é qual método
    // fecha a folha.
    var tituloDaTarefa = ""
    var responsavelDaTarefa = ""
    var prioridadeDaTarefa: PrioridadeDaTarefa = .media
    var statusDaTarefa: StatusDaTarefa = .naoIniciado
    var prazoDaTarefa = TarefasDaConversaViewModel.prazoPadrao

    /// Avisa a pessoa quando um prazo está perto. Fica como propriedade, e não
    /// no `init`, porque quem notifica é um view model de outra camada que a
    /// tela só tem em mãos depois de montada — mesmo arranjo da `Biblioteca`.
    var aoNotificar: ((_ titulo: String, _ mensagem: String) -> Void)?

    private var tarefaEmEdicaoID: UUID?
    private let arquivoID: ArquivoID

    init(arquivoID: ArquivoID) {
        self.arquivoID = arquivoID
    }

    /// Uma semana à frente: prazo neutro o bastante para não parecer urgente
    /// nem esquecido.
    static var prazoPadrao: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    }

    // MARK: - Carga

    func carregar(base: [ProximoPasso], tituloDaConversa: String, dataDaConversa: Date) {
        let carregadas = TarefasDaConversa.carregar(
            arquivoID,
            base: base,
            tituloDaConversa: tituloDaConversa,
            dataDaConversa: dataDaConversa
        )
        let ajustadas = carregadas.map(RegraDePrazoDaTarefa.ajustada)
        tarefas = ajustadas
        // Só grava se a regra de prazo mudou alguma coisa, para não reescrever
        // o arquivo a cada abertura da tela.
        if ajustadas != carregadas {
            salvar()
        }
    }

    // MARK: - Criação

    func adicionar(origem: String) {
        let tituloLimpo = tituloDaTarefa.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty else { return }

        let tarefa = RegraDePrazoDaTarefa.ajustada(
            TarefaDaConversa(
                titulo: tituloLimpo,
                origem: origem,
                prioridade: prioridadeDaTarefa,
                status: statusDaTarefa,
                responsavel: responsavelLimpo,
                prazo: prazoDaTarefa
            )
        )
        tarefas.append(tarefa)
        salvar()
        notificarPrazoSeNecessario(tarefa)
        limparFormulario()
        mostrandoCriacao = false
    }

    func cancelarCriacao() {
        limparFormulario()
        mostrandoCriacao = false
    }

    // MARK: - Edição

    func iniciarEdicao(_ tarefa: TarefaDaConversa) {
        tarefaEmEdicaoID = tarefa.id
        tituloDaTarefa = tarefa.titulo
        responsavelDaTarefa = tarefa.responsavelValido ?? ""
        prioridadeDaTarefa = tarefa.prioridade
        statusDaTarefa = tarefa.status
        prazoDaTarefa = tarefa.prazo ?? Self.prazoPadrao
        mostrandoEdicao = true
    }

    func salvarEdicao() {
        let tituloLimpo = tituloDaTarefa.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty,
              let tarefaEmEdicaoID,
              let indice = tarefas.firstIndex(where: { $0.id == tarefaEmEdicaoID })
        else { return }

        var tarefa = tarefas[indice]
        tarefa.titulo = tituloLimpo
        tarefa.responsavel = responsavelLimpo
        tarefa.prioridade = prioridadeDaTarefa
        tarefa.prioridadeDefinidaManualmente = true
        tarefa.status = statusDaTarefa
        // Prazo trocado à mão: o reconhecimento de atraso de uma data
        // anterior não vale mais pra esta nova data — se a nova também já
        // estiver vencida, a tarefa deve voltar a contar como "Atrasada"
        // normalmente. Ver `TarefaDaConversa.atrasoReconhecido`.
        if tarefa.prazo != prazoDaTarefa {
            tarefa.atrasoReconhecido = nil
        }
        tarefa.prazo = prazoDaTarefa
        // Editar e salvar uma sugestão é uma forma de aceitá-la — com os
        // ajustes que a pessoa acabou de fazer. Sem isto, uma sugestão
        // editada continuaria fora do quadro, esperando um "aceitar" que
        // ela já deu ao salvar.
        tarefa.sugestaoPendente = false
        tarefa = RegraDePrazoDaTarefa.ajustada(tarefa)
        tarefas[indice] = tarefa
        salvar()
        notificarPrazoSeNecessario(tarefa)
        cancelarEdicao()
    }

    func cancelarEdicao() {
        tarefaEmEdicaoID = nil
        limparFormulario()
        mostrandoEdicao = false
    }

    /// Apaga a tarefa que está aberta no formulário de edição — vai para a
    /// lixeira (a mesma de `LixeiraDeTarefas`, usada pelo Painel de Tarefas
    /// geral), de onde dá para restaurar depois, em vez de sumir de vez.
    func excluirTarefaEmEdicao(conversaTitulo: String) {
        guard let tarefaEmEdicaoID,
              let tarefa = tarefas.first(where: { $0.id == tarefaEmEdicaoID })
        else { return }

        tarefas.removeAll { $0.id == tarefaEmEdicaoID }
        salvar()
        LixeiraDeTarefas.mover(tarefa, arquivoID: arquivoID, conversaTitulo: conversaTitulo)
        cancelarEdicao()
    }

    // MARK: - Sugestões

    /// Aceita a sugestão do jeito que a IA propôs, sem abrir o formulário —
    /// ela sai da seção de sugestões e entra no quadro normal, na coluna
    /// "Não iniciado".
    func aceitarSugestao(_ tarefa: TarefaDaConversa) {
        guard let indice = tarefas.firstIndex(where: { $0.id == tarefa.id }) else { return }
        tarefas[indice].sugestaoPendente = false
        tarefas[indice] = RegraDePrazoDaTarefa.ajustada(tarefas[indice])
        salvar()
        notificarPrazoSeNecessario(tarefas[indice])
    }

    /// Descarta a sugestão de vez — ao contrário de rejeitar uma tarefa já
    /// aceita (que não existe como ação), aqui não há "desfazer": ela nunca
    /// chegou a entrar em nenhum quadro.
    func rejeitarSugestao(_ tarefa: TarefaDaConversa) {
        tarefas.removeAll { $0.id == tarefa.id }
        salvar()
    }

    // MARK: - Estado da tarefa

    func alternarConclusao(_ tarefa: TarefaDaConversa) {
        guard let indice = tarefas.firstIndex(where: { $0.id == tarefa.id }) else { return }
        tarefas[indice].status = tarefas[indice].status == .concluida ? .emAndamento : .concluida
        salvar()
    }

    func mover(_ id: UUID, para destino: DestinoDeTarefa) {
        guard let indice = tarefas.firstIndex(where: { $0.id == id }) else { return }
        tarefas[indice].status = destino.status
        // A pessoa acabou de escolher onde a tarefa fica — mesmo que o
        // prazo continue vencido, essa escolha vale mais que o cálculo
        // automático de "Atrasada". Sem isto, soltar uma tarefa vencida em
        // "Em andamento" mudava o status por baixo mas ela voltava pra
        // "Atrasada" no mesmo instante, parecendo que nada tinha
        // acontecido. Ver `TarefaDaConversa.atrasoReconhecido`.
        tarefas[indice].atrasoReconhecido = true
        tarefas[indice] = RegraDePrazoDaTarefa.ajustada(tarefas[indice])
        salvar()
        notificarPrazoSeNecessario(tarefas[indice])
    }

    // MARK: - Regra de prazo

    private func notificarPrazoSeNecessario(_ tarefa: TarefaDaConversa) {
        guard tarefa.status != .concluida, RegraDePrazoDaTarefa.prazoEstaPerto(tarefa.prazo) else { return }
        let data = tarefa.prazo?.formatted(.dateTime.day().month().year()) ?? "em breve".localized
        aoNotificar?(
            "Prazo perto".localized,
            "%@ vence %@ e foi marcada como prioridade alta.".localized(tarefa.titulo, data)
        )
    }

    // MARK: - Apoio

    private var responsavelLimpo: String? {
        let valor = responsavelDaTarefa.trimmingCharacters(in: .whitespacesAndNewlines)
        return valor.isEmpty ? nil : valor
    }

    private func limparFormulario() {
        tituloDaTarefa = ""
        responsavelDaTarefa = ""
        prioridadeDaTarefa = .media
        statusDaTarefa = .naoIniciado
        prazoDaTarefa = Self.prazoPadrao
    }

    private func salvar() {
        TarefasDaConversa.salvar(tarefas, para: arquivoID)
    }
}
