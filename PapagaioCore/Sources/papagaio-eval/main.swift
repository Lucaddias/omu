import AppKit
import Foundation
import LlamaRuntime
import PapagaioCore
import WhisperRuntime

// Passo 1: a CLI existe para provar que `PapagaioCore` é importável sem
// arrastar SwiftUI. O harness de medição real (WER, acurácia de entidades)
// chega no Passo 6.

let versao = "0.2.0-bench"

func formatarBytes(_ bytes: Int64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

func uso() {
#if OMU_PERF
    let linhaSeed = "      papagaio-eval seed-library --raiz <dir> --quantidade N [--trechos N] [--catalogo JSON]"
#else
    let linhaSeed = ""
#endif
    print("""
    papagaio-eval \(versao)

    USO:
      papagaio-eval contratos    imprime os contratos disponíveis
      papagaio-eval bench        micro/macro benchmarks de performance
                                [--so-micro] [--iteracoes N] [--audio <arquivo>]
                                [--somente-caso aec.processarBlocos]
                                [--modelos <dir>] [--saida <json>] [--comparar <baseline>]
    \(linhaSeed)
      papagaio-eval run          harness de medição (qualidade/WER) — reserva
      papagaio-eval resolver     diagnóstico da atribuição de falantes:
                                <audio> (ou --fixture <json>), --modelos <dir>,
                                --pasta <dir de diarização>, --sem-modelo
      papagaio-eval granola      fluxo OAuth + MCP reais no Granola

    GRANOLA:
      papagaio-eval granola [--servidor <URL>] [--lista] [--detalhe <id>]
                               [--transcricao] [--sair] [--sem-navegador]
        padrão       — conta conectada + até 10 reuniões mais recentes
        --lista      — só a lista de reuniões
        --detalhe    — notas + resumo da reunião (com --transcricao, inclui fala)
        --sair       — apaga credenciais e registro de cliente do Keychain
        --sem-navegador — não abre o navegador; só imprime a URL

    Esta fase só confirma que PapagaioCore linka fora do app.
    """)
}

/// Servidor HTTP de um pedido só, em 127.0.0.1:porta livre — o redirect URI
/// que os clientes MCP DCR aprovam sem custom scheme. Captura o `code` da
/// primeira requisição (e responde para o navegador fechar a aba).
final class ServidorDeLoopback: @unchecked Sendable {
    private var fd: Int32 = -1
    private var porta: UInt16 = 0

    /// Sobe o listener em `127.0.0.1:0` (porta livre) e devolve o redirect URI.
    func iniciar() throws -> URL {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ErroOAuth.falhaDeRede("socket local falhou") }
        var endereco = sockaddr_in()
        endereco.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endereco.sin_family = sa_family_t(AF_INET)
        endereco.sin_port = 0
        endereco.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &endereco) { ponteiro in
            ponteiro.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { throw ErroOAuth.falhaDeRede("bind em 127.0.0.1 falhou") }
        guard listen(fd, 1) == 0 else { throw ErroOAuth.falhaDeRede("listen falhou") }
        var portaRaw = socklen_t(MemoryLayout<sockaddr_in>.size)
        var enderecoReal = sockaddr_in()
        withUnsafeMutablePointer(to: &enderecoReal) { ponteiro in
            ponteiro.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &portaRaw)
            }
        }
        porta = enderecoReal.sin_port.bigEndian
        return URL(string: "http://127.0.0.1:\(porta)/oauth")!
    }

    /// Espera (até `tempoLimite` s) o navegador autorizar. Devolve o código de
    /// autorização — ou `nil`, para a CLI cair no modo de colagem manual.
    func esperarCodigo(estadoEsperado: String, tempoLimite: TimeInterval = 90) -> String? {
        var listernerPoll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pronto = poll(&listernerPoll, 1, Int32(tempoLimite * 1000))
        guard pronto > 0 else { return nil }
        let conexao = accept(fd, nil, nil)
        guard conexao >= 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let lidos = recv(conexao, &buffer, buffer.count, 0)
        let pedido = lidos > 0 ? String(decoding: buffer[..<lidos], as: UTF8.self) : ""
        let resposta = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 20\r\nConnection: close\r\n\r\nPode fechar esta aba."
        let bytesDaResposta = Array(resposta.utf8)
        _ = send(conexao, bytesDaResposta, bytesDaResposta.count, 0)
        close(conexao)

        guard let linha = pedido.split(separator: "\r\n").first,
              let alvo = linha.split(separator: " ").dropFirst().first,
              let componentes = URLComponents(string: "http://127.0.0.1\(alvo)"),
              let codigo = componentes.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        guard componentes.queryItems?.first(where: { $0.name == "state" })?.value == estadoEsperado else {
            return nil
        }
        return codigo
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

/// Apresentador de autorização para terminal: sobe o loopback, abre o
/// navegador e captura o `code`. Sem navegador/porta, cai na colagem manual.
struct ApresentadorDeTerminal: ApresentadorDeAutorizacaoOAuth {
    let abrirNavegador: Bool
    let servidor: ServidorDeLoopback

    func autorizar(url: URL) async throws -> String {
        print()
        print("Autorização necessária — autorize o Ōmu no navegador:")
        print()
        print("  \(url.absoluteString)")
        print()
        if abrirNavegador {
            NSWorkspace.shared.open(url)
        }
        let estado = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        if let codigo = servidor.esperarCodigo(estadoEsperado: estado) {
            print("código capturado pelo redirecionamento em 127.0.0.1.")
            return codigo
        }
        print("Não recebido em \(90) s. Cole aqui o código da URL final (parâmetro `code`).")
        print("(Enter vazio cancela.)")
        guard let linha = readLine(), !linha.isEmpty else {
            throw ErroOAuth.autorizacaoNegada
        }
        return linha
    }
}

let argumentos = Array(CommandLine.arguments.dropFirst())

switch argumentos.first {
case "contratos":
    let modelosPadrao = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/InterviewLab/Models")
    let transcricao: any TranscriptionEngine = WhisperEngine(
        modelo: modelosPadrao.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo)
    )
    let resumo: any SummarizationEngine = QwenEngine(
        modelo: modelosPadrao.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo)
    )
    print("TranscriptionEngine  -> \(transcricao.identifier)")
    print("SummarizationEngine  -> \(resumo.identifier)")
    print("ArquivoRepository    -> SwiftDataRepository (biblioteca local)")

case "runtime":
    let info = RuntimeInfo.coletar()
    print("whisper.cpp: \(info.whisperSystemInfo)")
    print("llama.cpp:   \(info.llamaSystemInfo)")
    print("Metal:       \(info.metalDisponivel ? "sim" : "NÃO")")

case "preflight":
    let pasta = argumentos.count > 1
        ? URL(fileURLWithPath: argumentos[1])
        : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/InterviewLab/Models")
    let verificar = argumentos.contains("--checksum")
    print("pasta: \(pasta.path)")
    print("RAM instalada: \(Preflight.ramInstalada / 1_073_741_824) GB (piso \(Preflight.ramMinima / 1_073_741_824) GB)")
    let pf = Preflight(pastaDeModelos: pasta)
    print("disco livre:   \(pf.discoLivre / 1_073_741_824) GB (piso \(Preflight.discoMinimo / 1_073_741_824) GB)")
    if verificar { print("verificando SHA-256 dos pesos — leva um tempo…") }
    let r = pf.avaliar(verificarChecksum: verificar)
    print("resultado: \(r)")
    print("bloqueia:  \(r.bloqueia)")
    print("mensagem:  \(r.mensagem)")

case "transcrever":
    guard argumentos.count > 1 else {
        print("uso: papagaio-eval transcrever <audio> [--modelo <caminho>]")
        exit(2)
    }
    let audio = URL(fileURLWithPath: argumentos[1])
    let modelo: URL
    if let i = argumentos.firstIndex(of: "--modelo"), i + 1 < argumentos.count {
        modelo = URL(fileURLWithPath: argumentos[i + 1])
    } else {
        modelo = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/InterviewLab/Models")
            .appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo)
    }

    let amostras = try await DecodificadorDeAudio.amostras(de: audio)
    let duracao = DecodificadorDeAudio.duracao(de: amostras)
    print("áudio:  \(audio.lastPathComponent)")
    print("modelo: \(modelo.lastPathComponent)")
    print(String(format: "duração: %.1f s (%d amostras a 16 kHz)", duracao, amostras.count))
    print("processos filhos antes: \(ContagemDeProcessos.filhos())")

    let engine = WhisperEngine(modelo: modelo)
    let relogio = ContinuousClock()
    let inicio = relogio.now
    let trechos = try await engine.transcribe(audio, speaker: Speaker.eu)
    let gasto = relogio.now - inicio

    print("processos filhos depois: \(ContagemDeProcessos.filhos())")
    print("tempo: \(gasto)")
    if duracao > 0 {
        let segundos = Double(gasto.components.seconds) + Double(gasto.components.attoseconds) / 1e18
        print(String(format: "fator de tempo real: %.2fx", duracao / segundos))
    }
    let agrupados = Segmentacao.agrupar(trechos)
    print("segmentos brutos: \(trechos.count)  →  trechos agrupados: \(agrupados.count)")
    let palavras = agrupados.flatMap(\.palavras)
    let palavrasComConfianca = palavras.compactMap { palavra -> (String, Float)? in
        guard let confianca = palavra.confianca else { return nil }
        return (palavra.texto, confianca)
    }
    print("palavras: \(palavras.count)  ·  com confiança: \(palavrasComConfianca.count)")
    if !palavrasComConfianca.isEmpty {
        print("amostra de confiança: " + palavrasComConfianca.prefix(12)
            .map { String(format: "%@=%.0f%%", $0.0, $0.1 * 100) }
            .joined(separator: " · "))
    }
    let duracoes = agrupados.map { $0.end - $0.start }
    if let menor = duracoes.min(), let maior = duracoes.max() {
        let media = duracoes.reduce(0, +) / Double(duracoes.count)
        print(String(format: "duração dos trechos: min %.1f s · média %.1f s · max %.1f s",
                     menor, media, maior))
        let foraDaFaixa = duracoes.dropLast().filter { $0 < 20 || $0 > 60 }.count
        print("trechos fora de 20–60 s (ignorando o último): \(foraDaFaixa)")
    }
    print("primeiro trecho começa em \(String(format: "%.2f", agrupados.first?.start ?? 0)) s")
    print("--- trechos ---")
    for t in agrupados.prefix(6) {
        print(String(format: "  [%6.2f → %6.2f · %4.1fs] (%@) %@",
                     t.start, t.end, t.end - t.start, t.speaker ?? "—",
                     String(t.texto.prefix(90))))
    }
    if agrupados.count > 6 { print("  … mais \(agrupados.count - 6)") }
    print("--- segmentos brutos (amostra) ---")
    for t in trechos.prefix(4) {
        print(String(format: "  [%6.2f → %6.2f · %4.1fs] %@",
                     t.start, t.end, t.end - t.start, String(t.texto.prefix(70))))
    }

case "resumir":
    guard argumentos.count > 1 else {
        print("uso: papagaio-eval resumir <audio>")
        exit(2)
    }
    let audioR = URL(fileURLWithPath: argumentos[1])
    let modelos = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/InterviewLab/Models")

    let engineW = WhisperEngine(modelo: modelos.appendingPathComponent(Pesos.whisperLargeV3.nomeArquivo))
    let brutos = try await engineW.transcribe(audioR, speaker: Speaker.eu)
    let trechosR = Segmentacao.agrupar(brutos)
    await engineW.descarregar()
    print("transcrição: \(brutos.count) segmentos → \(trechosR.count) trechos")

    let contextoQ = ContextoLlama(modelo: modelos.appendingPathComponent(Pesos.qwen35_9B.nomeArquivo))
    let engineQ = QwenEngine(contexto: contextoQ)
    let entrada = QwenEngine.formatar(trechosR)
    let memoriaAntes = CicloDeVidaDeModelos.memoriaDoProcesso
    let nTokens = try await contextoQ.contarTokens(entrada)
    let memoriaComModelo = CicloDeVidaDeModelos.memoriaDoProcesso
    print("entrada: \(nTokens) tokens (teto de passe único: \(ContextoLlama.tetoDeEntrada))")
    print("modo: \(nTokens <= ContextoLlama.tetoDeEntrada ? "passe único" : "map-reduce")")
    print("memória antes do Qwen: \(formatarBytes(memoriaAntes))")
    print("memória após carregar Qwen: \(formatarBytes(memoriaComModelo))")

    let relogioQ = ContinuousClock()
    let inicioQ = relogioQ.now
    let resumoFinal: Resumo
    do {
        resumoFinal = try await engineQ.summarize(trechosR)
    } catch {
        FileHandle.standardError.write(Data("ERRO na sumarização: \(error)\n".utf8))
        await engineQ.descarregar()
        exit(3)
    }
    print("tempo de resumo: \(relogioQ.now - inicioQ)")
    print("memória após resumo: \(formatarBytes(CicloDeVidaDeModelos.memoriaDoProcesso))")
    print("engine: \(engineQ.identifier)")
    print()
    print("# \(resumoFinal.titulo)")
    print()
    print(resumoFinal.visaoGeral)
    print()
    print("## Temas")
    for t in resumoFinal.temas { print("- **\(t.titulo)** — \(t.detalhe)") }
    print("## Citações")
    for c in resumoFinal.citacoes {
        print("> \(c.texto)  [\(c.speaker ?? "—") @ \(c.start.map { String(format: "%.1fs", $0) } ?? "—")]")
    }
    print("## Próximos passos")
    for p in resumoFinal.proximosPassos { print("- \(p.descricao) (\(p.responsavel ?? "—"))") }
    await engineQ.descarregar()

case "diarizar":
    guard argumentos.count > 1 else {
        print("uso: papagaio-eval diarizar <audio>")
        exit(2)
    }
    let audioD = URL(fileURLWithPath: argumentos[1])
    print("áudio:  \(audioD.lastPathComponent)")

    // Modelos diarização embutidos no bundle do PapagaioCore (estagiados pelo
    // bootstrap). `--pasta` permite apontar para o layout do ModelHub
    // (…/speaker-diarization) quando o bundle não estiver montado.
    let gerente: GerenciadorDeModelosDeDiarizacao
    if let i = argumentos.firstIndex(of: "--pasta") {
        let pasta = URL(fileURLWithPath: argumentos[i + 1])
        gerente = GerenciadorDeModelosDeDiarizacao(diretorio: pasta)
    } else {
        gerente = .embutido()
    }
    print("modelos disponíveis: \(gerente.disponivel ? "sim" : "NÃO")")
    if !gerente.disponivel { exit(4) }

    let relogioD = ContinuousClock()
    let inicioD = relogioD.now
    let segmentos: [SegmentoDeFalante]
    do {
        segmentos = try await gerente.diarizar(audioD)
    } catch {
        FileHandle.standardError.write(Data("ERRO na diarização: \(error)\n".utf8))
        exit(3)
    }
    print("tempo: \(relogioD.now - inicioD)")
    print("segmentos: \(segmentos.count)")
    for s in segmentos {
        print(String(format: "  [%7.2f → %7.2f · %5.2fs] %@",
                     s.inicio, s.fim, s.fim - s.inicio, s.falanteId))
    }

case "resolver":
    var opcoes = DiagnosticoDeResolucao.Opcoes(
        audio: nil,
        fixture: nil,
        pastaDeModelos: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.papagaio.Papagaio/Data/Library/Application Support/Papagaio/Models"),
        pastaDeDiarizacao: nil,
        semModelo: false
    )
    var restantes = Array(argumentos.dropFirst())
    if restantes.first == "--fixture" {
        guard restantes.count > 1 else {
            print("uso: papagaio-eval resolver --fixture <json> [--modelos <dir>] [--sem-modelo]")
            exit(2)
        }
        opcoes.fixture = URL(fileURLWithPath: restantes[1])
        restantes.removeFirst(2)
    } else if let primeiro = restantes.first, !primeiro.hasPrefix("--") {
        opcoes.audio = URL(fileURLWithPath: primeiro)
        restantes.removeFirst()
    } else {
        print("uso: papagaio-eval resolver <audio> [--pasta <dir>] [--modelos <dir>] [--sem-modelo]")
        exit(2)
    }
    while let flag = restantes.first {
        switch flag {
        case "--modelos":
            guard restantes.count > 1 else { exit(2) }
            opcoes.pastaDeModelos = URL(fileURLWithPath: restantes[1])
            restantes.removeFirst(2)
        case "--pasta" where opcoes.audio != nil:
            guard restantes.count > 1 else { exit(2) }
            opcoes.pastaDeDiarizacao = URL(fileURLWithPath: restantes[1])
            restantes.removeFirst(2)
        case "--sem-modelo":
            opcoes.semModelo = true
            restantes.removeFirst()
        default:
            exit(2)
        }
    }
    await DiagnosticoDeResolucao.rodar(opcoes)

case "granola":
    var servidor = URL(string: "https://mcp.granola.ai/mcp")!
    var soLista = false
    var detalhe: String?
    var comTranscricao = false
    var sair = false
    var abrirNavegador = true
    var i = 1
    while i < argumentos.count {
        switch argumentos[i] {
        case "--servidor" where i + 1 < argumentos.count:
            servidor = URL(string: argumentos[i + 1]) ?? servidor
            i += 2
        case "--lista":
            soLista = true; i += 1
        case "--detalhe" where i + 1 < argumentos.count:
            detalhe = argumentos[i + 1]; i += 2
        case "--transcricao":
            comTranscricao = true; i += 1
        case "--sair":
            sair = true; i += 1
        case "--sem-navegador":
            abrirNavegador = false; i += 1
        default:
            print("argumento desconhecido: \(argumentos[i])")
            exit(2)
        }
    }

    let cofre = CofreDeTokens(servico: "papagaio-eval:granola")
    let loopback = ServidorDeLoopback()
    let redirecionamento = try? loopback.iniciar()
    if redirecionamento == nil, abrirNavegador {
        print("aviso: não consegui subir o listener em 127.0.0.1 — será necessário colar o código manualmente.")
    }
    let sessao = SessaoOAuth(
        servidorMCP: servidor,
        redirecionamento: redirecionamento,
        cofre: cofre,
        apresentador: ApresentadorDeTerminal(abrirNavegador: abrirNavegador, servidor: loopback)
    )
    if sair {
        await sessao.sair()
        print("credenciais apagadas do Keychain.")
        exit(0)
    }
    let cliente = ClienteMCP(url: servidor) { forcar in
        try await sessao.tokenDeAcesso(forcandoRenovacao: forcar)
    }
    let granola = FonteGranola(cliente: cliente)

    do {
        let conta = try await granola.conta()
        print("conectado como: \(conta.email)\(conta.workspace.map { " · workspace \($0)" } ?? "")")
        print()

        if let detalhe {
            let reuniao = try await granola.obterReuniao(
                id: detalhe,
                incluirTranscricao: comTranscricao
            )
            print("# \(reuniao.titulo)")
            print("data: \(reuniao.data.formatted(date: .abbreviated, time: .shortened))")
            print("participantes: \(reuniao.participantesNomes.isEmpty ? "—" : reuniao.participantesNomes.joined(separator: ", "))")
            if let notas = reuniao.notas, !notas.isEmpty {
                print()
                print("## Notas")
                print(notas)
            }
            if let resumo = reuniao.resumo, !resumo.isEmpty {
                print()
                print("## Resumo")
                print(resumo)
            }
            if let transcricao = reuniao.transcricao, !transcricao.isEmpty {
                print()
                print("## Transcrição (\(transcricao.count) segmentos)")
                for segmento in transcricao {
                    let falante = segmento.falante.map { "\($0): " } ?? ""
                    print("  \(falante)\(segmento.texto)")
                }
            }
        } else {
            let reunioes = try await granola.listarReunioes()
            print("reuniões acessíveis: \(reunioes.count)")
            for (indice, reuniao) in reunioes.prefix(10).enumerated() {
                print(String(format: "  %2d  %@  %@",
                             indice + 1,
                             reuniao.data.formatted(date: .abbreviated, time: .omitted),
                             reuniao.titulo))
                if !reuniao.participantesNomes.isEmpty {
                    print("        com \(reuniao.participantesNomes.joined(separator: ", "))")
                }
            }
            if soLista { exit(0) }
            print()
            print("dica: papagaio-eval granola --detalhe <id> para ver notas e resumo.")
        }
    } catch {
        FileHandle.standardError.write(Data("ERRO no Granola: \(error.localizedDescription)\n".utf8))
        exit(3)
    }

case "bench":
    var soMicro = false
    var iteracoes = 5
    var audio: URL?
    var modelos: URL?
    var saida: String?
    var compararCom: String?
    var somenteCaso: String?
    var somenteQwen = false

    var i = 1
    while i < argumentos.count {
        switch argumentos[i] {
        case "--so-micro":
            soMicro = true; i += 1
        case "--iteracoes" where i + 1 < argumentos.count:
            iteracoes = Int(argumentos[i + 1]) ?? 5; i += 2
        case "--audio" where i + 1 < argumentos.count:
            audio = URL(fileURLWithPath: argumentos[i + 1]); i += 2
        case "--modelos" where i + 1 < argumentos.count:
            modelos = URL(fileURLWithPath: argumentos[i + 1]); i += 2
        case "--saida" where i + 1 < argumentos.count:
            saida = argumentos[i + 1]; i += 2
        case "--comparar" where i + 1 < argumentos.count:
            compararCom = argumentos[i + 1]; i += 2
        case "--somente-caso" where i + 1 < argumentos.count:
            somenteCaso = argumentos[i + 1]; i += 2
        case "--somente-qwen":
            somenteQwen = true; i += 1
        default:
            print("argumento desconhecido: \(argumentos[i])")
            exit(2)
        }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let raizPerf = home.appendingPathComponent("OmuPerf", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let raizDeRuns = home.appendingPathComponent("OmuPerf/runs", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path + "/"
    func estaDentro(_ url: URL, da raiz: String) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(raiz)
    }

    if let saida,
       !estaDentro(URL(fileURLWithPath: saida), da: raizDeRuns) {
        FileHandle.standardError.write(Data("--saida precisa ficar dentro de ~/OmuPerf/runs/.\n".utf8))
        exit(2)
    }
    if let compararCom,
       !estaDentro(URL(fileURLWithPath: compararCom), da: raizPerf) {
        FileHandle.standardError.write(Data("--comparar precisa apontar para uma referência dentro de ~/OmuPerf/.\n".utf8))
        exit(2)
    }
    if let modelos {
        let modelosDoApp = home.appendingPathComponent("Library/Application Support/Papagaio/Models", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let modelosDaFixture = home.appendingPathComponent("OmuPerf/fixtures", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let caminhoModelos = modelos.resolvingSymlinksInPath().standardizedFileURL.path
        guard caminhoModelos == modelosDoApp || caminhoModelos.hasPrefix(modelosDaFixture) else {
            FileHandle.standardError.write(Data("--modelos precisa ser a pasta local do app ou uma fixture em ~/OmuPerf/fixtures/.\n".utf8))
            exit(2)
        }
    }

    if let audio {
        let pastaDeFixtures = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OmuPerf/fixtures", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let caminhoDoAudio = audio.resolvingSymlinksInPath().standardizedFileURL.path
        guard caminhoDoAudio.hasPrefix(pastaDeFixtures) else {
            FileHandle.standardError.write(Data("Audio precisa estar dentro de ~/OmuPerf/fixtures/.\n".utf8))
            exit(2)
        }
    }

    print("papagaio-eval bench — iteracoes=\(iteracoes)")
    let info = RuntimeInfo.coletar()
    print("whisper: \(info.whisperSystemInfo.prefix(80))…")
    print("metal:   \(info.metalDisponivel ? "sim" : "NÃO")")
    print("memoria: \(formatarBytes(CicloDeVidaDeModelos.memoriaDoProcesso))")

    var todos: [ResultadoBench] = []

    if let somenteCaso {
        guard somenteCaso == "aec.processarBlocos" else {
            FileHandle.standardError.write(Data("Caso de micro-benchmark inválido: \(somenteCaso)\n".utf8))
            exit(2)
        }
        soMicro = true
        print("\n--- micro-benchmark isolado: \(somenteCaso) ---")
        todos.append(CasosDeMicroBench.rodarAEC(iteracoes: iteracoes))
    } else if !somenteQwen {
        print("\n--- micro-benchmarks (sem modelos) ---")
        todos += await CasosDeMicroBench.rodar(iteracoes: iteracoes)
    }

    if !soMicro {
        if let modelos {
            print("\n--- macro-benchmarks (modelos locais informados explicitamente) ---")
            let macro = CasosDeMacroBench.Opcoes(
                pastaDeModelos: modelos,
                audio: audio,
                iteracoes: max(1, min(iteracoes, 3)),
                somenteQwen: somenteQwen
            )
            todos += await CasosDeMacroBench.rodar(macro)
        } else {
            print("\nAVISO: passe --modelos para habilitar macro-benchmarks; nenhum diretório de modelos foi examinado.")
        }
    }

    EscritorDeRelatorio.imprimir(todos)

    // Comparar ANTES de gravar: gravar primeiro e depois carregar o mesmo
    // arquivo faria a comparação sempre sair "igual".
    if let baselineCaminho = compararCom,
       let baseline = EscritorDeRelatorio.carregarBaseline(caminho: baselineCaminho) {
        EscritorDeRelatorio.comparar(atual: todos, baseline: baseline)
    }

    if let caminho = saida {
        try EscritorDeRelatorio.gravar(todos, em: caminho)
    }

#if OMU_PERF
case "seed-library":
    var raiz: URL?
    var catalogo: URL?
    var quantidade = 0
    var trechosPorArquivo = 32
    var i = 1
    while i < argumentos.count {
        switch argumentos[i] {
        case "--raiz" where i + 1 < argumentos.count:
            raiz = URL(fileURLWithPath: argumentos[i + 1], isDirectory: true); i += 2
        case "--catalogo" where i + 1 < argumentos.count:
            catalogo = URL(fileURLWithPath: argumentos[i + 1]); i += 2
        case "--quantidade" where i + 1 < argumentos.count:
            quantidade = Int(argumentos[i + 1]) ?? -1; i += 2
        case "--trechos" where i + 1 < argumentos.count:
            trechosPorArquivo = Int(argumentos[i + 1]) ?? -1; i += 2
        default:
            FileHandle.standardError.write(Data("argumento desconhecido: \(argumentos[i])\n".utf8))
            exit(2)
        }
    }
    guard let raiz, quantidade >= 0, (0...500).contains(trechosPorArquivo) else {
        FileHandle.standardError.write(Data("uso: seed-library --raiz <dir> --quantidade N [--trechos 0...500]\n".utf8))
        exit(2)
    }

    let raizPermitida = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("OmuPerf/runs", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard raiz.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(raizPermitida) else {
        FileHandle.standardError.write(Data("--raiz do seed precisa ficar dentro de ~/OmuPerf/runs/.\n".utf8))
        exit(2)
    }

    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    let container = try SwiftDataRepository.containerLocal(
        nome: "OmuPerf",
        url: raiz.appendingPathComponent("biblioteca.store")
    )
    let repositorio = SwiftDataRepository(modelContainer: container)
    let espaco = EspacoID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    var conversas: [[String: Any]] = []
    if let catalogo {
        let pastaDeFixtures = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OmuPerf/fixtures", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let caminhoCatalogo = catalogo.resolvingSymlinksInPath().standardizedFileURL.path
        guard caminhoCatalogo.hasPrefix(pastaDeFixtures) else {
            FileHandle.standardError.write(Data("Catálogo precisa estar em ~/OmuPerf/fixtures/.\n".utf8))
            exit(2)
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogo))
        guard let objeto = json as? [String: Any],
              let itens = objeto["conversas"] as? [[String: Any]],
              quantidade <= itens.count
        else {
            FileHandle.standardError.write(Data("Catálogo seed inválido ou pequeno demais.\n".utf8))
            exit(2)
        }
        conversas = Array(itens.prefix(quantidade))
    }
    for indice in 0..<quantidade {
        let item = conversas.indices.contains(indice) ? conversas[indice] : [:]
        let textosCatalogados = item["trechos"] as? [String]
        let textos = Array((textosCatalogados ?? []).prefix(trechosPorArquivo))
        let quantidadeDeTrechos = textos.isEmpty ? trechosPorArquivo : textos.count
        let termoDeBusca = item["consulta"] as? String ?? ""
        let trechos = (0..<quantidadeDeTrechos).map { ordem in
            let inicio = Double(ordem) * 12
            let base = textos.indices.contains(ordem)
                ? textos[ordem]
                : "Decisão sintética \(indice) etapa \(ordem): revisar prazo, orçamento e próximos passos."
            let texto = ordem == 0 && !termoDeBusca.isEmpty ? "\(base) \(termoDeBusca)" : base
            return Trecho(start: inicio, end: inicio + 4, texto: texto)
        }
        let idArquivo = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", indice + 1))!
        let arquivo = Arquivo(
            id: ArquivoID(rawValue: idArquivo),
            titulo: item["titulo"] as? String ?? "Reunião sintética \(indice + 1)",
            pastaRelativa: "",
            espaco: espaco,
            trechos: trechos,
            resumo: Resumo(
                titulo: item["titulo"] as? String ?? "Plano da reunião \(indice + 1)",
                visaoGeral: item["resumo"] as? String ?? "Decisões, prazos e tarefas sintéticas para medir abertura e busca."
            )
        )
        try await repositorio.salvar(arquivo)
    }
    print("seed-library: \(quantidade) conversas, \(trechosPorArquivo) trechos cada, store em \(raiz.path)")
#endif

case "run":
    FileHandle.standardError.write(
        Data("papagaio-eval run: qualidade/WER ainda no Passo 6 — use `bench` para performance.\n".utf8)
    )
    exit(2)

default:
    uso()
}
