import Foundation
import Observation
import os
import PapagaioCore

/// Estado da conexão com a conta do Granola.
enum EstadoDaConexaoGranola: Equatable {
    case desconectado
    case conectando
    case conectado(ContaExterna)
    case falhou(String)

    var conectado: Bool {
        if case .conectado = self { return true }
        return false
    }
}

/// A conexão Granola da interface: OAuth no navegador (DCR + PKCE), a conta
/// conectada e a importação de reuniões para a biblioteca local.
///
/// Só este view model conhece `SessaoOAuth`/`FonteGranola`; as telas recebem
/// estados e listas prontos. Nada do Granola sai do Mac além do que o fluxo
/// OAuth exige — a importação é local.
@MainActor
@Observable
final class GranolaViewModel {
    private(set) var estado: EstadoDaConexaoGranola = .desconectado
    private(set) var reunioes: [ReuniaoExterna] = []
    private(set) var carregandoReunioes = false
    private(set) var importando = false
    /// Falha da última importação (recuperável: as outras reuniões seguem).
    private(set) var falhaDeImportacao: String?

    var aoNotificar: (@MainActor (_ titulo: String, _ mensagem: String, _ tipo: NotificacaoDoApp.Tipo) -> Void)?

    private let servidorMCP: URL
    private let cofre = CofreDeTokens(servico: "papagaio:granola")
    private var sessao: SessaoOAuth?
    private var fonte: FonteGranola?
    private let registro = Logger(subsystem: "Papagaio", category: "Granola")
    private var tarefaDeConexao: Task<Void, Never>?
    private var idDaTarefaDeConexao: UUID?
    private var tarefaDeImportacao: Task<Int, Never>?
    private var idDaTarefaDeImportacao: UUID?

    init(servidorMCP: URL = URL(string: "https://mcp.granola.ai/mcp")!) {
        self.servidorMCP = servidorMCP
    }

    // MARK: - Conexão

    func conectar() async {
        guard tarefaDeConexao == nil, !estado.conectado, !(estado == .conectando) else { return }
        let id = UUID()
        let tarefa = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executarConexao()
        }
        idDaTarefaDeConexao = id
        tarefaDeConexao = tarefa
        await tarefa.value
        if idDaTarefaDeConexao == id {
            tarefaDeConexao = nil
            idDaTarefaDeConexao = nil
        }
    }

    private func executarConexao() async {
        estado = .conectando
        registro.info("Iniciando conexão com o Granola")

        let sessao = SessaoOAuth(
            servidorMCP: servidorMCP,
            cofre: cofre,
            apresentador: ApresentadorDeSessaoDeAutorizacao()
        )
        self.sessao = sessao

        do {
            let cliente = ClienteMCP(url: servidorMCP) { forcar in
                try await sessao.tokenDeAcesso(forcandoRenovacao: forcar)
            }
            let fonte = FonteGranola(cliente: cliente)
            let conta = try await fonte.conta()
            self.fonte = fonte
            estado = .conectado(conta)
            // Sem o e-mail: no log unificado ele ficaria legível no Console
            // e em qualquer sysdiagnose enviado a terceiros.
            registro.info("Conta do Granola conectada")
            await carregarReunioes()
        } catch {
            self.sessao = nil
            self.fonte = nil
            estado = .falhou(ErroDaConexao.descricao(do: error))
            registro.error("Conexão falhou: \(ErroDaConexao.descricao(do: error), privacy: .public)")
        }
    }

    func desconectar() async {
        await sessao?.sair()
        sessao = nil
        fonte = nil
        reunioes = []
        falhaDeImportacao = nil
        estado = .desconectado
    }

    /// Descarta a sessão e os resultados em memória sem exigir uma chamada de
    /// revogação. A limpeza do Keychain é feita pela cascata da conta.
    func encerrarLocalmenteParaExclusaoDoPerfil() async {
        let conexao = tarefaDeConexao
        let importacao = tarefaDeImportacao
        conexao?.cancel()
        importacao?.cancel()
        if let conexao { await conexao.value }
        if let importacao { _ = await importacao.value }

        tarefaDeConexao = nil
        idDaTarefaDeConexao = nil
        tarefaDeImportacao = nil
        idDaTarefaDeImportacao = nil
        sessao = nil
        fonte = nil
        reunioes = []
        carregandoReunioes = false
        importando = false
        falhaDeImportacao = nil
        estado = .desconectado
    }

    /// Reune a lista da conta. Usado pela UI também para "atualizar".
    func recarregar() async {
        guard estado.conectado else { return }
        await carregarReunioes()
    }

    private func carregarReunioes() async {
        guard let fonte else { return }
        carregandoReunioes = true
        defer { carregandoReunioes = false }
        do {
            reunioes = try await fonte.listarReunioes()
            registro.info("\(self.reunioes.count) reuniões carregadas da conta")
        } catch {
            falhaDeImportacao = ErroDaConexao.descricao(do: error)
            registro.error("Falha ao carregar reuniões: \(ErroDaConexao.descricao(do: error), privacy: .public)")
        }
    }

    // MARK: - Importação

    /// Importa as reuniões selecionadas para a biblioteca local. A transcrição
    /// é pedida quando existe (planos pagos); Basic e falhas de transcrição
    /// entram com notas e resumo. Devolve quantas foram salvas.
    func importar(_ ids: Set<String>, biblioteca: Biblioteca) async -> Int {
        guard tarefaDeImportacao == nil else { return 0 }
        let id = UUID()
        let tarefa = Task { @MainActor [weak self, weak biblioteca] () -> Int in
            guard let self, let biblioteca else { return 0 }
            return await self.executarImportacao(ids, biblioteca: biblioteca)
        }
        idDaTarefaDeImportacao = id
        tarefaDeImportacao = tarefa
        let quantidade = await tarefa.value
        if idDaTarefaDeImportacao == id {
            tarefaDeImportacao = nil
            idDaTarefaDeImportacao = nil
        }
        return quantidade
    }

    private func executarImportacao(_ ids: Set<String>, biblioteca: Biblioteca) async -> Int {
        guard let fonte, estado.conectado, !importando else { return 0 }
        importando = true
        falhaDeImportacao = nil
        defer { importando = false }
        registro.info("Importando \(ids.count) reunião(ns)")

        var salvas = 0
        var importadas: [ReuniaoExterna] = []
        for id in ids {
            guard !Task.isCancelled else { break }
            guard let reuniao = reunioes.first(where: { $0.id == id }) else { continue }
            do {
                let detalhe = try await fonte.obterReuniao(id: id, incluirTranscricao: true)
                guard !Task.isCancelled else { break }
                if await biblioteca.registrarExterna(detalhe, identificador: fonte.identificador) != nil {
                    salvas += 1
                    importadas.append(reuniao)
                }
            } catch {
                falhaDeImportacao = "\(reuniao.titulo): \(ErroDaConexao.descricao(do: error))"
            }
        }
        if salvas > 0 {
            registro.info("\(salvas) reunião(ns) importada(s)")
            aoNotificar?(
                "Reuniões importadas",
                "\(salvas) reunião(ns) do Granola na biblioteca.",
                .sucesso
            )
        }
        return salvas
    }

    // MARK: - Apoio

    private enum ErroDaConexao {
        static func descricao(do erro: any Error) -> String {
            if let localizado = erro as? any LocalizedError,
               let mensagem = localizado.errorDescription {
                return mensagem
            }
            return erro.localizedDescription
        }
    }
}

/// Fala do Granola para os rótulos do contrato: `me`/`them` viram os valores
/// canônicos; nomes próprios e rótulos de diarização passam como vieram (a
/// exceção deliberada do binário "eu"/"interlocutor", porque a fonte entrega
/// quem falou — ver D-14.3).
enum FalanteExterno {
    static func rotulo(de falante: String?) -> String? {
        switch falante {
        case "me": Speaker.eu
        case "them": Speaker.interlocutor
        default: falante
        }
    }
}
