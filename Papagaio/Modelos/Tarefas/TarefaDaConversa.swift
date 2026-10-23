import Foundation
import PapagaioCore

struct TarefaDaConversa: Identifiable, Codable, Equatable {
    let id: UUID
    var titulo: String
    var origem: String
    var prioridade: PrioridadeDaTarefa
    var status: StatusDaTarefa
    var responsavel: String?
    var prazo: Date?
    /// Opcional e por último de propósito: tarefas gravadas antes desta versão
    /// decodificam com `nil` aqui, sem quebrar.
    var descricao: String?
    /// `true` só para uma sugestão recém-extraída da transcrição, ainda não
    /// revisada pela pessoa — enquanto isso, ela não aparece em nenhum
    /// Kanban (nem o da conversa, nem o geral), só na seção de sugestões.
    /// Opcional pelo mesmo motivo de `descricao`: tarefas de antes desta
    /// versão decodificam com `nil`, que `pendenteDeRevisao` trata como
    /// "já revisada" — não seria correto ressuscitar tarefas antigas como
    /// pendentes.
    var sugestaoPendente: Bool?
    /// `true` quando a pessoa escolheu a prioridade à mão (pelo formulário de
    /// criação/edição) — a partir daí, `RegraDePrazoDaTarefa` não mexe mais
    /// nela. Sem isto, uma tarefa vencida (prazo no passado conta como "prazo
    /// perto") tinha a prioridade forçada de volta para Alta assim que a tela
    /// recarregava, um instante depois de a pessoa salvar outra escolha —
    /// parecendo que a edição simplesmente não tinha sido salva. Opcional
    /// pelo mesmo motivo dos outros campos novos: tarefas antigas decodificam
    /// com `nil`, tratado como "ainda não é manual" (mantendo a promoção
    /// automática que já existia para elas).
    var prioridadeDefinidaManualmente: Bool?
    /// `true` depois que a pessoa arrasta manualmente uma tarefa vencida
    /// para "Não iniciado", "Em andamento" ou "Concluída" — sem isto, soltar
    /// numa dessas colunas mudava o status por baixo, mas a tarefa
    /// continuava vencida e voltava pra "Atrasada" no mesmo instante,
    /// parecendo que o arraste não tinha feito nada. A escolha da pessoa
    /// passa a valer mais que o cálculo automático a partir daqui — até ela
    /// editar o prazo de novo (ver `TarefasView.moverTarefa` e
    /// `TarefasDaConversaViewModel.mover`, que zeram isto ao trocar o
    /// prazo). Opcional pelo mesmo motivo dos outros campos novos: tarefas
    /// antigas decodificam com `nil`, tratado como "ainda não reconhecida".
    var atrasoReconhecido: Bool?

    init(
        id: UUID = UUID(),
        titulo: String,
        origem: String,
        prioridade: PrioridadeDaTarefa,
        status: StatusDaTarefa,
        responsavel: String?,
        prazo: Date?,
        descricao: String? = nil,
        sugestaoPendente: Bool? = nil,
        prioridadeDefinidaManualmente: Bool? = nil,
        atrasoReconhecido: Bool? = nil
    ) {
        self.id = id
        self.titulo = titulo
        self.origem = origem
        self.prioridade = prioridade
        self.status = status
        self.responsavel = responsavel
        self.prazo = prazo
        self.descricao = descricao
        self.sugestaoPendente = sugestaoPendente
        self.prioridadeDefinidaManualmente = prioridadeDefinidaManualmente
        self.atrasoReconhecido = atrasoReconhecido
    }

    /// `false` para tarefas nunca editadas por uma pessoa — só aí a régua de
    /// prazo (`RegraDePrazoDaTarefa`) ainda pode promover a prioridade sozinha.
    var prioridadeEhManual: Bool { prioridadeDefinidaManualmente ?? false }

    /// `true` enquanto a sugestão espera a pessoa aceitar, editar ou
    /// descartar — ver o comentário de `sugestaoPendente`.
    var pendenteDeRevisao: Bool { sugestaoPendente ?? false }

    /// Ver o comentário de `atrasoReconhecido`.
    var atrasoFoiReconhecido: Bool { atrasoReconhecido ?? false }

    /// O nome do responsável, só quando é um nome de verdade.
    ///
    /// O resumo vem de um modelo local que, quando um próximo passo não cita
    /// ninguém, às vezes preenche o campo com o texto literal "null" em vez
    /// de omiti-lo — comportamento de LLM, não uma pessoa chamada Null. Sem
    /// este filtro esse texto ia direto para a tela, como se fosse o nome de
    /// alguém.
    var responsavelValido: String? { Self.responsavelSaneado(responsavel) }

    static func responsavelSaneado(_ texto: String?) -> String? {
        guard let texto else { return nil }
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        // Além dos "nulos" escritos por extenso, o modelo devolve os rótulos
        // de canal que recebeu na transcrição — "(interlocutor)",
        // "desconhecido" — como se fossem o nome de alguém.
        let chave = limpo.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
        let naoSaoPessoas: Set<String> = [
            "null", "nil", "n/a", "none", "",
            Speaker.interlocutor, "desconhecido", "unknown", "other", "them",
        ]
        guard !naoSaoPessoas.contains(chave) else { return nil }
        // O canal do microfone é a própria pessoa.
        if chave == Speaker.eu || chave == "me" { return "Eu".localized }
        return limpo
    }
}
