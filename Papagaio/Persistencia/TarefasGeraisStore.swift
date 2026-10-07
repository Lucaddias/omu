import Foundation
import PapagaioCore

enum TarefasGeraisStore {
    /// Mesma carga da aba Tarefas da conversa (`TarefasDaConversa.carregar`):
    /// as duas telas leem a mesma chave e precisam concordar sobre quais
    /// sugestões do resumo já foram oferecidas.
    static func carregar(_ arquivo: Arquivo) -> [TarefaDaConversa] {
        let tarefas = TarefasDaConversa.carregar(
            arquivo.id,
            base: arquivo.resumo?.proximosPassos ?? [],
            tituloDaConversa: arquivo.resumo?.titulo ?? arquivo.titulo,
            dataDaConversa: arquivo.criadoEm
        )
        // Reaplicada a cada carga, e não só na criação: sem isto, uma
        // tarefa cujo prazo foi ficando perto só subia de prioridade se
        // alguém reabrisse a tela da conversa — a aba geral de Tarefas,
        // que lê direto daqui, nunca via a promoção.
        let ajustadas = tarefas.map(RegraDePrazoDaTarefa.ajustada)
        if ajustadas != tarefas {
            salvar(ajustadas, para: arquivo.id)
        }
        return ajustadas
    }

    static func salvar(_ tarefas: [TarefaDaConversa], para arquivoID: ArquivoID) {
        guard let dados = try? JSONEncoder().encode(tarefas) else { return }
        UserDefaults.standard.set(dados, forKey: chave(arquivoID))
    }

    /// Duplica o estado atual das tarefas para uma conversa distinta. IDs e a
    /// origem precisam ser recriados: a cópia é uma nova conversa e não pode
    /// compartilhar a identidade nem continuar mostrando o título antigo.
    static func duplicar(_ arquivo: Arquivo, para copia: Arquivo) {
        let origemDaCopia = copia.resumo?.titulo ?? copia.titulo
        let tarefasCopiadas = carregar(arquivo).map { tarefa in
            TarefaDaConversa(
                titulo: tarefa.titulo,
                origem: origemDaCopia,
                prioridade: tarefa.prioridade,
                status: tarefa.status,
                responsavel: tarefa.responsavel,
                prazo: tarefa.prazo,
                descricao: tarefa.descricao,
                sugestaoPendente: tarefa.sugestaoPendente,
                prioridadeDefinidaManualmente: tarefa.prioridadeDefinidaManualmente,
                atrasoReconhecido: tarefa.atrasoReconhecido
            )
        }

        TarefasDaConversa.copiarPassosOferecidos(
            de: arquivo.id,
            para: copia.id,
            passosAtuais: arquivo.resumo?.proximosPassos ?? []
        )
        guard !tarefasCopiadas.isEmpty else { return }
        salvar(tarefasCopiadas, para: copia.id)
    }

    static func remover(_ arquivoID: ArquivoID, em defaults: UserDefaults = .standard) {
        TarefasDaConversa.remover(arquivoID, em: defaults)
    }

    private static func chave(_ arquivoID: ArquivoID) -> String {
        "tarefasDaConversa.\(arquivoID.rawValue.uuidString)"
    }
}
