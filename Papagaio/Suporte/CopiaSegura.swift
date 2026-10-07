import Foundation

/// Copia um arquivo para um destino que pode já existir, sem destruir o que
/// está lá se a cópia falhar.
///
/// O caminho antigo era `removeItem` seguido de `copyItem`: se a cópia
/// falhasse no meio (disco cheio, volume desmontado), o arquivo que já
/// existia no destino tinha sido perdido. Aqui a cópia vai primeiro para o
/// diretório de substituição do sistema — o único lugar vizinho ao destino
/// em que um app em sandbox pode escrever — e só então troca de lugar.
enum CopiaSegura {
    static func copiar(_ origem: URL, substituindo destino: URL, fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: destino.path) else {
            try fm.copyItem(at: origem, to: destino)
            return
        }

        let pasta = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destino,
            create: true
        )
        defer { try? fm.removeItem(at: pasta) }
        let provisorio = pasta.appendingPathComponent(destino.lastPathComponent)
        try fm.copyItem(at: origem, to: provisorio)
        _ = try fm.replaceItemAt(destino, withItemAt: provisorio)
    }
}
