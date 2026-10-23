import Foundation
import OSLog
import PapagaioCore

/// Um pedido de processamento que ainda não terminou.
struct PendenciaDeProcessamento: Codable, Equatable {
    let id: UUID
    let espaco: UUID
    var somenteResumo: Bool
    /// Quantas vezes o processamento começou sem chegar ao fim.
    var tentativas: Int
}

/// A fila de processamento em disco.
///
/// A fila da `Biblioteca` vive em memória: fechar o app com itens pendentes,
/// ou trocar de espaço, deixava as conversas como "pronto para transcrever"
/// sem aviso. Este arquivo guarda os pedidos — inclusive o que estava em
/// andamento — para que sejam retomados na próxima abertura do espaço.
///
/// O arquivo é pequeno (uma linha por pedido) e só é tocado na `MainActor`,
/// junto com a fila em memória.
struct FilaDeProcessamentoPersistida {
    /// Um processamento que começou duas vezes e não terminou provavelmente
    /// derruba o app; insistir a cada abertura prenderia a pessoa num ciclo.
    static let tentativasMaximas = 2

    let url: URL

    func todas() -> [PendenciaDeProcessamento] {
        guard let dados = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendenciaDeProcessamento].self, from: dados)) ?? []
    }

    func pendentes(do espaco: EspacoID) -> [PendenciaDeProcessamento] {
        todas().filter { $0.espaco == espaco.rawValue }
    }

    /// Entra no fim da fila; um pedido repetido só atualiza o modo.
    func registrar(_ id: ArquivoID, espaco: EspacoID, somenteResumo: Bool) {
        var pendencias = todas()
        if let indice = pendencias.firstIndex(where: { $0.id == id.rawValue }) {
            pendencias[indice].somenteResumo = somenteResumo
        } else {
            pendencias.append(PendenciaDeProcessamento(
                id: id.rawValue, espaco: espaco.rawValue, somenteResumo: somenteResumo, tentativas: 0
            ))
        }
        gravar(pendencias)
    }

    func marcarInicio(_ id: ArquivoID) {
        alterar(id) { $0.tentativas += 1 }
    }

    /// O processamento nem começou (faltam modelos, memória ou disco): o
    /// pedido continua valendo e a tentativa não conta.
    func adiar(_ id: ArquivoID) {
        alterar(id) { $0.tentativas = 0 }
    }

    func remover(_ id: ArquivoID) {
        let pendencias = todas()
        let restantes = pendencias.filter { $0.id != id.rawValue }
        if restantes.count != pendencias.count { gravar(restantes) }
    }

    func removerTodas(do espaco: EspacoID) {
        let pendencias = todas()
        let restantes = pendencias.filter { $0.espaco != espaco.rawValue }
        if restantes.count != pendencias.count { gravar(restantes) }
    }

    private func alterar(_ id: ArquivoID, _ mudanca: (inout PendenciaDeProcessamento) -> Void) {
        var pendencias = todas()
        guard let indice = pendencias.firstIndex(where: { $0.id == id.rawValue }) else { return }
        mudanca(&pendencias[indice])
        gravar(pendencias)
    }

    private func gravar(_ pendencias: [PendenciaDeProcessamento]) {
        let fm = FileManager.default
        do {
            if pendencias.isEmpty {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                return
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pendencias).write(to: url, options: .atomic)
        } catch {
            // Perder a persistência não impede o processamento desta sessão.
            Logger(subsystem: "Papagaio", category: "Processamento").error(
                "Não foi possível gravar a fila de processamento: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
