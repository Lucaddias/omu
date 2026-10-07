import AppKit
import AVFoundation
import Foundation
import Observation
import PapagaioCore

enum EstadoDaSincronizacaoCloudKit: Equatable {
    case local
    case enviando
    case sincronizado
    case falhou(String)
}

/// A biblioteca de arquivos do app: o que está salvo, o que está processando e
/// o que falhou.
///
/// É aqui que o app finalmente **chama o pipeline**. Antes disso a transcrição e
/// o resumo existiam só em `PapagaioCore` e na CLI — gravar pelo app produzia um
/// `.m4a` e nada mais.
@MainActor
@Observable
final class Biblioteca {
    private enum ErroDeReidratacao: LocalizedError {
        case arquivoAusente

        var errorDescription: String? {
            "A conversa não está mais disponível na biblioteca.".localized
        }
    }

    private(set) var arquivos: [Arquivo] = []
    /// Arquivos removidos da listagem principal, mas ainda recuperáveis. A
    /// mídia continua no container até a exclusão definitiva.
    private(set) var arquivosNaLixeira: [Arquivo] = []

    /// Fase corrente por arquivo. Chaveado pelo `UUID` cru porque é o que a view
    /// tem em mãos na navegação.
    private(set) var fases: [UUID: PipelineDeArquivo.Fase] = [:]
    /// Quando cada processamento começou, para estimar o quanto falta.
    private(set) var iniciadoEm: [UUID: Date] = [:]
    private(set) var erros: [UUID: String] = [:]

    /// Falha ao abrir a lista do banco. Observável por conta própria —
    /// dentro do dicionário `erros` (chaveado por arquivo) ela não tinha
    /// dono e a interface nunca a via.
    private(set) var erroDeCarregamento: String?

    /// Whisper e Qwen continuam pesados. A fila mantém os
    /// pedidos em ordem de chegada e permite que somente um deles carregue os
    /// modelos por vez.
    private var filaDeProcessamento: [ArquivoID] = []
    /// Os mesmos pedidos em disco, por espaço: sobrevivem a fechar o app e a
    /// trocar de perfil ou equipe.
    private let filaPersistida: FilaDeProcessamentoPersistida
    /// O que cada item da fila pediu. Ausente = processamento completo.
    private var modosDaFila: [ArquivoID: ModoDeProcessamento] = [:]
    private var arquivoEmProcessamento: ArquivoID?

    /// Quanto do pipeline um pedido executa.
    enum ModoDeProcessamento: Equatable {
        /// Transcreve, diariza e resume — refaz a transcrição.
        case completo
        /// Só o resumo, sobre a transcrição que já existe (inclusive a
        /// corrigida à mão). Não carrega o Whisper.
        case somenteResumo
    }

    /// Contador que sobe a cada mudança gravada numa conversa. A tela de
    /// detalhe trabalha sobre a versão completa, carregada do banco; é por
    /// este número que ela sabe que precisa recarregar — sem ele, a tela
    /// seguia com a cópia da abertura e cada correção apagava a anterior.
    private(set) var revisoes: [ArquivoID: Int] = [:]

    func revisao(de id: UUID) -> Int {
        revisoes[ArquivoID(rawValue: id)] ?? 0
    }
    private var identificadorDaExecucao: UUID?
    private var tarefaDeProcessamento: Task<Void, Never>?

    /// Uma operação de lixeira pode suspender ao salvar no SwiftData. Rastrear
    /// os itens em transição evita dois cliques concorrentes e também impede
    /// que um item seja re-enfileirado enquanto está sendo removido.
    private var operacoesDeLixeiraEmAndamento: Set<ArquivoID> = []
    private(set) var erroDaLixeira: String?
    private(set) var estadoDaSincronizacaoCloudKit: EstadoDaSincronizacaoCloudKit = .local

    let armazenamento: Armazenamento

    /// De onde os pesos são carregados. A `ContentView` mantém isto igual à
    /// pasta ativa do `ModelosViewModel` — pode ser a do container ou uma
    /// escolhida pelo usuário.
    var pastaDeModelos: URL

    /// Controla somente a entrada automática de áudios novos na fila. A fila
    /// continua sendo o único caminho para qualquer processamento manual ou
    /// automático, mantendo um único par de modelos carregado por vez.
    var processamentoAutomatico = true
    var aoNotificar: (@MainActor (_ titulo: String, _ mensagem: String, _ tipo: NotificacaoDoApp.Tipo) -> Void)?
    private var avisouMacQuente = false
    private var ultimoExpurgoDaLixeira: [EspacoID: Date] = [:]
    private var lixeiraDaEquipeConferida = false
    /// Ditado e separação de vozes carregam modelos fora da fila.
    private var operacoesAvulsasComModelos = 0
    var aoConcluirProcessamento: (@MainActor (_ arquivo: Arquivo) -> Void)?

    /// Arquivos que acabaram de ser transcritos e resumidos e ainda esperam a
    /// ficha da entrevista (título, entrevistado, participantes...) ser
    /// preenchida. Diferente do fluxo antigo, que abria o formulário sozinho
    /// assim que o processamento terminava — não importa em que tela a pessoa
    /// estivesse —, agora o cartão só mostra um selo "Concluído" e é a pessoa
    /// quem decide clicar para abrir a ficha.
    private(set) var arquivosComFichaPendente: Set<ArquivoID> = []

    /// Arquivos cujo selo "Concluído" já terminou de subir e está revelado.
    ///
    /// Mora aqui, e não num `@State` do cartão, de propósito: `Biblioteca` é
    /// `@Observable`, e QUALQUER mudança nela (o processamento de um arquivo
    /// diferente terminando, por exemplo) força o SwiftUI a recalcular o
    /// `body` de todos os cartões da grade. Se "já revelei o selo deste
    /// arquivo" vivesse só num `@State` local do cartão, uma recriação da
    /// view (por perda de identidade nesse recálculo) reiniciava o `@State`
    /// e replayava a animação de subida até 100% num cartão que já estava
    /// pronto havia tempos — exatamente o bug relatado ("os outros cards
    /// pulam pra 100% de novo"). Guardando aqui, a resposta a "já revelei
    /// esse selo?" sobrevive a qualquer recriação de view.
    private(set) var arquivosComSeloRevelado: Set<ArquivoID> = []

    func marcarFichaPendente(_ id: ArquivoID) {
        arquivosComFichaPendente.insert(id)
        arquivosComSeloRevelado.remove(id)
        // Meio segundo de atraso antes de revelar o selo "Concluído": tempo
        // para a tarja lateral subir até 100% primeiro (ver
        // `CartaoDeConversa.tarjaLateral`), em vez de o selo cobri-la no
        // meio do caminho — a fração por tempo estimado quase nunca bate
        // exatamente com o fim real do processamento.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, arquivosComFichaPendente.contains(id) else { return }
            arquivosComSeloRevelado.insert(id)
        }
    }

    func fichaPendente(_ id: ArquivoID) -> Bool {
        arquivosComFichaPendente.contains(id)
    }

    func seloDeConclusaoRevelado(_ id: ArquivoID) -> Bool {
        arquivosComSeloRevelado.contains(id)
    }

    func limparFichaPendente(_ id: ArquivoID) {
        arquivosComFichaPendente.remove(id)
        arquivosComSeloRevelado.remove(id)
    }

    private let repositorio: SwiftDataRepository
    private let salvarReuniaoNoRepositorio: @Sendable (Arquivo) async throws -> Void
    private let ciclo = CicloDeVidaDeModelos()
    /// O container CloudKit não pertence ao ciclo de abertura da biblioteca
    /// pessoal. A criação lazy permite testes unsigned e evita inicializar uma
    /// conta externa quando nenhuma equipe está ativa.
    @ObservationIgnored
    private var sincronizadorCloudKitArmazenado: SincronizadorDaBibliotecaCloudKit?
    private let filaCloudKit: FilaPersistenteCloudKit
    private let marcadoresCloudKit: MarcadoresDeSincronizacaoCloudKit
    private var tarefaDeRetryCloudKit: Task<Void, Never>?
    /// O envio da fila do iCloud em curso — um por biblioteca. Quem salva
    /// localmente só agenda (gravação durável) e segue; a rede fica aqui.
    private var tarefaDeEnvioCloudKit: Task<Void, Never>?
    /// Revisão remota já aplicada de cada conversa, nesta execução do app.
    /// Cada troca de espaço baixa a zona inteira; sem isto, toda conversa
    /// era regravada por inteiro no banco, tivesse mudado ou não.
    private var revisoesRemotasAplicadas: [ArquivoID: Date] = [:]
    private var avisouQuarentenaDaFila = false
    private var haEnvioCloudKitAguardando = false
    /// Sem isto, o que um colega gravava só aparecia ao trocar de espaço ou
    /// reabrir o app. A consulta é incremental: custa uma requisição pequena.
    private var tarefaDeAtualizacaoDaEquipe: Task<Void, Never>?
    /// Contexto do espaço cuja baixa está em andamento, se houver.
    private var baixaDaEquipeEmAndamento: UUID?
    @ObservationIgnored
    var intervaloDeAtualizacaoDaEquipe: Duration = .seconds(60)
    private var sincronizadorCloudKit: SincronizadorDaBibliotecaCloudKit {
        if let sincronizadorCloudKitArmazenado {
            return sincronizadorCloudKitArmazenado
        }
        let novo = SincronizadorDaBibliotecaCloudKit()
        sincronizadorCloudKitArmazenado = novo
        return novo
    }
    private var espaco: EspacoID
    private var equipeCloudKit: EquipeDisponivel?
    /// Espaços cuja exclusão já começou não aceitam mais gravações tardias.
    /// O bloqueio dura pela vida desta biblioteca porque o identificador do
    /// perfil excluído é aposentado e não deve voltar a receber dados.
    private var espacosExcluidos: Set<EspacoID> = []

    private func criarMotoresLocais() -> MotoresLocais {
#if OMU_PERF
        if PerfProbe.ativada {
            return MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo) { evento, modelo, duracao in
                Task { @MainActor in
                    PerfProbe.shared.registrarEventoModelo(evento, modelo: modelo, duracao: duracao)
                }
            }
        }
#endif
        return MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)
    }

    init() throws {
#if OMU_PERF
        if let configuracao = PerfProbe.configuracao {
            try FileManager.default.createDirectory(
                at: configuracao.raiz,
                withIntermediateDirectories: true
            )
            let armazenamento = Armazenamento(raiz: configuracao.raiz)
            let repositorio = SwiftDataRepository(
                modelContainer: try SwiftDataRepository.containerLocal(
                    nome: "OmuPerf",
                    url: configuracao.raiz.appendingPathComponent("biblioteca.store")
                )
            )
            self.armazenamento = armazenamento
            self.pastaDeModelos = configuracao.modelos
            self.repositorio = repositorio
            self.salvarReuniaoNoRepositorio = { arquivo in
                try await repositorio.salvar(arquivo)
            }
            self.filaCloudKit = FilaPersistenteCloudKit(
                url: configuracao.raiz
                    .appendingPathComponent("CloudKit", isDirectory: true)
                    .appendingPathComponent("fila-pendente.json")
            )
            self.filaPersistida = Self.filaPersistida(em: armazenamento)
            self.marcadoresCloudKit = MarcadoresDeSincronizacaoCloudKit(
                url: configuracao.raiz
                    .appendingPathComponent("CloudKit", isDirectory: true)
                    .appendingPathComponent("marcadores-de-sincronizacao.json")
            )
            self.espaco = PerfProbe.espacoPadrao
            return
        }
#endif
        let armazenamento = try Armazenamento.padrao()
        let repositorio = SwiftDataRepository(
            modelContainer: try SwiftDataRepository.containerLocal()
        )
        self.armazenamento = armazenamento
        self.pastaDeModelos = armazenamento.pastaDeModelos
        self.repositorio = repositorio
        self.salvarReuniaoNoRepositorio = { arquivo in
            try await repositorio.salvar(arquivo)
        }
        self.filaCloudKit = FilaPersistenteCloudKit(
            url: armazenamento.raiz
                .appendingPathComponent("CloudKit", isDirectory: true)
                .appendingPathComponent("fila-pendente.json")
        )
        self.filaPersistida = Self.filaPersistida(em: armazenamento)
        self.marcadoresCloudKit = MarcadoresDeSincronizacaoCloudKit(
            url: armazenamento.raiz
                .appendingPathComponent("CloudKit", isDirectory: true)
                .appendingPathComponent("marcadores-de-sincronizacao.json")
        )
        self.espaco = Self.espacoPessoal()
    }

    /// Injeção para testes: container em memória, armazenamento temporário e
    /// espaço isolado — sem tocar o banco nem o container reais do usuário.
    /// O caminho de produção continua sendo o `init()` acima.
    init(
        armazenamento: Armazenamento,
        repositorio: SwiftDataRepository,
        espaco: EspacoID,
        salvarArquivo: (@Sendable (Arquivo) async throws -> Void)? = nil,
        sincronizadorCloudKit: SincronizadorDaBibliotecaCloudKit? = nil,
        filaCloudKit: FilaPersistenteCloudKit? = nil
    ) {
        self.armazenamento = armazenamento
        self.pastaDeModelos = armazenamento.pastaDeModelos
        self.repositorio = repositorio
        self.salvarReuniaoNoRepositorio = salvarArquivo ?? { arquivo in
            try await repositorio.salvar(arquivo)
        }
        self.sincronizadorCloudKitArmazenado = sincronizadorCloudKit
        self.filaCloudKit = filaCloudKit ?? FilaPersistenteCloudKit(
            url: armazenamento.raiz
                .appendingPathComponent("CloudKit", isDirectory: true)
                .appendingPathComponent("fila-pendente.json")
        )
        self.filaPersistida = Self.filaPersistida(em: armazenamento)
        self.marcadoresCloudKit = MarcadoresDeSincronizacaoCloudKit(
            url: armazenamento.raiz
                .appendingPathComponent("CloudKit", isDirectory: true)
                .appendingPathComponent("marcadores-de-sincronizacao.json")
        )
        self.espaco = espaco
    }

    private static func filaPersistida(em armazenamento: Armazenamento) -> FilaDeProcessamentoPersistida {
        FilaDeProcessamentoPersistida(
            url: armazenamento.raiz
                .appendingPathComponent("Processamento", isDirectory: true)
                .appendingPathComponent("fila-pendente.json")
        )
    }

    /// O espaço individual é um só e precisa sobreviver a relançamentos: sem
    /// isto, cada abertura criaria um espaço novo e a lista voltaria vazia.
    static func espacoPessoal(em defaults: UserDefaults = .standard) -> EspacoID {
        let chave = "espacoIndividual"
        if let guardado = defaults.string(forKey: chave),
           let id = UUID(uuidString: guardado) {
            return EspacoID(rawValue: id)
        }
        let novo = UUID()
        defaults.set(novo.uuidString, forKey: chave)
        return EspacoID(rawValue: novo)
    }

    // MARK: - Ciclo de vida

    private var contextoDoEspaco = UUID()
    private var cargaAtual = UUID()

    func usarEspaco(_ novoEspaco: EspacoID, equipeCloudKit: EquipeDisponivel? = nil) async {
        contextoDoEspaco = UUID()
        let contexto = contextoDoEspaco
        tarefaDeRetryCloudKit?.cancel()
        tarefaDeRetryCloudKit = nil
        tarefaDeAtualizacaoDaEquipe?.cancel()
        tarefaDeAtualizacaoDaEquipe = nil
        let mudouDeEspaco = espaco != novoEspaco
        self.equipeCloudKit = equipeCloudKit
        if equipeCloudKit == nil {
            estadoDaSincronizacaoCloudKit = .local
        }
        if mudouDeEspaco {
            filaDeProcessamento.removeAll()
            modosDaFila.removeAll()
            espaco = novoEspaco
            arquivos.removeAll()
            arquivosNaLixeira.removeAll()
            fases.removeAll()
            erros.removeAll()
            erroDaLixeira = nil
        }
        await carregar()
        guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
        if equipeCloudKit != nil {
            await retomarSincronizacaoCloudKit()
        }
        guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
        await baixarAtualizacoesDaEquipe()
        guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
        agendarAtualizacaoDaEquipe()
    }

    func preparar() async {
        await ciclo.iniciarMonitoramento()
        await ciclo.encerrarNaSaidaDoApp()
        await carregar()
    }

    /// Apaga de vez as conversas que estão na lixeira há mais tempo que o
    /// prazo anunciado em cada cartão. Devolve quantas saíram.
    ///
    /// Passa pelo mesmo caminho do botão "Apagar definitivamente" — registro,
    /// pasta de áudio, lojas auxiliares e, numa equipe, a remoção no iCloud —
    /// e roda no máximo uma vez por dia por espaço. Uma falha fica para a
    /// próxima rodada, sem aviso: ninguém pediu esta exclusão agora.
    @discardableResult
    func expurgarLixeiraVencida(agora: Date = Date()) async -> Int {
        let espacoDoExpurgo = espaco
        if let ultimo = ultimoExpurgoDaLixeira[espacoDoExpurgo],
           agora.timeIntervalSince(ultimo) < 24 * 3_600, agora >= ultimo {
            return 0
        }
        ultimoExpurgoDaLixeira[espacoDoExpurgo] = agora

        let vencidos = arquivosNaLixeira.filter { arquivo in
            arquivo.apagadoEm.map { PrazoDaLixeira.venceu($0, agora: agora) } ?? false
        }
        guard !vencidos.isEmpty else { return 0 }

        let erroAnterior = erroDaLixeira
        var apagados = 0
        for arquivo in vencidos {
            guard espaco == espacoDoExpurgo else { break }
            await apagarDefinitivamente(arquivo)
            if !arquivosNaLixeira.contains(where: { $0.id == arquivo.id }) { apagados += 1 }
        }
        erroDaLixeira = erroAnterior
        return apagados
    }

    func carregar() async {
        let contexto = contextoDoEspaco
        let espacoDaCarga = espaco
        let carga = UUID()
        cargaAtual = carga
        do {
            let ativos = try await repositorio.listarParaBiblioteca(espaco: espacoDaCarga)
            let excluidos = try await repositorio.listarNaLixeiraParaBiblioteca(espaco: espacoDaCarga)
            guard contexto == contextoDoEspaco, carga == cargaAtual,
                  !Task.isCancelled else { return }
            arquivos = ativos
            arquivosNaLixeira = excluidos
            erroDeCarregamento = nil
            // Numa equipe, o estado da lixeira só vale depois de baixar o que
            // os colegas fizeram: uma conversa restaurada por alguém ainda
            // apareceria aqui como "vencida" e seria removida para todos.
            if equipeCloudKit == nil || lixeiraDaEquipeConferida {
                await expurgarLixeiraVencida()
            }
            guard contexto == contextoDoEspaco, carga == cargaAtual,
                  !Task.isCancelled else { return }
            retomarProcessamentosPendentes()
        } catch {
            guard contexto == contextoDoEspaco, carga == cargaAtual,
                  !Task.isCancelled else { return }
            erroDeCarregamento = "Não foi possível abrir a biblioteca: %@".localized(error.localizedDescription)
        }
    }

    // MARK: - Entrada de áudio

    /// Registra um áudio recém-gravado ou importado. Com o processamento
    /// automático ativo ele entra na fila; caso contrário fica pronto para a
    /// pessoa iniciar pela aba Transcrição. As notas são criadas antes da fila,
    /// para que os saves do pipeline apenas as preservem junto de transcrição
    /// e resumo.
    @discardableResult
    func registrar(
        titulo: String,
        pastaRelativa: String,
        duracao: TimeInterval,
        notas: [NotaDaConversa] = [],
        dataDeGravacao: Date? = nil,
        usavaFones: Bool? = nil
    ) async -> Arquivo? {
        let espacoDestino = espaco
        guard !espacosExcluidos.contains(espacoDestino) else {
            if !pastaRelativa.isEmpty {
                try? armazenamento.removerGravacao(relativa: pastaRelativa)
            }
            return nil
        }
        let arquivo = Arquivo(
            titulo: titulo,
            criadoEm: dataDeGravacao ?? Date(),
            duracao: duracao,
            pastaRelativa: pastaRelativa,
            espaco: espacoDestino,
            notas: notas,
            importadoEm: dataDeGravacao != nil ? Date() : nil,
            // Sem isto o pipeline nunca sabia que a gravação foi feita pelo
            // alto-falante, e o cancelamento de eco não rodava no app.
            usavaFones: usavaFones
        )
        do {
            try await repositorio.salvar(arquivo)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar: %@".localized(error.localizedDescription)
            return nil
        }
        if espacosExcluidos.contains(espacoDestino) {
            if !pastaRelativa.isEmpty {
                try? armazenamento.removerGravacao(relativa: pastaRelativa)
            }
            try? await repositorio.descartarRegistro(arquivo.id)
            return nil
        }
        // Trocar de perfil enquanto o save aguardava não move o arquivo para
        // o novo espaço nem o insere na lista errada. Ele permanece salvo no
        // espaço em que a operação começou e reaparece quando ele for aberto.
        guard espaco == espacoDestino else { return arquivo }
        arquivos.insert(arquivo, at: 0)
        await sincronizar(arquivo)
        if processamentoAutomatico {
            enfileirarProcessamento(arquivo)
        }
        return arquivo
    }

    // MARK: - Gravações órfãs

    /// Reencontra gravações que ficaram no disco sem registro no banco.
    ///
    /// A conversa só nasce quando a gravação é finalizada. Se o app é
    /// encerrado à força, trava ou a máquina desliga no meio de uma reunião,
    /// a pasta em `Gravacoes/` sobra com o áudio dentro e nada a mostra. Aqui
    /// cada pasta sem registro vira uma conversa "recuperada" (com o
    /// cabeçalho do WAV consertado), e as que não têm áudio aproveitável —
    /// clique acidental interrompido — são removidas.
    ///
    /// - Parameter pastasEmUso: pastas de uma gravação em curso ou de uma
    ///   entrega ainda a caminho do banco; não são órfãs, só novas.
    @discardableResult
    func recuperarGravacoesOrfas(ignorando pastasEmUso: Set<String> = []) async -> [Arquivo] {
        let destino = Self.espacoPessoal()
        guard !espacosExcluidos.contains(destino) else { return [] }

        let fm = FileManager.default
        let raizDasGravacoes = armazenamento.raiz
            .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        guard let pastas = try? fm.contentsOfDirectory(
            at: raizDasGravacoes,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Sem a lista do banco não dá para afirmar que algo é órfão.
        guard let conhecidas = try? await repositorio.pastasRelativasConhecidas() else { return [] }
        // O sistema de arquivos não distingue caixa nem forma de acento; um
        // falso "órfão" criaria um segundo registro apontando para a pasta de
        // uma conversa que existe.
        func chave(_ relativa: String) -> String {
            relativa.precomposedStringWithCanonicalMapping.lowercased()
        }
        let ocupadas = Set(conhecidas.map(chave)).union(pastasEmUso.map(chave))

        var recuperadas: [Arquivo] = []
        for pasta in pastas {
            let valores = try? pasta.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard valores?.isDirectory == true else { continue }
            let relativa = "\(Armazenamento.pastaGravacoes)/\(pasta.lastPathComponent)"
            guard !ocupadas.contains(chave(relativa)) else { continue }

            let conteudo = (try? fm.contentsOfDirectory(atPath: pasta.path)) ?? []
            let microfone = pasta.appendingPathComponent(Armazenamento.Nome.microfone)
            let importado = conteudo
                .first { $0.hasPrefix("\(Armazenamento.Nome.prefixoImportado).") }
                .map { pasta.appendingPathComponent($0) }

            var duracao: TimeInterval = 0
            if fm.fileExists(atPath: microfone.path) {
                _ = try? ReparoDeWAV.reparar(microfone)
                duracao = SessaoGravacao.duracaoDoMicrofone(em: microfone) ?? 0
            } else if let importado {
                duracao = await Self.duracaoDoAudio(importado)
            }

            guard duracao.isFinite, duracao >= SessaoGravacao.duracaoMinima else {
                // Só apaga o que a própria captura criou e descartaria: pasta
                // vazia ou com os arquivos canônicos de uma gravação que não
                // chegou a um segundo. Qualquer outra coisa fica onde está.
                let arquivosDaCaptura: Set<String> = [Armazenamento.Nome.microfone, Armazenamento.Nome.sistema]
                if Set(conteudo).isSubset(of: arquivosDaCaptura) {
                    try? armazenamento.removerGravacao(relativa: relativa)
                }
                continue
            }

            let criadaEm = valores?.creationDate ?? Date()
            let arquivo = Arquivo(
                titulo: "Gravação recuperada — %@".localized(
                    criadaEm.formatted(date: .abbreviated, time: .shortened)
                ),
                criadoEm: criadaEm,
                duracao: duracao,
                pastaRelativa: relativa,
                espaco: destino
            )
            do {
                try await repositorio.salvar(arquivo)
            } catch {
                continue
            }
            recuperadas.append(arquivo)
            guard espaco == destino else { continue }
            arquivos.insert(arquivo, at: 0)
            if processamentoAutomatico {
                enfileirarProcessamento(arquivo)
            }
        }

        if !recuperadas.isEmpty {
            let mensagem = recuperadas.count == 1
                ? "Uma gravação que não tinha sido finalizada voltou para a biblioteca.".localized
                : "%lld gravações que não tinham sido finalizadas voltaram para a biblioteca.".localized(recuperadas.count)
            aoNotificar?("Gravação recuperada".localized, mensagem, .aviso)
        }
        return recuperadas
    }

    /// Importa uma reunião de fonte externa (Granola, Google Calendar etc.):
    /// sem áudio — `pastaRelativa` vazia é a marca de `Arquivo.semAudio` —,
    /// com transcrição, notas e resumo prontos, e **fora** da fila de
    /// processamento (não há nada para os modelos locais fazerem aqui).
    ///
    /// A importação é idempotente por `idExterno`: a mesma reunião nunca
    /// duplica, mesmo se o loop de importação rodar duas vezes.
    @discardableResult
    func registrarExterna(_ reuniao: ReuniaoExterna, identificador: String) async -> Arquivo? {
        let espacoDestino = espaco
        guard !espacosExcluidos.contains(espacoDestino) else { return nil }
        let idExternoCompleto = "\(identificador):\(reuniao.id)"
        guard !arquivos.contains(where: { $0.idExterno == idExternoCompleto }),
              !arquivosNaLixeira.contains(where: { $0.idExterno == idExternoCompleto })
        else { return nil }

        let trechos = reuniao.transcricao?.map { segmento in
            Trecho(
                start: segmento.inicio ?? 0,
                end: segmento.fim ?? segmento.inicio ?? 0,
                texto: segmento.texto,
                speaker: FalanteExterno.rotulo(de: segmento.falante)
            )
        } ?? []

        let notas: [NotaDaConversa]
        if let texto = reuniao.notas, !texto.isEmpty {
            notas = [NotaDaConversa(texto: texto, start: 0)]
        } else {
            notas = []
        }

        let resumo = reuniao.resumo.map {
            Resumo(titulo: reuniao.titulo, visaoGeral: $0)
        }

        let arquivo = Arquivo(
            titulo: reuniao.titulo,
            criadoEm: reuniao.data == .distantPast ? Date() : reuniao.data,
            duracao: trechos.map(\.end).max() ?? 0,
            pastaRelativa: "",
            espaco: espacoDestino,
            trechos: trechos,
            notas: notas,
            resumo: resumo,
            idExterno: idExternoCompleto
        )
        do {
            try await repositorio.salvar(arquivo)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível importar a reunião: %@".localized(error.localizedDescription)
            return nil
        }
        if espacosExcluidos.contains(espacoDestino) {
            try? await repositorio.descartarRegistro(arquivo.id)
            return nil
        }
        guard espaco == espacoDestino else { return arquivo }
        arquivos.insert(arquivo, at: 0)
        arquivos.sort { $0.criadoEm > $1.criadoEm }
        // Sem isto, no próximo download a versão remota (que não tem a
        // reunião) vencia e a importação sumia do espaço da equipe.
        await sincronizar(arquivo)
        return arquivo
    }

    // MARK: - Lixeira

    /// Move um arquivo para a lixeira. Se ele estiver resumindo/transcrevendo,
    /// a execução atual é cancelada antes do soft delete para a UI não ficar
    /// presa esperando o pipeline terminar.
    @discardableResult
    func moverParaLixeira(_ arquivo: Arquivo) async -> Bool {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return false }

        // `cancelarProcessamentoDoArquivo` também remove o id da fila. A
        // posição precisa ser capturada antes: se o save do soft delete
        // falhar, a conversa continua ativa e deve voltar ao processamento
        // que a própria pessoa já tinha pedido.
        let indiceNaFila = filaDeProcessamento.firstIndex(of: arquivo.id)
        let modoNaFila = modosDaFila[arquivo.id]
        let estavaEmProcessamento = arquivoEmProcessamento == arquivo.id
        await cancelarProcessamentoDoArquivo(arquivo.id)

        let chave = arquivo.id.rawValue
        let faseAnterior = fases[chave]
        let erroAnterior = erros[chave]
        fases[chave] = nil
        iniciadoEm[chave] = nil
        erros[chave] = nil
        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            // A lista contém previews sem arrays de Palavra. Buscar o registro
            // completo também garante que a sincronização não envie um objeto
            // parcial ao mover a conversa para a lixeira.
            var movido = try await exigirArquivoCompleto(arquivo.id)
            try await repositorio.moverParaLixeira(arquivo.id)
            arquivos.removeAll { $0.id == arquivo.id }

            movido.apagadoEm = Date()
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }
            arquivosNaLixeira.insert(movido, at: 0)
            await sincronizar(movido)
            return true
        } catch {
            // O registro continuou ativo porque o soft delete não foi salvo;
            // devolvemos a posição anterior da fila em vez de perder trabalho.
            fases[chave] = faseAnterior
            erros[chave] = erroAnterior
            if estavaEmProcessamento || indiceNaFila != nil {
                filaDeProcessamento.insert(
                    arquivo.id,
                    at: min(indiceNaFila ?? filaDeProcessamento.count, filaDeProcessamento.count)
                )
                modosDaFila[arquivo.id] = modoNaFila
                filaPersistida.registrar(
                    arquivo.id, espaco: arquivo.espaco, somenteResumo: modoNaFila == .somenteResumo
                )
                iniciarProximoProcessamentoSeNecessario()
            }
            erroDaLixeira = "Não foi possível mover o arquivo para a lixeira: %@".localized(error.localizedDescription)
            return false
        }
    }

    /// Restaura o arquivo para Todos os arquivos sem iniciar processamento de
    /// novo. Se ele tiver sido removido enquanto aguardava, a pessoa escolhe
    /// explicitamente quando reprocessá-lo — nunca carregamos modelos de surpresa.
    @discardableResult
    func restaurarDaLixeira(_ arquivo: Arquivo) async -> Bool {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return false }

        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            var restaurado = try await exigirArquivoCompleto(arquivo.id)
            try await repositorio.restaurar(arquivo.id)
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }

            restaurado.apagadoEm = nil
            arquivos.removeAll { $0.id == arquivo.id }
            arquivos.append(restaurado)
            arquivos.sort { $0.criadoEm > $1.criadoEm }
            await sincronizar(restaurado)
            return true
        } catch {
            erroDaLixeira = "Não foi possível recuperar o arquivo: %@".localized(error.localizedDescription)
            return false
        }
    }

    /// Exclusão irreversível. O repositório remove o registro, a pasta relativa
    /// correta e todos os arquivos derivados apenas neste ponto.
    func apagarDefinitivamente(_ arquivo: Arquivo) async {
        guard arquivo.apagadoEm != nil,
              arquivosNaLixeira.contains(where: { $0.id == arquivo.id }),
              arquivoEmProcessamento != arquivo.id,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else {
            erroDaLixeira = "Mova o arquivo para a lixeira antes de apagá-lo definitivamente.".localized
            return
        }

        erroDaLixeira = nil
        operacoesDeLixeiraEmAndamento.insert(arquivo.id)
        defer { operacoesDeLixeiraEmAndamento.remove(arquivo.id) }

        do {
            try await repositorio.apagar(arquivo.id, em: armazenamento)
            removerPastaDeAnexos(de: arquivo)
            if let equipeCloudKit {
                do {
                    try await filaCloudKit.agendarRemocao(arquivo.id, da: equipeCloudKit)
                    dispararEnvioCloudKit()
                } catch {
                    let mensagem = "A conversa saiu deste Mac, mas a remoção não entrou na fila do iCloud: %@".localized(error.localizedDescription)
                    estadoDaSincronizacaoCloudKit = .falhou(mensagem)
                    aoNotificar?("Falha ao remover do iCloud".localized, mensagem, .aviso)
                }
            }
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }
            filaDeProcessamento.removeAll { $0 == arquivo.id }
            modosDaFila[arquivo.id] = nil
            revisoes[arquivo.id] = nil
            fases[arquivo.id.rawValue] = nil
            erros[arquivo.id.rawValue] = nil
            // O registro e a pasta já saíram; agora nenhum store auxiliar
            // pode continuar apontando para esta conversa inexistente.
            LimpezaDeArquivo.executar(arquivo.id)
        } catch {
            erroDaLixeira = "Não foi possível apagar o arquivo definitivamente: %@".localized(error.localizedDescription)
        }
    }

    func restaurarTudoDaLixeira() async {
        let arquivos = arquivosNaLixeira
        guard !arquivos.isEmpty else { return }

        for arquivo in arquivos {
            _ = await restaurarDaLixeira(arquivo)
            if erroDaLixeira != nil { break }
        }
    }

    func esvaziarLixeira() async {
        let arquivos = arquivosNaLixeira
        guard !arquivos.isEmpty else { return }

        for arquivo in arquivos {
            await apagarDefinitivamente(arquivo)
            if erroDaLixeira != nil { break }
        }
    }

    /// Remove permanentemente toda a biblioteca de um espaço. A execução do
    /// pipeline é cancelada e aguardada antes de apagar o banco, impedindo que
    /// um processamento tardio recrie um registro depois da exclusão.
    ///
    /// O espaço pode ser diferente daquele aberto na interface. Isso é
    /// necessário ao excluir o perfil pessoal enquanto uma equipe está ativa:
    /// os dados da equipe permanecem no banco e na memória.
    @discardableResult
    func excluirDadosDaConta(espaco espacoAlvo: EspacoID? = nil) async throws -> [ArquivoID] {
        let espacoExcluido = espacoAlvo ?? espaco
        espacosExcluidos.insert(espacoExcluido)
        var exclusaoConcluida = false
        defer {
            if !exclusaoConcluida {
                espacosExcluidos.remove(espacoExcluido)
            }
        }
        let tarefa = tarefaDeProcessamento
        tarefa?.cancel()
        tarefaDeProcessamento = nil
        arquivoEmProcessamento = nil
        identificadorDaExecucao = nil
        filaDeProcessamento.removeAll()
        modosDaFila.removeAll()

        if let tarefa { await tarefa.value }

        // O repositório separa os registros por espaço. Apagar a pasta
        // `Gravacoes` inteira aqui apagava o áudio de outros espaços que
        // ainda continuavam no banco, deixando conversas sem mídia. Só as
        // pastas referenciadas pela conta atual participam desta exclusão.
        let arquivosAtivos = try await repositorio.listar(espaco: espacoExcluido)
        let arquivosArquivados = try await repositorio.listarNaLixeira(espaco: espacoExcluido)
        let arquivosDaConta = arquivosAtivos + arquivosArquivados
        let pastasDaConta = Set(
            arquivosDaConta.map(\.pastaRelativa).filter { !$0.isEmpty }
        )
        // Os registros saem primeiro e as pastas depois, uma a uma e sem
        // interromper: antes, a primeira pasta que falhasse (ou um caminho
        // fora do padrão) parava tudo com parte da mídia já apagada e os
        // registros ainda no banco — e a exclusão da conta nunca concluía.
        try await repositorio.apagarTodosOsDados(espaco: espacoExcluido)
        filaPersistida.removerTodas(do: espacoExcluido)
        arquivosDaConta.forEach(removerPastaDeAnexos)
        var pastasQueSobraram = 0
        for pastaRelativa in pastasDaConta {
            do {
                try armazenamento.removerGravacao(relativa: pastaRelativa)
            } catch {
                pastasQueSobraram += 1
            }
        }
        if pastasQueSobraram > 0 {
            aoNotificar?(
                "Parte do áudio não pôde ser apagada".localized,
                "%lld pasta(s) de gravação continuam no disco. Elas ficam na pasta de gravações do Ōmu e podem ser removidas pelo Finder.".localized(pastasQueSobraram),
                .aviso
            )
        }

        if espaco == espacoExcluido {
            arquivos.removeAll()
            arquivosNaLixeira.removeAll()
            fases.removeAll()
            iniciadoEm.removeAll()
            erros.removeAll()
            operacoesDeLixeiraEmAndamento.removeAll()
            erroDaLixeira = nil
        }

        exclusaoConcluida = true
        return arquivosDaConta.map(\.id)
    }

    /// Descarta somente a outbox de uma equipe que acabou de ser removida no
    /// CloudKit. Não mistura essa limpeza com a conta pessoal: uma equipe
    /// diferente pode ter alterações pendentes legítimas.
    func descartarOperacoesPendentes(daEquipeComID equipeID: String) async throws {
        try await filaCloudKit.descartarOperacoes(daEquipeComID: equipeID)
        // Os dados locais da equipe vão sair; um marcador sobrevivente faria
        // uma futura reentrada baixar "só o que mudou" sobre uma base vazia.
        try await marcadoresCloudKit.descartar(daEquipeComID: equipeID)
    }

    func estaEmOperacaoDeLixeira(_ arquivo: Arquivo) -> Bool {
        operacoesDeLixeiraEmAndamento.contains(arquivo.id)
    }

    func dispensarErroDaLixeira() {
        erroDaLixeira = nil
    }

    // MARK: - Edição de arquivos

    func renomear(_ arquivo: Arquivo, para novoTitulo: String) async {
        let tituloLimpo = novoTitulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return }

        do {
            var editado = try await exigirArquivoCompleto(arquivo.id)
            editado.titulo = tituloLimpo
            editado.tituloManual = true
            if let resumo = editado.resumo {
                editado.resumo = Resumo(
                    titulo: tituloLimpo,
                    visaoGeral: resumo.visaoGeral,
                    temas: resumo.temas,
                    citacoes: resumo.citacoes,
                    proximosPassos: resumo.proximosPassos
                )
            }
            try await repositorio.salvar(editado)
            await publicar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível renomear: %@".localized(error.localizedDescription)
        }
    }

    func atualizarMetadados(
        _ arquivo: Arquivo,
        titulo novoTitulo: String,
        criadoEm: Date,
        duracao: TimeInterval
    ) async {
        let tituloLimpo = novoTitulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tituloLimpo.isEmpty,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id)
        else { return }

        do {
            var editado = try await exigirArquivoCompleto(arquivo.id)
            // Só vira "título da pessoa" quando ela de fato o trocou: salvar
            // a ficha sem mexer no título não congela o provisório.
            let tituloExibido = editado.resumo?.titulo ?? editado.titulo
            if tituloLimpo != tituloExibido {
                editado.tituloManual = true
            }
            editado.titulo = tituloLimpo
            editado.criadoEm = criadoEm
            editado.duracao = duracao.isFinite ? max(0, duracao) : 0
            if let resumo = editado.resumo {
                editado.resumo = Resumo(
                    titulo: tituloLimpo,
                    visaoGeral: resumo.visaoGeral,
                    temas: resumo.temas,
                    citacoes: resumo.citacoes,
                    proximosPassos: resumo.proximosPassos
                )
            }
            try await repositorio.salvar(editado)
            await publicar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar as informações: %@".localized(error.localizedDescription)
        }
    }

    func atualizarNotas(_ notas: [NotaDaConversa], de arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }

        do {
            var editado = try await exigirArquivoCompleto(arquivo.id)
            // Fechar a conversa chama isto mesmo sem edição. Regravar (e, em
            // equipe, reenviar) algo idêntico marcava a conversa como "edição
            // local pendente" de quem só leu.
            guard editado.notas != notas else { return }
            editado.notas = notas
            try await repositorio.salvar(editado)
            await publicar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar as notas: %@".localized(error.localizedDescription)
        }
    }

    /// Salva a transcrição corrigida à mão.
    ///
    /// O resumo **não** é refeito: ele já foi gerado e regerar sozinho gastaria
    /// minutos de modelo sem a pessoa ter pedido. Quem quiser o resumo alinhado
    /// à correção reprocessa pelo menu.
    func atualizarTrechos(_ trechos: [Trecho], de arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }

        do {
            var editado = try await exigirArquivoCompleto(arquivo.id)
            editado.trechos = trechos
            try await repositorio.salvar(editado)
            await publicar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar a transcrição: %@".localized(error.localizedDescription)
        }
    }

    @discardableResult
    func duplicar(_ arquivo: Arquivo) async -> Arquivo? {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return nil }

        let origemCompleta: Arquivo
        do {
            origemCompleta = try await exigirArquivoCompleto(arquivo.id)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível duplicar: %@".localized(error.localizedDescription)
            return nil
        }

        let novoID = ArquivoID()
        // Conversa sem áudio (Granola, recebida de um colega): `pastaRelativa`
        // vazia resolveria para a RAIZ do armazenamento, e copiá-la para
        // dentro de `Gravacoes/<novo>` duplicava a biblioteca inteira e os
        // modelos, recursivamente. Aqui a cópia é só do registro.
        let semAudio = origemCompleta.semAudio
        let pastaNovaRelativa = semAudio
            ? ""
            : Armazenamento.caminhoRelativo(id: novoID.rawValue)

        do {
            var origemCopiada: (origem: URL, destino: URL)?
            if !semAudio {
                let origem = try armazenamento.resolverSeguro(relativo: origemCompleta.pastaRelativa)
                let destino = try armazenamento.resolverSeguro(relativo: pastaNovaRelativa)
                if FileManager.default.fileExists(atPath: origem.path) {
                    try FileManager.default.copyItem(at: origem, to: destino)
                    origemCopiada = (origem, destino)
                } else {
                    try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
                }
            }

            var copia = Arquivo(
                id: novoID,
                titulo: "%@ cópia".localized(origemCompleta.titulo),
                criadoEm: Date(),
                duracao: origemCompleta.duracao,
                pastaRelativa: pastaNovaRelativa,
                espaco: espaco,
                trechos: origemCompleta.trechos.map {
                    Trecho(start: $0.start, end: $0.end, texto: $0.texto, speaker: $0.speaker, palavras: $0.palavras)
                },
                notas: origemCompleta.notas.map {
                    NotaDaConversa(texto: $0.texto, start: $0.start, critica: $0.critica, tipo: $0.tipo)
                },
                resumo: origemCompleta.resumo,
                engineTranscricao: origemCompleta.engineTranscricao,
                engineResumo: origemCompleta.engineResumo
            )
            if let resumo = origemCompleta.resumo {
                copia.resumo = Resumo(
                    titulo: "%@ cópia".localized(resumo.titulo),
                    visaoGeral: resumo.visaoGeral,
                    temas: resumo.temas,
                    citacoes: resumo.citacoes,
                    proximosPassos: resumo.proximosPassos
                )
            }

            if let origemCopiada {
                let anexosCopiados = try MidiasDaConversa.anexosCopiados(
                    de: origemCompleta.id,
                    da: origemCopiada.origem,
                    para: origemCopiada.destino
                )
                if !anexosCopiados.isEmpty {
                    try MidiasDaConversa.salvar(anexosCopiados, para: novoID)
                }
            }
            TarefasGeraisStore.duplicar(origemCompleta, para: copia)
            try await repositorio.salvar(copia)
            arquivos.insert(copia, at: 0)
            await sincronizar(copia)
            return copia
        } catch {
            // O id novo ainda não é visível em lugar nenhum. Se a cópia de
            // disco, seus bookmarks ou o registro falharem, eliminar os dois
            // resíduos impede que uma tentativa posterior herde mídia órfã.
            MidiasDaConversa.remover(novoID)
            TarefasGeraisStore.remover(novoID)
            do {
                if !pastaNovaRelativa.isEmpty {
                    try armazenamento.removerGravacao(relativa: pastaNovaRelativa)
                }
                erros[origemCompleta.id.rawValue] = "Não foi possível duplicar: %@".localized(error.localizedDescription)
            } catch {
                erros[origemCompleta.id.rawValue] = "Não foi possível duplicar: %@. A cópia incompleta permaneceu no armazenamento para não apagar dados de forma insegura.".localized(error.localizedDescription)
            }
            return nil
        }
    }

    // MARK: - Processamento

    var processando: Bool {
        arquivoEmProcessamento != nil || !filaDeProcessamento.isEmpty
    }

    func enfileirarProcessamento(_ arquivo: Arquivo, modo: ModoDeProcessamento = .completo) {
        guard arquivoEmProcessamento != arquivo.id,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id),
              !filaDeProcessamento.contains(arquivo.id) else { return }

        erros[arquivo.id.rawValue] = nil
        filaDeProcessamento.append(arquivo.id)
        modosDaFila[arquivo.id] = modo
        filaPersistida.registrar(arquivo.id, espaco: arquivo.espaco, somenteResumo: modo == .somenteResumo)
        iniciarProximoProcessamentoSeNecessario()
    }

    /// Reenfileira o que ficou pendente neste espaço: pedidos interrompidos
    /// ao fechar o app ou trocar de espaço, e os recusados por falta de
    /// modelos. Chamado a cada carga da lista e quando o download dos modelos
    /// termina; pedidos já na fila são ignorados por `enfileirarProcessamento`.
    func retomarProcessamentosPendentes() {
        guard processamentoAutomatico else { return }
        let pendencias = filaPersistida.pendentes(do: espaco)
        guard !pendencias.isEmpty else { return }
        // Sem modelos (ou sem memória/disco) cada pedido seria recusado de
        // novo: melhor esperar em disco do que piscar o erro em cada cartão.
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        guard preflight == .pronto || preflight == .termicoCritico else { return }
        for pendencia in pendencias {
            let id = ArquivoID(rawValue: pendencia.id)
            guard arquivoEmProcessamento != id, !filaDeProcessamento.contains(id) else { continue }
            guard let arquivo = arquivos.first(where: { $0.id == id }) else {
                // Foi para a lixeira ou deixou de existir: não há o que retomar.
                filaPersistida.remover(id)
                continue
            }
            guard pendencia.tentativas < FilaDeProcessamentoPersistida.tentativasMaximas else {
                filaPersistida.remover(id)
                erros[pendencia.id] = "O processamento desta conversa foi interrompido mais de uma vez. Tente de novo pelo menu da conversa.".localized
                continue
            }
            enfileirarProcessamento(arquivo, modo: pendencia.somenteResumo ? .somenteResumo : .completo)
        }
    }

    /// Refaz só o resumo, sobre a transcrição atual — é o que "Gerar novo
    /// resumo" promete. O processamento completo refaria a transcrição e
    /// descartaria trechos corrigidos à mão e falantes preservados.
    func enfileirarNovoResumo(_ arquivo: Arquivo) {
        enfileirarProcessamento(arquivo, modo: .somenteResumo)
    }

    /// Conversas sem áudio (Granola, recebidas da equipe) não têm o que
    /// transcrever: "Transcrever"/"Reprocessar" só fazem sentido com mídia.
    func podeTranscrever(_ arquivo: Arquivo) -> Bool {
        !arquivo.semAudio
    }

    /// Pergunta antes de refazer uma transcrição que já existe. Injetável:
    /// os testes respondem sem abrir um alerta.
    var confirmarReprocessamento: @MainActor (Arquivo) -> Bool = Biblioteca.alertaDeReprocessamento

    /// "Reprocessar" do menu da conversa: refaz transcrição, falantes e
    /// resumo. Como isso descarta trechos corrigidos à mão e a atribuição de
    /// vozes, pede confirmação quando já existe o que perder.
    func reprocessar(_ arquivo: Arquivo) {
        guard podeTranscrever(arquivo) else {
            erros[arquivo.id.rawValue] = "Esta conversa não tem áudio para transcrever.".localized
            return
        }
        let temOQuePerder = !arquivo.trechos.isEmpty || arquivo.resumo != nil
        if temOQuePerder, !confirmarReprocessamento(arquivo) { return }
        enfileirarProcessamento(arquivo)
    }

    private static func alertaDeReprocessamento(_ arquivo: Arquivo) -> Bool {
        let alerta = NSAlert()
        alerta.alertStyle = .warning
        alerta.messageText = "Reprocessar esta conversa?".localized
        alerta.informativeText = "A transcrição e o resumo serão refeitos a partir do áudio. Correções feitas à mão no texto e na identificação das vozes serão perdidas. Para atualizar só o resumo, use \"Gerar novo resumo\" dentro da conversa.".localized
        alerta.addButton(withTitle: "Reprocessar".localized)
        alerta.addButton(withTitle: "Cancelar".localized)
        return alerta.runModal() == .alertFirstButtonReturn
    }

    /// Cancela e **espera o trabalho realmente parar**.
    ///
    /// `Task.cancel()` só levanta uma bandeira; quem decide obedecer é o
    /// código que roda dentro. O whisper e o Qwen trabalham em blocos longos e
    /// síncronos, então continuam ocupando GPU e memória por bastante tempo
    /// depois do pedido — e o `iniciarProximoProcessamentoSeNecessario()` já
    /// disparava o próximo em cima disso. Dois modelos pesados carregados
    /// ao mesmo tempo é o que fazia o `AVAudioRecorder` recusar começar a
    /// gravar logo em seguida.
    ///
    /// Esperar pelo `value` custa alguns segundos, mas garante que a máquina
    /// esteja livre antes de começar qualquer coisa nova.
    private func cancelarProcessamentoDoArquivo(_ arquivoID: ArquivoID) async {
        filaDeProcessamento.removeAll { $0 == arquivoID }
        modosDaFila[arquivoID] = nil
        filaPersistida.remover(arquivoID)
        guard arquivoEmProcessamento == arquivoID else { return }

        let emCurso = tarefaDeProcessamento
        tarefaDeProcessamento = nil
        arquivoEmProcessamento = nil
        identificadorDaExecucao = nil
        fases[arquivoID.rawValue] = nil
        iniciadoEm[arquivoID.rawValue] = nil

        emCurso?.cancel()
        await emCurso?.value

        iniciarProximoProcessamentoSeNecessario()
    }

    func estaProcessando(_ arquivo: Arquivo) -> Bool {
        arquivoEmProcessamento == arquivo.id
    }

    func estaNaFila(_ arquivo: Arquivo) -> Bool {
        filaDeProcessamento.contains(arquivo.id)
    }

    private func iniciarProximoProcessamentoSeNecessario() {
        // Um ditado ou uma separação de vozes em curso também tem modelos
        // carregados: a fila espera e é retomada quando eles terminam.
        guard arquivoEmProcessamento == nil, operacoesAvulsasComModelos == 0 else { return }

        while let proximoID = filaDeProcessamento.first {
            filaDeProcessamento.removeFirst()
            let modo = modosDaFila.removeValue(forKey: proximoID) ?? .completo
            guard let arquivo = arquivos.first(where: { $0.id == proximoID }) else {
                filaPersistida.remover(proximoID)
                continue
            }

            let execucao = UUID()
            filaPersistida.marcarInicio(proximoID)
            arquivoEmProcessamento = proximoID
            identificadorDaExecucao = execucao
            tarefaDeProcessamento = Task { [weak self] in
                await self?.executarProcessamento(arquivo, modo: modo, execucao: execucao)
            }
            return
        }
    }

    /// O estado térmico crítico não bloqueia — quem pediu a transcrição pode
    /// precisar dela agora —, mas a pessoa tem de saber por que vai demorar e
    /// que dá para cancelar na fila e tentar depois. Um aviso por episódio de
    /// calor: a fila reavalia a cada item e não deve repetir a mesma mensagem.
    private func avisarSeOMacEstiverQuente(_ preflight: ResultadoPreflight) {
        guard preflight == .termicoCritico else {
            avisouMacQuente = false
            return
        }
        guard !avisouMacQuente else { return }
        avisouMacQuente = true
        aoNotificar?(
            "Seu Mac está muito quente".localized,
            "A transcrição vai ficar mais lenta e esquentar mais o Mac. Se preferir, cancele na fila e tente de novo depois.".localized,
            .aviso
        )
    }

    /// Transcreve um trecho ditado e devolve o texto corrido.
    ///
    /// Mesmo Whisper das conversas, e descarrega no fim: uma nota ditada não
    /// justifica deixar modelos pesados residentes.
    func transcreverDitado(_ audio: URL) async throws -> String {
        // Com uma conversa em processamento, carregar um segundo Whisper
        // (3 GB) ao lado do Qwen (6 GB) quebra a regra "nunca os dois
        // residentes" num Mac de 18 GB — e o ditado ainda ficaria minutos
        // esperando a fila do VAD. Quem chama usa o texto reconhecido ao vivo.
        guard arquivoEmProcessamento == nil, operacoesAvulsasComModelos == 0 else {
            throw ErroDeDitado.modelosOcupados
        }
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            throw ErroDeDitado.modelosIndisponiveis(preflight.mensagem)
        }

        operacoesAvulsasComModelos += 1
        defer {
            operacoesAvulsasComModelos -= 1
            iniciarProximoProcessamentoSeNecessario()
        }
        let motores = criarMotoresLocais()
        return try await OperacaoComLimpeza.executar {
            try await motores.transcrever(audio, speaker: nil, initialPrompt: nil)
                .map(\.texto)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } limpar: {
            await motores.descarregarTudo()
        }
    }

    enum ErroDeDitado: LocalizedError {
        case modelosIndisponiveis(String)
        case modelosOcupados

        var errorDescription: String? {
            switch self {
            case let .modelosIndisponiveis(motivo): motivo
            case .modelosOcupados:
                "O refinamento do ditado fica disponível quando o processamento em andamento terminar.".localized
            }
        }
    }

    private func executarProcessamento(
        _ arquivo: Arquivo,
        modo: ModoDeProcessamento,
        execucao: UUID
    ) async {
        let chave = arquivo.id.rawValue
        defer { finalizarProcessamento(chave, execucao: execucao) }

        let arquivoCompleto: Arquivo
        do {
            arquivoCompleto = try await exigirArquivoCompleto(arquivo.id)
        } catch {
            erros[chave] = "Não foi possível abrir a conversa para processamento: %@".localized(error.localizedDescription)
            filaPersistida.remover(arquivo.id)
            return
        }
#if OMU_PERF
        PerfProbe.shared.registrarPipelineInicio(arquivoCompleto)
#endif

        // Antes de qualquer checagem de modelo: pedir o impossível deve
        // dizer por quê, e não "faltam os pesos".
        if modo == .somenteResumo, arquivoCompleto.trechos.isEmpty {
            erros[chave] = "Não há transcrição para resumir.".localized
            filaPersistida.remover(arquivo.id)
            return
        }
        if modo == .completo, arquivoCompleto.semAudio {
            erros[chave] = "Esta conversa não tem áudio para transcrever.".localized
            filaPersistida.remover(arquivo.id)
            return
        }

        // Sem os pesos, o Whisper falharia lá dentro com um erro de carga. Dizer
        // o que falta é mais útil que repassar o erro do llama.cpp.
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            erros[chave] = preflight.mensagem
            // O pedido continua valendo: é retomado quando os modelos
            // chegarem (ou na próxima abertura), sem contar como tentativa.
            filaPersistida.adiar(arquivo.id)
            return
        }
        avisarSeOMacEstiverQuente(preflight)

        erros[chave] = nil
        fases[chave] = modo == .somenteResumo ? .resumindo : .transcrevendo
        iniciadoEm[chave] = Date()

        // O usuário iniciou explicitamente a transcrição. Mantém o trabalho
        // elegível para execução em segundo plano sem depender do App Nap;
        // o defer libera a asserção também em erro, retorno antecipado ou
        // cancelamento, depois da descarga garantida dos modelos.
        let atividadeDeProcessamento = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Processando uma reunião solicitada pelo usuário"
        )
        defer { ProcessInfo.processInfo.endActivity(atividadeDeProcessamento) }
#if OMU_PERF
        // Reusa a normalização real do prompt com nomes sintéticos, sem consultar Contatos ou Calendário.
        let promptDeEntidades = await PromptDeEntidades.construir(
            para: arquivoCompleto,
            termosSinteticos: PerfProbe.termosDeEntidades
        )
#else
        let promptDeEntidades = await PromptDeEntidades.construir(para: arquivoCompleto)
#endif
        // Criado por execução, e descarregado no fim: os dois modelos somam
        // Eles não podem ficar residentes entre gravações num Mac de 18 GB.
        let motores = criarMotoresLocais()

        // Diarização acústica: mini modelos embutidos no bundle (~40 MB
        // compilados). Se o bootstrap não os estagiou, a primeira diarização
        // falha — e o pipeline engole: é uma camada decorativa por cima da
        // transcrição, nunca um bloqueio (ver PipelineDeArquivo).
        let diarizacao = GerenciadorDeModelosDeDiarizacao.embutido()
        await ciclo.registrar(diarizacao)

        let pipeline = PipelineDeArquivo(
            armazenamento: armazenamento,
            repositorio: repositorio,
            idTranscricao: WhisperEngine.identificador,
            idResumo: QwenEngine.identificador,
            transcrever: { [motores, promptDeEntidades] url, speaker in
                try await motores.transcrever(
                    url,
                    speaker: speaker,
                    initialPrompt: promptDeEntidades
                )
            },
            resumir: { [motores] trechos in
                try await motores.resumir(trechos)
            },
            resumirNoIdioma: { [motores] trechos, idiomaDeSaida in
                try await motores.resumir(trechos, idiomaDeSaida: idiomaDeSaida)
            },
            // Sem tradução: o Whisper detecta o idioma falado e a transcrição e o
            // resumo ficam nesse idioma (inglês → inglês, português → português).
            diarizar: { [diarizacao] url in
                try await diarizacao.diarizar(url)
            },
            resolverFalantes: { [motores] arquivo in
                try await motores.resolverFalantes(arquivo)
            },
            liberarTranscricao: { [motores] in
                await motores.descarregarTranscricao()
            }
        )

        await OperacaoComLimpeza.executar {
            do {
                let aoProgredir: @Sendable (PipelineDeArquivo.Fase) -> Void = { fase in
                    let instante = DispatchTime.now().uptimeNanoseconds
                    Task { @MainActor [weak self] in
                        guard self?.identificadorDaExecucao == execucao else { return }
#if OMU_PERF
                        PerfProbe.shared.registrarFase(String(describing: fase), timestamp: instante)
#endif
                        _ = instante
                        self?.fases[chave] = fase
                    }
                }
                switch modo {
                case .completo:
                    try await pipeline.processar(arquivoCompleto, aoProgredir: aoProgredir)
                case .somenteResumo:
                    try await pipeline.resumirExistente(arquivoCompleto, aoProgredir: aoProgredir)
                }
                // O trabalho está salvo no banco, qualquer que seja o espaço
                // aberto agora.
                filaPersistida.remover(arquivoCompleto.id)
                guard identificadorDaExecucao == execucao else { return }
                // O pipeline gravou só transcrição e resumo; título, data e
                // notas podem ter mudado enquanto ele trabalhava. A versão
                // que vai para a tela e para a equipe é a do banco.
                let final = try await exigirArquivoCompleto(arquivoCompleto.id)
                guard identificadorDaExecucao == execucao else { return }
                guard final.espaco == espaco,
                      arquivos.contains(where: { $0.id == final.id })
                else {
                    // A pessoa trocou de espaço no meio: a conversa não está
                    // na tela, mas o aviso de que ficou pronta ainda vale.
                    if final.espaco != espaco, final.apagadoEm == nil {
                        aoNotificar?(
                            "Transcrição concluída".localized,
                            "%@ já está com transcrição e resumo prontos.".localized(final.resumo?.titulo ?? final.titulo),
                            .sucesso
                        )
                    }
                    return
                }
                await publicar(final)
                aoConcluirProcessamento?(final)
                if final.trechos.isEmpty {
                    erros[chave] = "Nenhuma fala reconhecida neste áudio.".localized
                    aoNotificar?(
                        "Transcrição finalizada sem falas".localized,
                        "%@ não teve fala reconhecida.".localized(final.resumo?.titulo ?? final.titulo),
                        .aviso
                    )
                } else {
                    aoNotificar?(
                        "Transcrição concluída".localized,
                        "%@ já está com transcrição e resumo prontos.".localized(final.resumo?.titulo ?? final.titulo),
                        .sucesso
                    )
                }
            } catch is CancellationError {
                // Cancelar (ou mover para a lixeira) é decisão da pessoa, não
                // falha: sem erro no cartão e sem notificação do sistema.
            } catch {
                // Uma falha de verdade não se repete sozinha a cada abertura;
                // o cancelamento (fechar o app) deixa o pedido pendente.
                if !Task.isCancelled { filaPersistida.remover(arquivoCompleto.id) }
                guard !Task.isCancelled, identificadorDaExecucao == execucao else { return }
                erros[chave] = error.localizedDescription
                aoNotificar?(
                    modo == .somenteResumo ? "Resumo falhou".localized : "Transcrição falhou".localized,
                    "\(arquivoCompleto.titulo): \(error.localizedDescription)",
                    .erro
                )
            }
        } limpar: {
            // Só retorna quando os modelos de linguagem e diarização saíram
            // da memória, mesmo em erro, cancelamento ou guarda antecipada.
            await motores.descarregarTudo()
            await diarizacao.descarregar()
            await ciclo.remover(GerenciadorDeModelosDeDiarizacao.identificador)
        }
    }

    /// Aplica a diarização às palavras de uma transcrição já salva, sem
    /// re-transcrever nem resumir — para arquivos de antes da diarização
    /// existir. Os modelos pequenos de diarização (~40 MB) entram sempre; o
    /// Whisper nunca. O Qwen entra SÓ se sobrarem falas curtas entre vozes
    /// DIFERENTES para a resolução contextual — se a costura de vozes iguais
    /// resolver tudo, o modelo nem carrega (ver `MotoresLocais
    /// .resolverFalantes`).
    func diarizarTranscricao(_ arquivo: Arquivo) async {
        guard arquivoEmProcessamento != arquivo.id,
              !filaDeProcessamento.contains(arquivo.id),
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }
        let chave = arquivo.id.rawValue
        guard fases[chave] == nil else { return }

        let arquivoCompleto: Arquivo
        do {
            arquivoCompleto = try await exigirArquivoCompleto(arquivo.id)
        } catch {
            erros[chave] = "Não foi possível abrir a transcrição: %@".localized(error.localizedDescription)
            return
        }

        let diarizacao = GerenciadorDeModelosDeDiarizacao.embutido()
        guard diarizacao.disponivel else {
            erros[chave] = "Modelos de diarização não estagiados. Rode Scripts/bootstrap-runtimes.sh.".localized
            return
        }

        // Mesma regra do ditado: nunca um segundo conjunto de modelos ao
        // lado de um processamento em curso.
        guard arquivoEmProcessamento == nil, operacoesAvulsasComModelos == 0 else {
            erros[chave] = "Aguarde o processamento em andamento terminar para separar as vozes.".localized
            return
        }

        erros[chave] = nil
        fases[chave] = .diarizando
        operacoesAvulsasComModelos += 1
        defer {
            operacoesAvulsasComModelos -= 1
            iniciarProximoProcessamentoSeNecessario()
        }
        await ciclo.registrar(diarizacao)

        // Os motores são apenas o contrato do pipeline; o caminho leve nunca
        // chama transcrever/resumir, então o Whisper não entra em memória. A
        // resolução contextual usa o Qwen quando há caso entre vozes
        // diferentes (o mesmo modelo do resumo, carregado e descarregado aqui).
        let motores = criarMotoresLocais()
        let pipeline = PipelineDeArquivo(
            armazenamento: armazenamento,
            repositorio: repositorio,
            idTranscricao: WhisperEngine.identificador,
            idResumo: QwenEngine.identificador,
            transcrever: { [motores] url, speaker in
                try await motores.transcrever(url, speaker: speaker)
            },
            resumir: { [motores] trechos in
                try await motores.resumir(trechos)
            },
            diarizar: { [diarizacao] url in
                try await diarizacao.diarizar(url)
            },
            resolverFalantes: { [motores] arquivo in
                try await motores.resolverFalantes(arquivo)
            }
        )

        await OperacaoComLimpeza.executar {
            let diarizado = await pipeline.diarizarExistente(arquivoCompleto)
            guard arquivos.contains(where: { $0.id == arquivoCompleto.id }) else { return }
            do {
                // Só os trechos: título, notas e resumo podem ter mudado
                // enquanto a diarização rodava.
                try await repositorio.salvarResultadoDoProcessamento(diarizado, partes: .transcricao)
                let salvo = try await exigirArquivoCompleto(diarizado.id)
                await publicar(salvo)
            } catch {
                erros[chave] = "Não foi possível salvar a diarização: %@".localized(error.localizedDescription)
            }
        } limpar: {
            await motores.descarregarTudo()
            await diarizacao.descarregar()
            await ciclo.remover(GerenciadorDeModelosDeDiarizacao.identificador)
        }
        fases[chave] = nil
    }

    private func finalizarProcessamento(_ chave: UUID, execucao: UUID) {
        guard identificadorDaExecucao == execucao else { return }

        // Antes de esquecer o começo, aprende com ele: quanto este Mac levou
        // por segundo de áudio. É esse número que a próxima estimativa usa.
        if let inicio = iniciadoEm[chave],
           let arquivo = arquivos.first(where: { $0.id.rawValue == chave }),
           arquivo.duracao > 0 {
            RitmoDeProcessamento.registrar(
                decorrido: Date().timeIntervalSince(inicio),
                paraAudioDe: arquivo.duracao
            )
        }

        fases[chave] = nil
        iniciadoEm[chave] = nil
        arquivoEmProcessamento = nil
        identificadorDaExecucao = nil
        tarefaDeProcessamento = nil
        iniciarProximoProcessamentoSeNecessario()
    }

    private func substituir(_ arquivo: Arquivo) {
        if let indice = arquivos.firstIndex(where: { $0.id == arquivo.id }) {
            arquivos[indice] = arquivo
        } else {
            arquivos.insert(arquivo, at: 0)
        }
        revisoes[arquivo.id, default: 0] += 1
    }

    /// Leva uma conversa já salva para a lista e para a fila do iCloud —
    /// **só se ela pertence ao espaço aberto agora**.
    ///
    /// As edições suspendem ao ler e salvar. Se o espaço mudou nesse meio
    /// (aceitar um convite com uma conversa pessoal aberta basta), a conversa
    /// era inserida na lista do novo espaço e enviada à zona da nova equipe.
    /// O que foi salvo continua no banco, no espaço certo, e reaparece
    /// quando ele for aberto.
    private func publicar(_ arquivo: Arquivo) async {
        guard arquivo.espaco == espaco else { return }
        if arquivo.apagadoEm == nil {
            substituir(arquivo)
        } else {
            revisoes[arquivo.id, default: 0] += 1
        }
        await sincronizar(arquivo)
    }

    private func sincronizar(_ arquivo: Arquivo) async {
        // Nunca para "a equipe ativa": só para a equipe dona do espaço da
        // conversa, que é a que está aberta quando os espaços coincidem.
        guard let equipeCloudKit, arquivo.espaco == espaco else { return }
        estadoDaSincronizacaoCloudKit = .enviando
        do {
            try await filaCloudKit.agendarEnvio(arquivo, para: equipeCloudKit)
            dispararEnvioCloudKit()
        } catch {
            let mensagem = "Não foi possível guardar a sincronização pendente de %@: %@".localized(arquivo.titulo, error.localizedDescription)
            estadoDaSincronizacaoCloudKit = .falhou(mensagem)
            aoNotificar?("Conversa salva só neste Mac".localized, mensagem, .aviso)
        }
    }

    /// Processa a fila do iCloud fora do caminho de quem salvou.
    ///
    /// Antes, registrar uma gravação, salvar notas ou mover para a lixeira
    /// esperavam a fila inteira passar pela rede: em equipe, a transcrição só
    /// entrava na fila depois dessa tentativa e as notas ficavam em
    /// "Salvando…" no ritmo do iCloud. A operação já está gravada na fila
    /// durável; o envio é uma tarefa única que se repete se algo novo chegar
    /// enquanto ela roda.
    private func dispararEnvioCloudKit() {
        guard tarefaDeEnvioCloudKit == nil else {
            haEnvioCloudKitAguardando = true
            return
        }
        tarefaDeEnvioCloudKit = Task { @MainActor [weak self] in
            repeat {
                self?.haEnvioCloudKitAguardando = false
                await self?.retomarSincronizacaoCloudKit()
            } while self?.haEnvioCloudKitAguardando == true && !Task.isCancelled
            self?.tarefaDeEnvioCloudKit = nil
        }
    }

    /// Espera o envio em curso terminar. Para os testes e para quem precisa
    /// do estado final da sincronização (encerramento, troca de equipe).
    func aguardarEnvioCloudKit() async {
        while let tarefa = tarefaDeEnvioCloudKit {
            await tarefa.value
        }
    }

    func retomarSincronizacaoCloudKit(forcar: Bool = false) async {
        guard equipeCloudKit != nil else { return }
        if !avisouQuarentenaDaFila, let quarentena = filaCloudKit.quarentena {
            avisouQuarentenaDaFila = true
            aoNotificar?(
                "Fila do iCloud recuperada".localized,
                "A lista de alterações pendentes estava ilegível. As que puderam ser lidas continuam na fila; o arquivo original foi guardado em %@.".localized(quarentena.lastPathComponent),
                .aviso
            )
        }
        let contexto = contextoDoEspaco
        tarefaDeRetryCloudKit?.cancel()
        tarefaDeRetryCloudKit = nil
        estadoDaSincronizacaoCloudKit = .enviando

        do {
            let resultado = try await filaCloudKit.processar(
                com: sincronizadorCloudKit,
                ignorarBackoff: forcar
            )
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            if resultado.pendentes == 0 {
                estadoDaSincronizacaoCloudKit = .sincronizado
            } else {
                let erro = resultado.erros.first ?? ""
                let detalhe = erro.isEmpty
                    ? ""
                    : ": \(DiagnosticoDaSincronizacaoCloudKit.mensagem(paraTexto: erro))"
                if resultado.bloqueadas == resultado.pendentes {
                    // Tudo o que resta foi recusado por algo que repetir não
                    // resolve: dizer isso, em vez de "nova tentativa".
                    estadoDaSincronizacaoCloudKit = .falhou(
                        "%d alteração(ões) não puderam ser enviadas ao iCloud e ficaram só neste Mac%@. Verifique sua permissão na equipe e o espaço no iCloud, depois toque em tentar de novo.".localized(resultado.pendentes, detalhe)
                    )
                } else {
                    estadoDaSincronizacaoCloudKit = .falhou(
                        "%d alteração(ões) aguardando nova tentativa no iCloud%@".localized(resultado.pendentes, detalhe)
                    )
                }
                if !DiagnosticoDaSincronizacaoCloudKit.exigeAcaoDoProprietario(erro) {
                    agendarRetryCloudKit(para: resultado.proximaTentativa)
                }
            }
        } catch {
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            let mensagem = "Não foi possível ler ou salvar a fila do iCloud: %@".localized(error.localizedDescription)
            estadoDaSincronizacaoCloudKit = .falhou(mensagem)
            aoNotificar?("Falha na fila do iCloud".localized, mensagem, .aviso)
        }
    }

    private func agendarRetryCloudKit(para data: Date?) {
        guard let data else { return }
        let atraso = min(max(0.1, data.timeIntervalSinceNow), 15 * 60)
        let nanos = UInt64(atraso * 1_000_000_000)
        tarefaDeRetryCloudKit = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await retomarSincronizacaoCloudKit()
        }
    }

    /// Envia o que estiver pendente e relê a zona inteira da equipe. É o
    /// caminho do botão "Tentar agora": além de repetir a fila, serve de
    /// recuperação se a cópia local tiver se afastado do iCloud.
    func sincronizarEquipeAgora() async {
        await retomarSincronizacaoCloudKit(forcar: true)
        await baixarAtualizacoesDaEquipe(completa: true)
    }

    /// Consulta discreta: não mexe no indicador enquanto roda e não gera
    /// notificação se a rede falhar — a próxima consulta tenta de novo.
    func atualizarEquipeEmSegundoPlano() async {
        await baixarAtualizacoesDaEquipe(discreta: true)
    }

    private func agendarAtualizacaoDaEquipe() {
        tarefaDeAtualizacaoDaEquipe?.cancel()
        guard equipeCloudKit != nil else { return }
        let intervalo = intervaloDeAtualizacaoDaEquipe
        tarefaDeAtualizacaoDaEquipe = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: intervalo)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await atualizarEquipeEmSegundoPlano()
            }
        }
    }

    private func baixarAtualizacoesDaEquipe(
        completa: Bool = false,
        discreta: Bool = false
    ) async {
        guard let equipeCloudKit else { return }
        // Duas baixas simultâneas do mesmo espaço aplicariam as mesmas
        // alterações e poderiam gravar um marcador antigo por cima do novo.
        // A de um espaço anterior não bloqueia: ela se encerra sozinha ao
        // perceber que o contexto mudou.
        let contexto = contextoDoEspaco
        guard baixaDaEquipeEmAndamento != contexto else { return }
        baixaDaEquipeEmAndamento = contexto
        defer {
            if baixaDaEquipeEmAndamento == contexto { baixaDaEquipeEmAndamento = nil }
        }

        if !discreta {
            estadoDaSincronizacaoCloudKit = .enviando
        }
        do {
            // Sem nenhuma conversa local não existe base para "só o que
            // mudou": um marcador herdado esconderia a equipe inteira.
            let semBaseLocal = arquivos.isEmpty && arquivosNaLixeira.isEmpty
            let marcador = completa || semBaseLocal
                ? nil
                : await marcadoresCloudKit.marcador(para: equipeCloudKit)
            let baixado = try await sincronizadorCloudKit.baixarAlteracoes(
                da: equipeCloudKit,
                desde: marcador
            )
            // Lidas depois da rede: um envio concluído durante a baixa já
            // conta como entregue, e o eco dele não volta por cima do local.
            let revisoesPendentes = try await filaCloudKit.revisoesLocaisPendentes(
                equipeID: equipeCloudKit.id
            )
            let revisoesEntregues = await filaCloudKit.revisoesEntregues(equipeID: equipeCloudKit.id)
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }

            var conflitos = 0
            var mudouAlgo = false
            for conversa in baixado.conversas {
                guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
                switch PoliticaDeConflitoCloudKit.decidir(
                    revisaoRemota: conversa.atualizadoEm,
                    revisaoLocalPendente: revisoesPendentes[conversa.arquivo.id],
                    revisoesEntreguesDaqui: revisoesEntregues[conversa.arquivo.id] ?? []
                ) {
                case .aplicarRemoto:
                    break
                case .ignorarEco, .preservarLocalPendente:
                    continue
                case .conflito:
                    conflitos += 1
                    continue
                }
                let local = (arquivos + arquivosNaLixeira).first {
                    $0.id == conversa.arquivo.id
                }
                if local != nil,
                   revisoesRemotasAplicadas[conversa.arquivo.id] == conversa.atualizadoEm {
                    continue
                }
                let midiaLocalExiste = local.map {
                    !$0.pastaRelativa.isEmpty
                        && FileManager.default.fileExists(
                            atPath: armazenamento.resolver(relativo: $0.pastaRelativa).path
                        )
                } ?? false
                let combinado = PoliticaDeMidiaCloudKit.mesclar(
                    remoto: conversa.arquivo,
                    local: local,
                    midiaLocalExiste: midiaLocalExiste
                )
                // Com o estado de lixeira que veio: a restauração (ou a
                // exclusão) feita por um colega vale aqui também.
                try await repositorio.salvarRecebido(combinado)
                revisoesRemotasAplicadas[conversa.arquivo.id] = conversa.atualizadoEm
                revisoes[conversa.arquivo.id, default: 0] += 1
                mudouAlgo = true
            }
            let ilegiveis = await sincronizadorCloudKit.ignoradasNoUltimoDownload
            // A consulta periódica repete a baixa enquanto a conversa seguir
            // ilegível; o aviso fica com as ações que a pessoa de fato pediu.
            if ilegiveis > 0, !discreta {
                aoNotificar?(
                    "Conversas da equipe não lidas".localized,
                    "%lld conversa(s) da equipe não puderam ser lidas e foram puladas. Atualizar o Ōmu costuma resolver.".localized(ilegiveis),
                    .aviso
                )
            }
            for id in baixado.removidas {
                guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
                // Uma edição local que ainda vai subir recria o registro.
                guard revisoesPendentes[id] == nil else { continue }
                if try await recolherConversaApagadaNaEquipe(id) { mudouAlgo = true }
            }
            // Só depois de tudo aplicado: se algo acima falhar, a próxima
            // baixa recebe as mesmas alterações outra vez.
            try await marcadoresCloudKit.guardar(baixado.marcador, para: equipeCloudKit)
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            if mudouAlgo || !discreta {
                // A lixeira da equipe só é expurgada com o estado dos colegas
                // já aplicado — e inteiro: uma conversa ilegível pode ser
                // justamente a restauração feita por alguém.
                lixeiraDaEquipeConferida = ilegiveis == 0
                await carregar()
                lixeiraDaEquipeConferida = false
                guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            }
            if conflitos > 0 {
                let mensagem = "%d conversa(s) têm uma edição local pendente; a cópia local foi preservada até o próximo envio.".localized(conflitos)
                estadoDaSincronizacaoCloudKit = .falhou(mensagem)
                aoNotificar?("Conflito de sincronização".localized, mensagem, .aviso)
                return
            }
            let pendentes = try await filaCloudKit.operacoesPendentes().count
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            if pendentes == 0 {
                estadoDaSincronizacaoCloudKit = .sincronizado
            } else if !discreta {
                estadoDaSincronizacaoCloudKit = .falhou(
                    "%d alteração(ões) continuam na fila do iCloud.".localized(pendentes)
                )
            }
        } catch {
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            // Offline, a consulta periódica falharia a cada minuto. O estado
            // e o aviso ficam com as ações que a pessoa de fato pediu.
            guard !discreta else { return }
            let mensagem = "Não foi possível baixar as conversas da equipe: %@".localized(DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error))
            estadoDaSincronizacaoCloudKit = .falhou(mensagem)
            aoNotificar?("Falha de sincronização do iCloud".localized, mensagem, .aviso)
        }
    }

    /// Alguém da equipe apagou a conversa definitivamente. Neste Mac ela vai
    /// para a lixeira em vez de sumir: a mídia só existe aqui, e uma ação
    /// remota não deve destruir o que ainda pode ser recuperado. Não há envio
    /// de volta — isso recriaria o registro que acabou de ser apagado.
    private func recolherConversaApagadaNaEquipe(_ id: ArquivoID) async throws -> Bool {
        guard arquivos.contains(where: { $0.id == id }) else { return false }
        await cancelarProcessamentoDoArquivo(id)
        try await repositorio.moverParaLixeira(id)
        return true
    }

    // MARK: - Consulta pela view

    func arquivo(id: UUID) -> Arquivo? {
        arquivos.first { $0.id.rawValue == id }
    }

    func buscarArquivoCompleto(id: UUID) async throws -> Arquivo? {
        try await repositorio.buscarCompleto(id: ArquivoID(rawValue: id))
    }

    private func exigirArquivoCompleto(_ id: ArquivoID) async throws -> Arquivo {
        guard let arquivo = try await repositorio.buscarCompleto(id: id) else {
            throw ErroDeReidratacao.arquivoAusente
        }
        return arquivo
    }

    /// Apaga a pasta de anexos de uma conversa sem áudio — o repositório só
    /// conhece `pastaRelativa`, que nelas é vazia. Inclui o endereço antigo
    /// (`MidiaIndisponivel/<id>`), de antes de a pasta ir para `Gravacoes`.
    private func removerPastaDeAnexos(de arquivo: Arquivo) {
        guard arquivo.semAudio else { return }
        let id = arquivo.id.rawValue
        try? armazenamento.removerGravacao(relativa: Armazenamento.caminhoRelativo(id: id))
        try? FileManager.default.removeItem(
            at: armazenamento.raiz
                .appendingPathComponent("MidiaIndisponivel", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        )
    }

    /// Canal principal para reprodução, na nova convenção: `microfone.wav`.
    ///
    /// Gravações antigas e arquivos importados têm **um único arquivo** (a
    /// mixagem legada `gravacao.m4a` ou o original copiado como `gravacao.<ext>`);
    /// nesses casos ele é o canal único. A reprodução em dois canais usa
    /// `audioSecundario` junto.
    func audio(de arquivo: Arquivo) -> URL {
        if arquivo.semAudio {
            // Sem áudio (Granola, conversa de colega), a pasta da conversa
            // só existe para os anexos. Ela mora em `Gravacoes/<id>` como
            // todas as outras: fora dali a lixeira de mídia recusava os
            // anexos e nada os apagava junto com a conversa.
            return armazenamento
                .resolver(relativo: Armazenamento.caminhoRelativo(id: arquivo.id.rawValue))
                .appendingPathComponent("audio-indisponivel")
        }
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        let microfone = pasta.appendingPathComponent(Armazenamento.Nome.microfone)
        if Self.existe(microfone) { return microfone }
        return Self.arquivoDeCanalUnico(em: pasta)
    }

    /// Veio de arquivo escolhido pela pessoa, e não do microfone.
    ///
    /// Deduzido do disco, e não guardado no modelo: gravação sempre escreve
    /// `microfone.wav`, importação sempre escreve `gravacao.<extensão>`. Um
    /// campo novo em `Arquivo` obrigaria a migrar o que já está salvo para
    /// responder algo que os próprios arquivos já dizem.
    func importado(_ arquivo: Arquivo) -> Bool {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        return !Self.existe(pasta.appendingPathComponent(Armazenamento.Nome.microfone))
    }

    /// Canal do sistema tocado em paralelo ao microfone — `sistema.caf`.
    ///
    /// Só existe quando a gravação capturou os dois canais (o tap subiu).
    /// Importado e legado são canal único: `nil` aqui, e a reprodução toca
    /// só o principal.
    func audioSecundario(de arquivo: Arquivo) -> URL? {
        let pasta = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        guard Self.existe(pasta.appendingPathComponent(Armazenamento.Nome.microfone)) else {
            return nil
        }
        for nome in [Armazenamento.Nome.sistema, Armazenamento.Nome.sistemaM4ALegado] {
            let sistema = pasta.appendingPathComponent(nome)
            if Self.existe(sistema) { return sistema }
        }
        return nil
    }

    private static func existe(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// O arquivo único de quando não há canais separados: a mixagem legada
    /// `gravacao.m4a`, ou o importado copiado como veio (`gravacao.<ext>`).
    private static func arquivoDeCanalUnico(em pasta: URL) -> URL {
        let mixagem = pasta.appendingPathComponent(Armazenamento.Nome.mixagem)
        if existe(mixagem) { return mixagem }
        let conteudo = (try? FileManager.default.contentsOfDirectory(
            at: pasta, includingPropertiesForKeys: nil
        )) ?? []
        if let importado = conteudo.first(where: {
            $0.lastPathComponent.hasPrefix(Armazenamento.Nome.prefixoImportado + ".")
        }) {
            return importado
        }
        return mixagem
    }

    /// Estado do arquivo no pipeline.
    ///
    /// Devolvia `String`, e cada tela reclassificava esse texto por conta
    /// própria: o cartão por lista de literais, o detalhe por `contains("erro")`.
    /// O mesmo arquivo aparecia vermelho numa tela e neutro na outra, e trocar
    /// uma palavra em `Fase.descricao` quebrava a cor sem quebrar o build.
    /// Quanto do processamento já passou e quanto falta, em segundos.
    ///
    /// Continua sendo **estimativa por tempo decorrido** — nem o whisper nem o
    /// Qwen reportam percentual daqui —, mas agora calibrada por este Mac, e
    /// não por um fator fixo. Ver `RitmoDeProcessamento`.
    ///
    /// A fração satura em 95% enquanto o trabalho não termina: barra parada em
    /// 100% com o app ainda pensando é pior que barra lenta.
    func progresso(de arquivo: Arquivo) -> (inicio: Date, estimativa: TimeInterval)? {
        let chave = arquivo.id.rawValue
        guard fases[chave] != nil, let inicio = iniciadoEm[chave] else { return nil }
        return (inicio, RitmoDeProcessamento.estimativa(paraAudioDe: arquivo.duracao))
    }

    func estado(de arquivo: Arquivo) -> EstadoDoArquivo {
        let chave = arquivo.id.rawValue
        if let fase = fases[chave] { return .processando(fase) }
        if let posicao = filaDeProcessamento.firstIndex(of: arquivo.id) {
            return .naFila(posicao: posicao + 1)
        }
        if let erro = erros[chave] { return .falhou(erro) }
        if arquivo.resumo != nil { return .transcritoEResumido }
        if !arquivo.trechos.isEmpty { return .transcrito }
        return .prontoParaTranscrever
    }

    /// Cria um Arquivo definitivo a partir de uma reunião pendente + áudio.
    ///
    /// O áudio é obrigatório: gravar ou importar são os únicos caminhos que
    /// transformam uma pendente em conversa. O arquivo entra na biblioteca
    /// (array em memória **e** banco) e, quando o áudio veio de fora, na fila
    /// de processamento — mesma jornada do `registrar` normal.
    @discardableResult
    func criarArquivoDeReuniaoPendente(
        _ pendente: ReuniaoPendenteCalendar,
        audioURL: URL,
        duracao: TimeInterval? = nil,
        notas: [NotaDaConversa] = [],
        usavaFones: Bool? = nil
    ) async -> Arquivo? {
        let espacoDestino = espaco
        guard !espacosExcluidos.contains(espacoDestino) else { return nil }
        let idExterno = pendente.idExterno
        guard !arquivos.contains(where: { $0.idExterno == idExterno }),
              !arquivosNaLixeira.contains(where: { $0.idExterno == idExterno })
        else { return nil }

        // Sem pasta não há transcrição possível — falha antes de sujar o banco.
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            erros[ArquivoID().rawValue] = "O arquivo de áudio escolhido não foi encontrado.".localized
            return nil
        }

        var arquivo = Arquivo(
            titulo: pendente.titulo,
            criadoEm: pendente.dataHora,
            duracao: duracao.map { $0.isFinite ? max(0, $0) : 0 } ?? 0,
            pastaRelativa: "",
            espaco: espacoDestino,
            trechos: [],
            notas: Self.combinarNotas(descricaoDoEvento: pendente.descricao, notasDaGravacao: notas),
            resumo: nil,
            idExterno: idExterno,
            usavaFones: usavaFones,
            // O título veio do evento: o resumo não deve trocá-lo.
            tituloManual: true
        )

        // Só a pasta que esta função criou pode ser apagada num erro. A da
        // gravação interna é o próprio áudio recém-gravado: apagá-la numa
        // falha de salvamento destruía a reunião que a pessoa acabou de ter.
        var pastaCriadaAqui: String?
        func desfazerPastaCriada() {
            guard let pastaCriadaAqui else { return }
            try? armazenamento.removerGravacao(relativa: pastaCriadaAqui)
        }

        do {
            let pastaDoAudio = audioURL.deletingLastPathComponent()
            let dentroDasGravacoes = pastaDoAudio.deletingLastPathComponent().standardizedFileURL
                == armazenamento.raiz
                    .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
                    .standardizedFileURL
            if audioURL.lastPathComponent == Armazenamento.Nome.microfone, dentroDasGravacoes {
                // Veio da gravação interna (`microfone.wav` dentro de
                // `Gravacoes/`): a pasta já existe no lugar canônico; só
                // apontamos para ela. Um arquivo de fora que por acaso se
                // chame `microfone.wav` é importado como qualquer outro.
                arquivo.pastaRelativa = "\(Armazenamento.pastaGravacoes)/\(pastaDoAudio.lastPathComponent)"
            } else {
                // Importado: pasta nova + extensão preservada (`gravacao.<ext>`).
                let idNovo = UUID()
                let destino = try armazenamento.criarArquivoImportado(
                    id: idNovo,
                    extensao: audioURL.pathExtension.lowercased()
                )
                pastaCriadaAqui = Armazenamento.caminhoRelativo(id: idNovo)
                try FileManager.default.copyItem(at: audioURL, to: destino)
                arquivo.pastaRelativa = Armazenamento.caminhoRelativo(id: idNovo)
                arquivo.importadoEm = Date()
                // Duração real lida do arquivo: alimenta a estimativa de
                // progresso e o cartão desde o primeiro segundo.
                if duracao == nil {
                    arquivo.duracao = await Self.duracaoDoAudio(audioURL)
                }
            }
        } catch {
            desfazerPastaCriada()
            erros[arquivo.id.rawValue] = "Não foi possível copiar o áudio da reunião: %@".localized(error.localizedDescription)
            return nil
        }

        do {
            try await salvarReuniaoNoRepositorio(arquivo)
        } catch {
            desfazerPastaCriada()
            erros[arquivo.id.rawValue] = "Não foi possível criar arquivo da reunião: %@".localized(error.localizedDescription)
            return nil
        }

        if espacosExcluidos.contains(espacoDestino) {
            // Perfil excluído no meio do caminho: aqui sim a mídia sai toda,
            // inclusive a gravada agora — é o que a exclusão pediu.
            if !arquivo.pastaRelativa.isEmpty {
                try? armazenamento.removerGravacao(relativa: arquivo.pastaRelativa)
            }
            try? await repositorio.descartarRegistro(arquivo.id)
            return nil
        }
        guard espaco == espacoDestino else { return arquivo }

        // Em memória ANTES de enfileirar: o loop da fila resolve o próximo
        // arquivo buscando neste array — ausente aqui, o processamento morria
        // silenciosamente no primeiro tick.
        arquivos.insert(arquivo, at: 0)
        arquivos.sort { $0.criadoEm > $1.criadoEm }

        let equipes = EquipesDoUsuario.carregar()
        let equipeAtivaID = UserDefaults.standard.string(forKey: "equipeAtiva") ?? ""
        let equipe = equipes.first { $0.id == equipeAtivaID } ?? equipes.first
        let classificacao = ClassificacaoDeParticipantes.classificar(pendente.participantes, equipe: equipe)
        let quantidadeDeParticipantes = max(
            1,
            classificacao.equipeNomes.split(separator: "\n").count
                + classificacao.externosNomes.split(separator: "\n").count
        )
        PreferenciasVisuaisDoArquivo.definirMetadados(
            MetadadosVisuaisDoArquivo(
                entrevistado: classificacao.externosNomes,
                emailDoEntrevistado: classificacao.externosEmails,
                entrevistadores: classificacao.equipeNomes,
                emailDosEntrevistadores: classificacao.equipeEmails,
                descricao: pendente.descricao ?? "",
                formato: "",
                participantes: quantidadeDeParticipantes
            ),
            para: arquivo.id
        )

        await sincronizar(arquivo)
        if processamentoAutomatico {
            enfileirarProcessamento(arquivo)
        }
        return arquivo
    }

    /// Duração em segundos lida dos metadados do arquivo de áudio.
    /// Falha silenciosa devolve 0 — o pipeline recalcula ao transcrever.
    private static func duracaoDoAudio(_ url: URL) async -> TimeInterval {
        await Task.detached {
            let asset = AVURLAsset(url: url)
            // Mídia de duração indefinida devolve `NaN` — que o `try?` não
            // cobre, e que derruba a exportação (`Int(.nan)`) mais adiante.
            let segundos = (try? await asset.load(.duration).seconds) ?? 0
            return segundos.isFinite && segundos > 0 ? segundos : 0
        }.value
    }

    private static func combinarNotas(
        descricaoDoEvento: String?,
        notasDaGravacao: [NotaDaConversa]
    ) -> [NotaDaConversa] {
        let descricao = descricaoDoEvento?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notaDoEvento = descricao.isEmpty
            ? []
            : [NotaDaConversa(texto: descricao, start: 0)]
        return notaDoEvento + notasDaGravacao
    }
}
