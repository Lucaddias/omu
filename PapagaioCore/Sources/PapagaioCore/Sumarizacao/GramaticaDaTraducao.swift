import Foundation

/// Formato mínimo para transportar traduções em lote sem depender de texto
/// livre do modelo. A contagem e a ordem ainda são validadas por `QwenEngine`.
enum GramaticaDaTraducao {
    static let gbnf = #"""
    root ::= "{" ws "\"traducoes\":" ws traducoes ws "}"
    traducoes ::= "[" ws (string (ws "," ws string)*)? ws "]"
    string ::= "\"" chars "\""
    chars ::= char*
    char ::= [^"\\] | "\\" escape
    escape ::= ["\\/bfnrt] | "u" hex hex hex hex
    hex ::= [0-9a-fA-F]
    ws ::= [ \t\n\r]*
    """#
}
