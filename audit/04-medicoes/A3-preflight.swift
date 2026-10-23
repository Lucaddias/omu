// A3 — Performance · preflight de medições (mecanismos reproduzidos fora do app)
//
// Roda:  swiftc -O audit/04-medicoes/A3-preflight.swift -o /tmp/a3preflight && /tmp/a3preflight
//
// Condições registradas em audit/04-medicoes/A3-preflight.md.
// Cada bloco reproduz o MECANISMO exato de um caminho quente (mesma API,
// mesmos parâmetros), com dados sintéticos de tamanho declarado. Os números
// são custo de mecanismo; a extrapolação para o app multiplica pelo nº de
// repetições provado no código (citado no achado).

import Foundation

// MARK: - utilidades

func mediana(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Executa `bloco` `reps` vezes e devolve a mediana em segundos (primeira
/// execução descartada como aquecimento).
func medir(reps: Int, aquecer: Bool = true, _ bloco: () -> Void) -> Double {
    if aquecer { bloco() }
    var amostras: [Double] = []
    for _ in 0..<reps {
        let t0 = DispatchTime.now().uptimeNanoseconds
        bloco()
        let t1 = DispatchTime.now().uptimeNanoseconds
        amostras.append(Double(t1 - t0) / 1e9)
    }
    return mediana(amostras)
}

func ms(_ s: Double) -> Double { s * 1000 }
func us(_ s: Double) -> Double { s * 1_000_000 }

var linhas: [String] = []
func reportar(_ nome: String, _ detalhe: String, _ tempo: Double) {
    let l = "\(nome.padding(toLength: 34, withPad: " ", startingAt: 0)) | " +
        "\(detalhe.padding(toLength: 58, withPad: " ", startingAt: 0)) | " +
        String(format: "%10.3f ms", ms(tempo))
    linhas.append(l)
    print(l)
}

// MARK: - geradores de dados

func frase(pt: Int = 12) -> String {
    let palavras = ["reunião", "orçamento", "cliente", "proposta", "prazo", "entrega",
                    "equipe", "retroalimentação", "prioridade", "decisão", "pendência",
                    "alinhamento", "contexto", "resultado", "análise", "verba", "contrato",
                    "implementação", "cronograma", "revisão", "apresentação", "dados"]
    return (0..<pt).map { _ in palavras.randomElement()! }.joined(separator: " ")
}

// MARK: - 1. Cura regex por palavra  (SwiftDataRepository.curarTextoDePalavraLegada,
//             chamada por paraDominio em CADA palavra de CADA trecho em CADA load)

let nPalavrasCura = 100_000
let palavrasCura: [String] = {
    var out: [String] = []
    out.reserveCapacity(nPalavrasCura)
    for _ in 0..<nPalavrasCura { out.append(frase(pt: 1)) } // ~1 palavra real, sem "["
    return out
}()

let tCura = medir(reps: 5) {
    for w in palavrasCura {
        _ = w.replacingOccurrences(of: #"\[_[^]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
// normaliza por palavra (o loop processou nPalavrasCura palavras por rep)
reportar("1. cura-regex por palavra", "\(nPalavrasCura) palavras/rep", tCura)
let curaPorPalavra = tCura / Double(nPalavrasCura)
print(String(format: "   → %.0f ns/palavra (regex+trim); caminho alternativo contains(\"[\") gate:",
             us(curaPorPalavra) * 1000))

let tCuraGate = medir(reps: 5) {
    for w in palavrasCura {
        if w.contains("[") {
            _ = w.replacingOccurrences(of: #"\[_[^]]*\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
print(String(format: "   → %.0f ns/palavra com gate contains(\"[\")  (ganho %.1fx)",
             us(tCuraGate / Double(nPalavrasCura)) * 1000,
             tCura / tCuraGate))

// extrapolações de carga de biblioteca (palavras totais = Σ trechos·palavras)
for cenario in [(nome: "50 conversas × 5k palavras", total: 250_000),
                (nome: "200 conversas × 9k palavras", total: 1_800_000),
                (nome: "500 conversas × 9k palavras", total: 4_500_000)] {
    print(String(format: "   → carregar() com %@: cura-regex ≈ %.2f s  (com gate ≈ %.2f s)",
                 cenario.nome,
                 curaPorPalavra * Double(cenario.total),
                 (tCuraGate / Double(nPalavrasCura)) * Double(cenario.total)))
}

// MARK: - 2. Decode de palavrasJSON por trecho (paraDominio, CADA load)

struct Palavra: Codable {
    let id: UUID
    let start: Double
    let end: Double
    let texto: String
    let confianca: Float?
    let noSpeechProb: Float?
    let falanteAcustico: String?
}

let jsonPalavras: Data = {
    let ps: [Palavra] = (0..<15_000).map { i in // ~1 h de fala (~15k palavras)
        Palavra(id: UUID(), start: Double(i) * 0.3, end: Double(i) * 0.3 + 0.28,
                texto: frase(pt: 1), confianca: 0.87, noSpeechProb: 0.02,
                falanteAcustico: i % 400 < 200 ? "S1" : "S2")
    }
    return try! JSONEncoder().encode(ps)
}()
print("\njson palavras (1 h de fala): \(jsonPalavras.count) bytes / 15.000 palavras")

let tDecode1h = medir(reps: 10) {
    _ = try! JSONDecoder().decode([Palavra].self, from: jsonPalavras)
}
reportar("2. decode palavrasJSON", "15k palavras (1 h de fala)", tDecode1h)
for cenario in [(nome: "50 conversas", n: 50), (nome: "200 conversas", n: 200),
                (nome: "500 conversas", n: 500)] {
    print(String(format: "   → paraDominio em %@: decodes ≈ %.2f s (fora da cura-regex item 1)",
                 cenario.nome, tDecode1h * Double(cenario.n)))
}

// MARK: - 3. Busca da biblioteca POR TECLA  (BibliotecaHomeView.arquivosFiltrados +
//             conversaCasaTermo: sort + filtro com varredura do corpus, SEM debounce)

func casaComBusca(_ texto: String, _ termo: String) -> Bool {
    texto.range(of: termo, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

struct ArquivoSintetico {
    let id: UUID
    let criadoEm: Date
    let titulo: String
    let resumo: String
    let trechos: [String]
}

let biblioteca: [ArquivoSintetico] = (0..<100).map { a in
    ArquivoSintetico(
        id: UUID(),
        criadoEm: Date(timeIntervalSinceNow: Double(-a) * 86_400),
        titulo: "Entrevista \(a) — projeto Horizonte",
        resumo: String(repeating: frase(pt: 30) + " ", count: 8), // ~2k chars
        trechos: (0..<300).map { _ in frase(pt: 18) }            // ~120 chars × 300
    )
}
let charsCorpus = biblioteca.reduce(0) { total, a in
    total + a.titulo.count + a.resumo.count + a.trechos.reduce(0) { $0 + $1.count }
}
print("\ncorpus: 100 arquivos × 300 trechos ≈ \(charsCorpus) chars de corpo")

let termoSemMatch = "orçamentoxyz"
let termoComMatchFinal = biblioteca[99].trechos[299].components(separatedBy: " ").last!

func filtrar(_ termo: String) -> [ArquivoSintetico] {
    let ordenados = biblioteca.sorted { $0.criadoEm > $1.criadoEm } // arquivosFiltrados:344
    guard !termo.isEmpty else { return ordenados }
    return ordenados.filter { a in // conversaCasaTermo (linhas 401-432)
        if casaComBusca(a.titulo, termo) || casaComBusca(a.resumo, termo) { return true }
        if a.trechos.contains(where: { casaComBusca($0, termo) }) { return true }
        return false
    }
}

let tBuscaSem = medir(reps: 7) { _ = filtrar(termoSemMatch) }
reportar("3. busca por tecla (sem match)", "sort 100 + varredura 3,6M chars", tBuscaSem)

let tBuscaCom = medir(reps: 7) { _ = filtrar(termoComMatchFinal) }
reportar("3b. busca por tecla (match no fim)", "pior caso: varredura total", tBuscaCom)

let tSoSort = medir(reps: 7) { _ = biblioteca.sorted { $0.criadoEm > $1.criadoEm } }
reportar("3c. só o sort por tecla", "100 arquivos", tSoSort)

// projeção por tecla: BibliotecaHomeView.body chama arquivosFiltrados ≥2× por
// avaliação (ForEach:1106 + isEmpty:1116) e o body roda a cada tecla.
print(String(format: "   → por tecla (2× chamadas + 1 body extra): ≈ %.1f ms já só no filtro",
             ms(tBuscaSem) * 2))

// MARK: - 4. ocorrenciasDaBusca (Cmd+F na transcrição, por tecla)
//     ArquivoDetalheView.swift:202-233 — varre TODAS as palavras com casaComBusca

let palavras1h: [String] = (0..<15_000).map { _ in frase(pt: 1) }
let tOcorrencias = medir(reps: 7) {
    var out = 0
    for p in palavras1h where casaComBusca(p, termoSemMatch) { out += 1 }
    _ = out
}
reportar("4. ocorrenciasDaBusca por tecla", "15k palavras, sem match", tOcorrencias)

// MARK: - 5. UserDefaults O(pastas × arquivos)  (informacoesDasPastas:482-490)
//     suite temporária — não toca os defaults do usuário; removida no fim.

let suite = UserDefaults(suiteName: "audit.a3.preflight")!
let nArq = 500
let nPastas = 50
let ids: [String] = (0..<nArq).map { _ in UUID().uuidString }
let pastas: [String] = (0..<nPastas).map { "Pasta \($0)" }
for (i, id) in ids.enumerated() { suite.set(pastas[i % nPastas], forKey: "arquivoPasta." + id) }

let tPastas = medir(reps: 7) {
    for pasta in pastas {
        var n = 0
        for id in ids {
            let chave = "arquivoPasta." + id
            if suite.string(forKey: chave) == pasta { n += 1 }
        }
        _ = n
    }
}
reportar("5. informacoesDasPastas (50×500)", "25k leituras+keys UserDefaults", tPastas)

let tUmaPasta = medir(reps: 7) {
    var n = 0
    for id in ids where suite.string(forKey: "arquivoPasta." + id) == pastas[0] { n += 1 }
    _ = n
}
reportar("5b. CabecalhoDaPastaAberta (500)", "500 leituras UserDefaults", tUmaPasta)

// MARK: - 6. Decode do mapa FalantePreservado (obter por LINHA por TICK)
//     FalantePreservadoParaTrecho.carregar: UserDefaults + JSONDecoder, SEM cache,
//     chamado 1+× por linha visível a cada tick de 100 ms durante a reprodução.

let mapaPreservado: [String: String] = {
    var m: [String: String] = [:]
    for i in 0..<3000 { m[UUID().uuidString] = "Nome \(i % 40)" }
    return m
}()
let jsonPreservado = try! JSONEncoder().encode(mapaPreservado)
let tPreservado = medir(reps: 200) {
    _ = try! JSONDecoder().decode([String: String].self, from: jsonPreservado)
}
reportar("6. decode mapa preservado", "3000 trechos nomeados (\(jsonPreservado.count) B)", tPreservado)
print(String(format: "   → 30 linhas visíveis × 10 Hz = 300 decodes/s ≈ %.1f%% de um core",
             (tPreservado * 300) * 100))

// MARK: - 7. metadados do cartão (UserDefaults + JSONDecoder por ACESSO)
//     PreferenciasVisuaisDoArquivo.metadados:186-191; ArquivoDetalheView.body
//     acessa ~5-8× por avaliação (linhas 146-192, 697...).

struct Metadados: Codable {
    var titulo = ""; var entrevistado = ""; var emailDoEntrevistado = ""
    var entrevistadores = [String](); var emailsDosEntrevistadores = [String]()
    var descricao = ""; var formato = ""; var participantes: Int? = nil
}
var md = Metadados()
md.entrevistado = "Maria da Silva"
md.entrevistadores = ["João Souza", "Ana Paula"]
md.descricao = String(repeating: frase(pt: 20) + " ", count: 3)
md.formato = "Podcast"
let jsonMD = try! JSONEncoder().encode(md)
suite.set(jsonMD, forKey: "arquivoMetadados." + ids[0])
let tMD = medir(reps: 10_000) {
    guard let d = suite.data(forKey: "arquivoMetadados." + ids[0]) else { return }
    _ = try? JSONDecoder().decode(Metadados.self, from: d)
}
reportar("7. metadados por acesso", "\(jsonMD.count) B UserDefaults+decode", tMD)

// MARK: - 8. Geração do dódulo Markdown NO BODY (DossieDaConversa.gerar
//     chamado por ArquivoDetalheView.swift:526 a cada avaliação de body)

let tDossie = medir(reps: 7) {
    var texto = ""
    for a in biblioteca {
        texto += "# \(a.titulo)\n\n\(a.resumo)\n\n"
        for t in a.trechos { texto += "- \(t)\n" }
    }
    _ = texto
}
reportar("8. gerar dossie no body", "100 arquivos × 300 trechos", tDossie)

// MARK: - 9. sort repetido de arquivos por body (TarefasView:49, MidiasView:31,
//     BibliotecaHomeView arquivosFiltrados — mesmo padrão)

struct Leve { let id: UUID; let data: Date }
let leve: [Leve] = (0..<2_000).map { Leve(id: UUID(), data: Date(timeIntervalSinceNow: Double($0))) }
let tSort2k = medir(reps: 50) { _ = leve.sorted { $0.data > $1.data } }
reportar("9. sort de 2k arquivos", "por avaliação de body", tSort2k)

// MARK: - limpeza

for id in ids { suite.removeObject(forKey: "arquivoPasta." + id) }
suite.removeObject(forKey: "arquivoMetadados." + ids[0])
suite.removePersistentDomain(forName: "audit.a3.preflight")

print("\nOK — suite temporária removida.")
