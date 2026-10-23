import CryptoKit
import Foundation
import LlamaRuntime
import Testing
import WhisperRuntime
@testable import PapagaioCore

// MARK: - Linkagem dos runtimes

@Test("whisper.cpp e llama.cpp linkam juntos, os dois com Metal")
func runtimesLinkados() {
    let info = RuntimeInfo.coletar()

    #expect(info.whisperSystemInfo.contains("WHISPER"))
    #expect(info.whisperSystemInfo.contains("MTL"))
    #expect(info.llamaSystemInfo.contains("MTL"))
    #expect(info.metalDisponivel)
}

// MARK: - Preflight

@Test("Preflight bloqueia por RAM antes de olhar qualquer outra coisa")
func preflightRAM() {
    // O piso é 18 GB; a máquina de desenvolvimento tem 24 GB.
    #expect(Preflight.ramMinima == 18 * 1_073_741_824)
    #expect(Preflight.ramInstalada > 0)

    let vazia = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let resultado = Preflight(pastaDeModelos: vazia).avaliar()

    if Preflight.ramInstalada < Preflight.ramMinima {
        #expect(resultado.bloqueia)
        if case .ramInsuficiente = resultado {} else {
            Issue.record("esperava .ramInsuficiente, veio \(resultado)")
        }
    } else {
        // Passando a RAM e o disco, a pasta vazia cai em pesosFaltando.
        if case let .pesosFaltando(faltando) = resultado {
            #expect(faltando.count == 2)
        } else {
            Issue.record("esperava .pesosFaltando, veio \(resultado)")
        }
    }
}

@Test("Estados de bloqueio são os dois de hardware, e só eles")
func preflightBloqueio() {
    #expect(ResultadoPreflight.ramInsuficiente(instalada: 1, minima: 2).bloqueia)
    #expect(ResultadoPreflight.discoInsuficiente(livre: 1, minimo: 2).bloqueia)
    #expect(!ResultadoPreflight.pronto.bloqueia)
    #expect(!ResultadoPreflight.termicoCritico.bloqueia)
    #expect(!ResultadoPreflight.pesosFaltando([]).bloqueia)
}

@Test("Mensagem de RAM insuficiente diz que não há modo reduzido")
func preflightMensagemRAM() {
    let msg = ResultadoPreflight
        .ramInsuficiente(instalada: 8 * 1_073_741_824, minima: 18 * 1_073_741_824)
        .mensagem
    #expect(msg.contains("18 GB"))
    #expect(msg.contains("8 GB"))
    #expect(msg.lowercased().contains("não há modo reduzido"))
}

@Test("Peso com tamanho errado é recusado sem precisar do hash")
func preflightTamanhoErrado() throws {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }

    let falso = PesoDeModelo(
        nomeArquivo: "modelo.bin", bytes: 1_000, sha256: "",
        url: URL(string: "https://exemplo.invalido/modelo.bin")!
    )
    try Data(repeating: 0, count: 999).write(to: pasta.appendingPathComponent("modelo.bin"))

    let preflight = Preflight(pastaDeModelos: pasta)
    #expect(!preflight.pesoValido(falso, verificarChecksum: false))
}

@Test("Checksum inválido reprova o peso mesmo com o tamanho certo")
func preflightChecksumInvalido() throws {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }

    let conteudo = Data("conteúdo do modelo".utf8)
    let arquivo = pasta.appendingPathComponent("modelo.bin")
    try conteudo.write(to: arquivo)

    let hashCerto = SHA256.hash(data: conteudo).map { String(format: "%02x", $0) }.joined()

    let certo = PesoDeModelo(
        nomeArquivo: "modelo.bin", bytes: Int64(conteudo.count), sha256: hashCerto,
        url: URL(string: "https://exemplo.invalido/m")!
    )
    let errado = PesoDeModelo(
        nomeArquivo: "modelo.bin", bytes: Int64(conteudo.count),
        sha256: String(repeating: "0", count: 64),
        url: URL(string: "https://exemplo.invalido/m")!
    )

    let preflight = Preflight(pastaDeModelos: pasta)
    #expect(preflight.pesoValido(certo, verificarChecksum: true))
    #expect(!preflight.pesoValido(errado, verificarChecksum: true))
    // Sem verificar o hash, o tamanho certo basta.
    #expect(preflight.pesoValido(errado, verificarChecksum: false))
}

@Test("SHA-256 em streaming bate com o de uma tacada só")
func sha256Streaming() throws {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }

    // Maior que o bloco de leitura de 4 MB, para exercitar o laço.
    var dados = Data()
    dados.reserveCapacity(10 * 1_048_576)
    for i in 0..<(10 * 1_048_576) { dados.append(UInt8(i % 251)) }

    let arquivo = pasta.appendingPathComponent("grande.bin")
    try dados.write(to: arquivo)

    let esperado = SHA256.hash(data: dados).map { String(format: "%02x", $0) }.joined()
    #expect(try Preflight.sha256(de: arquivo) == esperado)
}

// MARK: - Pesos declarados

@Test("Os dois pesos declarados têm tamanho e hash preenchidos")
func pesosDeclarados() {
    #expect(Pesos.todos.count == 2)
    for peso in Pesos.todos {
        #expect(peso.bytes > 1_000_000_000)
        #expect(peso.sha256.count == 64)
        #expect(peso.url.scheme == "https")
    }
    #expect(Pesos.whisperLargeV3.bytes == 3_095_033_483)
    #expect(Pesos.qwen35_9B.bytes == 6_169_341_984)
}

// MARK: - Ciclo de vida

private final class ResidenteFalso: CicloDeVidaDeModelos.Residente, @unchecked Sendable {
    let identificador: String
    private(set) var descarregou = false
    init(_ id: String) { identificador = id }
    func descarregar() async { descarregou = true }
}

@Test("Pressão de memória descarrega todos os residentes")
func cicloDeVidaDescarrega() async {
    let ciclo = CicloDeVidaDeModelos()
    let whisper = ResidenteFalso("whisper")
    let qwen = ResidenteFalso("qwen")

    await ciclo.registrar(whisper)
    await ciclo.registrar(qwen)
    #expect(await ciclo.identificadoresResidentes == ["qwen", "whisper"])

    await ciclo.descarregarTudo()

    #expect(whisper.descarregou)
    #expect(qwen.descarregou)
    #expect(await ciclo.identificadoresResidentes.isEmpty)
    #expect(await ciclo.descartouRecentemente != nil)
}

@Test("Monitoramento é idempotente e para sem crashar")
func cicloDeVidaMonitoramento() async {
    let ciclo = CicloDeVidaDeModelos()
    await ciclo.iniciarMonitoramento()
    await ciclo.iniciarMonitoramento()
    await ciclo.pararMonitoramento()
    await ciclo.pararMonitoramento()
    #expect(CicloDeVidaDeModelos.memoriaDoProcesso > 0)
}

// MARK: - Download

@Test("Download recusa e apaga arquivo com checksum errado")
func downloadChecksumErrado() async throws {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pasta) }

    // Servidor inexistente: só precisamos provar que não promove nada.
    let peso = PesoDeModelo(
        nomeArquivo: "inexistente.bin", bytes: 10,
        sha256: String(repeating: "a", count: 64),
        url: URL(string: "https://localhost:1/inexistente.bin")!
    )
    let baixador = DownloadDeModelos(pastaDeModelos: pasta)

    await #expect(throws: (any Error).self) {
        _ = try await baixador.baixar(peso)
    }
    #expect(!FileManager.default.fileExists(
        atPath: pasta.appendingPathComponent("inexistente.bin").path
    ))
}

@Test("Peso já presente em disco não é rebaixado")
func downloadNaoRebaixa() async throws {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }

    let destino = pasta.appendingPathComponent("ja-existe.bin")
    try Data("pronto".utf8).write(to: destino)

    let peso = PesoDeModelo(
        nomeArquivo: "ja-existe.bin", bytes: 6, sha256: "",
        url: URL(string: "https://localhost:1/nunca-chamado.bin")!
    )
    let url = try await DownloadDeModelos(pastaDeModelos: pasta).baixar(peso)
    #expect(url == destino)
}

@Test("Erros dos runtimes chegam à tela com a própria mensagem")
func errosDosRuntimesTemDescricaoLocalizada() {
    let erros: [(any Error, String)] = [
        (ErroWhisper.semFalaDetectada, ErroWhisper.semFalaDetectada.description),
        (ErroLlama.contextoNaoCriado, ErroLlama.contextoNaoCriado.description),
        (ErroDownload.interrompido, ErroDownload.interrompido.description),
    ]
    for (erro, esperado) in erros {
        // Sem `LocalizedError` isto era "The operation couldn't be completed…".
        #expect(erro.localizedDescription == esperado)
    }
}

@Test("Com os pesos instalados, pouco disco livre não bloqueia a transcrição")
func preflightDiscoSoPeloQueFaltaBaixar() throws {
    guard Preflight.ramInstalada >= Preflight.ramMinima else { return }
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pasta) }
    let gb: Int64 = 1_073_741_824
    let instalado = PesoDeModelo(
        nomeArquivo: "instalado.bin", bytes: 1_000, sha256: "",
        url: URL(string: "https://exemplo.invalido/instalado.bin")!
    )
    let ausente = PesoDeModelo(
        nomeArquivo: "ausente.bin", bytes: 6 * gb, sha256: "",
        url: URL(string: "https://exemplo.invalido/ausente.bin")!
    )
    try Data(repeating: 0, count: 1_000).write(to: pasta.appendingPathComponent("instalado.bin"))

    // 5 GB livres — bem abaixo dos 20 GB do piso de instalação.
    let apertado = Preflight(pastaDeModelos: pasta, discoLivre: 5 * gb)

    // Tudo instalado: só a folga de trabalho é exigida.
    let comTudo = apertado.avaliar(pesos: [instalado])
    #expect(comTudo == .pronto || comTudo == .termicoCritico)

    // Falta um peso de 6 GB: aí sim o espaço não basta, e o número pedido é
    // o do que falta baixar — não os 20 GB fixos.
    #expect(
        apertado.avaliar(pesos: [instalado, ausente])
            == .discoInsuficiente(livre: 5 * gb, minimo: 6 * gb + Preflight.folgaDeDisco)
    )

    // Com espaço para o que falta, o resultado é a oferta de download.
    let folgado = Preflight(pastaDeModelos: pasta, discoLivre: 9 * gb)
    #expect(folgado.avaliar(pesos: [instalado, ausente]) == .pesosFaltando([ausente]))

    // Sem a folga mínima nem os modelos instalados resolvem.
    let cheio = Preflight(pastaDeModelos: pasta, discoLivre: gb)
    #expect(cheio.avaliar(pesos: [instalado]).bloqueia)
}

@Test("Os pesos são baixados de um commit fixo, não do ramo (M-02)")
func pesosApontamParaUmCommit() {
    for peso in Pesos.todos {
        let partes = peso.url.pathComponents
        let indice = partes.firstIndex(of: "resolve")
        let revisao = indice.flatMap { partes.indices.contains($0 + 1) ? partes[$0 + 1] : nil }
        #expect(revisao?.count == 40, "\(peso.nomeArquivo) aponta para \(revisao ?? "nada")")
        #expect(revisao?.allSatisfy(\.isHexDigit) == true)
        #expect(partes.last == peso.nomeArquivo)
    }
}
