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
}

struct ResultadoDaFilaCloudKit: Sendable, Equatable {
    let concluidas: Int
    let pendentes: Int
    let erros: [String]
    let proximaTentativa: Date?
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

    init(url: URL, fm: FileManager = .default) {
        self.url = url
        self.fm = fm
        do {
            guard fm.fileExists(atPath: url.path) else {
                estadoInicial = .success([])
                return
            }
            let dados = try Data(contentsOf: url)
            estadoInicial = .success(
                try JSONDecoder().decode([OperacaoPendenteCloudKit].self, from: dados)
            )
        } catch {
            estadoInicial = .failure(error)
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
            ignorarBackoff || $0.proximaTentativa <= agora
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
            } catch {
                var atuais = try carregar()
                if let indice = atuais.firstIndex(where: { $0.id == operacao.id }) {
                    atuais[indice].tentativas = min(atuais[indice].tentativas + 1, 10)
                    atuais[indice].proximaTentativa = agora.addingTimeInterval(
                        Self.atraso(para: atuais[indice].tentativas)
                    )
                    try salvar(atuais)
                }
                erros.append(error.localizedDescription)
            }
        }

        let restantes = try carregar()
        return ResultadoDaFilaCloudKit(
            concluidas: concluidas,
            pendentes: restantes.count,
            erros: erros,
            proximaTentativa: restantes.map(\.proximaTentativa).min()
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
