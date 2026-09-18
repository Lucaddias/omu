import CloudKit
import Foundation
import PapagaioCore

/// Cursor opaco: produção guarda `CKQueryOperation.Cursor`; testes usam um
/// marcador simples sem importar detalhes do transporte.
final class CursorDeConversasCloudKit: @unchecked Sendable {
    fileprivate let valor: Any

    init(_ valor: Any) {
        self.valor = valor
    }
}

struct PaginaDeConversasCloudKit: Sendable {
    let registros: [Data]
    let proxima: CursorDeConversasCloudKit?
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
        case preservarLocalPendente
    }

    static func decidir(
        revisaoRemota: Date,
        revisaoLocalPendente: Date?
    ) -> Decisao {
        guard let revisaoLocalPendente,
              revisaoLocalPendente != revisaoRemota
        else { return .aplicarRemoto }
        return .preservarLocalPendente
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
    func pagina(
        da equipe: EquipeDisponivel,
        continuando cursor: CursorDeConversasCloudKit?
    ) async throws -> PaginaDeConversasCloudKit
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
    private static let tamanhoDaPagina = 200
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

    func pagina(
        da equipe: EquipeDisponivel,
        continuando cursor: CursorDeConversasCloudKit?
    ) async throws -> PaginaDeConversasCloudKit {
        let banco = try bancoDaEquipe(equipe)
        let zona = try await zonaDaEquipe(equipe, no: banco)

        if let cursor {
            guard let paginaPendente = cursor.valor as? PaginaPendenteDeConversasCloudKit else {
                throw ErroDeEquipeCloudKit.cursorInvalido
            }
            return Self.pagina(de: paginaPendente.registros, aPartirDe: paginaPendente.proximoIndice)
        }

        // CKQuery exige que o tipo esteja marcado como indexável no schema de
        // produção. Como a equipe já identifica uma zona customizada única,
        // buscamos suas alterações diretamente: esse fluxo não depende de
        // índices e inclui a carga completa quando o token é nulo.
        let registros = try await registrosDaZona(zona, no: banco)
        return Self.pagina(de: try Self.dadosDosRegistros(registros), aPartirDe: 0)
    }

    func remover(id: String, equipe: EquipeDisponivel) async throws {
        let banco = try bancoDaEquipe(equipe)
        let zona = try await zonaDaEquipe(equipe, no: banco)
        let recordID = CKRecord.ID(recordName: id, zoneID: zona)
        _ = try await banco.modifyRecords(
            saving: [],
            deleting: [recordID],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
    }

    private static func dadosDosRegistros(_ registros: [CKRecord]) throws -> [Data] {
        try registros.compactMap { registro -> Data? in
            guard registro.recordType == tipoDeRegistro else { return nil }
            if let asset = registro[Campo.conteudo] as? CKAsset,
               let url = asset.fileURL {
                return try Data(contentsOf: url)
            }
            return registro[Campo.dados] as? Data
        }
    }

    private static func pagina(
        de registros: [Data],
        aPartirDe indice: Int
    ) -> PaginaDeConversasCloudKit {
        let limite = min(indice + tamanhoDaPagina, registros.count)
        let proxima = limite < registros.count
            ? CursorDeConversasCloudKit(
                PaginaPendenteDeConversasCloudKit(
                    registros: registros,
                    proximoIndice: limite
                )
            )
            : nil
        return PaginaDeConversasCloudKit(
            registros: Array(registros[indice..<limite]),
            proxima: proxima
        )
    }

    private func registrosDaZona(
        _ zona: CKRecordZone.ID,
        no banco: CKDatabase
    ) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let operacao = CKFetchRecordZoneChangesOperation()
            operacao.recordZoneIDs = [zona]
            operacao.fetchAllChanges = true

            var registros: [CKRecord] = []
            var erroPorRegistro: (any Error)?
            operacao.recordWasChangedBlock = { _, resultado in
                switch resultado {
                case let .success(registro):
                    registros.append(registro)
                case let .failure(erro):
                    erroPorRegistro = erro
                }
            }
            operacao.fetchRecordZoneChangesResultBlock = { resultado in
                if let erroPorRegistro {
                    continuation.resume(throwing: erroPorRegistro)
                } else if case let .failure(erro) = resultado {
                    continuation.resume(throwing: erro)
                } else {
                    continuation.resume(returning: registros)
                }
            }
            banco.add(operacao)
        }
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

private final class PaginaPendenteDeConversasCloudKit: @unchecked Sendable {
    let registros: [Data]
    let proximoIndice: Int

    init(registros: [Data], proximoIndice: Int) {
        self.registros = registros
        self.proximoIndice = proximoIndice
    }
}

/// Espelha os dados textuais da conversa no workspace da equipe.
///
/// O áudio e anexos não entram aqui. O payload compartilhado leva metadados,
/// transcrição, notas e resumo; a mídia permanece local até existir uma
/// política explícita de `CKAsset`.
actor SincronizadorDaBibliotecaCloudKit {
    private let transporte: any TransporteDeConversasCloudKit

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
        let espacoEsperado = try espacoDaEquipe(equipe)
        var cursor: CursorDeConversasCloudKit?
        var conversas: [ConversaRecebidaCloudKit] = []

        repeat {
            let pagina = try await transporte.pagina(da: equipe, continuando: cursor)
            for dados in pagina.registros {
                let conversa = try Self.decodificar(dados)
                let arquivo = conversa.arquivo
                guard arquivo.espaco == espacoEsperado else { continue }
                conversas.append(conversa)
            }
            cursor = pagina.proxima
        } while cursor != nil

        return conversas
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
