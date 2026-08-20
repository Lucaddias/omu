import CloudKit
import Foundation

/// Workspaces colaborativos no container do Papagaio.
///
/// Cada equipe vive numa zona privada própria e a zona inteira recebe um
/// `CKShare`. Assim, os próximos tipos de registro (conversa, tarefa e mídia)
/// entram no mesmo escopo sem que seja necessário compartilhar item a item.
actor ServicoDeEquipesCloudKit {
    static let identificadorDoContainer = "iCloud.com.papagaio.Papagaio"

    private enum Campo {
        static let id = "id"
        static let nome = "nome"
    }

    private enum TipoDeRegistro {
        static let equipe = "Equipe"
    }

    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.papagaio.Papagaio")) {
        self.container = container
    }

    /// Cria o workspace e o compartilhamento da zona de uma equipe nova.
    ///
    /// O link não concede acesso sozinho: a fase de UI adicionará os e-mails
    /// dos membros como participantes privados antes de distribuí-lo.
    func criarWorkspace(para equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()

        let zonaID = CKRecordZone.ID(
            zoneName: Self.nomeDaZona(para: equipe.id)
        )
        let banco = container.privateCloudDatabase
        _ = try await banco.save(CKRecordZone(zoneID: zonaID))

        let registro = registroDaEquipe(equipe, na: zonaID)
        let compartilhamento = CKShare(recordZoneID: zonaID)
        compartilhamento[CKShare.SystemFieldKey.title] = equipe.nome as NSString

        _ = try await banco.modifyRecords(
            saving: [registro, compartilhamento],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )

        return EquipeDisponivel(
            id: equipe.id,
            nome: equipe.nome,
            papel: equipe.papel,
            quantidadeDeMembros: equipe.quantidadeDeMembros,
            zonaCloudKit: zonaID.zoneName,
            compartilhamentoCloudKit: compartilhamento.recordID.recordName
        )
    }

    /// Inclui um membro identificado pelo e-mail do Apple Account com acesso
    /// de leitura e escrita ao workspace completo da equipe.
    func adicionarMembro(email: String, a equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        let referencia = try referenciaDaZona(de: equipe)
        let idDoCompartilhamento = try idDoCompartilhamento(de: equipe, na: referencia)
        let banco = container.privateCloudDatabase
        let compartilhamento = try await banco.record(for: idDoCompartilhamento) as! CKShare
        let participante = try await container.shareParticipant(forEmailAddress: email)

        participante.permission = .readWrite
        compartilhamento.addParticipant(participante)
        _ = try await banco.save(compartilhamento)
    }

    /// Aceita um convite entregue pelo sistema e devolve a equipe para a lista
    /// local do participante. Os registros passam a aparecer no banco
    /// compartilhado dessa conta.
    func aceitar(_ metadados: CKShare.Metadata) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        let compartilhamento = try await container.accept(metadados)
        let zonaID = compartilhamento.recordID.zoneID
        let registroID = CKRecord.ID(recordName: "equipe", zoneID: zonaID)
        let registro = try await container.sharedCloudDatabase.record(for: registroID)

        guard
            let id = registro[Campo.id] as? String,
            let nome = registro[Campo.nome] as? String
        else {
            throw ErroDeEquipeCloudKit.registroDaEquipeInvalido
        }

        return EquipeDisponivel(
            id: id,
            nome: nome,
            papel: "Membro",
            quantidadeDeMembros: 0,
            zonaCloudKit: zonaID.zoneName,
            compartilhamentoCloudKit: compartilhamento.recordID.recordName
        )
    }

    nonisolated static func nomeDaZona(para equipeID: String) -> String {
        "equipe.\(equipeID)"
    }

    private func garantirContaICloudDisponivel() async throws {
        guard try await container.accountStatus() == .available else {
            throw ErroDeEquipeCloudKit.contaICloudIndisponivel
        }
    }

    private func registroDaEquipe(_ equipe: EquipeDisponivel, na zonaID: CKRecordZone.ID) -> CKRecord {
        let registro = CKRecord(
            recordType: TipoDeRegistro.equipe,
            recordID: CKRecord.ID(recordName: "equipe", zoneID: zonaID)
        )
        registro[Campo.id] = equipe.id as NSString
        registro[Campo.nome] = equipe.nome as NSString
        return registro
    }

    private func referenciaDaZona(de equipe: EquipeDisponivel) throws -> CKRecordZone.ID {
        guard let zona = equipe.zonaCloudKit
        else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        return CKRecordZone.ID(zoneName: zona)
    }

    private func idDoCompartilhamento(
        de equipe: EquipeDisponivel,
        na zona: CKRecordZone.ID
    ) throws -> CKRecord.ID {
        guard let nome = equipe.compartilhamentoCloudKit else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        return CKRecord.ID(recordName: nome, zoneID: zona)
    }
}

enum ErroDeEquipeCloudKit: LocalizedError {
    case contaICloudIndisponivel
    case equipeAindaLocal
    case registroDaEquipeInvalido

    var errorDescription: String? {
        switch self {
        case .contaICloudIndisponivel:
            "Entre no iCloud neste Mac para usar equipes compartilhadas."
        case .equipeAindaLocal:
            "Esta equipe ainda não foi publicada no CloudKit."
        case .registroDaEquipeInvalido:
            "O convite não contém uma equipe válida do Papagaio."
        }
    }
}
