import CloudKit
import Foundation

/// Gravações e remoções em lote com o resultado de cada registro conferido.
///
/// `CKDatabase.modifyRecords` assíncrono só lança quando a operação inteira
/// falha. A recusa de um registro — conflito de versão, campo ausente no
/// esquema, permissão negada — chega apenas no resultado daquele registro.
/// Quem descarta o retorno trata essas recusas como sucesso.
enum LoteCloudKit {
    /// Salva os registros numa única operação atômica e devolve as versões
    /// confirmadas pelo servidor, na mesma ordem em que foram enviados.
    @discardableResult
    static func salvar(_ registros: [CKRecord], em banco: CKDatabase) async throws -> [CKRecord] {
        let resultado = try await banco.modifyRecords(
            saving: registros,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        if let falha = falhaMaisInformativa(em: resultado.saveResults.values.map { $0.map { _ in } }) {
            throw falha
        }
        return try registros.map { registro in
            guard let salvo = try resultado.saveResults[registro.recordID]?.get() else {
                throw CKError(.internalError)
            }
            return salvo
        }
    }

    /// Remove os registros. Um ID que já não existe conta como removido: é o
    /// estado que o chamador queria, e repetir a remoção precisa ser seguro.
    static func apagar(_ ids: [CKRecord.ID], em banco: CKDatabase) async throws {
        guard !ids.isEmpty else { return }
        let resultado = try await banco.modifyRecords(
            saving: [],
            deleting: ids,
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        let pendentes = resultado.deleteResults.values.filter { item in
            guard case let .failure(erro) = item else { return false }
            return (erro as? CKError)?.code != .unknownItem
        }
        if let falha = falhaMaisInformativa(em: pendentes) {
            throw falha
        }
    }

    /// Num lote atômico, um registro recusado derruba os demais com
    /// `batchRequestFailed`. Só a recusa original explica o que aconteceu.
    private static func falhaMaisInformativa(em resultados: [Result<Void, any Error>]) -> (any Error)? {
        let falhas = resultados.compactMap { item -> (any Error)? in
            guard case let .failure(erro) = item else { return nil }
            return erro
        }
        return falhas.first { ($0 as? CKError)?.code != .batchRequestFailed } ?? falhas.first
    }
}
