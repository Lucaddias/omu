import Foundation
import PapagaioCore

/// O prazo que a lixeira anuncia em cada cartão ("Exclui em 12 dias").
///
/// Vivia só no texto: quatro cartões faziam a conta dos 30 dias para mostrar
/// a contagem e nada apagava. Aqui a regra é uma só, usada por quem mostra e
/// por quem cumpre.
enum PrazoDaLixeira {
    static let dias = 30

    static func limite(de apagadoEm: Date, calendario: Calendar = .current) -> Date? {
        calendario.date(byAdding: .day, value: dias, to: apagadoEm)
    }

    static func venceu(
        _ apagadoEm: Date,
        agora: Date = Date(),
        calendario: Calendar = .current
    ) -> Bool {
        guard let limite = limite(de: apagadoEm, calendario: calendario) else { return false }
        return agora >= limite
    }
}

/// Cumpre o prazo nas lixeiras que vivem fora do banco: anexos, pastas e
/// tarefas. As conversas são expurgadas pela `Biblioteca`, que conhece o
/// espaço aberto e a fila do iCloud.
@MainActor
enum ExpurgoDaLixeira {
    /// Devolve quantos itens saíram. Um anexo cujo arquivo não pôde ser
    /// apagado continua na lixeira, para a próxima tentativa.
    @discardableResult
    static func lojasAuxiliares(
        agora: Date = Date(),
        em defaults: UserDefaults = .standard,
        armazenamento: Armazenamento? = nil
    ) -> Int {
        var removidos = 0

        for item in LixeiraDeMidia.itens(em: defaults) where PrazoDaLixeira.venceu(item.apagadoEm, agora: agora) {
            do {
                try LixeiraDeMidia.remover(item, em: defaults, armazenamento: armazenamento)
                removidos += 1
            } catch {
                continue
            }
        }

        // As lojas de pastas e de tarefas só existem no `UserDefaults` padrão.
        guard defaults === UserDefaults.standard else { return removidos }

        // O retrato da pasta é só o rótulo e a aparência: as conversas que
        // estavam nela têm o próprio prazo e saem pela `Biblioteca`.
        for pasta in LixeiraDePastas.itens() where PrazoDaLixeira.venceu(pasta.apagadaEm, agora: agora) {
            LixeiraDePastas.remover(pasta)
            removidos += 1
        }
        for tarefa in LixeiraDeTarefas.itens() where PrazoDaLixeira.venceu(tarefa.apagadoEm, agora: agora) {
            LixeiraDeTarefas.remover(tarefa)
            removidos += 1
        }
        return removidos
    }
}
