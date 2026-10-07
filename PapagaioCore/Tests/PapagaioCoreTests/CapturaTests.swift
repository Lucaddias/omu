import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import PapagaioCore

// Testes do Passo 2, atualizados para o backend do Eko. Cobrem o que dá para
// verificar sem microfone, sem permissão de TCC e sem uma reunião real: o
// medidor de nível, os caminhos sob sandbox, os formatos de gravação e a
// importação de arquivo.
//
// O que NÃO dá para testar aqui está listado no relatório do passo: gravação
// de chamada real, subida do `SystemAudioTap`, inteligibilidade das duas
// vozes e ausência de alocação nos blocos de tap (isso é Instruments, não
// teste unitário).

// MARK: - Nível

@Test("NivelAudio calcula RMS e normaliza em dB")
func nivelRMS() {
    let nivel = NivelAudio()
    let amostras = [Float](repeating: 0.5, count: 100)
    amostras.withUnsafeBufferPointer { nivel.registrar($0.baseAddress!, quantidade: 100) }

    #expect(abs(nivel.rms - 0.5) < 0.0001)
    // 0,5 linear ≈ -6 dBFS → (−6+60)/60 = 0,9
    #expect(abs(nivel.normalizado - 0.9) < 0.01)

    let silencio = NivelAudio()
    let zeros = [Float](repeating: 0, count: 10)
    zeros.withUnsafeBufferPointer { silencio.registrar($0.baseAddress!, quantidade: 10) }
    #expect(silencio.normalizado == 0)
}

@Test("NivelAudio aceita valor normalizado do medidor do AVAudioRecorder")
func nivelDefinidoNormalizado() {
    let nivel = NivelAudio()
    nivel.definirNormalizado(0.9)
    #expect(abs(nivel.normalizado - 0.9) < 0.01)

    nivel.definirNormalizado(0)
    #expect(nivel.normalizado == 0)

    // O medidor entrega dB reais; 0 dBFS vira 1, e o clamp protege a UI.
    nivel.definirNormalizado(2)
    #expect(nivel.normalizado == 1)
    nivel.definirNormalizado(-1)
    #expect(nivel.normalizado == 0)
}

// MARK: - Pausa do tap do sistema

/// ASBD de teste: Float32 PCM 48 kHz estéreo — o formato típico do tap.
private var formatoDeTeste: AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

/// Escreve num CAF real para medir quantos frames chegaram ao arquivo.
private func framesEscritos(em url: URL) throws -> Int64 {
    let arquivo = try AVAudioFile(forReading: url)
    return arquivo.length
}

@Test("Tap do sistema pausado não escreve frames no arquivo")
func tapPausadoDescartaBuffers() async throws {
    try await confirmation("o callback descartou os buffers durante a pausa") { confirmado in
        let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaria, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaria) }
        let url = temporaria.appendingPathComponent("sistema.caf")
        let formato = formatoDeTeste

        let writer = try SystemTrackWriter(url: url, format: formato)
        let estado = SystemTapCallbackState(writer: writer, format: formato, nivel: NivelAudio())

        func buffer(frames: UInt32) -> AudioBuffer {
            // O formato de teste tem 8 bytes por frame (2 canais Float32).
            let bytes = Int(frames) * 8
            let ponteiro = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4)
            ponteiro.initializeMemory(as: Float.self, repeating: 0.1, count: bytes / 4)
            return AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes), mData: ponteiro)
        }

        // 10 frames antes da pausa.
        let antes = buffer(frames: 10)
        estado.consume(buffer: antes, frames: 10)
        free(antes.mData)

        // Durante a pausa, nenhum frame pode chegar ao arquivo.
        estado.pausar()
        let descartado = buffer(frames: 50)
        estado.consume(buffer: descartado, frames: 50)
        free(descartado.mData)

        estado.continuar()
        let depois = buffer(frames: 10)
        estado.consume(buffer: depois, frames: 10)
        free(depois.mData)

        estado.finalizarEscrita()

        let frames = try framesEscritos(em: url)
        #expect(frames == 20) // 10 + 10; os 50 da pausa não entraram
        confirmado()
    }
}

@Test("Estatísticas do tap contam só os frames escritos")
func tapPausadoEstatisticas() throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporaria, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaria) }
    let url = temporaria.appendingPathComponent("sistema.caf")
    let formato = formatoDeTeste

    let writer = try SystemTrackWriter(url: url, format: formato)
    let estado = SystemTapCallbackState(writer: writer, format: formato, nivel: NivelAudio())

    let amostras = [Float](repeating: 0.2, count: 8)
    amostras.withUnsafeBufferPointer { ponteiro in
        let audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(ponteiro.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(mutating: ponteiro.baseAddress)
        )
        estado.consume(buffer: audioBuffer, frames: 4)
        estado.pausar()
        estado.consume(buffer: audioBuffer, frames: 4)
        estado.continuar()
        estado.consume(buffer: audioBuffer, frames: 4)
    }

    let estatisticas = estado.statistics
    #expect(estatisticas.callbacks == 2) // o callback da pausa não conta
    #expect(estatisticas.frames == 8) // 4 + 4; o do meio foi descartado
    #expect(estatisticas.peak != nil)
}

// MARK: - Formato de gravação

@Test("Formato do microfone é WAV PCM 16 kHz mono de 16 bits")
func formatoMicrofone() {
    let formato = FormatoAudio.microfoneWAV
    #expect(formato[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
    #expect(formato[AVSampleRateKey] as? Double == FormatoAudio.taxaCanonica)
    #expect(formato[AVNumberOfChannelsKey] as? Int == 1)
    #expect(formato[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(formato[AVLinearPCMIsFloatKey] as? Bool == false)
}

@Test("Gravação mais curta que 1 s é descartada como clique acidental")
func duracaoMinima() {
    #expect(SessaoGravacao.duracaoMinima == 1.0)
    // O corte vale para o que de fato foi gravado, não para o relógio do gravador.
    #expect(SessaoGravacao.duracaoFinal(observada: 0.4, doArquivo: 0.4) < SessaoGravacao.duracaoMinima)
}

// C-01: quando o sistema encerra o `AVAudioRecorder` sozinho, `currentTime`
// volta a 0. Decidir o descarte por esse 0 apagava a pasta inteira, mesmo com
// minutos de áudio já gravados.
@Test("Gravação interrompida pelo sistema mantém a duração real em vez de virar zero")
func duracaoDeGravacaoInterrompida() {
    // Gravador já parado (reporta 0), mas o arquivo tem 5 minutos.
    #expect(SessaoGravacao.duracaoFinal(observada: 0, doArquivo: 300) == 300)
    // Arquivo ilegível: vale o maior tempo observado enquanto gravava.
    #expect(SessaoGravacao.duracaoFinal(observada: 127.5, doArquivo: nil) == 127.5)
    // Nada gravado de fato.
    #expect(SessaoGravacao.duracaoFinal(observada: 0, doArquivo: nil) == 0)
    // Valores não finitos nunca viram duração.
    #expect(SessaoGravacao.duracaoFinal(observada: .nan, doArquivo: .infinity) == 0)
}

@Test("Duração do microfone é lida do próprio arquivo WAV")
func duracaoLidaDoArquivoDoMicrofone() throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporaria, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaria) }

    let url = temporaria.appendingPathComponent(Armazenamento.Nome.microfone)
    let quadros = AVAudioFrameCount(FormatoAudio.taxaCanonica * 3)
    do {
        let arquivo = try AVAudioFile(forWriting: url, settings: FormatoAudio.microfoneWAV)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: arquivo.processingFormat, frameCapacity: quadros)
        )
        buffer.frameLength = quadros
        try arquivo.write(from: buffer)
    }

    let duracao = try #require(SessaoGravacao.duracaoDoMicrofone(em: url))
    #expect(abs(duracao - 3) < 0.01)

    // Cabeçalho ilegível: a estimativa por tamanho ainda evita o descarte.
    let semCabecalho = temporaria.appendingPathComponent("cru.wav")
    try Data(repeating: 0, count: 44 + 64_000).write(to: semCabecalho)
    let estimada = try #require(SessaoGravacao.duracaoDoMicrofone(em: semCabecalho))
    #expect(abs(estimada - 2) < 0.01)

    #expect(SessaoGravacao.duracaoDoMicrofone(em: temporaria.appendingPathComponent("ausente.wav")) == nil)
}

// C-09/B-01: caminho persistido vazio ou com travessia não pode virar alvo de
// cópia ou exclusão.
@Test("resolverSeguro recusa caminho vazio, absoluto e com travessia")
func armazenamentoResolveSoDentroDaRaiz() throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let armazenamento = Armazenamento(raiz: temporaria)
    let id = UUID()

    let valido = try armazenamento.resolverSeguro(relativo: Armazenamento.caminhoRelativo(id: id))
    #expect(valido == armazenamento.pastaDaGravacao(id: id).standardizedFileURL)

    for invalido in ["", "/etc", "Gravacoes/..", "Gravacoes/../..", "../fora", "Gravacoes//x", "."] {
        #expect(throws: ErroArmazenamento.self, "aceitou \"\(invalido)\"") {
            _ = try armazenamento.resolverSeguro(relativo: invalido)
        }
    }
}

// MARK: - Armazenamento

@Test("Caminho da gravação é relativo e fica sob a raiz")
func armazenamentoCaminhoRelativo() throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporaria) }

    let armazenamento = Armazenamento(raiz: temporaria)
    let id = UUID()

    let relativo = Armazenamento.caminhoRelativo(id: id)
    #expect(!relativo.hasPrefix("/"))
    #expect(relativo == "Gravacoes/\(id.uuidString)")

    let pasta = try armazenamento.criarPastaDaGravacao(id: id)
    #expect(FileManager.default.fileExists(atPath: pasta.path))
    #expect(pasta.path.hasPrefix(temporaria.path))

    // O caminho relativo guardado no modelo resolve de volta para a mesma pasta.
    #expect(armazenamento.resolver(relativo: relativo).standardizedFileURL == pasta.standardizedFileURL)
}

@Test("Arquivos de áudio canônicos nascem com os nomes da nova convenção")
func armazenamentoArquivosCanonicos() throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporaria) }

    let armazenamento = Armazenamento(raiz: temporaria)
    let id = UUID()

    let microfone = try armazenamento.criarArquivoDeAudio(id: id, nome: Armazenamento.Nome.microfone)
    #expect(microfone.lastPathComponent == "microfone.wav")
    #expect(microfone.deletingLastPathComponent().lastPathComponent == id.uuidString)
    #expect(FileManager.default.fileExists(atPath: microfone.deletingLastPathComponent().path))

    let sistema = try armazenamento.criarArquivoDeAudio(id: id, nome: Armazenamento.Nome.sistema)
    #expect(sistema.lastPathComponent == "sistema.caf")

    let importado = try armazenamento.criarArquivoImportado(id: id, extensao: "m4a")
    #expect(importado.lastPathComponent == "gravacao.m4a")
    let importadoWav = try armazenamento.criarArquivoImportado(id: id, extensao: "wav")
    #expect(importadoWav.lastPathComponent == "gravacao.wav")
}

// MARK: - Importação

/// Gera um `.m4a` real de teste: um seno de 440 Hz, 2 s, 44,1 kHz mono.
private func gerarAudioDeTeste(em destino: URL, segundos: Double = 2) throws {
    let taxa: Double = 44_100
    let formato = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: taxa, channels: 1, interleaved: false
    )!
    let arquivo = try AVAudioFile(
        forWriting: destino,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: taxa,
            AVNumberOfChannelsKey: 1,
        ]
    )

    let quadros = AVAudioFrameCount(taxa * segundos)
    let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: quadros)!
    buffer.frameLength = quadros
    let canal = buffer.floatChannelData![0]
    let doisPi: Double = 2 * Double.pi
    let frequencia: Double = 440
    for quadro in 0..<Int(quadros) {
        let fase: Double = doisPi * frequencia * Double(quadro) / taxa
        canal[quadro] = Float(0.3 * sin(fase))
    }
    try arquivo.write(from: buffer)
}

@Test("Importa .m4a externo copiando como veio, sem re-encodar")
func importacaoCopiaParaContainer() async throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporaria, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaria) }

    let origem = temporaria.appendingPathComponent("entrevista-externa.m4a")
    try gerarAudioDeTeste(em: origem)

    let armazenamento = Armazenamento(raiz: temporaria.appendingPathComponent("container"))
    let importador = ImportadorAudio(armazenamento: armazenamento)
    let resultado = try await importador.importar(de: origem)

    #expect(resultado.tituloSugerido == "entrevista-externa")
    #expect(abs(resultado.duracao - 2) < 0.5)
    #expect(resultado.bytes > 0)
    #expect(!resultado.pastaRelativa.hasPrefix("/"))

    // O arquivo tem que estar dentro do container, não ser referência ao original.
    let destino = armazenamento
        .resolver(relativo: resultado.pastaRelativa)
        .appendingPathComponent("gravacao.m4a")
    #expect(FileManager.default.fileExists(atPath: destino.path))

    // E tem que ter sido copiado no formato original, sem conversão — a
    // conversão acontece na leitura (`DecodificadorDeAudio`), não na importação.
    let copiado = try AVAudioFile(forReading: destino)
    #expect(copiado.fileFormat.sampleRate == 44_100)
    #expect(copiado.fileFormat.channelCount == 1)
}

@Test("Importação recusa arquivo que não tem trilha de áudio")
func importacaoRecusaArquivoInvalido() async throws {
    let temporaria = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporaria, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaria) }

    let falso = temporaria.appendingPathComponent("nao-e-audio.m4a")
    try Data("isto não é áudio".utf8).write(to: falso)

    let importador = ImportadorAudio(
        armazenamento: Armazenamento(raiz: temporaria.appendingPathComponent("container"))
    )

    await #expect(throws: (any Error).self) {
        _ = try await importador.importar(de: falso)
    }
}

// MARK: - Reparo de WAV interrompido

/// WAV PCM 16 bits mono a 16 kHz, com um bloco de enchimento antes do `data`
/// (como o `AVAudioRecorder` escreve) e os tamanhos que o teste pedir.
private func wavDeTeste(
    amostras: Int,
    tamanhoRIFF: UInt32?,
    tamanhoDeDados: UInt32?
) -> Data {
    func le(_ valor: UInt32) -> Data { Data([0, 8, 16, 24].map { UInt8((valor >> $0) & 0xFF) }) }
    func le16(_ valor: UInt16) -> Data { Data([UInt8(valor & 0xFF), UInt8(valor >> 8)]) }
    let dados = Data(repeating: 1, count: amostras * 2)
    var corpo = Data("WAVE".utf8)
    corpo += Data("fmt ".utf8) + le(16) + le16(1) + le16(1) + le(16_000) + le(32_000) + le16(2) + le16(16)
    corpo += Data("FLLR".utf8) + le(8) + Data(repeating: 0, count: 8)
    corpo += Data("data".utf8) + le(tamanhoDeDados ?? UInt32(dados.count)) + dados
    return Data("RIFF".utf8) + le(tamanhoRIFF ?? UInt32(corpo.count)) + corpo
}

@Test("WAV de gravação interrompida ganha o tamanho real no cabeçalho")
func reparoDeWAVInterrompido() throws {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // Dois segundos de áudio no disco, cabeçalho ainda zerado.
    try wavDeTeste(amostras: 32_000, tamanhoRIFF: 0, tamanhoDeDados: 0).write(to: url)

    #expect(try ReparoDeWAV.reparar(url))

    let arquivo = try AVAudioFile(forReading: url)
    #expect(arquivo.length == 32_000)
    #expect(try Data(contentsOf: url) == wavDeTeste(amostras: 32_000, tamanhoRIFF: nil, tamanhoDeDados: nil))
    // Reparar de novo não mexe em mais nada.
    #expect(try !ReparoDeWAV.reparar(url))
}

@Test("WAV íntegro e arquivo que não é WAV ficam intocados")
func reparoDeWAVNaoTocaNoQueEstaCerto() throws {
    let integro = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    let outro = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    defer {
        try? FileManager.default.removeItem(at: integro)
        try? FileManager.default.removeItem(at: outro)
    }
    let original = wavDeTeste(amostras: 1_600, tamanhoRIFF: nil, tamanhoDeDados: nil)
    try original.write(to: integro)
    try Data("isto não é áudio, de jeito nenhum".utf8).write(to: outro)

    #expect(try !ReparoDeWAV.reparar(integro))
    #expect(try Data(contentsOf: integro) == original)
    #expect(try !ReparoDeWAV.reparar(outro))
    #expect(try Data(contentsOf: outro) == Data("isto não é áudio, de jeito nenhum".utf8))
}

@Test("WAV truncado tem o tamanho declarado reduzido ao que existe")
func reparoDeWAVTruncado() throws {
    let url = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // Cabeçalho promete 10 s; o disco tem 1 s.
    try wavDeTeste(amostras: 16_000, tamanhoRIFF: 320_052, tamanhoDeDados: 320_000).write(to: url)

    #expect(try ReparoDeWAV.reparar(url))

    #expect(try AVAudioFile(forReading: url).length == 16_000)
}
