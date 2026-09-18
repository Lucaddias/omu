import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import PapagaioCore

private actor SinalDeTeste {
    private var aberto = false
    private var esperas: [CheckedContinuation<Void, Never>] = []

    func aguardar() async {
        guard !aberto else { return }
        await withCheckedContinuation { esperas.append($0) }
    }

    func abrir() {
        aberto = true
        let atuais = esperas
        esperas.removeAll()
        for espera in atuais { espera.resume() }
    }
}

private actor ResidenteSuspenso: CicloDeVidaDeModelos.Residente {
    nonisolated let identificador: String
    let entrou = SinalDeTeste()
    let liberar = SinalDeTeste()
    private(set) var descartes = 0

    init(_ identificador: String) { self.identificador = identificador }

    func descarregar() async {
        descartes += 1
        await entrou.abrir()
        await liberar.aguardar()
    }
}

@Test("Registrar nova geração durante unload mantém o residente monitorado")
func cicloPreservaRegistroDuranteUnload() async {
    let ciclo = CicloDeVidaDeModelos()
    let anterior = ResidenteSuspenso("modelo")
    let novo = ResidenteSuspenso("modelo")
    await ciclo.registrar(anterior)
    let descarte = Task { await ciclo.descarregarTudo() }
    await anterior.entrou.aguardar()
    await ciclo.registrar(novo)
    await anterior.liberar.abrir()
    await descarte.value
    #expect(await ciclo.identificadoresResidentes == ["modelo"])
    #expect(await novo.descartes == 0)
    await novo.liberar.abrir()
    await ciclo.descarregarTudo()
    #expect(await novo.descartes == 1)
}

@Test("AEC conserva cauda do microfone e bloco final sem referência")
func aecPreservaDuracaoEBlocoParcial() {
    for quantidade in [0, 1, 511, 512, 513, 1027] {
        let microfone = [Float](repeating: 0.37, count: quantidade)
        let cancelador = CanceladorDeEco(tamanhoBloco: 512, comprimentoFiltro: 512)
        let saida = cancelador.processar(microfone: microfone, sistema: [Float](repeating: 0, count: 17))
        #expect(saida == microfone)
    }
}

@Test("Anotação acústica conserva confiança e metadados originais")
func comPalavrasPreservaConfianca() {
    let palavra = Palavra(start: 0, end: 1, texto: "Olá", confianca: 0.92)
    let trecho = Trecho(start: 0, end: 1, texto: "Olá", palavras: [palavra], confianca: 0.92, noSpeechProb: 0.03)
    let marcado = trecho.comPalavras(AlinhamentoDeFalantes.atribuir(
        palavras: trecho.palavras,
        a: [SegmentoDeFalante(falanteId: "S1", inicio: 0, fim: 1)]
    ))
    #expect(marcado.confianca == trecho.confianca)
    #expect(marcado.noSpeechProb == trecho.noSpeechProb)
    #expect(marcado.id == trecho.id)
    #expect(marcado.palavras.first?.falanteAcustico == "S1")
}

private final class ProtocoloDownloadDeTeste: URLProtocol, @unchecked Sendable {
    struct Resposta: Sendable {
        var status = 200
        var cabecalhos: [String: String] = [:]
        var dados = Data()
    }
    static let respostas = Mutex<[String: Resposta]>([:])
    static let pedidos = Mutex<[String: [String?]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let chave = request.url!.absoluteString
        Self.pedidos.withLock { $0[chave, default: []].append(request.value(forHTTPHeaderField: "Range")) }
        let resposta = Self.respostas.withLock { $0[chave]! }
        let http = HTTPURLResponse(url: request.url!, statusCode: resposta.status,
                                   httpVersion: "HTTP/1.1", headerFields: resposta.cabecalhos)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resposta.dados)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct DownloadDeTeste {
    let pasta = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = URL(string: "https://download.test/\(UUID().uuidString)")!
    let sessao: URLSession
    let conteudo = Data("modelo completo".utf8)

    init() throws {
        let configuracao = URLSessionConfiguration.ephemeral
        configuracao.protocolClasses = [ProtocoloDownloadDeTeste.self]
        sessao = URLSession(configuration: configuracao)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    }

    var peso: PesoDeModelo {
        PesoDeModelo(nomeArquivo: "modelo.bin", bytes: Int64(conteudo.count),
                     sha256: SHA256.hash(data: conteudo).map { String(format: "%02x", $0) }.joined(), url: url)
    }
    var destino: URL { pasta.appendingPathComponent(peso.nomeArquivo) }
    var parcial: URL { destino.appendingPathExtension("parcial") }
    func limpar() {
        sessao.invalidateAndCancel()
        try? FileManager.default.removeItem(at: pasta)
        _ = ProtocoloDownloadDeTeste.respostas.withLock { $0.removeValue(forKey: url.absoluteString) }
        _ = ProtocoloDownloadDeTeste.pedidos.withLock { $0.removeValue(forKey: url.absoluteString) }
    }
    func responder(status: Int = 200, cabecalhos: [String: String] = [:], dados: Data) {
        ProtocoloDownloadDeTeste.respostas.withLock {
            $0[url.absoluteString] = .init(status: status, cabecalhos: cabecalhos, dados: dados)
        }
    }
}

@Test("Duas instâncias concorrentes promovem um único download íntegro")
func downloadsConcorrentes() async throws {
    let teste = try DownloadDeTeste()
    defer { teste.limpar() }
    teste.responder(dados: teste.conteudo)
    async let primeiro = DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    async let segundo = DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    let urls = try await [primeiro, segundo]
    #expect(urls == [teste.destino, teste.destino])
    #expect(try Data(contentsOf: teste.destino) == teste.conteudo)
    #expect(ProtocoloDownloadDeTeste.pedidos.withLock { $0[teste.url.absoluteString]?.count } == 1)
}

@Test("Retomada rejeita Content-Range incompatível e preserva parcial")
func downloadRejeitaIntervaloErrado() async throws {
    let teste = try DownloadDeTeste()
    defer { teste.limpar() }
    let prefixo = teste.conteudo.prefix(3)
    try prefixo.write(to: teste.parcial)
    teste.responder(status: 206, cabecalhos: ["Content-Range": "bytes 0-14/15"], dados: teste.conteudo)
    await #expect(throws: ErroDownload.self) {
        _ = try await DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    }
    #expect(try Data(contentsOf: teste.parcial) == prefixo)
    #expect(!FileManager.default.fileExists(atPath: teste.destino.path))
}

@Test("Parcial completo é validado e promovido sem pedir Range além do fim")
func downloadPromoveParcialCompleto() async throws {
    let teste = try DownloadDeTeste()
    defer { teste.limpar() }
    try teste.conteudo.write(to: teste.parcial)
    let destino = try await DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    #expect(destino == teste.destino)
    #expect(try Data(contentsOf: destino) == teste.conteudo)
    #expect(ProtocoloDownloadDeTeste.pedidos.withLock { $0[teste.url.absoluteString] } == nil)
}

@Test("Corpo baixado de mesmo tamanho com checksum incorreto nunca é promovido")
func downloadRejeitaCorpoCorrompido() async throws {
    let teste = try DownloadDeTeste()
    defer { teste.limpar() }
    teste.responder(dados: Data(repeating: 0, count: teste.conteudo.count))
    await #expect(throws: ErroDownload.self) {
        _ = try await DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    }
    #expect(!FileManager.default.fileExists(atPath: teste.destino.path))
    #expect(!FileManager.default.fileExists(atPath: teste.parcial.path))
}

@Test("Destino existente com checksum errado não é aceito como modelo pronto")
func downloadValidaDestinoExistente() async throws {
    let teste = try DownloadDeTeste()
    defer { teste.limpar() }
    try Data(repeating: 0, count: teste.conteudo.count).write(to: teste.destino)
    await #expect(throws: ErroDownload.self) {
        _ = try await DownloadDeModelos(pastaDeModelos: teste.pasta, sessao: teste.sessao).baixar(teste.peso)
    }
}
