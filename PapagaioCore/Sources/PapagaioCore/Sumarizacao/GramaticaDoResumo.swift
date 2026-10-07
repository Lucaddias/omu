import Foundation

/// Gramática GBNF que força o formato de `Resumo` na decodificação.
///
/// Por que gramática e não só instrução no prompt: o `llama.cpp` restringe o
/// espaço de tokens **a cada passo**, então a saída não pode sair do formato.
/// Pedir JSON no prompt e torcer é o que produz o JSON malformado que o
/// reprompt teria que consertar. Ver skill `papagaio-summarization`.
///
/// `@Generable`/`@Guide` não existem aqui — são exclusivos do `FoundationModels`
/// da Apple, que está fora da stack (D-0.5).
public enum GramaticaDoResumo {
    public static let gbnf = #"""
    root ::= "{" ws "\"titulo\":" ws string "," ws "\"visaoGeral\":" ws string "," ws "\"temas\":" ws temas "," ws "\"citacoes\":" ws citacoes "," ws "\"proximosPassos\":" ws passos ws "}"
    temas ::= "[" ws (tema (ws "," ws tema)*)? ws "]"
    tema ::= "{" ws "\"titulo\":" ws string "," ws "\"detalhe\":" ws string ws "}"
    citacoes ::= "[" ws (citacao (ws "," ws citacao)*)? ws "]"
    citacao ::= "{" ws "\"texto\":" ws string "," ws "\"speaker\":" ws opcional "," ws "\"start\":" ws numeroOuNulo ws "}"
    passos ::= "[" ws (passo (ws "," ws passo)*)? ws "]"
    passo ::= "{" ws "\"descricao\":" ws string "," ws "\"responsavel\":" ws opcional ws "}"
    opcional ::= string | "null"
    numeroOuNulo ::= numero | "null"
    string ::= "\"" char* "\"" ws
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    numero ::= "-"? [0-9]+ ("." [0-9]+)? ws
    ws ::= [ \t\n]*
    """#

    /// Descrição do formato para o prompt. A gramática garante a **sintaxe**;
    /// isto orienta o **conteúdo**.
    public static let descricaoDoFormato = """
    Responda SOMENTE com um objeto JSON com exatamente estas chaves:
    - "titulo": nome claro e direto do encontro, sem prefixos como "Ata:" (ex: "Revisão de Escopo do MVP")
    - "visaoGeral": resumo completo e detalhado da reunião em 4 a 6 frases. \
    Vá direto ao conteúdo discutido, sem mencionar data, hora nem listar participantes. \
    Seja direto e realista, sem termos corporativos vazios como "sinergia" ou "disrupção". \
    Não comprima: uma reunião de 1 hora merece um resumo proporcional ao conteúdo discutido.
    - "temas": lista de {"titulo", "detalhe"} com os assuntos discutidos. Para cada tema:
        - "titulo": assunto objetivo e curto
        - "detalhe": MÁXIMO 30 palavras. Uma frase curta com a conclusão ou decisão principal. \
    Sem repetir o que já está na visão geral. \
    NÃO use caracteres especiais como bullet points ou marcadores. Texto corrido simples.
    - "citacoes": no máximo 3 falas MARCANTES, copiadas LITERALMENTE da transcrição — \
    {"texto", "speaker", "start"}, com "start" em segundos. \
    Marcante é a fala que carrega ideia, conselho, decisão, conclusão, aprendizado ou \
    posicionamento, e que se entende sozinha, fora do contexto. \
    Não sirvem: saudação, confirmação curta, pergunta solta, repetição e transição de assunto. \
    Copie palavra por palavra, sem reescrever nem juntar frases distantes. Entre 8 e 32 palavras. \
    Prefira devolver menos, ou nenhuma, a inventar.
    - "proximosPassos": lista de {"descricao", "responsavel"} com TODOS os compromissos, \
    tarefas e ações mencionados. Identifique donos e prazos sempre que possível.
    Use "null" quando não souber o falante ou o responsável.
    """
}
