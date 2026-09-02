import Foundation

/// Iniciais para avatares de texto: as duas primeiras letras do nome.
///
/// O `vazio` é parâmetro porque cada chamador tem um símbolo próprio para
/// "não sei quem é" — "?" quando a tarefa está sem responsável, "M" quando é
/// um membro de equipe sem nome preenchido. Antes disso a função existia em
/// três cópias que só divergiam nessa letra.
enum Iniciais {
    static func de(_ nome: String, vazio: String = "?") -> String {
        let partes = nome.split(separator: " ")
        let letras = partes.prefix(2).compactMap(\.first)
        return letras.isEmpty ? vazio : String(letras).uppercased()
    }
}

// Manter compatibilidade com código antigo que chama a função global
@available(*, deprecated, message: "Use Iniciais.de(_:vazio:) em vez disso")
func iniciais(de nome: String, vazio: String = "?") -> String {
    Iniciais.de(nome, vazio: vazio)
}
