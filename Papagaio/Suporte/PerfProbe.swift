#if OMU_PERF
import AppKit
import Darwin
import Foundation
import PapagaioCore
import SwiftUI

struct ConfiguracaoPerf: Sendable {
    let cenario: String
    let raiz: URL
    let modelos: URL
    let saida: URL
    let fixtures: [URL]
    let timeoutSegundos: Int
    let idDetalhe: UUID?

    var fixture: URL? { fixtures.first }

    static func homeDoUsuario(ambiente: [String: String], fallback: URL) -> URL {
        guard let caminho = ambiente["HOME"], caminho.hasPrefix("/") else {
            return fallback.standardizedFileURL
        }
        return URL(fileURLWithPath: caminho, isDirectory: true).standardizedFileURL
    }

    static func diretorioDoLoop(home: URL, ambiente: [String: String]) -> URL {
        let padrao = home.appendingPathComponent("OmuPerf", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard let caminhoSolicitado = ambiente["OMU_PERF_DIR"], !caminhoSolicitado.isEmpty else {
            return padrao
        }

        let solicitado = URL(fileURLWithPath: caminhoSolicitado, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let pertenceAoLoop = solicitado.path == padrao.path
            || solicitado.path.hasPrefix(padrao.path + "/")
        return pertenceAoLoop ? solicitado : padrao
    }

    static func ler() -> ConfiguracaoPerf? {
        let argumentos = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var valores: [String: String] = [:]
        var caminhosDeFixture: [URL] = []
        var indice = 0
        while indice < argumentos.count {
            let chave = argumentos[indice]
            guard chave.hasPrefix("--perf-"), indice + 1 < argumentos.count else {
                indice += 1
                continue
            }
            if chave == "--perf-fixture" {
                caminhosDeFixture.append(URL(fileURLWithPath: argumentos[indice + 1]))
            } else {
                valores[chave] = argumentos[indice + 1]
            }
            indice += 2
        }

        guard let cenario = valores["--perf-cenario"] else { return nil }
        let ambiente = ProcessInfo.processInfo.environment
        let home = Self.homeDoUsuario(
            ambiente: ambiente,
            fallback: FileManager.default.homeDirectoryForCurrentUser
        )
        let diretorioDoLoop = Self.diretorioDoLoop(home: home, ambiente: ambiente)
        let raizDeRuns = diretorioDoLoop.appendingPathComponent("runs", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let raizPadrao = raizDeRuns.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let raizSolicitada = URL(
            fileURLWithPath: valores["--perf-raiz"] ?? raizPadrao.path,
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let raizPermitida = raizSolicitada.path == raizDeRuns.path
            || raizSolicitada.path.hasPrefix(raizDeRuns.path + "/")
        let raiz = raizPermitida ? raizSolicitada : raizPadrao
        let modelosPadrao = diretorioDoLoop
            .appendingPathComponent("fixtures/modelos-nao-configurados", isDirectory: true)
        let modelosSolicitados = URL(
            fileURLWithPath: valores["--perf-modelos"] ?? modelosPadrao.path,
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let modelosDoApp = home
            .appendingPathComponent("Library/Application Support/Papagaio/Models", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let raizDeFixtures = diretorioDoLoop.appendingPathComponent("fixtures", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let modelosPermitidos = modelosSolicitados.path == modelosDoApp.path
            || modelosSolicitados.path.hasPrefix(raizDeFixtures.path + "/")
        let modelos = modelosPermitidos ? modelosSolicitados : modelosPadrao
        let saidaPadrao = raiz.appendingPathComponent("eventos.jsonl")
        let saidaSolicitada = URL(fileURLWithPath: valores["--perf-saida"] ?? saidaPadrao.path)
            .resolvingSymlinksInPath().standardizedFileURL
        let saidaPermitida = saidaSolicitada.path.hasPrefix(raizDeRuns.path + "/")
        let saida = saidaPermitida ? saidaSolicitada : saidaPadrao
        let timeout = max(1, Int(valores["--perf-timeout"] ?? "7200") ?? 7200)
        let idDetalhe = valores["--perf-detalhe-id"].flatMap(UUID.init(uuidString:))
        let raizDeFixturesPath = raizDeFixtures.path + "/"
        let fixturesSolicitadas = caminhosDeFixture.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let fixtures = fixturesSolicitadas.allSatisfy { $0.path.hasPrefix(raizDeFixturesPath) }
            ? fixturesSolicitadas
            : []

        return ConfiguracaoPerf(
            cenario: cenario,
            raiz: raiz,
            modelos: modelos,
            saida: saida,
            fixtures: fixtures,
            timeoutSegundos: timeout,
            idDetalhe: idDetalhe
        )
    }
}

/// Sonda existe apenas na build Release explicitamente compilada com OMU_PERF.
@MainActor
final class PerfProbe {
    static let termosDeEntidades = [
        "Projeto Aurora", "Marina Costa", "João Martins", "Lívia Nascimento",
        "Equipe de Pesquisa", "Plano Beta", "Instituto Horizonte", "Rafael Lima",
        "Acessibilidade", "Comitê de Produto", "Projeto Atlas", "Camila Rocha",
        "Felipe Santos", "Núcleo de Design", "Orçamento Trimestral", "Ana Ribeiro",
        "Equipe Aurora", "Lucas Ferreira", "Plano de Entrega", "Estúdio Sabiá"
    ]
    static let espacoPadrao = EspacoID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    static let configuracao = ConfiguracaoPerf.ler()
    static var ativada: Bool { configuracao != nil }
    static let shared = PerfProbe(configuracao: configuracao)

    let configuracao: ConfiguracaoPerf?

    private var arquivo: FileHandle?
    private let codificador = JSONEncoder()
    private let formatadorDeData = ISO8601DateFormatter()
    private var relogioPrincipal: DispatchSourceTimer?
    private var amostrador: DispatchSourceTimer?
    private var primeiroFrameRegistrado = false
    private var bibliotecaPronta = false
    private var mainThreadLivre = false
    private var interativoRegistrado = false
    private var terminoSolicitado = false
    private var inicioDoUltimoPulso = DispatchTime.now().uptimeNanoseconds
    private var ultimaAmostra = DispatchTime.now().uptimeNanoseconds
    private var ultimoCPU: Double?
    private var ultimoCPUUptime: UInt64?
    private var faseEmCurso: (nome: String, inicio: UInt64)?
    private var buscasPendentes: [String: UInt64] = [:]
    private var pipelinesConcluidos = 0
    private var importacoesConcluidas = 0
    private var navegacoesPendentes: [String: UInt64] = [:]

    private init(configuracao: ConfiguracaoPerf?) {
        self.configuracao = configuracao
        guard let configuracao else { return }

        do {
            try FileManager.default.createDirectory(
                at: configuracao.raiz,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: configuracao.saida.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: configuracao.saida.path, contents: nil)
            arquivo = try FileHandle(forWritingTo: configuracao.saida)
            try arquivo?.seekToEnd()
        } catch {
            FileHandle.standardError.write(Data("PerfProbe: \(error)\n".utf8))
        }

        codificador.dateEncodingStrategy = .iso8601
        iniciarSonda()
        let processoIniciouEm = Self.inicioDoProcesso()
        let uptimeAgora = DispatchTime.now().uptimeNanoseconds
        let atrasoDeInicioNs = processoIniciouEm.map {
            UInt64(max(0, Date().timeIntervalSince($0)) * 1_000_000_000)
        } ?? 0
        registrar("process.start", [
            "pid": getpid(),
            "t_ns": uptimeAgora > atrasoDeInicioNs ? uptimeAgora - atrasoDeInicioNs : uptimeAgora,
            "hora": processoIniciouEm.map { formatadorDeData.string(from: $0) } ?? formatadorDeData.string(from: Date()),
            "process_start": processoIniciouEm?.timeIntervalSince1970 ?? 0
        ])
    }

    static func inicializarAntesDoApp() {
        guard configuracao != nil else { return }
        shared.registrar("app.entry")
        DetectorDeAtividadeDeVoz.configurarRegistroPerf { evento, modelo, duracao in
            Task { @MainActor in
                PerfProbe.shared.registrarEventoModelo(evento, modelo: modelo, duracao: duracao)
            }
        }
    }

    func registrarInicioDoApp() {
        registrar("app.init")
    }

    func registrarBibliotecaPronta() {
        bibliotecaPronta = true
        registrar("library.ready")
        marcarInterativoSePronto()
    }

    func registrarEventoModelo(_ evento: String, modelo: String, duracao: TimeInterval?) {
        var dados: [String: Any] = ["modelo": modelo]
        if let duracao { dados["duracao_s"] = duracao }
        registrar(evento, dados)
    }

    func registrarPrimeiroFrame() {
        guard !primeiroFrameRegistrado else { return }
        primeiroFrameRegistrado = true
        registrar("ui.first_frame")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.mainThreadLivre = true
                self.marcarInterativoSePronto()
            }
        }
    }

    private func marcarInterativoSePronto() {
        guard primeiroFrameRegistrado, bibliotecaPronta, mainThreadLivre, !interativoRegistrado else { return }
        interativoRegistrado = true
        registrar("ui.interactive")
    }

    func registrarImportacaoInicio(_ url: URL) {
        registrar("import.start", ["extensao": url.pathExtension.lowercased()])
    }

    func registrarBuscaSolicitada(_ consulta: String) {
        guard !consulta.isEmpty else { return }
        buscasPendentes[consulta] = DispatchTime.now().uptimeNanoseconds
        registrar("search.input", ["consulta": consulta])
    }

    func registrarBuscaCalculada(_ consulta: String, duracao: TimeInterval) {
        guard !consulta.isEmpty else { return }
        registrar("search.compute", ["consulta": consulta, "duracao_s": duracao])
        guard let inicio = buscasPendentes.removeValue(forKey: consulta) else { return }
        let latencia = Double(DispatchTime.now().uptimeNanoseconds &- inicio) / 1_000_000_000
        registrar("search.response", ["consulta": consulta, "latencia_s": latencia])
    }

    func registrarNavegacaoSolicitada(_ tela: String) {
        navegacoesPendentes[tela] = DispatchTime.now().uptimeNanoseconds
        registrar("ui.navigation.request", ["tela": tela])
    }

    func registrarDesenhoDaTela(_ tela: String) {
        registrarPrimeiroFrame()
        guard let inicio = navegacoesPendentes.removeValue(forKey: tela) else { return }
        let latencia = Double(DispatchTime.now().uptimeNanoseconds &- inicio) / 1_000_000_000
        registrar("ui.navigation.draw", ["tela": tela, "latencia_s": latencia])
    }

    func registrarImportacaoFim(
        duracao: TimeInterval,
        bytes: Int,
        duracaoAudio: TimeInterval? = nil,
        erro: String? = nil
    ) {
        var dados: [String: Any] = ["duracao_s": duracao, "bytes": bytes]
        if let duracaoAudio { dados["duracao_audio_s"] = duracaoAudio }
        if let erro { dados["erro"] = erro }
        registrar("import.end", dados)
        importacoesConcluidas += 1
        if configuracao?.cenario.lowercased() == "i1" {
            terminar(apos: .milliseconds(500))
        } else if configuracao?.cenario.lowercased() == "u3", erro != nil {
            terminar(apos: .milliseconds(500))
        } else if configuracao?.cenario.lowercased() == "s1-import",
                  importacoesConcluidas >= (configuracao?.fixtures.count ?? 10) {
            // Deixa uma janela para o runner capturar `leaks` depois de todas
            // as dez importações e antes do encerramento controlado.
            terminar(apos: .seconds(60))
        }
    }

    func iniciarReproducaoSintetica(_ reprodutor: ReprodutorDeArquivo) {
        guard configuracao?.cenario.lowercased() == "u3" else { return }
        reprodutor.volume = 0
        reprodutor.tocar()
        registrar("playback.start", ["volume": 0])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            reprodutor.pausar()
            registrar("playback.end", ["duracao_s": 30])
            terminar(apos: .seconds(1))
        }
    }

    func registrarFase(_ fase: String, timestamp: UInt64? = nil) {
        let agora = timestamp ?? DispatchTime.now().uptimeNanoseconds
        if let anterior = faseEmCurso {
            registrar("pipeline.phase.end", [
                "fase": anterior.nome,
                "t_ns": agora,
                "duracao_s": Double(agora &- anterior.inicio) / 1_000_000_000
            ])
        }
        registrar("pipeline.phase.start", ["fase": fase, "t_ns": agora])
        faseEmCurso = (fase, agora)
    }

    func registrarPipelineInicio(_ arquivo: Arquivo) {
        registrar("pipeline.start", ["arquivo_id": arquivo.id.rawValue.uuidString])
    }

    func registrarPipelineFim(_ arquivo: Arquivo) {
        if let fase = faseEmCurso {
            let agora = DispatchTime.now().uptimeNanoseconds
            registrar("pipeline.phase.end", [
                "fase": fase.nome,
                "duracao_s": Double(agora &- fase.inicio) / 1_000_000_000
            ])
            faseEmCurso = nil
        }
        registrar("pipeline.end", [
            "arquivo_id": arquivo.id.rawValue.uuidString,
            "trechos": arquivo.trechos.count,
            "tem_resumo": arquivo.resumo != nil
        ])
        if let configuracao {
            do {
                let dados = try codificador.encode(arquivo)
                let caminho = URL(
                    fileURLWithPath: configuracao.saida.deletingPathExtension().path
                        + "-\(arquivo.id.rawValue.uuidString).saida.json"
                )
                try dados.write(to: caminho, options: .atomic)
                registrar("output.dump", ["caminho": caminho.path, "bytes": dados.count])
            } catch {
                registrar("output.dump.error", ["erro": String(describing: error)])
            }
        }
        let cenario = configuracao?.cenario.lowercased() ?? ""
        pipelinesConcluidos += 1
        let quantidadeEsperada = cenario == "p4" ? 3 : 1
        if ["q1", "p1", "p2", "p3", "p4", "p5", "p6"].contains(cenario),
           pipelinesConcluidos >= quantidadeEsperada {
            terminar(apos: .seconds(1))
        }
    }

    func iniciarCenario(
        importar: @escaping @MainActor (URL) async -> Void,
        navegar: @escaping @MainActor (String) -> Void,
        buscar: @escaping @MainActor (String) -> Void,
        abrirDetalhe: @escaping @MainActor (UUID) -> Void
    ) {
        guard let configuracao else { return }
        registrar("scenario.start", ["cenario": configuracao.cenario])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(configuracao.timeoutSegundos)))
            guard !terminoSolicitado else { return }
            registrar("scenario.timeout")
            terminar(apos: .milliseconds(250))
        }

        switch configuracao.cenario.lowercased() {
        case "l1", "l2", "abrir":
            terminar(apos: .seconds(5))
        case "q1-idle":
            terminar(apos: .seconds(60))
        case "o1":
            terminar(apos: .seconds(60))
        case "i1", "q1", "p1", "p2", "p3", "p5", "p6", "u3":
            guard let fixture = configuracao.fixture else {
                registrar("scenario.error", ["erro": "faltou --perf-fixture"])
                terminar(apos: .milliseconds(250))
                return
            }
            Task { @MainActor in
                if configuracao.cenario.lowercased() == "p6" { NSApp.hide(nil) }
                await importar(fixture)
            }
        case "p4":
            guard configuracao.fixtures.count == 3 else {
                registrar("scenario.error", ["erro": "P4 exige exatamente três --perf-fixture"])
                terminar(apos: .milliseconds(250))
                return
            }
            Task { @MainActor in
                for fixture in configuracao.fixtures {
                    await importar(fixture)
                }
            }
        case "s1-import":
            guard configuracao.fixtures.count == 10 else {
                registrar("scenario.error", ["erro": "S1 exige dez --perf-fixture"])
                terminar(apos: .milliseconds(250))
                return
            }
            Task { @MainActor in
                for fixture in configuracao.fixtures {
                    await importar(fixture)
                }
            }
        case "u1", "navegar":
            Task { @MainActor in
                for tela in ["tarefas", "midias", "configuracoes", "biblioteca"] {
                    registrarNavegacaoSolicitada(tela)
                    navegar(tela)
                    try? await Task.sleep(for: .milliseconds(350))
                }
                if let idDetalhe = configuracao.idDetalhe {
                    registrarNavegacaoSolicitada("detalhe")
                    abrirDetalhe(idDetalhe)
                    registrar("ui.navigation.detail", ["arquivo_id": idDetalhe.uuidString])
                    try? await Task.sleep(for: .milliseconds(500))
                } else {
                    registrar("scenario.error", ["erro": "U1 exige uma biblioteca sintética semeada"])
                }
                terminar(apos: .seconds(1))
            }
        case "u2":
            Task { @MainActor in
                navegar("biblioteca")
                try? await Task.sleep(for: .milliseconds(500))
                var consulta = ""
                for caractere in "semcorrespondencia" {
                    consulta.append(caractere)
                    buscar(consulta)
                    try? await Task.sleep(for: .milliseconds(150))
                }
                terminar(apos: .seconds(1))
            }
        default:
            registrar("scenario.error", ["erro": "cenario desconhecido: \(configuracao.cenario)"])
            terminar(apos: .milliseconds(250))
        }
    }

    func aplicaçãoVaiTerminar() {
        registrar("app.will_terminate")
        relogioPrincipal?.cancel()
        amostrador?.cancel()
        relogioPrincipal = nil
        amostrador = nil
        try? arquivo?.synchronize()
        try? arquivo?.close()
        arquivo = nil
    }

    func terminar(apos atraso: Duration) {
        guard !terminoSolicitado else { return }
        terminoSolicitado = true
        registrar("terminate.scheduled")
        Task { @MainActor in
            try? await Task.sleep(for: atraso)
            registrar("terminate.request")
            NSApp.terminate(nil)
        }
    }

    private func iniciarSonda() {
        let pulso = DispatchSource.makeTimerSource(queue: .main)
        pulso.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        pulso.setEventHandler { [weak self] in
            Task { @MainActor in self?.verificarTravadaDaMainThread() }
        }
        pulso.resume()
        relogioPrincipal = pulso

        let amostra = DispatchSource.makeTimerSource(queue: .main)
        amostra.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        amostra.setEventHandler { [weak self] in
            Task { @MainActor in self?.registrarAmostra() }
        }
        amostra.resume()
        amostrador = amostra
    }

    private func verificarTravadaDaMainThread() {
        let agora = DispatchTime.now().uptimeNanoseconds
        let duracao = Double(agora &- inicioDoUltimoPulso) / 1_000_000_000
        inicioDoUltimoPulso = agora
        guard duracao >= 0.050 else { return }
        registrar(duracao >= 0.250 ? "main.hang" : "main.hitch", ["duracao_ms": duracao * 1_000])
    }

    private func registrarAmostra() {
        let agora = DispatchTime.now().uptimeNanoseconds
        let intervalo = Double(agora &- ultimaAmostra) / 1_000_000_000
        ultimaAmostra = agora

        var vm = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let resultadoVM = withUnsafeMutablePointer(to: &vm) { ponteiro in
            ponteiro.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &contagem
                )
            }
        }

        var uso = rusage()
        let resultadoCPU = getrusage(RUSAGE_SELF, &uso)
        let cpu = resultadoCPU == 0
            ? Double(uso.ru_utime.tv_sec) + Double(uso.ru_utime.tv_usec) / 1_000_000
                + Double(uso.ru_stime.tv_sec) + Double(uso.ru_stime.tv_usec) / 1_000_000
            : 0
        let deltaCPU = ultimoCPU.map { cpu - $0 }
        let cpuPercentual: Double?
        if let deltaCPU, let ultimoCPUUptime, agora > ultimoCPUUptime {
            let deltaTempo = Double(agora - ultimoCPUUptime) / 1_000_000_000
            cpuPercentual = deltaTempo > 0 ? deltaCPU / deltaTempo * 100 : nil
        } else {
            cpuPercentual = nil
        }
        ultimoCPU = cpu
        ultimoCPUUptime = agora

        var dados: [String: Any] = [
            "intervalo_s": intervalo,
            "cpu_s": cpu,
            "thermal_state": String(describing: ProcessInfo.processInfo.thermalState)
        ]
        if resultadoVM == KERN_SUCCESS {
            dados["phys_footprint_bytes"] = vm.phys_footprint
        }
        if let cpuPercentual { dados["cpu_percentual"] = cpuPercentual }
        registrar("sample", dados)
    }

    private func registrar(_ evento: String, _ dados: [String: Any] = [:]) {
        guard let arquivo else { return }
        var objeto = dados
        objeto["evento"] = evento
        if objeto["t_ns"] == nil { objeto["t_ns"] = DispatchTime.now().uptimeNanoseconds }
        if objeto["hora"] == nil { objeto["hora"] = formatadorDeData.string(from: Date()) }
        do {
            var linha = try JSONSerialization.data(withJSONObject: objeto, options: [.sortedKeys])
            linha.append(0x0A)
            try arquivo.write(contentsOf: linha)
        } catch {
            FileHandle.standardError.write(Data("PerfProbe: falha ao registrar \(evento): \(error)\n".utf8))
        }
    }

    private static func inicioDoProcesso() -> Date? {
        var informacao = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var tamanho = MemoryLayout<kinfo_proc>.stride
        let estado = sysctl(&mib, u_int(mib.count), &informacao, &tamanho, nil, 0)
        guard estado == 0 else { return nil }
        let inicio = informacao.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(inicio.tv_sec) + Double(inicio.tv_usec) / 1_000_000)
    }
}

@MainActor
struct MarcadorDoPrimeiroFrame: NSViewRepresentable {
    let tela: String

    func makeNSView(context: Context) -> ViewDoPrimeiroFrame {
        let view = ViewDoPrimeiroFrame(frame: .zero)
        view.identificadorDaTela = tela
        view.wantsLayer = true
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ nsView: ViewDoPrimeiroFrame, context: Context) {
        nsView.identificadorDaTela = tela
        nsView.needsDisplay = true
    }
}

@MainActor
final class ViewDoPrimeiroFrame: NSView {
    var identificadorDaTela = "biblioteca"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        NSBezierPath(rect: dirtyRect).fill()
        let tela = identificadorDaTela
        Task { @MainActor in PerfProbe.shared.registrarDesenhoDaTela(tela) }
    }
}
#endif
