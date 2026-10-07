import CloudKit
import Foundation
import os
import PapagaioCore

/// O que mudou na zona de uma equipe desde o último marcador conhecido.
struct AlteracoesDeConversasCloudKit: Sendable {
    let registros: [Data]
    /// Nomes dos registros de conversa apagados no servidor.
    let removidos: [String]
    /// Ponto de continuação opaco: produção arquiva o `CKServerChangeToken`.
    let marcador: Data?
    let haMais: Bool
    /// Registros que o servidor devolveu mas não puderam ser lidos.
    var ignorados: Int = 0
}

struct PayloadDeConversaCloudKit: Codable, Sendable, Equatable {
    let versao: Int
    let atualizadoEm: Date
    let arquivo: Arquivo
    let midiaDisponivelNaOrigem: Bool?

    init(
        arquivo: Arquivo,
        atualizadoEm: Date,
        midiaDisponivelNaOrigem: Bool? = nil
    ) {
        versao = 2
        self.atualizadoEm = atualizadoEm
        self.arquivo = arquivo
        self.midiaDisponivelNaOrigem = midiaDisponivelNaOrigem
    }
}

struct ConversaRecebidaCloudKit: Sendable, Equatable {
    let arquivo: Arquivo
    let atualizadoEm: Date
    let midiaDisponivelNaOrigem: Bool
}

struct ConversasBaixadasCloudKit: Sendable, Equatable {
    let conversas: [ConversaRecebidaCloudKit]
    /// Conversas que alguém da equipe apagou definitivamente.
    let removidas: [ArquivoID]
    /// Guardar depois de aplicar tudo; a próxima baixa parte daqui.
    let marcador: Data?
}

enum PoliticaDeMidiaCloudKit {
    static func prepararParaEnvio(_ arquivo: Arquivo) -> Arquivo {
        var compartilhavel = arquivo
        compartilhavel.pastaRelativa = ""
        return compartilhavel
    }

    static func mesclar(
        remoto: Arquivo,
        local: Arquivo?,
        midiaLocalExiste: Bool
    ) -> Arquivo {
        guard let local, midiaLocalExiste, !local.pastaRelativa.isEmpty else {
            return remoto
        }
        var combinado = remoto
        combinado.pastaRelativa = local.pastaRelativa
        return combinado
    }
}

enum PoliticaDeConflitoCloudKit {
    enum Decisao: Equatable {
        case aplicarRemoto
        /// O remoto é um envio deste próprio Mac voltando pela zona. O banco
        /// local já tem esse conteúdo, ou um mais novo que ainda não subiu.
        case ignorarEco
        /// O remoto é mais antigo que a edição que ainda vai subir.
        case preservarLocalPendente
        /// Outra pessoa salvou depois da edição local que ainda vai subir. A
        /// cópia local continua valendo, mas a pessoa precisa saber.
        case conflito
    }

    static func decidir(
        revisaoRemota: Date,
        revisaoLocalPendente: Date?,
        revisoesEntreguesDaqui: Set<Date> = []
    ) -> Decisao {
        if revisaoRemota == revisaoLocalPendente || revisoesEntreguesDaqui.contains(revisaoRemota) {
            return .ignorarEco
        }
        guard let revisaoLocalPendente else { return .aplicarRemoto }
        return revisaoRemota > revisaoLocalPendente ? .conflito : .preservarLocalPendente
    }
}

/// Traduz erros de infraestrutura do CloudKit para uma ação possível no app.
///
/// Em especial, um participante não consegue criar tipos no esquema de
/// produção nem recriar a zona privada do proprietário. Essas condições não
/// melhoram ao repetir a mesma operação em segundo plano.
enum DiagnosticoDaSincronizacaoCloudKit {
    static func mensagem(para erro: any Error) -> String {
        mensagem(paraTexto: erro.localizedDescription)
    }

    static func mensagem(paraTexto texto: String) -> String {
        let normalizado = texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if normalizado.contains("cannot create new type conversa in production schema")
            || normalizado.contains("did not find record type: conversa") {
            return "A equipe foi aceita, mas o tipo de registro “Conversa” ainda não está publicado no CloudKit de produção. Peça ao proprietário da equipe para publicar o esquema no CloudKit Dashboard; suas alterações continuam neste Mac até isso acontecer.".localized
        }
        if normalizado.contains("cannot create new type equipeexcluida in production schema")
            || normalizado.contains("did not find record type: equipeexcluida") {
            return "A exclusão ainda não pode ser concluída porque o tipo público “EquipeExcluida” não está publicado no CloudKit de produção. No CloudKit Dashboard, publique esse tipo e os campos equipeID, excluidaEm e estadoDaExclusao; nenhum dado foi apagado.".localized
        }
        if normalizado.contains("nomesdosparticipantes")
            && (normalizado.contains("production schema") || normalizado.contains("field")) {
            return "Para salvar nomes da equipe, publique o campo “nomesDosParticipantes” (Bytes) no tipo Equipe do CloudKit Dashboard. O nome atual continua preservado neste Mac.".localized
        }
        if normalizado.contains("zone does not exist") {
            return "A zona compartilhada desta equipe ainda não está disponível nesta Apple Account. Peça ao proprietário para confirmar o compartilhamento e entre novamente com o código da equipe.".localized
        }
        if normalizado.contains("type is not marked indexable")
            && normalizado.contains("conversa") {
            return "A versão instalada ainda tenta consultar o tipo de registro “Conversa”, mas ele não está indexado no CloudKit. Atualize o Ōmu para a versão que sincroniza diretamente a zona compartilhada; suas alterações locais permanecem neste Mac.".localized
        }
        return texto
    }

    static func exigeAcaoDoProprietario(_ texto: String) -> Bool {
        let normalizado = texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalizado.contains("cannot create new type conversa in production schema")
            || normalizado.contains("did not find record type: conversa")
            || normalizado.contains("zone does not exist")
            || normalizado.contains("cannot create new type equipeexcluida in production schema")
    }
}

/// Limite testável entre regras de sincronização e as APIs concretas do
/// CloudKit. Nenhum double precisa construir `CKContainer` ou acessar iCloud.
protocol TransporteDeConversasCloudKit: Sendable {
    func salvar(_ dados: Data, id: String, equipe: EquipeDisponivel) async throws
    /// `marcador` nulo pede a zona inteira; nesse caso não há remoções a relatar.
    func alteracoes(
        da equipe: EquipeDisponivel,
        desde marcador: Data?
    ) async throws -> AlteracoesDeConversasCloudKit
    func remover(id: String, equipe: EquipeDisponivel) async throws
}

/// Implementação concreta do transporte. Todo acesso a `CKDatabase` fica
/// isolado neste ator; o sincronizador acima dele trabalha apenas com `Data`.
actor TransporteDeConversasCloudKitReal: TransporteDeConversasCloudKit {
    private enum Campo {
        static let dados = "dados"
        static let conteudo = "conteudo"
        static let titulo = "titulo"
        static let criadoEm = "criadoEm"
        static let atualizadoEm = "atualizadoEm"
        static let midiaDisponivelNaOrigem = "midiaDisponivelNaOrigem"
    }

    private static let tipoDeRegistro = "Conversa"
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func salvar(_ dados: Data, id: String, equipe: EquipeDisponivel) async throws {
        let banco = try bancoDaEquipe(equipe)
        let zona = try await zonaDaEquipe(equipe, no: banco)
        let recordID = CKRecord.ID(recordName: id, zoneID: zona)
        let registro = try await registroExistente(ouNovo: recordID, no: banco)
        let payload = try JSONDecoder().decode(PayloadDeConversaCloudKit.self, from: dados)
        let temporario = FileManager.default.temporaryDirectory
            .appendingPathComponent("papagaio-cloudkit-\(UUID().uuidString).json")
        try dados.write(to: temporario, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporario) }

        registro[Campo.conteudo] = CKAsset(fileURL: temporario)
        registro[Campo.dados] = nil
        registro[Campo.titulo] = payload.arquivo.titulo as NSString
        registro[Campo.criadoEm] = payload.arquivo.criadoEm as NSDate
        registro[Campo.atualizadoEm] = payload.atualizadoEm as NSDate
        registro[Campo.midiaDisponivelNaOrigem] = NSNumber(
            value: payload.midiaDisponivelNaOrigem ?? false
        )
        _ = try await banco.save(registro)
    }

    func alteracoes(
        da equipe: EquipeDisponivel,
        desde marcador: Data?
    ) async throws -> AlteracoesDeConversasCloudKit {
        let banco = try bancoDaEquipe(equipe)
        let zona = try await zonaDaEquipe(equipe, no: banco)
        // Um marcador ilegível vale como "nunca sincronizei": a zona inteira
        // é mais cara, mas nunca errada.
        let token = marcador.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }

        // A zona é lida pelas alterações, não por CKQuery: não depende de
        // índice no esquema e relata o que foi apagado. E é a API assíncrona
        // de propósito — uma `CKFetchRecordZoneChangesOperation` criada à mão
        // roda com prioridade padrão, que o sistema adia por tempo
        // indeterminado quando o Ōmu não é o app em primeiro plano. Durante
        // uma reunião, a baixa simplesmente não saía para a rede.
        let resultado: (
            modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
            deletions: [CKDatabase.RecordZoneChange.Deletion],
            changeToken: CKServerChangeToken,
            moreComing: Bool
        )
        do {
            resultado = try await banco.recordZoneChanges(inZoneWith: zona, since: token)
        } catch let erro as CKError where erro.code == .changeTokenExpired && token != nil {
            resultado = try await banco.recordZoneChanges(inZoneWith: zona, since: nil)
        }

        // A falha de um registro (ou de um anexo que não pôde ser lido) é
        // problema daquela conversa, não da equipe inteira: antes, uma
        // conversa problemática bloqueava o download de todas.
        var registros: [Data] = []
        var ignorados = 0
        for (id, item) in resultado.modificationResultsByID {
            do {
                if let dados = try Self.dados(de: item.get().record) {
                    registros.append(dados)
                }
            } catch {
                ignorados += 1
                Self.logger.error("registro \(id.recordName, privacy: .public) ignorado no download: \(error.localizedDescription, privacy: .public)")
            }
        }
        return AlteracoesDeConversasCloudKit(
            registros: registros,
            removidos: resultado.deletions
                .filter { $0.recordType == Self.tipoDeRegistro }
                .map(\.recordID.recordName),
            marcador: try NSKeyedArchiver.archivedData(
                withRootObject: resultado.changeToken,
                requiringSecureCoding: true
            ),
            haMais: resultado.moreComing,
            ignorados: ignorados
        )
    }

    func remover(id: String, equipe: EquipeDisponivel) async throws {
        let banco = try bancoDaEquipe(equipe)
        let zona = try await zonaDaEquipe(equipe, no: banco)
        try await LoteCloudKit.apagar([CKRecord.ID(recordName: id, zoneID: zona)], em: banco)
    }

    private static let logger = Logger(subsystem: "com.papagaio.Papagaio", category: "cloudkit")

    private static func dados(de registro: CKRecord) throws -> Data? {
        guard registro.recordType == tipoDeRegistro else { return nil }
        if let asset = registro[Campo.conteudo] as? CKAsset,
           let url = asset.fileURL {
            return try Data(contentsOf: url)
        }
        return registro[Campo.dados] as? Data
    }

    private func registroExistente(
        ouNovo id: CKRecord.ID,
        no banco: CKDatabase
    ) async throws -> CKRecord {
        do {
            return try await banco.record(for: id)
        } catch let erro as CKError where erro.code == .unknownItem {
            return CKRecord(recordType: Self.tipoDeRegistro, recordID: id)
        }
    }

    private func bancoDaEquipe(_ equipe: EquipeDisponivel) throws -> CKDatabase {
        guard let banco = equipe.bancoCloudKit.flatMap(BancoCloudKitDaEquipe.init(rawValue:)) else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        return switch banco {
        case .privado: container.privateCloudDatabase
        case .compartilhado: container.sharedCloudDatabase
        }
    }

    private func zonaDaEquipe(
        _ equipe: EquipeDisponivel,
        no banco: CKDatabase
    ) async throws -> CKRecordZone.ID {
        guard let nome = equipe.zonaCloudKit else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        if let dono = equipe.donoDaZonaCloudKit {
            return CKRecordZone.ID(zoneName: nome, ownerName: dono)
        }
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.compartilhado.rawValue else {
            return CKRecordZone.ID(zoneName: nome)
        }

        // Operações que ficaram na fila antes de guardarmos o ownerName ainda
        // carregam a equipe antiga. Recuperamos a zona real uma vez no iCloud
        // para que elas sejam enviadas, sem voltar a consultar __defaultOwner.
        let zonas = try await banco.allRecordZones()
        let correspondentes = zonas.filter { $0.zoneID.zoneName == nome }
        guard correspondentes.count == 1 else {
            throw ErroDeEquipeCloudKit.zonaCompartilhadaIndisponivel
        }
        return correspondentes[0].zoneID
    }
}

/// Espelha os dados textuais da conversa no workspace da equipe.
///
/// O áudio e anexos não entram aqui. O payload compartilhado leva metadados,
/// transcrição, notas e resumo; a mídia permanece local até existir uma
/// política explícita de `CKAsset`.
actor SincronizadorDaBibliotecaCloudKit {
    private let transporte: any TransporteDeConversasCloudKit
    private static let logger = Logger(subsystem: "com.papagaio.Papagaio", category: "cloudkit")
    /// Quantos registros o último download não conseguiu ler (payload de uma
    /// versão mais nova do app, conteúdo corrompido).
    private(set) var ignoradasNoUltimoDownload = 0

    init(
        container: CKContainer = CKContainer(
            identifier: ServicoDeEquipesCloudKit.identificadorDoContainer
        )
    ) {
        self.transporte = TransporteDeConversasCloudKitReal(container: container)
    }

    init(transporte: any TransporteDeConversasCloudKit) {
        self.transporte = transporte
    }

    func enviar(
        _ arquivo: Arquivo,
        para equipe: EquipeDisponivel,
        revisao: Date = Date()
    ) async throws {
        let compartilhavel = PoliticaDeMidiaCloudKit.prepararParaEnvio(arquivo)
        let dados = try JSONEncoder().encode(
            PayloadDeConversaCloudKit(
                arquivo: compartilhavel,
                atualizadoEm: revisao,
                midiaDisponivelNaOrigem: !arquivo.semAudio
            )
        )
        try await transporte.salvar(
            dados,
            id: arquivo.id.rawValue.uuidString,
            equipe: equipe
        )
    }

    func baixar(da equipe: EquipeDisponivel) async throws -> [Arquivo] {
        try await baixarComVersoes(da: equipe).map(\.arquivo)
    }

    func baixarComVersoes(
        da equipe: EquipeDisponivel
    ) async throws -> [ConversaRecebidaCloudKit] {
        try await baixarAlteracoes(da: equipe, desde: nil).conversas
    }

    /// Baixa o que mudou na zona desde `marcador`. Com `nil` devolve todas as
    /// conversas atuais e nenhuma remoção.
    func baixarAlteracoes(
        da equipe: EquipeDisponivel,
        desde marcador: Data?
    ) async throws -> ConversasBaixadasCloudKit {
        let espacoEsperado = try espacoDaEquipe(equipe)
        var marcadorAtual = marcador
        var conversas: [ConversaRecebidaCloudKit] = []
        var removidas: [ArquivoID] = []
        var haMais = true
        var ignoradas = 0

        while haMais {
            let lote = try await transporte.alteracoes(da: equipe, desde: marcadorAtual)
            ignoradas += lote.ignorados
            for dados in lote.registros {
                // Um payload que não decodifica (versão mais nova do app,
                // campo novo obrigatório) é pulado e registrado; as outras
                // conversas da equipe continuam chegando.
                let conversa: ConversaRecebidaCloudKit
                do {
                    conversa = try Self.decodificar(dados)
                } catch {
                    ignoradas += 1
                    Self.logger.error("conversa ilegível ignorada no download: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard conversa.arquivo.espaco == espacoEsperado else { continue }
                conversas.append(conversa)
            }
            removidas += lote.removidos.compactMap { UUID(uuidString: $0).map(ArquivoID.init(rawValue:)) }
            marcadorAtual = lote.marcador
            haMais = lote.haMais
        }

        // Se o mesmo ID vier como alterado e como removido, fica a versão
        // que mantém a conversa ativa.
        let presentes = Set(conversas.map(\.arquivo.id))
        ignoradasNoUltimoDownload = ignoradas
        return ConversasBaixadasCloudKit(
            conversas: conversas,
            removidas: removidas.filter { !presentes.contains($0) },
            // O marcador só avança quando tudo foi lido. Uma conversa pulada
            // não volta a aparecer numa baixa incremental; mantendo o ponto
            // anterior, a próxima baixa a recebe de novo.
            marcador: ignoradas == 0 ? marcadorAtual : marcador
        )
    }

    func remover(_ arquivo: Arquivo, da equipe: EquipeDisponivel) async throws {
        try await remover(id: arquivo.id, da: equipe)
    }

    func remover(id: ArquivoID, da equipe: EquipeDisponivel) async throws {
        try await transporte.remover(
            id: id.rawValue.uuidString,
            equipe: equipe
        )
    }

    private static func decodificar(_ dados: Data) throws -> ConversaRecebidaCloudKit {
        let decodificador = JSONDecoder()
        if let payload = try? decodificador.decode(PayloadDeConversaCloudKit.self, from: dados) {
            return ConversaRecebidaCloudKit(
                arquivo: PoliticaDeMidiaCloudKit.prepararParaEnvio(payload.arquivo),
                atualizadoEm: payload.atualizadoEm,
                midiaDisponivelNaOrigem: payload.midiaDisponivelNaOrigem ?? false
            )
        }
        let legado = try decodificador.decode(Arquivo.self, from: dados)
        return ConversaRecebidaCloudKit(
            arquivo: PoliticaDeMidiaCloudKit.prepararParaEnvio(legado),
            atualizadoEm: legado.entradaNaBiblioteca,
            midiaDisponivelNaOrigem: !legado.semAudio
        )
    }

    private func espacoDaEquipe(_ equipe: EquipeDisponivel) throws -> EspacoID {
        guard let texto = equipe.espacoID, let id = UUID(uuidString: texto) else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        return EspacoID(rawValue: id)
    }
}
