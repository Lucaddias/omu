import Foundation

/// Guarda, por equipe, até onde este Mac já leu as alterações da zona.
///
/// Com o marcador a baixa traz só o que mudou — sem ele cada troca de espaço
/// baixava de novo todas as conversas — e o servidor passa a relatar as
/// conversas apagadas, que numa leitura completa simplesmente não aparecem.
///
/// Perder este arquivo é inofensivo: a próxima baixa volta a ser completa.
actor MarcadoresDeSincronizacaoCloudKit {
    private struct Entrada: Codable {
        let equipeID: String
        /// Banco, dono e zona. Se a equipe passar a apontar para outro lugar,
        /// o marcador antigo deixa de valer.
        let referencia: String
        let marcador: Data
    }

    private let url: URL
    private let fm: FileManager
    private var carregadas: [Entrada]?

    init(url: URL, fm: FileManager = .default) {
        self.url = url
        self.fm = fm
    }

    func marcador(para equipe: EquipeDisponivel) -> Data? {
        entradas().first {
            $0.equipeID == equipe.id && $0.referencia == Self.referencia(de: equipe)
        }?.marcador
    }

    func guardar(_ marcador: Data?, para equipe: EquipeDisponivel) throws {
        var atuais = entradas()
        atuais.removeAll { $0.equipeID == equipe.id }
        if let marcador {
            atuais.append(
                Entrada(equipeID: equipe.id, referencia: Self.referencia(de: equipe), marcador: marcador)
            )
        }
        try salvar(atuais)
    }

    func descartar(daEquipeComID equipeID: String) throws {
        var atuais = entradas()
        guard atuais.contains(where: { $0.equipeID == equipeID }) else { return }
        atuais.removeAll { $0.equipeID == equipeID }
        try salvar(atuais)
    }

    private static func referencia(de equipe: EquipeDisponivel) -> String {
        [equipe.bancoCloudKit, equipe.donoDaZonaCloudKit, equipe.zonaCloudKit]
            .map { $0 ?? "" }
            .joined(separator: "\u{1F}")
    }

    private func entradas() -> [Entrada] {
        if let carregadas { return carregadas }
        let lidas = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([Entrada].self, from: $0) } ?? []
        carregadas = lidas
        return lidas
    }

    private func salvar(_ entradas: [Entrada]) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entradas).write(to: url, options: .atomic)
        carregadas = entradas
    }
}
