import Foundation

/// Conserta o cabeçalho de um WAV cuja gravação não foi fechada.
///
/// O `AVAudioRecorder` só escreve os tamanhos definitivos (`RIFF` e `data`)
/// ao parar. Se o app é encerrado à força ou trava no meio, o áudio está
/// inteiro no disco, mas o cabeçalho ainda diz "0 bytes" — e quem lê o arquivo
/// vê uma gravação vazia. Aqui os dois campos são reescritos com o tamanho
/// real, sem tocar nas amostras.
public enum ReparoDeWAV {
    /// - Returns: `true` se o arquivo foi alterado; `false` se já estava
    ///   coerente ou se não é um WAV reconhecível (nesse caso nada é escrito).
    @discardableResult
    public static func reparar(_ url: URL) throws -> Bool {
        let arquivo = try FileHandle(forUpdating: url)
        defer { try? arquivo.close() }

        let tamanho = try arquivo.seekToEnd()
        guard tamanho >= 12 else { return false }
        try arquivo.seek(toOffset: 0)
        guard let inicio = try arquivo.read(upToCount: 12), inicio.count == 12,
              String(decoding: inicio[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: inicio[8..<12], as: UTF8.self) == "WAVE"
        else { return false }

        // Percorre os blocos até o `data`. O gravador costuma pôr um bloco de
        // enchimento (`FLLR`) antes dele, então o áudio não começa no byte 44.
        var posicao: UInt64 = 12
        var blocoDeDados: (posicao: UInt64, declarado: UInt32)?
        while posicao + 8 <= tamanho {
            try arquivo.seek(toOffset: posicao)
            guard let cabecalho = try arquivo.read(upToCount: 8), cabecalho.count == 8 else { break }
            let nome = String(decoding: cabecalho[cabecalho.startIndex..<cabecalho.startIndex + 4], as: UTF8.self)
            let declarado = inteiro(cabecalho.suffix(4))
            if nome == "data" {
                blocoDeDados = (posicao, declarado)
                break
            }
            // Blocos têm tamanho par: um byte de preenchimento quando ímpar.
            posicao += 8 + UInt64(declarado) + UInt64(declarado & 1)
        }
        guard let blocoDeDados else { return false }

        let inicioDosDados = blocoDeDados.posicao + 8
        let real = tamanho - inicioDosDados
        let fimDeclarado = inicioDosDados + UInt64(blocoDeDados.declarado)
        var alterado = false

        // Só corrige o que está claramente errado: tamanho zero (cabeçalho
        // nunca finalizado) ou maior que o arquivo (escrita truncada). Um
        // `data` menor que o resto do arquivo pode ter blocos legítimos
        // depois dele, e esses ficam como estão.
        let dadosIncoerentes = (blocoDeDados.declarado == 0 && real > 0) || fimDeclarado > tamanho
        if dadosIncoerentes {
            try arquivo.seek(toOffset: blocoDeDados.posicao + 4)
            try arquivo.write(contentsOf: bytes(UInt32(clamping: real)))
            alterado = true
        }

        let riffEsperado = UInt32(clamping: tamanho - 8)
        if alterado || inteiro(inicio[4..<8]) == 0 {
            if inteiro(inicio[4..<8]) != riffEsperado {
                try arquivo.seek(toOffset: 4)
                try arquivo.write(contentsOf: bytes(riffEsperado))
                alterado = true
            }
        }
        if alterado { try arquivo.synchronize() }
        return alterado
    }

    private static func inteiro(_ dados: Data) -> UInt32 {
        dados.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func bytes(_ valor: UInt32) -> Data {
        Data([0, 8, 16, 24].map { UInt8((valor >> $0) & 0xFF) })
    }
}
