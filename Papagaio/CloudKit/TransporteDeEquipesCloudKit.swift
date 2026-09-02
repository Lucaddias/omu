import CloudKit
import Foundation

/// Um `CKShare` já gravado no servidor, reduzido ao que o serviço precisa.
///
/// Existe por dois motivos concretos: `CKShare.url` só é preenchida pelo
/// CloudKit depois do save, e `CKShare.Metadata` não tem inicializador
/// público. Sem este intermediário, nenhum teste consegue exercitar criação de
/// equipe e entrada por código sem tocar o iCloud real — e foi exatamente essa
/// falta de cobertura que deixou `publicPermission = .none` passar na CI.
struct CompartilhamentoDaEquipe: Sendable {
    let recordName: String
    let url: URL
}

/// Fronteira testável entre as regras de entrada por código e as APIs
/// concretas do CloudKit.
///
/// Cobre só o fluxo de criação e entrada — o resto do
/// `ServicoDeEquipesCloudKit` continua falando com `CKContainer` diretamente,
/// porque manipula `CKShare` vivo (permissões e participantes) e não ganharia
/// testabilidade sem espelhar meio framework.
protocol TransporteDeEquipesCloudKit: Sendable {
    func garantirContaDisponivel() async throws

    /// Cria a zona da equipe, grava o registro `Equipe` e o `CKShare` da zona
    /// numa única operação atômica.
    func criarEquipeCompartilhada(
        zona: CKRecordZone.ID,
        registroDaEquipe: CKRecord,
        titulo: String,
        permissaoPublica: CKShare.ParticipantPermission
    ) async throws -> CompartilhamentoDaEquipe

    func salvarRegistroPublico(_ registro: CKRecord) async throws
    func registroPublico(comID id: CKRecord.ID) async throws -> CKRecord
    func apagarRegistroPublico(comID id: CKRecord.ID) async throws

    /// Resolve a URL do compartilhamento e aceita o convite na conta atual.
    func aceitarCompartilhamento(em url: URL) async throws -> CKShare
    func registroDaZonaCompartilhada(comID id: CKRecord.ID) async throws -> CKRecord
}

/// Implementação concreta. Todo acesso a `CKContainer` do fluxo de entrada por
/// código fica isolado aqui.
actor TransporteDeEquipesCloudKitReal: TransporteDeEquipesCloudKit {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func garantirContaDisponivel() async throws {
        guard try await container.accountStatus() == .available else {
            throw ErroDeEquipeCloudKit.contaICloudIndisponivel
        }
    }

    func criarEquipeCompartilhada(
        zona: CKRecordZone.ID,
        registroDaEquipe: CKRecord,
        titulo: String,
        permissaoPublica: CKShare.ParticipantPermission
    ) async throws -> CompartilhamentoDaEquipe {
        let banco = container.privateCloudDatabase
        _ = try await banco.save(CKRecordZone(zoneID: zona))

        let compartilhamento = CKShare(recordZoneID: zona)
        compartilhamento[CKShare.SystemFieldKey.title] = titulo as NSString
        compartilhamento.publicPermission = permissaoPublica

        _ = try await banco.modifyRecords(
            saving: [registroDaEquipe, compartilhamento],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )

        guard let url = compartilhamento.url else {
            throw ErroDeEquipeCloudKit.conviteIndisponivel
        }
        return CompartilhamentoDaEquipe(
            recordName: compartilhamento.recordID.recordName,
            url: url
        )
    }

    func salvarRegistroPublico(_ registro: CKRecord) async throws {
        _ = try await container.publicCloudDatabase.save(registro)
    }

    func registroPublico(comID id: CKRecord.ID) async throws -> CKRecord {
        try await container.publicCloudDatabase.record(for: id)
    }

    func apagarRegistroPublico(comID id: CKRecord.ID) async throws {
        do {
            _ = try await container.publicCloudDatabase.modifyRecords(
                saving: [], deleting: [id], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
        } catch let erro as CKError where erro.code == .unknownItem {
            // Invalidar um código que já não existe é o estado desejado. Vale
            // para equipes publicadas antes do `recordName` derivado, cujo
            // registro tinha nome aleatório e não é mais endereçável.
        }
    }

    func aceitarCompartilhamento(em url: URL) async throws -> CKShare {
        let metadados = try await container.shareMetadata(for: url)
        return try await container.accept(metadados)
    }

    func registroDaZonaCompartilhada(comID id: CKRecord.ID) async throws -> CKRecord {
        try await container.sharedCloudDatabase.record(for: id)
    }
}
