import Foundation
import Observation
import os
import PapagaioCore

enum EstadoDaConexaoGoogleCalendar: Equatable {
    case desconectado
    case conectando
    case conectado(ContaExterna)
    case falhou(String)

    var conectado: Bool {
        if case .conectado = self { return true }
        return false
    }
}

@MainActor
@Observable
final class GoogleCalendarViewModel {
    private(set) var estado: EstadoDaConexaoGoogleCalendar = .desconectado
    private(set) var reunioesPendentes: [ReuniaoPendenteCalendar] = []
    private(set) var reunioesIgnoradas: [ReuniaoPendenteCalendar]
    private(set) var carregandoReunioes = false
    private(set) var falhaDeImportacao: String?

    var aoNotificar: (@MainActor (_ titulo: String, _ mensagem: String, _ tipo: NotificacaoDoApp.Tipo) -> Void)?

    private let cofre = CofreDeTokens(servico: "papagaio:google-calendar")
    private var sessao: SessaoOAuthGoogle?
    private var fonte: FonteGoogleCalendarAPI?
    private let registro = Logger(subsystem: "Papagaio", category: "GoogleCalendar")
    private var timerDeSincronizacao: Task<Void, Never>?
    private var tarefaDeConexao: Task<Void, Never>?
    private var idDaTarefaDeConexao: UUID?
    private var tarefasDeImportacao: [UUID: Task<Arquivo?, Never>] = [:]
    private weak var bibliotecaRef: Biblioteca?
    private let estadoDasReunioes: EstadoDasReunioesCalendar

    init(defaults: UserDefaults = .standard) {
        let estadoDasReunioes = EstadoDasReunioesCalendar(defaults: defaults)
        self.estadoDasReunioes = estadoDasReunioes
        self.reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
    }

    /// Reconexão automática só é legítima quando já houve consentimento e há
    /// uma credencial persistida. Ter Client ID no build apenas habilita o
    /// botão de conexão; não autoriza rede nem abertura de navegador.
    ///
    /// UMA única leitura de Keychain, só de atributos (sem `kSecReturnData`):
    /// checar existência não decifra o segredo, então o launch não dispara
    /// prompt. O sinal canônico é o `refresh_token` (longa duração); o
    /// `access_token` (curto, rotativo) só é lido no uso/refresh, dentro de
    /// `SessaoOAuthGoogle.tokenDeAcesso`. Antes, dois `carregar` (refresh +
    /// access) disparavam dois prompts logo na abertura.
    var temAutorizacaoPersistida: Bool {
        !cofre.contasExistentes(entre: ["refresh_token"]).isEmpty
    }

    func conectar(biblioteca: Biblioteca) async {
        guard tarefaDeConexao == nil, !estado.conectado, !(estado == .conectando) else { return }
        let id = UUID()
        let tarefa = Task { @MainActor [weak self, weak biblioteca] in
            guard let self, let biblioteca else { return }
            await self.executarConexao(biblioteca: biblioteca)
        }
        idDaTarefaDeConexao = id
        tarefaDeConexao = tarefa
        await tarefa.value
        if idDaTarefaDeConexao == id {
            tarefaDeConexao = nil
            idDaTarefaDeConexao = nil
        }
    }

    private func executarConexao(biblioteca: Biblioteca) async {
        estado = .conectando
        registro.info("Iniciando conexão com o Google Calendar")

        let sessao = SessaoOAuthGoogle(cofre: cofre)
        self.sessao = sessao

        do {
            let fonte = FonteGoogleCalendarAPI { forcar in
                try await sessao.tokenDeAcesso(forcandoRenovacao: forcar)
            }
            let conta = try await fonte.conta()
            self.fonte = fonte
            self.bibliotecaRef = biblioteca
            estado = .conectado(conta)
            registro.info("Conta Google Calendar conectada")
            await carregarReunioes()
            iniciarTimerSincronizacao()
        } catch {
            self.sessao = nil
            self.fonte = nil
            estado = .falhou(ErroDaConexao.descricao(do: error))
            registro.error("Conexão Google Calendar falhou: \(ErroDaConexao.descricao(do: error), privacy: .public)")
        }
    }

    func desconectar() async {
        timerDeSincronizacao?.cancel()
        timerDeSincronizacao = nil
        await sessao?.sair()
        sessao = nil
        fonte = nil
        bibliotecaRef = nil
        reunioesPendentes = []
        falhaDeImportacao = nil
        estado = .desconectado
    }

    /// Interrompe o estado local sem depender da rede. A cascata de exclusão
    /// apaga o Keychain em seguida, inclusive quando a reconexão havia falhado
    /// antes de criar uma sessão em memória.
    func encerrarLocalmenteParaExclusaoDoPerfil() async {
        let timer = timerDeSincronizacao
        timer?.cancel()
        timerDeSincronizacao = nil

        let conexao = tarefaDeConexao
        conexao?.cancel()
        let importacoes = Array(tarefasDeImportacao.values)
        importacoes.forEach { $0.cancel() }
        if let conexao { await conexao.value }
        for importacao in importacoes { _ = await importacao.value }

        tarefaDeConexao = nil
        idDaTarefaDeConexao = nil
        tarefasDeImportacao.removeAll()
        sessao = nil
        fonte = nil
        bibliotecaRef = nil
        reunioesPendentes = []
        reunioesIgnoradas = []
        carregandoReunioes = false
        falhaDeImportacao = nil
        estado = .desconectado
    }

    func recarregar() async {
        guard estado.conectado else { return }
        await carregarReunioes()
    }

    func obterDetalhesReuniao(id: String) async throws -> ReuniaoExterna? {
        guard let fonte, estado.conectado else { return nil }
        return try await fonte.obterReuniao(id: id, incluirTranscricao: false)
    }

    private func iniciarTimerSincronizacao() {
        timerDeSincronizacao?.cancel()
        timerDeSincronizacao = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                    guard let self else { break }
                    if self.estado.conectado {
                        await self.carregarReunioes()
                    }
                } catch {
                    break
                }
            }
        }
    }

    private func carregarReunioes() async {
        guard let fonte else { return }
        carregandoReunioes = true
        defer { carregandoReunioes = false }
        do {
            let eventos = try await fonte.listarEventos()
            aplicar(eventos: eventos, biblioteca: bibliotecaRef)
            falhaDeImportacao = nil
            registro.info("\(self.reunioesPendentes.count) reuniões pendentes carregadas do Google Calendar")
        } catch {
            falhaDeImportacao = ErroDaConexao.descricao(do: error)
            registro.error("Falha ao carregar reuniões: \(ErroDaConexao.descricao(do: error), privacy: .public)")
        }
    }

    /// Importa um arquivo de áudio local para uma reunião pendente e cria o
    /// Arquivo definitivo na biblioteca (com transcrição na fila). Não exige
    /// conexão: a pendente já está em memória.
    @discardableResult
    func importarAudioParaReuniao(
        _ pendente: ReuniaoPendenteCalendar,
        audioURL: URL,
        biblioteca: Biblioteca,
        duracao: TimeInterval? = nil,
        notas: [NotaDaConversa] = []
    ) async -> Arquivo? {
        let id = UUID()
        let tarefa = Task { @MainActor [weak self, weak biblioteca] () -> Arquivo? in
            guard let self, let biblioteca else { return nil }
            return await self.executarImportacaoDeAudio(
                pendente,
                audioURL: audioURL,
                biblioteca: biblioteca,
                duracao: duracao,
                notas: notas
            )
        }
        tarefasDeImportacao[id] = tarefa
        let arquivo = await tarefa.value
        tarefasDeImportacao[id] = nil
        return arquivo
    }

    private func executarImportacaoDeAudio(
        _ pendente: ReuniaoPendenteCalendar,
        audioURL: URL,
        biblioteca: Biblioteca,
        duracao: TimeInterval? = nil,
        notas: [NotaDaConversa] = []
    ) async -> Arquivo? {
        guard !Task.isCancelled else { return nil }
        let arquivo = await biblioteca.criarArquivoDeReuniaoPendente(
            pendente,
            audioURL: audioURL,
            duracao: duracao,
            notas: notas
        )
        if arquivo != nil {
            estadoDasReunioes.definir(.convertida, para: pendente)
            reunioesPendentes.removeAll { $0.id == pendente.id }
            reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
        }
        return arquivo
    }

    func ignorarPendente(_ pendente: ReuniaoPendenteCalendar) {
        estadoDasReunioes.definir(.ignorada, para: pendente)
        reunioesPendentes.removeAll { $0.id == pendente.id }
        reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
    }

    func restaurarPendente(_ pendente: ReuniaoPendenteCalendar) {
        estadoDasReunioes.definir(.ativa, para: pendente)
        reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
        let agora = Date()
        guard pendente.dataHora <= agora.addingTimeInterval(24 * 3600),
              pendente.dataHora.addingTimeInterval(12 * 3600) > agora,
              !reunioesPendentes.contains(where: { $0.idExterno == pendente.idExterno })
        else { return }
        reunioesPendentes.append(pendente)
        reunioesPendentes.sort { $0.dataHora < $1.dataHora }
    }

    func apagarPendenteDefinitivamente(_ pendente: ReuniaoPendenteCalendar) {
        // Uma reunião apagada da lixeira precisa continuar suprimida nas
        // próximas sincronizações; `convertida` representa o estado terminal.
        estadoDasReunioes.definir(.convertida, para: pendente)
        reunioesPendentes.removeAll { $0.idExterno == pendente.idExterno }
        reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
    }

    /// Concilia a página remota com o estado local persistido. É interna para
    /// permitir fixtures determinísticas sem qualquer acesso ao Google.
    func aplicar(
        eventos: [FonteGoogleCalendarAPI.EventoCalendarSimples],
        biblioteca: Biblioteca?,
        agora: Date = Date()
    ) {
        let limite = agora.addingTimeInterval(24 * 3600)
        let idsJaConvertidos = Set(
            (biblioteca?.arquivos ?? []).compactMap(\.idExterno)
            + (biblioteca?.arquivosNaLixeira ?? []).compactMap(\.idExterno)
        )

        var ativas: [ReuniaoPendenteCalendar] = []
        for evento in eventos {
            let pendente = ReuniaoPendenteCalendar(
                id: evento.id,
                titulo: evento.titulo,
                dataHora: evento.dataHora,
                participantes: evento.participantes,
                descricao: evento.descricao,
                idExterno: "google-calendar-api:\(evento.id)"
            )
            estadoDasReunioes.registrarSeNecessario(pendente)
            if idsJaConvertidos.contains(pendente.idExterno) {
                estadoDasReunioes.definir(.convertida, para: pendente)
            }
            guard pendente.dataHora <= limite,
                  pendente.dataHora.addingTimeInterval(12 * 3600) > agora,
                  estadoDasReunioes.registro(de: pendente.idExterno)?.estado == .ativa
            else { continue }
            ativas.append(pendente)
        }

        reunioesPendentes = ativas.sorted { $0.dataHora < $1.dataHora }
        reunioesIgnoradas = estadoDasReunioes.reunioesIgnoradas()
    }

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
