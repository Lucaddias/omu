import CryptoKit
import Foundation

/// Progresso de um download de peso, para a UI.
public struct ProgressoDownload: Sendable, Equatable {
    public let peso: PesoDeModelo
    public let bytesRecebidos: Int64
    public let bytesTotais: Int64

    public var fracao: Double {
        bytesTotais > 0 ? Double(bytesRecebidos) / Double(bytesTotais) : 0
    }
}

public enum ErroDownload: Error, CustomStringConvertible {
    case checksumInvalido(esperado: String, obtido: String)
    case respostaInvalida(Int)
    case tamanhoInvalido(esperado: Int64, obtido: Int64)
    case intervaloInvalido
    case interrompido

    public var description: String {
        switch self {
        case let .checksumInvalido(esperado, obtido):
            "O arquivo baixado não confere (esperado \(esperado.prefix(12))…, "
                + "obtido \(obtido.prefix(12))…). Ele foi descartado."
        case let .respostaInvalida(codigo):
            "O servidor respondeu \(codigo)."
        case let .tamanhoInvalido(esperado, obtido):
            "O modelo tem \(obtido) bytes; eram esperados \(esperado)."
        case .intervaloInvalido:
            "O servidor respondeu com um intervalo incompatível com a retomada."
        case .interrompido:
            "Download interrompido."
        }
    }
}

/// Baixa os pesos GGUF, com retomada em queda de conexão e verificação de
/// SHA-256 por artefato.
///
/// **Os pesos nunca vão no bundle** — são dados baixados depois da instalação.
/// É o que mantém o app dentro da guideline 2.5.2 da App Store (R-6) e o que
/// permite um `.app` de tamanho normal para modelos grandes.
public actor DownloadDeModelos {
    // Compartilhada entre instâncias: dois baixadores podem apontar à mesma pasta.
    private static let fila = FilaEstrita()
    private let pastaDeModelos: URL
    private let sessao: URLSession

    public init(pastaDeModelos: URL, sessao: URLSession = .shared) {
        self.pastaDeModelos = pastaDeModelos
        self.sessao = sessao
    }

    /// Baixa um peso, retomando de onde parou se houver arquivo parcial.
    ///
    /// A retomada usa `Range:` HTTP sobre um arquivo `.parcial` no disco, e não
    /// `URLSessionDownloadTask.cancel(byProducingResumeData:)`: o resume data da
    /// Apple não sobrevive a um encerramento do app, e um modelo de vários GB é grande demais
    /// para recomeçar do zero por causa disso.
    public func baixar(
        _ peso: PesoDeModelo,
        aoProgredir: @escaping @Sendable (ProgressoDownload) -> Void = { _ in }
    ) async throws -> URL {
        await Self.fila.entrar()
        do {
            try Task.checkCancellation()
            let resultado = try await baixarSemFila(peso, aoProgredir: aoProgredir)
            await Self.fila.sair()
            return resultado
        } catch {
            await Self.fila.sair()
            throw error
        }
    }

    private func baixarSemFila(
        _ peso: PesoDeModelo,
        aoProgredir: @escaping @Sendable (ProgressoDownload) -> Void
    ) async throws -> URL {
        let destino = pastaDeModelos.appendingPathComponent(peso.nomeArquivo)
        if FileManager.default.fileExists(atPath: destino.path) {
            try validar(destino, peso: peso)
            aoProgredir(ProgressoDownload(peso: peso, bytesRecebidos: peso.bytes, bytesTotais: peso.bytes))
            return destino
        }

        try FileManager.default.createDirectory(
            at: pastaDeModelos, withIntermediateDirectories: true
        )

        let parcial = destino.appendingPathExtension("parcial")
        var jaBaixado = Self.tamanhoEmDisco(parcial)
        // Uma transferência concluída antes de encerrar o app pode estar apenas
        // aguardando a promoção. Evita pedir Range além do fim (HTTP 416).
        if jaBaixado >= peso.bytes, jaBaixado > 0 {
            do {
                try validar(parcial, peso: peso)
                try FileManager.default.moveItem(at: parcial, to: destino)
                aoProgredir(ProgressoDownload(peso: peso, bytesRecebidos: peso.bytes, bytesTotais: peso.bytes))
                return destino
            } catch let erro as ErroDownload {
                switch erro {
                case .checksumInvalido, .tamanhoInvalido:
                    try FileManager.default.removeItem(at: parcial)
                    jaBaixado = 0
                default: throw erro
                }
            }
        }

        var requisicao = URLRequest(url: peso.url)
        if jaBaixado > 0 {
            requisicao.setValue("bytes=\(jaBaixado)-", forHTTPHeaderField: "Range")
        }

        let (bytes, resposta) = try await sessao.bytes(for: requisicao)
        guard let http = resposta as? HTTPURLResponse else {
            throw ErroDownload.respostaInvalida(-1)
        }
        // 200 = do começo; 206 = retomada aceita.
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw ErroDownload.respostaInvalida(http.statusCode)
        }

        let retomando = http.statusCode == 206
        if retomando {
            guard Self.intervaloValido(
                http.value(forHTTPHeaderField: "Content-Range"),
                inicio: jaBaixado, total: peso.bytes
            ) else { throw ErroDownload.intervaloInvalido }
        }
        let inicio: Int64 = retomando ? jaBaixado : 0
        if !retomando, FileManager.default.fileExists(atPath: parcial.path) {
            try FileManager.default.removeItem(at: parcial)
        }

        if !FileManager.default.fileExists(atPath: parcial.path) {
            FileManager.default.createFile(atPath: parcial.path, contents: nil)
        }
        let escritor = try FileHandle(forWritingTo: parcial)
        try escritor.seekToEnd()
        defer { try? escritor.close() }

        var recebidos = inicio
        var buffer = Data()
        buffer.reserveCapacity(4 * 1_048_576)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4 * 1_048_576 {
                try escritor.write(contentsOf: buffer)
                recebidos += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                aoProgredir(ProgressoDownload(
                    peso: peso, bytesRecebidos: recebidos, bytesTotais: peso.bytes
                ))
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try escritor.write(contentsOf: buffer)
            recebidos += Int64(buffer.count)
        }
        try escritor.close()

        try Task.checkCancellation()
        do {
            try validar(parcial, peso: peso)
        } catch let erro as ErroDownload {
            // Corpo incompleto continua retomável; conteúdo completo corrompido não.
            if case .checksumInvalido = erro { try? FileManager.default.removeItem(at: parcial) }
            throw erro
        }

        try FileManager.default.moveItem(at: parcial, to: destino)
        aoProgredir(ProgressoDownload(
            peso: peso, bytesRecebidos: peso.bytes, bytesTotais: peso.bytes
        ))
        return destino
    }

    private func validar(_ url: URL, peso: PesoDeModelo) throws {
        let tamanho = Self.tamanhoEmDisco(url)
        guard tamanho == peso.bytes else {
            throw ErroDownload.tamanhoInvalido(esperado: peso.bytes, obtido: tamanho)
        }
        if !peso.sha256.isEmpty {
            let hash = try Preflight.sha256(de: url)
            guard hash == peso.sha256 else {
                throw ErroDownload.checksumInvalido(esperado: peso.sha256, obtido: hash)
            }
        }
    }

    static func intervaloValido(_ valor: String?, inicio: Int64, total: Int64) -> Bool {
        guard let valor, valor.hasPrefix("bytes ") else { return false }
        let partes = valor.dropFirst(6).split(separator: "/")
        guard partes.count == 2, Int64(partes[1]) == total else { return false }
        let limites = partes[0].split(separator: "-")
        guard limites.count == 2,
              let primeiro = Int64(limites[0]), let ultimo = Int64(limites[1])
        else { return false }
        return primeiro == inicio && ultimo >= primeiro && ultimo < total
    }

    /// Quanto já existe em disco de um peso ainda incompleto.
    public func bytesParciais(de peso: PesoDeModelo) -> Int64 {
        let parcial = pastaDeModelos
            .appendingPathComponent(peso.nomeArquivo)
            .appendingPathExtension("parcial")
        return Self.tamanhoEmDisco(parcial)
    }

    static func tamanhoEmDisco(_ url: URL) -> Int64 {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
              let tamanho = atributos[.size] as? Int64
        else { return 0 }
        return tamanho
    }
}
