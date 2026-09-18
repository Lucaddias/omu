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
        static let espacoID = "espacoID"
        static let codigoDeEntrada = "codigoDeEntrada"
        static let configuracoes = "configuracoes"
        static let nomesDosParticipantes = "nomesDosParticipantes"
        static let urlDoCompartilhamento = "urlDoCompartilhamento"
        static let equipeID = "equipeID"
        static let excluidaEm = "excluidaEm"
        static let estadoDaExclusao = "estadoDaExclusao"
    }

    private enum TipoDeRegistro {
        static let equipe = "Equipe"
        static let codigoDeEquipe = "CodigoDeEquipe"
        /// Marcador fora da zona. A zona é apagada na exclusão, por isso não
        /// pode carregar o sinal que manda os demais Macs limparem o cache.
        static let equipeExcluida = "EquipeExcluida"
    }

    private let container: CKContainer

    private enum EstadoDoMarcadorDeExclusao: String {
        case preparando
        case concluida
    }

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.papagaio.Papagaio")) {
        self.container = container
    }

    /// Cria o workspace e o compartilhamento da zona de uma equipe nova.
    ///
    /// O código de entrada resolve o link do compartilhamento e concede acesso
    /// de edição à zona inteira para a Apple Account que o informar no Ōmu.
    func criarWorkspace(para equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()

        let zonaID = CKRecordZone.ID(
            zoneName: Self.nomeDaZona(para: equipe.id)
        )
        let banco = container.privateCloudDatabase
        _ = try await banco.save(CKRecordZone(zoneID: zonaID))

        let espacoID = UUID(uuidString: equipe.espacoID ?? "") ?? UUID()
        let registro = registroDaEquipe(equipe, espacoID: espacoID, na: zonaID)
        let compartilhamento = CKShare(recordZoneID: zonaID)
        compartilhamento[CKShare.SystemFieldKey.title] = equipe.nome as NSString
        compartilhamento.publicPermission = Self.permissaoDaEntradaPorCodigo

        _ = try await banco.modifyRecords(
            saving: [registro, compartilhamento],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )

        guard let url = compartilhamento.url else {
            throw ErroDeEquipeCloudKit.conviteIndisponivel
        }
        try await publicarCodigo(equipe.codigoDeEntrada, para: url)

        return EquipeDisponivel(
            id: equipe.id,
            nome: equipe.nome,
            papel: equipe.papel,
            quantidadeDeMembros: equipe.quantidadeDeMembros,
            espacoID: espacoID.uuidString,
            zonaCloudKit: zonaID.zoneName,
            donoDaZonaCloudKit: zonaID.ownerName,
            compartilhamentoCloudKit: compartilhamento.recordID.recordName,
            bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue,
            codigoDeEntrada: equipe.codigoDeEntrada,
            configuracoes: equipe.configuracoes
        )
    }

    /// Resolve o código informado e aceita a zona compartilhada da equipe.
    func entrarNaEquipe(com codigo: String) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        let codigoNormalizado = Self.normalizar(codigo)
        let consulta = CKQuery(
            recordType: TipoDeRegistro.codigoDeEquipe,
            predicate: NSPredicate(format: "%K == %@", Campo.codigoDeEntrada, codigoNormalizado)
        )
        let resultado = try await container.publicCloudDatabase.records(matching: consulta)
        guard let registro = try resultado.matchResults.first?.1.get(),
              let textoDaURL = registro[Campo.urlDoCompartilhamento] as? String,
              let url = URL(string: textoDaURL) else {
            throw ErroDeEquipeCloudKit.codigoInvalido
        }
        let metadados = try await container.shareMetadata(for: url)
        return try await aceitar(metadados)
    }

    /// Completa equipes aceitas por versões que ainda guardavam só o nome da
    /// zona. Isso recupera o dono real no banco compartilhado e permite que a
    /// referência seja persistida novamente pelo chamador.
    func completarReferenciaDaZonaCompartilhada(
        da equipe: EquipeDisponivel
    ) async throws -> EquipeDisponivel {
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.compartilhado.rawValue,
              equipe.donoDaZonaCloudKit == nil,
              let nomeDaZona = equipe.zonaCloudKit
        else { return equipe }

        try await garantirContaICloudDisponivel()
        let zonas = try await container.sharedCloudDatabase.allRecordZones()
        let correspondentes = zonas.filter { $0.zoneID.zoneName == nomeDaZona }
        guard correspondentes.count == 1 else {
            throw ErroDeEquipeCloudKit.zonaCompartilhadaIndisponivel
        }

        var corrigida = equipe
        corrigida.donoDaZonaCloudKit = correspondentes[0].zoneID.ownerName
        return corrigida
    }

    /// Somente a conta proprietária altera as preferências compartilhadas.
    func atualizarConfiguracoes(_ configuracoes: ConfiguracoesDaEquipe, da equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let id = CKRecord.ID(recordName: "equipe", zoneID: zona)
        let registro = try await container.privateCloudDatabase.record(for: id)
        registro[Campo.configuracoes] = try JSONEncoder().encode(configuracoes) as NSData
        _ = try await container.privateCloudDatabase.save(registro)
    }

    /// Lê o `CKShare` real. A identidade retornada é a que o CloudKit permite
    /// mostrar; e-mail não é um dado disponível para o app nesse fluxo.
    func participantes(da equipe: EquipeDisponivel) async throws -> [ParticipanteDaEquipe] {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let compartilhamento = try await compartilhamento(da: equipe)
        let idAtual = try await container.userRecordID().recordName
        let nomes = try await nomesDosParticipantes(da: equipe, no: container.privateCloudDatabase)
        return Self.participantes(no: compartilhamento, nomes: nomes, idAtual: idAtual)
    }

    /// Participantes não têm permissão para enumerar os demais membros do
    /// share. Ainda assim recebem a própria linha, para editar somente o
    /// nome que o grupo exibe para a Apple Account atual.
    func meuParticipante(
        da equipe: EquipeDisponivel,
        nomePadrao: String
    ) async throws -> ParticipanteDaEquipe {
        try await garantirContaICloudDisponivel()
        let idAtual = try await container.userRecordID().recordName
        let zona = try referenciaDaZona(de: equipe)
        let registro = try await container.sharedCloudDatabase.record(
            for: CKRecord.ID(recordName: "equipe", zoneID: zona)
        )
        let nomes = Self.nomes(no: registro)
        return ParticipanteDaEquipe(
            id: idAtual,
            nome: nomes[idAtual] ?? Self.nomeLimpo(nomePadrao, fallback: "Meu perfil".localized),
            eProprietario: false,
            eAtual: true,
            permissao: .escrita
        )
    }

    /// O proprietário pode nomear qualquer participante; os demais só podem
    /// alterar a identidade que representa a própria Apple Account.
    func atualizarNome(
        de participanteID: String,
        para nome: String,
        na equipe: EquipeDisponivel
    ) async throws {
        try await garantirContaICloudDisponivel()
        let nomeLimpo = Self.nomeLimpo(nome, fallback: "")
        guard !nomeLimpo.isEmpty else { throw ErroDeEquipeCloudKit.nomeInvalido }
        let idAtual = try await container.userRecordID().recordName
        let zona = try referenciaDaZona(de: equipe)
        let banco: CKDatabase

        if equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue {
            // A zona privada só é acessível à conta proprietária; não
            // dependemos de `userIdentity` do CKShare, que pode vir omitida.
            banco = container.privateCloudDatabase
        } else {
            guard participanteID == idAtual else { throw ErroDeEquipeCloudKit.apenasProprioNome }
            banco = container.sharedCloudDatabase
        }

        let id = CKRecord.ID(recordName: "equipe", zoneID: zona)
        let registro = try await banco.record(for: id)
        var nomes = Self.nomes(no: registro)
        nomes[participanteID] = nomeLimpo
        registro[Campo.nomesDosParticipantes] = try JSONEncoder().encode(nomes) as NSData
        _ = try await banco.modifyRecords(
            saving: [registro], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
    }

    /// Atualiza a permissão de uma Apple Account já aceita na equipe.
    func atualizarPermissao(
        do participanteID: String,
        para permissao: ParticipanteDaEquipe.Permissao,
        na equipe: EquipeDisponivel
    ) async throws {
        let compartilhamento = try await compartilhamento(da: equipe)
        guard let participante = compartilhamento.participants.first(where: {
            Self.idDoParticipante($0) == participanteID
        }) else {
            throw ErroDeEquipeCloudKit.membroNaoEncontrado
        }
        participante.permission = permissao == .leitura ? .readOnly : .readWrite
        _ = try await container.privateCloudDatabase.save(compartilhamento)
    }

    /// Revoga o acesso de uma Apple Account aceita. O proprietário nunca é
    /// incluído em `participants`, mas a defesa existe para evitar regressões.
    func removerParticipante(_ participanteID: String, da equipe: EquipeDisponivel) async throws {
        let compartilhamento = try await compartilhamento(da: equipe)
        guard let participante = compartilhamento.participants.first(where: {
            Self.idDoParticipante($0) == participanteID
        }) else {
            throw ErroDeEquipeCloudKit.membroNaoEncontrado
        }
        compartilhamento.removeParticipant(participante)
        _ = try await container.privateCloudDatabase.save(compartilhamento)
    }

    /// Trocar um código precisa trocar o `CKShare`, não só o registro público:
    /// um URL de share antigo continuaria concedendo acesso. Por consequência,
    /// pessoas já aceitas precisam entrar novamente com o novo código.
    func rotacionarCodigo(da equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let antigo = try await compartilhamento(da: equipe)
        let novo = CKShare(recordZoneID: zona)
        novo[CKShare.SystemFieldKey.title] = equipe.nome as NSString
        novo.publicPermission = Self.permissaoDaEntradaPorCodigo

        // Remover o share anterior é o ponto que invalida o URL antigo e os
        // participantes existentes. Só então a nova URL pode ser publicada.
        _ = try await container.privateCloudDatabase.modifyRecords(
            saving: [novo],
            deleting: [antigo.recordID],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let url = novo.url else { throw ErroDeEquipeCloudKit.conviteIndisponivel }
        let novoCodigo = EquipeDisponivel.novoCodigoDeEntrada()
        try await invalidarCodigoAnterior(equipe.codigoDeEntrada)
        try await publicarCodigo(novoCodigo, para: url)

        var atualizada = equipe
        atualizada.codigoDeEntrada = novoCodigo
        atualizada.compartilhamentoCloudKit = novo.recordID.recordName
        atualizada.quantidadeDeMembros = 1
        return atualizada
    }

    /// Exclusão global é uma operação do proprietário. O marcador passa por
    /// `preparando` antes de apagar a zona e só vira `concluida` depois: não
    /// podemos atomizar escrita pública e remoção de zona privada, portanto
    /// outros Macs só limpam conteúdo após a confirmação remota final.
    func excluirEquipeGlobalmente(_ equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let marcador = CKRecord(
            recordType: TipoDeRegistro.equipeExcluida,
            recordID: Self.idDoMarcadorDeExclusao(para: equipe.id)
        )
        marcador[Campo.equipeID] = equipe.id as NSString
        marcador[Campo.excluidaEm] = Date() as NSDate
        marcador[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.preparando.rawValue as NSString
        _ = try await container.publicCloudDatabase.save(marcador)
        try await invalidarCodigoAnterior(equipe.codigoDeEntrada)
        do {
            try await container.privateCloudDatabase.deleteRecordZone(withID: try referenciaDaZona(de: equipe))
        } catch let erro as CKError where erro.code == .unknownItem {
            // Repetir a confirmação depois de uma queda entre as duas bases
            // é seguro: a zona já saiu, falta só tornar o marcador visível.
        }
        marcador[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.concluida.rawValue as NSString
        _ = try await container.publicCloudDatabase.save(marcador)
    }

    /// Chamado por cada instalação antes de voltar a usar uma equipe salva.
    /// O resultado positivo é definitivo: a cópia local daquela equipe deve
    /// sair inclusive da lixeira e do disco.
    func equipeFoiExcluida(_ equipe: EquipeDisponivel) async throws -> Bool {
        do {
            let marcador = try await container.publicCloudDatabase.record(
                for: Self.idDoMarcadorDeExclusao(para: equipe.id)
            )
            return (marcador[Campo.estadoDaExclusao] as? String)
                == EstadoDoMarcadorDeExclusao.concluida.rawValue
        } catch let erro as CKError where erro.code == .unknownItem {
            return false
        }
    }

    /// Converte uma equipe criada antes da entrada por código. A ação é do
    /// proprietário porque muda quem pode entrar na zona compartilhada.
    func ativarEntradaPorCodigo(na equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }

        let zona = try referenciaDaZona(de: equipe)
        let id = try idDoCompartilhamento(de: equipe, na: zona)
        guard let compartilhamento = try await container.privateCloudDatabase.record(for: id) as? CKShare else {
            throw ErroDeEquipeCloudKit.compartilhamentoInvalido
        }
        compartilhamento.publicPermission = Self.permissaoDaEntradaPorCodigo
        _ = try await container.privateCloudDatabase.save(compartilhamento)
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
            let nome = registro[Campo.nome] as? String,
            let espacoID = registro[Campo.espacoID] as? String,
            UUID(uuidString: espacoID) != nil
        else {
            throw ErroDeEquipeCloudKit.registroDaEquipeInvalido
        }

        return EquipeDisponivel(
            id: id,
            nome: nome,
            papel: "Membro",
            // O compartilhamento devolvido pelo CloudKit contém as pessoas
            // que já aceitaram o convite. A versão anterior gravava zero de
            // propósito, embora esta conta já fosse participante.
            quantidadeDeMembros: compartilhamento.participants.count,
            espacoID: espacoID,
            zonaCloudKit: zonaID.zoneName,
            donoDaZonaCloudKit: zonaID.ownerName,
            compartilhamentoCloudKit: compartilhamento.recordID.recordName,
            bancoCloudKit: BancoCloudKitDaEquipe.compartilhado.rawValue,
            codigoDeEntrada: registro[Campo.codigoDeEntrada] as? String,
            configuracoes: configuracoes(no: registro)
        )
    }

    nonisolated static func nomeDaZona(para equipeID: String) -> String {
        "equipe.\(equipeID)"
    }

    nonisolated static func normalizar(_ codigo: String) -> String {
        codigo.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Quem possuir o código pode entrar e sincronizar alterações. O código
    /// precisa ser tratado como uma chave de acesso pela equipe.
    nonisolated static var permissaoDaEntradaPorCodigo: CKShare.ParticipantPermission {
        .readWrite
    }

    private func garantirContaICloudDisponivel() async throws {
        guard try await container.accountStatus() == .available else {
            throw ErroDeEquipeCloudKit.contaICloudIndisponivel
        }
    }

    private func registroDaEquipe(
        _ equipe: EquipeDisponivel,
        espacoID: UUID,
        na zonaID: CKRecordZone.ID
    ) -> CKRecord {
        let registro = CKRecord(
            recordType: TipoDeRegistro.equipe,
            recordID: CKRecord.ID(recordName: "equipe", zoneID: zonaID)
        )
        registro[Campo.id] = equipe.id as NSString
        registro[Campo.nome] = equipe.nome as NSString
        registro[Campo.espacoID] = espacoID.uuidString as NSString
        registro[Campo.codigoDeEntrada] = equipe.codigoDeEntrada.map(Self.normalizar) as NSString?
        registro[Campo.configuracoes] = (try? JSONEncoder().encode(equipe.configuracoes)) as NSData?
        return registro
    }

    private func publicarCodigo(_ codigo: String?, para url: URL) async throws {
        guard let codigo else { throw ErroDeEquipeCloudKit.codigoInvalido }
        let registro = CKRecord(recordType: TipoDeRegistro.codigoDeEquipe)
        registro[Campo.codigoDeEntrada] = Self.normalizar(codigo) as NSString
        registro[Campo.urlDoCompartilhamento] = url.absoluteString as NSString
        _ = try await container.publicCloudDatabase.save(registro)
    }

    private func invalidarCodigoAnterior(_ codigo: String?) async throws {
        guard let codigo else { return }
        let consulta = CKQuery(
            recordType: TipoDeRegistro.codigoDeEquipe,
            predicate: NSPredicate(format: "%K == %@", Campo.codigoDeEntrada, Self.normalizar(codigo))
        )
        let resultado = try await container.publicCloudDatabase.records(matching: consulta)
        let ids = resultado.matchResults.compactMap { chave, valor -> CKRecord.ID? in
            guard (try? valor.get()) != nil else { return nil }
            return chave
        }
        guard !ids.isEmpty else { return }
        _ = try await container.publicCloudDatabase.modifyRecords(
            saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: true
        )
    }

    private func compartilhamento(da equipe: EquipeDisponivel) async throws -> CKShare {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let id = try idDoCompartilhamento(de: equipe, na: zona)
        guard let compartilhamento = try await container.privateCloudDatabase.record(for: id) as? CKShare else {
            throw ErroDeEquipeCloudKit.compartilhamentoInvalido
        }
        return compartilhamento
    }

    private nonisolated static func participantes(
        no compartilhamento: CKShare,
        nomes: [String: String],
        idAtual: String
    ) -> [ParticipanteDaEquipe] {
        let dono = ParticipanteDaEquipe(
            id: idDoParticipante(compartilhamento.owner),
            nome: nomeDoParticipante(
                compartilhamento.owner,
                nomes: nomes,
                fallback: "Proprietário".localized
            ),
            eProprietario: true,
            eAtual: idDoParticipante(compartilhamento.owner) == idAtual,
            permissao: .escrita
        )
        let aceitos = compartilhamento.participants.compactMap { participante -> ParticipanteDaEquipe? in
            // O CloudKit pode repetir o proprietário em `participants`. A
            // role é a fonte de verdade, e a comparação pelo ID protege SDKs
            // que tenham omitido a role em metadados antigos.
            guard participante.role != .owner,
                  idDoParticipante(participante) != dono.id else { return nil }
            return ParticipanteDaEquipe(
                id: idDoParticipante(participante),
                nome: nomeDoParticipante(participante, nomes: nomes, fallback: "Membro da equipe".localized),
                eProprietario: false,
                eAtual: idDoParticipante(participante) == idAtual,
                permissao: participante.permission == .readOnly ? .leitura : .escrita
            )
        }
        return [dono] + aceitos.sorted { $0.nome.localizedStandardCompare($1.nome) == .orderedAscending }
    }

    private nonisolated static func idDoParticipante(_ participante: CKShare.Participant) -> String {
        participante.userIdentity.userRecordID?.recordName
            ?? participante.userIdentity.lookupInfo?.emailAddress
            ?? UUID().uuidString
    }

    private nonisolated static func nomeDoParticipante(
        _ participante: CKShare.Participant,
        nomes: [String: String],
        fallback: String
    ) -> String {
        nomes[idDoParticipante(participante)]
            ?? participante.userIdentity.nameComponents?.formatted(.name(style: .medium))
            ?? fallback
    }

    private func nomesDosParticipantes(
        da equipe: EquipeDisponivel,
        no banco: CKDatabase
    ) async throws -> [String: String] {
        let zona = try referenciaDaZona(de: equipe)
        let registro = try await banco.record(for: CKRecord.ID(recordName: "equipe", zoneID: zona))
        return Self.nomes(no: registro)
    }

    private nonisolated static func nomes(no registro: CKRecord) -> [String: String] {
        guard let dados = registro[Campo.nomesDosParticipantes] as? Data,
              let nomes = try? JSONDecoder().decode([String: String].self, from: dados)
        else { return [:] }
        return nomes
    }

    private nonisolated static func nomeLimpo(_ nome: String, fallback: String) -> String {
        let limpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? fallback : limpo
    }

    private nonisolated static func idDoMarcadorDeExclusao(para equipeID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "equipe-excluida.\(equipeID)")
    }

    private func configuracoes(no registro: CKRecord) -> ConfiguracoesDaEquipe {
        guard let dados = registro[Campo.configuracoes] as? Data,
              let configuracoes = try? JSONDecoder().decode(ConfiguracoesDaEquipe.self, from: dados)
        else { return .init() }
        return configuracoes
    }

    private func referenciaDaZona(de equipe: EquipeDisponivel) throws -> CKRecordZone.ID {
        guard let zona = equipe.zonaCloudKit
        else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        if let dono = equipe.donoDaZonaCloudKit {
            return CKRecordZone.ID(zoneName: zona, ownerName: dono)
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

enum BancoCloudKitDaEquipe: String {
    case privado
    case compartilhado
}

enum ErroDeEquipeCloudKit: LocalizedError {
    case contaICloudIndisponivel
    case equipeAindaLocal
    case registroDaEquipeInvalido
    case codigoInvalido
    case conviteIndisponivel
    case apenasAdministrador
    case compartilhamentoInvalido
    case cursorInvalido
    case zonaCompartilhadaIndisponivel
    case membroNaoEncontrado
    case proprietarioNaoPodeSerAlterado
    case proprietarioNaoPodeSerRemovido
    case nomeInvalido
    case apenasProprioNome

    var errorDescription: String? {
        switch self {
        case .contaICloudIndisponivel:
            "Entre no iCloud neste Mac para usar equipes compartilhadas.".localized
        case .equipeAindaLocal:
            "Esta equipe ainda não foi publicada no CloudKit.".localized
        case .registroDaEquipeInvalido:
            "O convite não contém uma equipe válida do Ōmu.".localized
        case .zonaCompartilhadaIndisponivel:
            "Não encontrei a zona compartilhada desta equipe no iCloud. Entre novamente com o código da equipe.".localized
        case .codigoInvalido:
            "Não encontramos uma equipe com esse código.".localized
        case .conviteIndisponivel:
            "Não foi possível preparar o convite desta equipe.".localized
        case .apenasAdministrador:
            "Somente quem criou a equipe pode alterar estas configurações.".localized
        case .compartilhamentoInvalido:
            "O compartilhamento desta equipe não é válido.".localized
        case .cursorInvalido:
            "Não foi possível continuar a paginação do espaço compartilhado.".localized
        case .membroNaoEncontrado:
            "Esse membro não faz mais parte do compartilhamento.".localized
        case .proprietarioNaoPodeSerAlterado:
            "A permissão do proprietário da equipe não pode ser alterada.".localized
        case .proprietarioNaoPodeSerRemovido:
            "O proprietário da equipe não pode ser removido.".localized
        case .nomeInvalido:
            "Informe um nome para mostrar na equipe.".localized
        case .apenasProprioNome:
            "Você só pode alterar o próprio nome nesta equipe.".localized
        }
    }
}
