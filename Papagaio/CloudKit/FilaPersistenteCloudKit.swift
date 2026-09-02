import Foundation
import os
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

/// Relato de uma abertura da fila em que parte do arquivo não pôde ser lida.
///
/// A fila não bloqueia por causa disso — mas o usuário precisa saber que
/// envios que ele viu confirmados na interface não vão acontecer. Sem este
/// aviso, `operacoesPendentes()` retorna 0 e a `Biblioteca` reporta
/// `.sincronizado` sobre uma fila que foi descartada.
struct AvisoDaFilaCloudKit: Sendable, Equatable {
    let recuperadas: Int
    let descartadas: Int
    let arquivoEmQuarentena: URL?

    var mensagem: String {
        let perdidas = "\(descartadas) alteração(ões) pendentes do iCloud não puderam ser lidas e foram descartadas"
        let salvas = recuperadas > 0
            ? "; \(recuperadas) foram recuperadas e continuam na fila"
            : ""
        let copia = arquivoEmQuarentena.map { "; uma cópia do arquivo ficou em \($0.lastPathComponent)" } ?? ""
        return perdidas + salvas + copia + ". Reenvie as conversas afetadas para sincronizá-las de novo."
    }
}

/// Outbox durável para alterações do workspace. A operação entra no arquivo
/// antes da chamada de rede; assim, encerrar o app no meio de uma falha não
/// transforma uma edição local numa promessa impossível de retomar.
actor FilaPersistenteCloudKit {
    /// Quantas quarentenas antigas são mantidas em disco. Sem um teto elas
    /// acumulam indefinidamente, um arquivo por relançamento com schema
    /// incompatível.
    private static let quarentenasMantidas = 3
    private static let sufixoDaQuarentena = ".corrupted-"
    private static let registro = Logger(subsystem: "Papagaio", category: "FilaCloudKit")

    private let url: URL
    private let fm: FileManager
    private var estadoInicial: Result<[OperacaoPendenteCloudKit], any Error>
    private var operacoesCarregadas: [OperacaoPendenteCloudKit]?
    private var avisoDeAbertura: AvisoDaFilaCloudKit?

    init(url: URL, fm: FileManager = .default) {
        self.url = url
        self.fm = fm
        estadoInicial = .success([])

        if fm.fileExists(atPath: url.path) {
            do {
                let dados = try Data(contentsOf: url)
                do {
                    estadoInicial = .success(
                        try JSONDecoder().decode([OperacaoPendenteCloudKit].self, from: dados)
                    )
                } catch {
                    // O gatilho real aqui é incompatibilidade de schema, não
                    // truncamento: `salvar` escreve com `.atomic`, então um
                    // crash no meio de uma escrita deixa o arquivo anterior
                    // intacto. O que quebra a leitura é `OperacaoPendenteCloudKit`
                    // embutir `EquipeDisponivel` e `Arquivo` — acrescentar um
                    // campo não-opcional a qualquer um deles torna todo
                    // arquivo já persistido indecodificável.
                    //
                    // Bloquear a fila perderia a interface inteira, então a
                    // quarentena fica. Mas ela deixa de ser silenciosa: o que
                    // der para salvar é recuperado item a item e o resto vira
                    // um `AvisoDaFilaCloudKit` que a `Biblioteca` mostra.
                    let recuperado = Self.decodificarTolerante(dados)
                    let quarentena = Self.colocarEmQuarentena(url, fm: fm)
                    estadoInicial = .success(recuperado.operacoes)
                    if !recuperado.operacoes.isEmpty {
                        try? Self.gravar(recuperado.operacoes, em: url, fm: fm)
                    }
                    let aviso = AvisoDaFilaCloudKit(
                        recuperadas: recuperado.operacoes.count,
                        descartadas: recuperado.descartadas,
                        arquivoEmQuarentena: quarentena
                    )
                    avisoDeAbertura = aviso
                    Self.registro.error(
                        """
                        Fila do iCloud ilegível (\(String(describing: error), privacy: .public)):                         \(aviso.descartadas, privacy: .public) descartadas,                         \(aviso.recuperadas, privacy: .public) recuperadas.
                        """
                    )
                }
            } catch {
                estadoInicial = .failure(error)
            }
        }

        Self.limparQuarentenasAntigas(de: url, fm: fm)
    }

    /// Devolve o aviso da abertura uma única vez. É consumido para que a
    /// `Biblioteca` não repita a notificação a cada ciclo de sincronização.
    func consumirAvisoDeAbertura() -> AvisoDaFilaCloudKit? {
        defer { avisoDeAbertura = nil }
        return avisoDeAbertura
    }

    /// Decodifica elemento a elemento para que uma única operação irrecuperável
    /// não leve junto o resto do backlog.
    private static func decodificarTolerante(
        _ dados: Data
    ) -> (operacoes: [OperacaoPendenteCloudKit], descartadas: Int) {
        guard let elementos = try? JSONSerialization.jsonObject(with: dados) as? [Any] else {
            return ([], 0)
        }
        let decodificador = JSONDecoder()
        var operacoes: [OperacaoPendenteCloudKit] = []
        var descartadas = 0
        for elemento in elementos {
            guard let bruto = try? JSONSerialization.data(withJSONObject: elemento),
                  let operacao = try? decodificador.decode(
                      OperacaoPendenteCloudKit.self, from: bruto
                  )
            else {
                descartadas += 1
                continue
            }
            operacoes.append(operacao)
        }
        return (operacoes, descartadas)
    }

    private static func colocarEmQuarentena(_ url: URL, fm: FileManager) -> URL? {
        let destino = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + sufixoDaQuarentena + "\(Int(Date().timeIntervalSince1970))"
        )
        do {
            try fm.moveItem(at: url, to: destino)
            return destino
        } catch {
            registro.error("Não foi possível isolar a fila ilegível: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func limparQuarentenasAntigas(de url: URL, fm: FileManager) {
        let pasta = url.deletingLastPathComponent()
        let prefixo = url.lastPathComponent + sufixoDaQuarentena
        guard let conteudo = try? fm.contentsOfDirectory(atPath: pasta.path) else { return }
        // O sufixo é um timestamp de largura crescente mas comparável por
        // valor; ordenar pelo número evita depender de datas do sistema de
        // arquivos, que um restore de backup embaralha.
        let antigas = conteudo
            .filter { $0.hasPrefix(prefixo) }
            .sorted { Int($0.dropFirst(prefixo.count)) ?? 0 > Int($1.dropFirst(prefixo.count)) ?? 0 }
            .dropFirst(quarentenasMantidas)
        for nome in antigas {
            try? fm.removeItem(at: pasta.appendingPathComponent(nome))
        }
    }

    private static func gravar(
        _ operacoes: [OperacaoPendenteCloudKit],
        em url: URL,
        fm: FileManager
    ) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(operacoes).write(to: url, options: .atomic)
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
        let elegiveis = try carregar().filter {
            ignorarBackoff || $0.proximaTentativa <= agora
        }
        var concluidas = 0
        var erros: [String] = []

        for operacao in elegiveis {
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
        try Self.gravar(operacoes, em: url, fm: fm)
        operacoesCarregadas = operacoes
        estadoInicial = .success(operacoes)
    }
}

enum ErroDaFilaCloudKit: LocalizedError {
    case payloadAusente

    var errorDescription: String? {
        switch self {
        case .payloadAusente:
            "Uma operação pendente do iCloud não contém a conversa esperada."
        }
    }
}
