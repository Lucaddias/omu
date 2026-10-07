import CloudKit
import Foundation
import PapagaioCore

struct OperacaoPendenteCloudKit: Codable, Equatable, Sendable, Identifiable {
    enum Acao: String, Codable, Sendable {
        case enviar
        case remover
    }

    let id: UUID
    let acao: Acao
    let arquivoID: ArquivoID
    let arquivo: Arquivo?
    let equipe: EquipeDisponivel
    let revisao: Date
    var tentativas: Int
    var proximaTentativa: Date
    /// Preenchido quando o iCloud recusou a operação por um motivo que
    /// repetir não resolve (sem permissão de escrita, cota cheia). Ela fica
    /// na fila — o conteúdo não se perde —, mas sai das tentativas
    /// automáticas; "Tentar de novo" na tela da equipe a reenvia.
    var bloqueadaPor: String?
}

struct ResultadoDaFilaCloudKit: Sendable, Equatable {
    let concluidas: Int
    let pendentes: Int
    let erros: [String]
    let proximaTentativa: Date?
    /// Das pendentes, quantas estão paradas à espera de uma ação da pessoa.
    var bloqueadas = 0
}

/// O que fazer com uma operação que o iCloud recusou.
enum DestinoDaFalhaCloudKit: Equatable {
    /// Rede, servidor ocupado, conflito: vale repetir com espera crescente.
    case tentarDeNovo
    /// O efeito desejado já é o estado do servidor (remover o que não existe).
    case jaConcluida
    /// Repetir não muda o resultado; é preciso alguém agir.
    case bloqueada

    static func classificar(
        _ erro: any Error,
        acao: OperacaoPendenteCloudKit.Acao
    ) -> DestinoDaFalhaCloudKit {
        guard let erro = erro as? CKError else { return .tentarDeNovo }
        return classificar(codigos: codigos(de: erro), acao: acao)
    }

    /// Separada do `CKError` para ser testável sem montar erros do CloudKit.
    static func classificar(
        codigos: [CKError.Code],
        acao: OperacaoPendenteCloudKit.Acao
    ) -> DestinoDaFalhaCloudKit {
        guard !codigos.isEmpty else { return .tentarDeNovo }
        let ausencias: Set<CKError.Code> = [.unknownItem, .zoneNotFound, .userDeletedZone]
        if acao == .remover, codigos.allSatisfy(ausencias.contains) {
            return .jaConcluida
        }
        let semSaida: Set<CKError.Code> = [.permissionFailure, .quotaExceeded]
        return codigos.contains(where: semSaida.contains) ? .bloqueada : .tentarDeNovo
    }

    /// Uma falha parcial carrega o motivo real dentro, por item.
    private static func codigos(de erro: CKError) -> [CKError.Code] {
        guard erro.code == .partialFailure,
              let porItem = erro.partialErrorsByItemID, !porItem.isEmpty
        else { return [erro.code] }
        return porItem.values.compactMap { ($0 as? CKError)?.code }
    }
}

/// Outbox durável para alterações do workspace. A operação entra no arquivo
/// antes da chamada de rede; assim, encerrar o app no meio de uma falha não
/// transforma uma edição local numa promessa impossível de retomar.
actor FilaPersistenteCloudKit {
    private let url: URL
    private let fm: FileManager
    private var estadoInicial: Result<[OperacaoPendenteCloudKit], any Error>
    private var processando = false
    private var esperas: [CheckedContinuation<Void, Never>] = []
    private var operacoesCarregadas: [OperacaoPendenteCloudKit]?
    /// Cópia do arquivo da fila que não pôde ser lido por inteiro, se houve.
    nonisolated let quarentena: URL?

    /// Revisões que este Mac entregou ao servidor nesta execução, por equipe
    /// e conversa. A zona devolve o próprio envio como alteração na baixa
    /// seguinte; sem este registro o eco seria aplicado por cima do banco
    /// local, que nesse meio-tempo pode ter avançado.
    private var revisoesEntregues: [String: [ArquivoID: Set<Date>]] = [:]

    init(url: URL, fm: FileManager = .default) {
        self.url = url
        self.fm = fm
        guard fm.fileExists(atPath: url.path) else {
            estadoInicial = .success([])
            quarentena = nil
            return
        }
        do {
            let dados = try Data(contentsOf: url)
            do {
                estadoInicial = .success(
                    try JSONDecoder().decode([OperacaoPendenteCloudKit].self, from: dados)
                )
                quarentena = nil
            } catch {
                // Arquivo truncado, ou gravado por uma versão com campos que
                // esta não conhece. Antes isso virava falha permanente: todo
                // agendamento e todo processamento passavam a lançar, para
                // sempre. O original vai para a quarentena e a fila segue com
                // as operações que ainda dá para ler.
                let destino = url.deletingPathExtension()
                    .appendingPathExtension("ilegivel-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: url, to: destino)
                quarentena = destino
                let legiveis = (try? JSONDecoder().decode([Tolerante].self, from: dados))?
                    .compactMap(\.operacao) ?? []
                estadoInicial = .success(legiveis)
            }
        } catch {
            // Nem ler o arquivo foi possível (permissão, disco): isso pode
            // ser passageiro, então o erro continua sendo relatado.
            estadoInicial = .failure(error)
            quarentena = nil
        }
    }

    /// Decodifica um item da fila sem derrubar os vizinhos.
    private struct Tolerante: Decodable {
        let operacao: OperacaoPendenteCloudKit?

        init(from decoder: any Decoder) throws {
            operacao = try? OperacaoPendenteCloudKit(from: decoder)
        }
    }

    func agendarEnvio(
        _ arquivo: Arquivo,
        para equipe: EquipeDisponivel,
        revisao: Date = Date()
    ) throws {
        var operacoes = try carregar()
        operacoes.removeAll {
            $0.equipe.id == equipe.id && $0.arquivoID == arquivo.id
        }
        operacoes.append(
            OperacaoPendenteCloudKit(
                id: UUID(),
                acao: .enviar,
                arquivoID: arquivo.id,
                arquivo: arquivo,
                equipe: equipe,
                revisao: revisao,
                tentativas: 0,
                proximaTentativa: revisao
            )
        )
        try salvar(operacoes)
    }

    func agendarRemocao(
        _ arquivoID: ArquivoID,
        da equipe: EquipeDisponivel,
        revisao: Date = Date()
    ) throws {
        var operacoes = try carregar()
        operacoes.removeAll {
            $0.equipe.id == equipe.id && $0.arquivoID == arquivoID
        }
        operacoes.append(
            OperacaoPendenteCloudKit(
                id: UUID(),
                acao: .remover,
                arquivoID: arquivoID,
                arquivo: nil,
                equipe: equipe,
                revisao: revisao,
                tentativas: 0,
                proximaTentativa: revisao
            )
        )
        try salvar(operacoes)
    }

    func processar(
        com sincronizador: SincronizadorDaBibliotecaCloudKit,
        agora: Date = Date(),
        ignorarBackoff: Bool = false
    ) async throws -> ResultadoDaFilaCloudKit {
        // Actors são reentrantes durante a rede: serialize os consumidores,
        // mas deixe agendar/descartar disponíveis enquanto um envio aguarda.
        if processando {
            await withCheckedContinuation { esperas.append($0) }
        } else {
            processando = true
        }
        defer {
            if esperas.isEmpty { processando = false }
            else { esperas.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let elegiveis = try carregar().filter {
            ignorarBackoff || ($0.bloqueadaPor == nil && $0.proximaTentativa <= agora)
        }
        var concluidas = 0
        var erros: [String] = []

        for operacao in elegiveis {
            try Task.checkCancellation()
            // Outra edição pode ter substituído esta revisão durante o envio
            // anterior; snapshots não dão autoridade para enviar dados antigos.
            guard try carregar().contains(where: { $0.id == operacao.id }) else { continue }
            do {
                switch operacao.acao {
                case .enviar:
                    guard let arquivo = operacao.arquivo else {
                        throw ErroDaFilaCloudKit.payloadAusente
                    }
                    try await sincronizador.enviar(
                        arquivo,
                        para: operacao.equipe,
                        revisao: operacao.revisao
                    )
                    revisoesEntregues[operacao.equipe.id, default: [:]][operacao.arquivoID, default: []]
                        .insert(operacao.revisao)
                case .remover:
                    try await sincronizador.remover(
                        id: operacao.arquivoID,
                        da: operacao.equipe
                    )
                }
                var atuais = try carregar()
                atuais.removeAll { $0.id == operacao.id }
                try salvar(atuais)
                concluidas += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var atuais = try carregar()
                switch DestinoDaFalhaCloudKit.classificar(error, acao: operacao.acao) {
                case .jaConcluida:
                    // Remover o que já não existe é sucesso, não falha a
                    // repetir para sempre.
                    atuais.removeAll { $0.id == operacao.id }
                    try salvar(atuais)
                    concluidas += 1
                    continue
                case .bloqueada:
                    if let indice = atuais.firstIndex(where: { $0.id == operacao.id }) {
                        atuais[indice].tentativas = min(atuais[indice].tentativas + 1, 10)
                        atuais[indice].bloqueadaPor = error.localizedDescription
                        try salvar(atuais)
                    }
                case .tentarDeNovo:
                    if let indice = atuais.firstIndex(where: { $0.id == operacao.id }) {
                        atuais[indice].tentativas = min(atuais[indice].tentativas + 1, 10)
                        atuais[indice].bloqueadaPor = nil
                        atuais[indice].proximaTentativa = agora.addingTimeInterval(
                            Self.atraso(para: atuais[indice].tentativas)
                        )
                        try salvar(atuais)
                    }
                }
                erros.append(error.localizedDescription)
            }
        }

        let restantes = try carregar()
        return ResultadoDaFilaCloudKit(
            concluidas: concluidas,
            pendentes: restantes.count,
            erros: erros,
            // As bloqueadas não marcam hora: não há tentativa automática
            // para elas.
            proximaTentativa: restantes.filter { $0.bloqueadaPor == nil }.map(\.proximaTentativa).min(),
            bloqueadas: restantes.filter { $0.bloqueadaPor != nil }.count
        )
    }

    func operacoesPendentes() throws -> [OperacaoPendenteCloudKit] {
        try carregar()
    }

    /// Uma zona apagada não pode continuar recebendo retentativas. Além de
    /// reter conteúdo que o proprietário excluiu, uma fila sobrevivente faria
    /// a interface informar falhas recorrentes sem nenhuma ação útil.
    func descartarOperacoes(daEquipeComID equipeID: String) throws {
        var operacoes = try carregar()
        operacoes.removeAll { $0.equipe.id == equipeID }
        try salvar(operacoes)
    }

    func revisoesLocaisPendentes(equipeID: String) throws -> [ArquivoID: Date] {
        var revisoes: [ArquivoID: Date] = [:]
        for operacao in try carregar()
        where operacao.equipe.id == equipeID && operacao.acao == .enviar {
            revisoes[operacao.arquivoID] = max(
                revisoes[operacao.arquivoID] ?? .distantPast,
                operacao.revisao
            )
        }
        return revisoes
    }

    func revisoesEntregues(equipeID: String) -> [ArquivoID: Set<Date>] {
        revisoesEntregues[equipeID] ?? [:]
    }

    nonisolated static func atraso(para tentativa: Int) -> TimeInterval {
        let expoente = max(0, min(tentativa - 1, 8))
        return min(5 * pow(2, Double(expoente)), 15 * 60)
    }

    private func carregar() throws -> [OperacaoPendenteCloudKit] {
        if let operacoesCarregadas { return operacoesCarregadas }
        let operacoes = try estadoInicial.get()
        operacoesCarregadas = operacoes
        return operacoes
    }

    private func salvar(_ operacoes: [OperacaoPendenteCloudKit]) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dados = try JSONEncoder().encode(operacoes)
        try dados.write(to: url, options: .atomic)
        operacoesCarregadas = operacoes
        estadoInicial = .success(operacoes)
    }
}

enum ErroDaFilaCloudKit: LocalizedError {
    case payloadAusente

    var errorDescription: String? {
        switch self {
        case .payloadAusente:
            "Uma operação pendente do iCloud não contém a conversa esperada.".localized
        }
    }
}
