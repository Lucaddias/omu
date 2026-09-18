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
    private var arquivoEmProcessamento: ArquivoID?
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
    /// Preferência de saída capturada quando a execução entra na fila. O
    /// Whisper ainda detecta o idioma falado; isto só governa a tradução local
    /// posterior e o idioma que o resumo deve usar.
    var traducaoAutomatica = true
    var idiomaPadraoDeProcessamento = IdiomaDeProcessamento(locale: .autoupdatingCurrent)
    var aoNotificar: (@MainActor (_ titulo: String, _ mensagem: String, _ tipo: NotificacaoDoApp.Tipo) -> Void)?
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
    private var tarefaDeRetryCloudKit: Task<Void, Never>?
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

    init() throws {
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
        self.espaco = espaco
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
        let mudouDeEspaco = espaco != novoEspaco
        self.equipeCloudKit = equipeCloudKit
        if equipeCloudKit == nil {
            estadoDaSincronizacaoCloudKit = .local
        }
        if mudouDeEspaco {
            filaDeProcessamento.removeAll()
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
    }

    func preparar() async {
        await ciclo.iniciarMonitoramento()
        await ciclo.encerrarNaSaidaDoApp()
        await carregar()
    }

    func carregar() async {
        let contexto = contextoDoEspaco
        let espacoDaCarga = espaco
        let carga = UUID()
        cargaAtual = carga
        do {
            let ativos = try await repositorio.listar(espaco: espacoDaCarga)
            let excluidos = try await repositorio.listarNaLixeira(espaco: espacoDaCarga)
            guard contexto == contextoDoEspaco, carga == cargaAtual,
                  !Task.isCancelled else { return }
            arquivos = ativos
            arquivosNaLixeira = excluidos
            erroDeCarregamento = nil
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
        dataDeGravacao: Date? = nil
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
            importadoEm: dataDeGravacao != nil ? Date() : nil
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
            try await repositorio.moverParaLixeira(arquivo.id)
            arquivos.removeAll { $0.id == arquivo.id }

            var movido = arquivo
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
            try await repositorio.restaurar(arquivo.id)
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }

            var restaurado = arquivo
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
            try await repositorio.apagar(arquivo.id)
            if let equipeCloudKit {
                do {
                    try await filaCloudKit.agendarRemocao(arquivo.id, da: equipeCloudKit)
                    await retomarSincronizacaoCloudKit()
                } catch {
                    let mensagem = "A conversa saiu deste Mac, mas a remoção não entrou na fila do iCloud: %@".localized(error.localizedDescription)
                    estadoDaSincronizacaoCloudKit = .falhou(mensagem)
                    aoNotificar?("Falha ao remover do iCloud".localized, mensagem, .aviso)
                }
            }
            arquivosNaLixeira.removeAll { $0.id == arquivo.id }
            filaDeProcessamento.removeAll { $0 == arquivo.id }
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
        for pastaRelativa in pastasDaConta {
            try armazenamento.removerGravacao(relativa: pastaRelativa)
        }
        try await repositorio.apagarTodosOsDados(espaco: espacoExcluido)

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

        var editado = arquivo
        editado.titulo = tituloLimpo
        if let resumo = arquivo.resumo {
            editado.resumo = Resumo(
                titulo: tituloLimpo,
                visaoGeral: resumo.visaoGeral,
                temas: resumo.temas,
                citacoes: resumo.citacoes,
                proximosPassos: resumo.proximosPassos
            )
        }

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
            await sincronizar(editado)
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

        var editado = arquivo
        editado.titulo = tituloLimpo
        editado.criadoEm = criadoEm
        editado.duracao = max(0, duracao)
        if let resumo = arquivo.resumo {
            editado.resumo = Resumo(
                titulo: tituloLimpo,
                visaoGeral: resumo.visaoGeral,
                temas: resumo.temas,
                citacoes: resumo.citacoes,
                proximosPassos: resumo.proximosPassos
            )
        }

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
            await sincronizar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar as informações: %@".localized(error.localizedDescription)
        }
    }

    func atualizarNotas(_ notas: [NotaDaConversa], de arquivo: Arquivo) async {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }

        var editado = arquivo
        editado.notas = notas

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
            await sincronizar(editado)
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

        var editado = arquivo
        editado.trechos = trechos

        do {
            try await repositorio.salvar(editado)
            substituir(editado)
            await sincronizar(editado)
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível salvar a transcrição: %@".localized(error.localizedDescription)
        }
    }

    @discardableResult
    func duplicar(_ arquivo: Arquivo) async -> Arquivo? {
        guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return nil }

        let novoID = ArquivoID()
        let pastaNovaRelativa = Armazenamento.caminhoRelativo(id: novoID.rawValue)
        let origem = armazenamento.resolver(relativo: arquivo.pastaRelativa)
        let destino = armazenamento.resolver(relativo: pastaNovaRelativa)

        do {
            let origemExiste = FileManager.default.fileExists(atPath: origem.path)
            if origemExiste {
                try FileManager.default.copyItem(at: origem, to: destino)
            } else {
                try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
            }

            var copia = Arquivo(
                id: novoID,
                titulo: "%@ cópia".localized(arquivo.titulo),
                criadoEm: Date(),
                duracao: arquivo.duracao,
                pastaRelativa: pastaNovaRelativa,
                espaco: espaco,
                trechos: arquivo.trechos.map {
                    Trecho(start: $0.start, end: $0.end, texto: $0.texto, speaker: $0.speaker, palavras: $0.palavras)
                },
                notas: arquivo.notas.map {
                    NotaDaConversa(texto: $0.texto, start: $0.start, critica: $0.critica, tipo: $0.tipo)
                },
                resumo: arquivo.resumo,
                engineTranscricao: arquivo.engineTranscricao,
                engineResumo: arquivo.engineResumo
            )
            if let resumo = arquivo.resumo {
                copia.resumo = Resumo(
                    titulo: "%@ cópia".localized(resumo.titulo),
                    visaoGeral: resumo.visaoGeral,
                    temas: resumo.temas,
                    citacoes: resumo.citacoes,
                    proximosPassos: resumo.proximosPassos
                )
            }

            if origemExiste {
                let anexosCopiados = try MidiasDaConversa.anexosCopiados(
                    de: arquivo.id,
                    da: origem,
                    para: destino
                )
                if !anexosCopiados.isEmpty {
                    try MidiasDaConversa.salvar(anexosCopiados, para: novoID)
                }
            }
            TarefasGeraisStore.duplicar(arquivo, para: copia)
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
                try armazenamento.removerGravacao(relativa: pastaNovaRelativa)
                erros[arquivo.id.rawValue] = "Não foi possível duplicar: %@".localized(error.localizedDescription)
            } catch {
                erros[arquivo.id.rawValue] = "Não foi possível duplicar: %@. A cópia incompleta permaneceu no armazenamento para não apagar dados de forma insegura.".localized(error.localizedDescription)
            }
            return nil
        }
    }

    // MARK: - Processamento

    var processando: Bool {
        arquivoEmProcessamento != nil || !filaDeProcessamento.isEmpty
    }

    func enfileirarProcessamento(_ arquivo: Arquivo) {
        guard arquivoEmProcessamento != arquivo.id,
              !operacoesDeLixeiraEmAndamento.contains(arquivo.id),
              !filaDeProcessamento.contains(arquivo.id) else { return }

        erros[arquivo.id.rawValue] = nil
        filaDeProcessamento.append(arquivo.id)
        iniciarProximoProcessamentoSeNecessario()
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
        guard arquivoEmProcessamento == nil else { return }

        while let proximoID = filaDeProcessamento.first {
            filaDeProcessamento.removeFirst()
            guard let arquivo = arquivos.first(where: { $0.id == proximoID }) else {
                continue
            }

            let execucao = UUID()
            arquivoEmProcessamento = proximoID
            identificadorDaExecucao = execucao
            tarefaDeProcessamento = Task { [weak self] in
                await self?.executarProcessamento(arquivo, execucao: execucao)
            }
            return
        }
    }

    /// Transcreve um trecho ditado e devolve o texto corrido.
    ///
    /// Mesmo Whisper das conversas, e descarrega no fim: uma nota ditada não
    /// justifica deixar modelos pesados residentes.
    func transcreverDitado(_ audio: URL) async throws -> String {
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            throw ErroDeDitado.modelosIndisponiveis(preflight.mensagem)
        }

        let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)
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

        var errorDescription: String? {
            switch self {
            case let .modelosIndisponiveis(motivo): motivo
            }
        }
    }

    private func executarProcessamento(_ arquivo: Arquivo, execucao: UUID) async {
        let chave = arquivo.id.rawValue
        defer { finalizarProcessamento(chave, execucao: execucao) }

        // Sem os pesos, o Whisper falharia lá dentro com um erro de carga. Dizer
        // o que falta é mais útil que repassar o erro do llama.cpp.
        let preflight = Preflight(pastaDeModelos: pastaDeModelos).avaliar()
        if preflight != .pronto, preflight != .termicoCritico {
            erros[chave] = preflight.mensagem
            return
        }

        erros[chave] = nil
        fases[chave] = .transcrevendo
        iniciadoEm[chave] = Date()
        let promptDeEntidades = await PromptDeEntidades.construir(para: arquivo)
        let configuracaoDeTraducao = ConfiguracaoDeTraducaoAutomatica(
            habilitada: traducaoAutomatica,
            idiomaPadrao: idiomaPadraoDeProcessamento
        )

        // Criado por execução, e descarregado no fim: os dois modelos somam
        // Eles não podem ficar residentes entre gravações num Mac de 18 GB.
        let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)

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
            traducaoAutomatica: configuracaoDeTraducao,
            traduzir: { [motores] trechos, idiomaDeDestino in
                try await motores.traduzir(trechos, para: idiomaDeDestino)
            },
            diarizar: { [diarizacao] url in
                try await diarizacao.diarizar(url)
            },
            resolverFalantes: { [motores] arquivo in
                try await motores.resolverFalantes(arquivo)
            }
        )

        await OperacaoComLimpeza.executar {
            do {
                let final = try await pipeline.processar(arquivo) { fase in
                    Task { @MainActor [weak self] in
                        guard self?.identificadorDaExecucao == execucao else { return }
                        self?.fases[chave] = fase
                    }
                }
                guard identificadorDaExecucao == execucao,
                      arquivos.contains(where: { $0.id == arquivo.id })
                else { return }
                substituir(final)
                await sincronizar(final)
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
            } catch {
                erros[chave] = "\(error)"
                aoNotificar?(
                    "Transcrição falhou".localized,
                    "\(arquivo.titulo): \(error.localizedDescription)",
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

        let diarizacao = GerenciadorDeModelosDeDiarizacao.embutido()
        guard diarizacao.disponivel else {
            erros[chave] = "Modelos de diarização não estagiados. Rode Scripts/bootstrap-runtimes.sh.".localized
            return
        }

        erros[chave] = nil
        fases[chave] = .diarizando
        await ciclo.registrar(diarizacao)

        // Os motores são apenas o contrato do pipeline; o caminho leve nunca
        // chama transcrever/resumir, então o Whisper não entra em memória. A
        // resolução contextual usa o Qwen quando há caso entre vozes
        // diferentes (o mesmo modelo do resumo, carregado e descarregado aqui).
        let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)
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
            let diarizado = await pipeline.diarizarExistente(arquivo)
            guard arquivos.contains(where: { $0.id == arquivo.id }) else { return }
            do {
                try await repositorio.salvar(diarizado)
                substituir(diarizado)
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
    }

    private func sincronizar(_ arquivo: Arquivo) async {
        guard let equipeCloudKit else { return }
        estadoDaSincronizacaoCloudKit = .enviando
        do {
            try await filaCloudKit.agendarEnvio(arquivo, para: equipeCloudKit)
            await retomarSincronizacaoCloudKit()
        } catch {
            let mensagem = "Não foi possível guardar a sincronização pendente de %@: %@".localized(arquivo.titulo, error.localizedDescription)
            estadoDaSincronizacaoCloudKit = .falhou(mensagem)
            aoNotificar?("Conversa salva só neste Mac".localized, mensagem, .aviso)
        }
    }

    func retomarSincronizacaoCloudKit(forcar: Bool = false) async {
        guard equipeCloudKit != nil else { return }
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
                estadoDaSincronizacaoCloudKit = .falhou(
                    "%d alteração(ões) aguardando nova tentativa no iCloud%@".localized(resultado.pendentes, detalhe)
                )
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

    private func baixarAtualizacoesDaEquipe() async {
        guard let equipeCloudKit else { return }
        let contexto = contextoDoEspaco
        estadoDaSincronizacaoCloudKit = .enviando
        do {
            let revisoesPendentes = try await filaCloudKit.revisoesLocaisPendentes(
                equipeID: equipeCloudKit.id
            )
            var conflitos = 0
            for conversa in try await sincronizadorCloudKit.baixarComVersoes(da: equipeCloudKit) {
                guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
                if PoliticaDeConflitoCloudKit.decidir(
                    revisaoRemota: conversa.atualizadoEm,
                    revisaoLocalPendente: revisoesPendentes[conversa.arquivo.id]
                ) == .preservarLocalPendente {
                    conflitos += 1
                    continue
                }
                let local = (arquivos + arquivosNaLixeira).first {
                    $0.id == conversa.arquivo.id
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
                try await repositorio.salvar(combinado)
            }
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            await carregar()
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            if conflitos == 0 {
                let pendentes = try await filaCloudKit.operacoesPendentes().count
                guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
                if pendentes == 0 {
                    estadoDaSincronizacaoCloudKit = .sincronizado
                } else {
                    estadoDaSincronizacaoCloudKit = .falhou(
                        "%d alteração(ões) continuam na fila do iCloud.".localized(pendentes)
                    )
                }
            } else {
                let mensagem = "%d conversa(s) têm uma edição local pendente; a cópia local foi preservada até o próximo envio.".localized(conflitos)
                estadoDaSincronizacaoCloudKit = .falhou(mensagem)
                aoNotificar?("Conflito de sincronização".localized, mensagem, .aviso)
            }
        } catch {
            guard contexto == contextoDoEspaco, !Task.isCancelled else { return }
            let mensagem = "Não foi possível baixar as conversas da equipe: %@".localized(DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error))
            estadoDaSincronizacaoCloudKit = .falhou(mensagem)
            aoNotificar?("Falha de sincronização do iCloud".localized, mensagem, .aviso)
        }
    }

    // MARK: - Consulta pela view

    func arquivo(id: UUID) -> Arquivo? {
        arquivos.first { $0.id.rawValue == id }
    }

    /// Canal principal para reprodução, na nova convenção: `microfone.wav`.
    ///
    /// Gravações antigas e arquivos importados têm **um único arquivo** (a
    /// mixagem legada `gravacao.m4a` ou o original copiado como `gravacao.<ext>`);
    /// nesses casos ele é o canal único. A reprodução em dois canais usa
    /// `audioSecundario` junto.
    func audio(de arquivo: Arquivo) -> URL {
        if arquivo.semAudio {
            return armazenamento.raiz
                .appendingPathComponent("MidiaIndisponivel", isDirectory: true)
                .appendingPathComponent(arquivo.id.rawValue.uuidString, isDirectory: true)
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
        notas: [NotaDaConversa] = []
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
            duracao: max(0, duracao ?? 0),
            pastaRelativa: "",
            espaco: espacoDestino,
            trechos: [],
            notas: Self.combinarNotas(descricaoDoEvento: pendente.descricao, notasDaGravacao: notas),
            resumo: nil,
            idExterno: idExterno
        )

        do {
            if audioURL.lastPathComponent.hasPrefix(Armazenamento.Nome.microfone) {
                // Veio da gravação interna (`microfone.wav`): a pasta já existe
                // no lugar canônico; só apontamos para ela.
                let relativa = audioURL.deletingLastPathComponent().lastPathComponent
                let pastaPai = audioURL.deletingLastPathComponent().deletingLastPathComponent()
                guard pastaPai.lastPathComponent == Armazenamento.pastaGravacoes else {
                    throw ErroDeImportacao.pastaInesperada
                }
                arquivo.pastaRelativa = "\(Armazenamento.pastaGravacoes)/\(relativa)"
            } else {
                // Importado: pasta nova + extensão preservada (`gravacao.<ext>`).
                let idNovo = UUID()
                let destino = try armazenamento.criarArquivoImportado(
                    id: idNovo,
                    extensao: audioURL.pathExtension.lowercased()
                )
                try FileManager.default.copyItem(at: audioURL, to: destino)
                arquivo.pastaRelativa = Armazenamento.caminhoRelativo(id: idNovo)
                // Duração real lida do arquivo: alimenta a estimativa de
                // progresso e o cartão desde o primeiro segundo.
                if duracao == nil {
                    arquivo.duracao = await Self.duracaoDoAudio(audioURL)
                }
            }
        } catch {
            erros[arquivo.id.rawValue] = "Não foi possível copiar o áudio da reunião: %@".localized(error.localizedDescription)
            return nil
        }

        do {
            try await salvarReuniaoNoRepositorio(arquivo)
        } catch {
            if !arquivo.pastaRelativa.isEmpty {
                try? armazenamento.removerGravacao(relativa: arquivo.pastaRelativa)
            }
            erros[arquivo.id.rawValue] = "Não foi possível criar arquivo da reunião: %@".localized(error.localizedDescription)
            return nil
        }

        if espacosExcluidos.contains(espacoDestino) {
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

        if processamentoAutomatico {
            enfileirarProcessamento(arquivo)
        }
        return arquivo
    }

    enum ErroDeImportacao: LocalizedError {
        case pastaInesperada

        var errorDescription: String? {
            switch self {
            case .pastaInesperada:
                "A gravação não estava na pasta esperada da biblioteca.".localized
            }
        }
    }

    /// Duração em segundos lida dos metadados do arquivo de áudio.
    /// Falha silenciosa devolve 0 — o pipeline recalcula ao transcrever.
    private static func duracaoDoAudio(_ url: URL) async -> TimeInterval {
        await Task.detached {
            let asset = AVURLAsset(url: url)
            return (try? await asset.load(.duration).seconds) ?? 0
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
