import Foundation

/// Traduz o rótulo bruto do diarizador ("S1", "S2"...) para o que aparece na
/// tela: o nome que a pessoa escolheu (ver
/// `PreferenciasVisuaisDoArquivo.nomesDeVoz`), ou, sem nome ainda, o rótulo
/// padrão "Voz N".
///
/// Com o namespacing por canal, os labels podem ter prefixo ("eu-S1",
/// "interlocutor-S2"). A exibição extrai só a parte numérica para gerar
/// "Voz N", mantendo a separação interna por canal.
///
/// Antes esta tradução vivia duplicada em `LinhaDeFala` e
/// `LinhaDeTranscricao` — cada uma com sua própria cópia da mesma função.
/// Unificada aqui para as duas (e o editor "Quem é quem", acima da
/// transcrição) nunca discordarem sobre como uma voz deveria se chamar.
enum RotuloDeVoz {
    /// Extrai o label acústico puro (sem prefixo de canal) para uso
    /// interno. "eu-S1" → "S1", "interlocutor-S2" → "S2", "S1" → "S1".
    static func labelPuro(_ falanteAcustico: String) -> String {
        if let ultimoHifen = falanteAcustico.lastIndex(of: "-") {
            let depois = falanteAcustico[falanteAcustico.index(after: ultimoHifen)...]
            return String(depois)
        }
        return falanteAcustico
    }

    /// "S1" → "Falante 1" / "Speaker 1". Nunca um nome de pessoa — é só o que aparece antes de
    /// alguém dar um nome de verdade à voz.
    static func padrao(_ falanteAcustico: String) -> String {
        let puro = labelPuro(falanteAcustico)
        if puro.hasPrefix("S"), let numero = Int(puro.dropFirst()) {
            return "Falante %@".localized("\(numero)")
        }
        return "Falante %@".localized(puro)
    }

    /// O nome escolhido para esta voz, ou o rótulo padrão quando ainda não
    /// foi renomeada (mapa vazio, ausente, ou só espaços em branco).
    static func exibicao(_ falanteAcustico: String, nomes: [String: String]) -> String {
        if let nome = nomes[falanteAcustico]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nome.isEmpty {
            return nome
        }
        return padrao(falanteAcustico)
    }
}
