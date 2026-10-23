import Foundation

/// Formato mínimo para transportar traduções em lote sem depender de texto
/// livre do modelo. A gramática fixa a quantidade; QwenEngine rejeita textos vazios.
enum GramaticaDaTraducao {
    static func gbnf(quantidade: Int) -> String {
        precondition(quantidade > 0)
        let itens = Array(repeating: "string", count: quantidade)
            .joined(separator: #" ws "," ws "#)
        return #"""
        root ::= "{" ws "\"traducoes\":" ws "[" ws \#(itens) ws "]" ws "}"
        string ::= "\"" char* "\""
        char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" hex hex hex hex)
        hex ::= [0-9a-fA-F]
        ws ::= [ \t\n]*
        """#
    }
}
