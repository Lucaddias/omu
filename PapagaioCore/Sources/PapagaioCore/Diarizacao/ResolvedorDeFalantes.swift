import Foundation

/// Resolve falas "Voz desconhecida" pelo **contexto da conversa**, com o
/// modelo de linguagem — o mesmo Qwen que resume.
///
/// O que o diarizador acústico não distingue, o texto às vezes distingue: um
/// trecho entre uma pergunta (Voz 1) e a resposta (Voz 2) quase sempre é a
/// resposta. O modelo decide entre as duas vozes confiáveis dos lados, ou
/// devolve "indeterminado" quando o contexto não dá evidência.
///
/// Não é uma segunda diarização: nada de estimar falante onde não há texto.
/// Só entra o que o `AlinhamentoDeFalantes` marcou como duvidoso (overlap
/// germinal, fronteira de turno, buraco cross-falante) — quem ficou sem
/// falante de propósito.
///
/// Regras:
/// - primeiro a **costura de vozes iguais** (`costurarVozesIguais`): fala sem
///   falante entre dois vizinhos confiáveis do MESMO falante recebe o rótulo
///   deles — não há voz concorrente na janela, custo zero, sem modelo;
/// - caso elegível = fala sem falante que sobrou, curta (≤
///   `maxPalavrasPorCaso`), com os dois vizinhos confiáveis de **falantes
///   diferentes**;
/// - chamadas em lotes de até `maxCasosPorChamada` (o `MotoresLocais`
///   repete a chamada para o resto) — janela pequena e barata, resposta
///   determinística;
/// - o modelo responde JSON restrito por gramática: só `"voz-1"`,
///   `"voz-2"` ou `"indeterminado"` por caso;
/// - resposta ambígua ou ausente → a fala continua sem falante (estado
///   honesto, nunca chute).
public enum ResolvedorDeFalantes {
    /// Fala duvidosa maior que isto não é caso: sem confiança contextual
    /// suficiente e sem limite de custo. Vale para a costura e para a
    /// resolução pelo modelo.
    public static let maxPalavrasPorCaso = 12

    /// Teto de casos numa chamada — contexto curto, resposta determinística.
    public static let maxCasosPorChamada = 12

    /// Janela de evidência de cada lado do caso, em palavras.
    public static let palavrasDeContexto = 40

    /// Um trecho duvidoso com os vizinhos confiáveis que o delimitam.
    public struct Caso: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let texto: String
        /// Rótulo acústico da fala confiável à esquerda (ex.: `"S1"`).
        public let falanteAnterior: String
        /// Rótulo acústico da fala confiável à direita.
        public let falanteSeguinte: String
        public let contextoAnterior: String
        public let contextoSeguinte: String

        public init(
            id: UUID,
            texto: String,
            falanteAnterior: String,
            falanteSeguinte: String,
            contextoAnterior: String,
            contextoSeguinte: String
        ) {
            self.id = id
            self.texto = texto
            self.falanteAnterior = falanteAnterior
            self.falanteSeguinte = falanteSeguinte
            self.contextoAnterior = contextoAnterior
            self.contextoSeguinte = contextoSeguinte
        }
    }

    // MARK: - Costura de vozes iguais

    /// Costura sem custo (sem modelo de linguagem): fala duvidosa entre dois
    /// vizinhos confiáveis do **mesmo** falante recebe o rótulo acústico deles.
    ///
    /// Não há voz concorrente na janela de evidência — o diarizador só marcou
    /// as fronteiras; entre dois pedaços da mesma voz, o turno foi dividido
    /// por pausa ou a palavra ficou na franja. Atribuir é a leitura acústica
    /// mais provável, e custa zero tokens. É o caso que o
    /// `casosElegiveis` deixava de fora: vizinhos de falantes diferentes eram
    /// a única ambiguidade que valia a chamada ao modelo.
    ///
    /// Limites iguais aos do caso: curta (≤ `maxPalavrasPorCaso`), com os dois
    /// lados confiáveis. O que sobra (vizinhos diferentes ou longa demais)
    /// segue para a resolução contextual (`casosElegiveis` + Qwen).
    public static func costurarVozesIguais(_ arquivo: Arquivo) -> Arquivo {
        guard let falas = FalasDaConversa.agrupar(arquivo.trechos) else { return arquivo }
        var rotulos: [UUID: String] = [:]
        for (indice, fala) in falas.enumerated() {
            guard fala.falanteAcustico == nil,
                  !fala.palavras.isEmpty,
                  fala.palavras.count <= maxPalavrasPorCaso,
                  let anterior = vizinhoConfiante(falas, aPartirDe: indice, passo: -1),
                  let seguinte = vizinhoConfiante(falas, aPartirDe: indice, passo: 1),
                  let falante = anterior.falanteAcustico,
                  falante == seguinte.falanteAcustico
            else { continue }
            rotulos[fala.id] = falante
        }
        guard !rotulos.isEmpty else { return arquivo }
        return aplicar(rotulos, em: arquivo)
    }

    // MARK: - Seleção

    /// Os casos resolvíveis da conversa, em ordem cronológica.
    ///
    /// - Precondition: `falas` na ordem de `FalasDaConversa.agrupar`.
    public static func casosElegiveis(falas: [FalaDeFalante]) -> [Caso] {
        var casos: [Caso] = []
        for (indice, fala) in falas.enumerated() {
            guard fala.falanteAcustico == nil,
                  !fala.palavras.isEmpty,
                  fala.palavras.count <= maxPalavrasPorCaso,
                  let anterior = vizinhoConfiante(falas, aPartirDe: indice, passo: -1),
                  let seguinte = vizinhoConfiante(falas, aPartirDe: indice, passo: 1),
                  let falanteAnterior = anterior.falanteAcustico,
                  let falanteSeguinte = seguinte.falanteAcustico,
                  falanteAnterior != falanteSeguinte
            else { continue }
            casos.append(Caso(
                id: fala.id,
                texto: fala.texto,
                falanteAnterior: falanteAnterior,
                falanteSeguinte: falanteSeguinte,
                contextoAnterior: contexto(de: anterior, ultimas: true),
                contextoSeguinte: contexto(de: seguinte, ultimas: false)
            ))
        }
        return casos
    }

    /// A fala confiável (com falante atribuído e palavras) mais próxima, no
    /// sentido pedido, pulando as falas sem falante.
    private static func vizinhoConfiante(
        _ falas: [FalaDeFalante],
        aPartirDe indice: Int,
        passo: Int
    ) -> FalaDeFalante? {
        var cursor = indice + passo
        while falas.indices.contains(cursor) {
            let fala = falas[cursor]
            if fala.falanteAcustico != nil, !fala.palavras.isEmpty {
                return fala
            }
            cursor += passo
        }
        return nil
    }

    /// As últimas (`ultimas: true`) ou primeiras palavras da fala, como
    /// janela de evidência do caso.
    private static func contexto(de fala: FalaDeFalante, ultimas: Bool) -> String {
        let palavras = ultimas
            ? Array(fala.palavras.suffix(palavrasDeContexto))
            : Array(fala.palavras.prefix(palavrasDeContexto))
        return palavras.map { $0.palavra.texto }.joined(separator: " ")
    }

    // MARK: - Prompt e gramática

    /// "Voz 1" no prompt é sempre a fala à esquerda; a resposta é mapeada de
    /// volta pela **posição** do caso (chave `"1"`, `"2"`, …), não pelo id.
    ///
    /// O id como chave era um erro na prática: a gramática aceita qualquer
    /// hexadecimal na chave, e o modelo eventualmente emitia um uuid que não
    /// correspondia ao caso — a resolução certa não encaixava e a fala ficava
    /// sem dono. Posição é à prova disso: a chave vem do `enumerated` e o
    /// `decodificar` casa pelo índice.
    public static func prompt(para casos: [Caso]) -> String {
        """
        <|im_start|>system
        Você decide quem disse trechos duvidosos de uma conversa que já tem \
        vozes separadas. As vozes confiáveis são rotuladas "Voz 1" e "Voz 2"; \
        o trecho entre [????] foi reconhecido como fala, mas o áudio não \
        permitiu distinguir quem disse. Use SÓ o contexto: quem pergunta \
        geralmente responde, quem retoma um assunto é quem o deixou, \
        confirmações curtas seguem quem acabou de falar. Não invente fala que \
        não está nos trechos.
        Responda SOMENTE com um objeto JSON: uma chave por caso — "1" para o \
        primeiro caso, "2" para o segundo, e assim por diante — e o valor \
        "voz-1", "voz-2" ou "indeterminado" (quando o contexto não permite \
        decidir).<|im_end|>
        <|im_start|>user
        \(casos.enumerated().map { indice, caso in caso.corpo(numero: indice + 1) }.joined(separator: "\n\n"))

        Responda somente o JSON.<|im_end|>
        <|im_start|>assistant
        """
    }

    /// GBNF que restringe a saída a chaves conhecidas e ao vocabulário de
    /// três valores — a sintaxe não pode sair do formato (mesma razão de
    /// `GramaticaDoResumo`).
    ///
    /// Chaves posicionais (`"1"`, `"2"`, …): cada uma é um literal curto entre
    /// aspas separadas — o formato que a amostragem desta versão do llama.cpp
    /// respeita (ver comentário histórico abaixo). Literais longos (36
    /// caracteres do uuid) desviavam a amostragem e a saída saía sem aspas.
    public static func gramatica(para casos: [Caso]) -> String {
        let pares = casos.enumerated().map { indice, _ in
            "\"\\\"\" \"\(indice + 1)\" \"\\\"\" ws \":\" ws valor"
        }.joined(separator: " ws \",\" ws ")
        return """
        root ::= "{" ws \(pares) ws "}"
        valor ::= "\\\"" "indeterminado" "\\\"" | "\\\"" "voz-1" "\\\"" | "\\\"" "voz-2" "\\\""
        ws ::= [ \\t\\n]{0,4}
        """
    }

    // MARK: - Aplicação

    /// Decodifica a resposta do modelo: chave posicional → `"voz-1"`/`"voz-2"`
    /// (só os resolvidos; o resto fica de fora). A chave `"1"` corresponde ao
    /// `casos[0]`, `"2"` ao `casos[1]`, e assim por diante.
    public static func decodificar(_ bruto: String, casos: [Caso]) -> [UUID: String] {
        guard let inicio = bruto.firstIndex(of: "{"),
              let fim = bruto.lastIndex(of: "}"), inicio < fim
        else { return [:] }
        let json = String(bruto[inicio...fim])
        guard let mapa = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        else { return [:] }

        var resolucoes: [UUID: String] = [:]
        for (indice, caso) in casos.enumerated() {
            let valor = mapa[String(indice + 1)] ?? ""
            if valor == "voz-1" || valor == "voz-2" {
                resolucoes[caso.id] = valor
            }
        }
        return resolucoes
    }

    /// Aplica rótulos às palavras do arquivo: `rotulosPorFala` mapeia a fala
    /// (o `id` da primeira palavra dela) ao rótulo acústico decidido. Nunca
    /// sobrescreve falante já atribuído — só entram falas duvidosas por
    /// construção.
    public static func aplicar(
        _ rotulosPorFala: [UUID: String],
        em arquivo: Arquivo
    ) -> Arquivo {
        guard !rotulosPorFala.isEmpty,
              let falas = FalasDaConversa.agrupar(arquivo.trechos)
        else { return arquivo }

        var rotuloPorAncora: [UUID: [Int: String]] = [:]
        for fala in falas where rotulosPorFala[fala.id] != nil {
            for palavra in fala.palavras {
                rotuloPorAncora[palavra.trechoId, default: [:]][palavra.indiceNoTrecho] =
                    rotulosPorFala[fala.id]
            }
        }

        let trechos = arquivo.trechos.map { trecho -> Trecho in
            guard let rotulos = rotuloPorAncora[trecho.id], !rotulos.isEmpty else { return trecho }
            return trecho.comPalavras(
                trecho.palavras.enumerated().map { indice, palavra -> Palavra in
                    guard let rotulo = rotulos[indice] else { return palavra }
                    return Palavra(
                        id: palavra.id,
                        start: palavra.start,
                        end: palavra.end,
                        texto: palavra.texto,
                        confianca: palavra.confianca,
                        noSpeechProb: palavra.noSpeechProb,
                        falanteAcustico: rotulo
                    )
                }
            )
        }

        return Arquivo(
            id: arquivo.id,
            titulo: arquivo.titulo,
            criadoEm: arquivo.criadoEm,
            duracao: arquivo.duracao,
            pastaRelativa: arquivo.pastaRelativa,
            espaco: arquivo.espaco,
            trechos: trechos,
            notas: arquivo.notas,
            resumo: arquivo.resumo,
            engineTranscricao: arquivo.engineTranscricao,
            engineResumo: arquivo.engineResumo,
            apagadoEm: arquivo.apagadoEm,
            idExterno: arquivo.idExterno,
            importadoEm: arquivo.importadoEm,
            usavaFones: arquivo.usavaFones
        )
    }

    /// Aplica as resoluções do modelo às palavras do arquivo: cada fala
    /// resolvida ganha o rótulo acústico do vizinho indicado.
    public static func aplicar(
        _ resolucoes: [UUID: String],
        casos: [Caso],
        em arquivo: Arquivo
    ) -> Arquivo {
        guard !resolucoes.isEmpty, !casos.isEmpty else { return arquivo }
        let rotulosPorFala: [UUID: String] = casos.reduce(into: [:]) { mapa, caso in
            guard let resposta = resolucoes[caso.id] else { return }
            mapa[caso.id] = resposta == "voz-1" ? caso.falanteAnterior : caso.falanteSeguinte
        }
        guard !rotulosPorFala.isEmpty else { return arquivo }
        return aplicar(rotulosPorFala, em: arquivo)
    }
}

private extension ResolvedorDeFalantes.Caso {
    /// O caso em texto para o prompt: vizinhos delimitando o trecho, com o
    /// número que servirá de chave na resposta (`CASO 1` → `"1"`).
    func corpo(numero: Int) -> String {
        """
        CASO \(numero)
        Voz 1: "\(contextoAnterior)"
        [????]: "\(texto)"
        Voz 2: "\(contextoSeguinte)"
        """
    }
}
