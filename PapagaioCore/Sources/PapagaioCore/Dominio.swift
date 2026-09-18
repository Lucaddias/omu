import Foundation

// MARK: - Identificadores

public struct ArquivoID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct EspacoID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }

    /// Fallback fixo para registro legado sem a relação de espaço. Não pode
    /// ser um `UUID()` novo a cada leitura: o mesmo arquivo trocaria de espaço
    /// toda vez que fosse relido do banco.
    public static let legado = EspacoID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    )
}

// MARK: - Palavra

/// Uma palavra da transcrição com âncora de tempo **própria**.
///
/// `start`/`end` vêm do `token_timestamps` do Whisper — nunca são uma divisão
/// do tempo do trecho — e são medidos em segundos desde o início do áudio,
/// como `Trecho.start`.
public struct Palavra: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let texto: String
    /// Probabilidade de confiança da palavra (0..1), derivada de `whisper_token_data.p`.
    /// `nil` para transcrições legadas ou palavras editadas manualmente.
    public let confianca: Float?
    /// Probabilidade de `no_speech` do segmento que originou a palavra, se aplicável.
    public let noSpeechProb: Float?

    /// Falante atribuído pela **diarização acústica** (ex.: `"S1"`, `"S2"`).
    ///
    /// Não confundir com `Trecho.speaker`, que vem do canal de origem — ver a
    /// regra em `SegmentoDeFalante`. `nil` = sem diarização (transcrição
    /// legada, falante desconhecido no empate técnico, ou modelos ausentes).
    public let falanteAcustico: String?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        texto: String,
        confianca: Float? = nil,
        noSpeechProb: Float? = nil,
        falanteAcustico: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.texto = texto
        self.confianca = confianca
        self.noSpeechProb = noSpeechProb
        self.falanteAcustico = falanteAcustico
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, texto, confianca, noSpeechProb, falanteAcustico
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        texto = try c.decode(String.self, forKey: .texto)
        confianca = try c.decodeIfPresent(Float.self, forKey: .confianca)
        noSpeechProb = try c.decodeIfPresent(Float.self, forKey: .noSpeechProb)
        falanteAcustico = try c.decodeIfPresent(String.self, forKey: .falanteAcustico)
    }
}

// MARK: - Segmento de falante

/// Um intervalo de fala atribuído a um falante pela diarização acústica.
///
/// `falanteId` usa a convenção do FluidAudio (`"S1"`, `"S2"`, …): serve para
/// **comparar** falantes dentro da mesma gravação, não é um rótulo estável.
///
/// Regra dos dois rótulos (skill `papagaio-speaker-attribution`): `Trecho.speaker`
/// continua sendo o canal de origem ("eu"/"interlocutor") e nunca é fundido com
/// o falante acústico — um microfone pode conter duas vozes ("S1"/"S2"), e o
/// mesmo "S1" pode aparecer no microfone e no tap do sistema.
public struct SegmentoDeFalante: Sendable, Equatable {
    public let falanteId: String
    public let inicio: TimeInterval
    public let fim: TimeInterval

    public init(falanteId: String, inicio: TimeInterval, fim: TimeInterval) {
        self.falanteId = falanteId
        self.inicio = inicio
        self.fim = fim
    }
}

// MARK: - Trecho

/// Unidade navegável da transcrição. `start` é a chave da navegação do player
/// (Passo 10) — não é índice, é tempo em segundos desde o início do áudio.
///
/// Contrato definido no Passo 1 do prompt mestre. Não altere sem justificar.
public struct Trecho: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let texto: String

    /// `"eu"` | `"interlocutor"` | `nil`.
    ///
    /// Vem do **canal de origem** da captura (microfone vs. tap do sistema),
    /// não de um modelo de diarização — ver skill `papagaio-speaker-attribution`.
    /// Use as constantes de `Speaker` em vez de literais soltos.
    public let speaker: String?

    /// Palavras com timestamps próprios do Whisper, na ordem da fala.
    ///
    /// Vazio para transcrições legadas — a interface volta ao `Text` inteiro.
    public let palavras: [Palavra]

    /// Confiança média do trecho (0..1), agregada das palavras por duração.
    /// `nil` quando nenhuma palavra tem confiança (legado/editado).
    public let confianca: Float?
    /// Probabilidade de não-fala do segmento Whisper que originou o trecho.
    public let noSpeechProb: Float?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        texto: String,
        speaker: String? = nil,
        palavras: [Palavra] = [],
        confianca: Float? = nil,
        noSpeechProb: Float? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.texto = texto
        self.speaker = speaker
        self.palavras = palavras
        self.confianca = confianca
        self.noSpeechProb = noSpeechProb
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, texto, speaker, palavras, confianca, noSpeechProb
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Self.CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        texto = try c.decode(String.self, forKey: .texto)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        palavras = try c.decodeIfPresent([Palavra].self, forKey: .palavras) ?? []
        confianca = try c.decodeIfPresent(Float.self, forKey: .confianca)
        noSpeechProb = try c.decodeIfPresent(Float.self, forKey: .noSpeechProb)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Self.CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(texto, forKey: .texto)
        try c.encodeIfPresent(speaker, forKey: .speaker)
        try c.encode(palavras, forKey: .palavras)
        try c.encodeIfPresent(confianca, forKey: .confianca)
        try c.encodeIfPresent(noSpeechProb, forKey: .noSpeechProb)
    }

    public var duracao: TimeInterval { end - start }

    /// Cópia com o texto corrigido à mão.
    ///
    /// `palavras` é zerado de propósito: os timestamps por palavra vêm do
    /// Whisper e deixam de corresponder ao texto assim que alguém edita. Sem
    /// palavras, a interface volta ao destaque por trecho inteiro — que é o
    /// mesmo caminho das transcrições legadas. Manter timestamps velhos
    /// destacaria a palavra errada, e errado é pior que grosso.
    public func comTextoEditado(_ novoTexto: String) -> Trecho {
        Trecho(
            id: id,
            start: start,
            end: end,
            texto: novoTexto,
            speaker: speaker,
            palavras: []
        )
    }

    /// Cópia com outras palavras — usada pela diarização para trocar as
    /// palavras do trecho pelas versões com `falanteAcustico`.
    public func comPalavras(_ novas: [Palavra]) -> Trecho {
        Trecho(
            id: id,
            start: start,
            end: end,
            texto: texto,
            speaker: speaker,
            palavras: novas,
            confianca: confianca,
            noSpeechProb: noSpeechProb
        )
    }

    /// Confiança média ponderada por duração da palavra
    static func confiancaMedia(_ palavras: [Palavra]) -> Float? {
        let valid = palavras.compactMap { p -> (Float, TimeInterval)? in
            guard let c = p.confianca else { return nil }
            let d = max(0, p.end - p.start)
            return (c, d)
        }
        guard !valid.isEmpty else { return nil }
        let totalDur = valid.map(\.1).reduce(0, +)
        if totalDur > 0 {
            let sum = valid.reduce(Float(0)) { $0 + $1.0 * Float($1.1) }
            return sum / Float(totalDur)
        }
        return valid.map(\.0).reduce(0, +) / Float(valid.count)
    }

    /// O rótulo acústico predominante nas palavras do trecho, ou `nil` sem
    /// diarização.
    ///
    /// Derivado, nunca persistido: o fonte da verdade são os
    /// `Palavra.falanteAcustico`. A UI usa isto para nomear o trecho quando o
    /// canal tem mais de um falante.
    public var falanteAcusticoDominante: String? {
        let contagens = palavras.reduce(into: [String: Int]()) { contagens, palavra in
            if let falante = palavra.falanteAcustico {
                contagens[falante, default: 0] += 1
            }
        }
        return contagens.max { $0.value < $1.value }?.key
    }

    /// Se o trecho comprova mais de uma voz acústica — o caso em que a UI
    /// mostra a voz predominante para distinguir os falantes do trecho.
    public var temVozesDistintas: Bool {
        Set(palavras.compactMap(\.falanteAcustico)).count > 1
    }
}

/// Os dois únicos valores válidos de `Trecho.speaker`.
///
/// O contrato mantém `speaker` como `String?` (é o que o prompt mestre define);
/// isto existe para evitar literais divergentes espalhados pelo código.
public enum Speaker {
    public static let eu = "eu"
    public static let interlocutor = "interlocutor"
}

// MARK: - Notas da conversa

/// O tipo visual de uma anotação feita durante a gravação.
///
/// O marcador registra um instante importante mesmo quando não há texto; a
/// criticidade é uma propriedade separada de `NotaDaConversa`, pois tanto uma
/// nota quanto um marcador podem ser críticos.
public enum TipoDeNotaDaConversa: String, Sendable, Codable, CaseIterable {
    case nota
    case marcador
}

/// Uma anotação criada enquanto a conversa ainda está sendo gravada.
///
/// `start` é medido em segundos a partir do início do áudio e pode ser
/// ajustado para a duração final real quando a sessão é encerrada. Não é uma
/// posição textual da transcrição: deve continuar apontando para o áudio mesmo
/// antes de a transcrição terminar.
public struct NotaDaConversa: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var texto: String
    public var start: TimeInterval
    public var critica: Bool
    public var tipo: TipoDeNotaDaConversa

    public init(
        id: UUID = UUID(),
        texto: String,
        start: TimeInterval,
        critica: Bool = false,
        tipo: TipoDeNotaDaConversa = .nota
    ) {
        self.id = id
        self.texto = texto
        self.start = start
        self.critica = critica
        self.tipo = tipo
    }
}

// MARK: - Resumo

/// Saída estruturada da sumarização. O formato é forçado na decodificação por
/// gramática GBNF + JSON schema no Passo 7 — ver skill `papagaio-summarization`.
public struct Resumo: Sendable, Codable, Equatable {
    public let titulo: String
    public let visaoGeral: String
    public let temas: [Tema]
    public let citacoes: [Citacao]
    public let proximosPassos: [ProximoPasso]

    public init(
        titulo: String,
        visaoGeral: String,
        temas: [Tema] = [],
        citacoes: [Citacao] = [],
        proximosPassos: [ProximoPasso] = []
    ) {
        self.titulo = titulo.removendoPrefixoAta()
        self.visaoGeral = visaoGeral
        self.temas = temas
        self.citacoes = citacoes
        self.proximosPassos = proximosPassos
    }

    enum CodingKeys: String, CodingKey {
        case titulo, visaoGeral, temas, citacoes, proximosPassos
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .titulo)
        titulo = raw.removendoPrefixoAta()
        visaoGeral = try c.decode(String.self, forKey: .visaoGeral)
        temas = try c.decodeIfPresent([Tema].self, forKey: .temas) ?? []
        citacoes = try c.decodeIfPresent([Citacao].self, forKey: .citacoes) ?? []
        proximosPassos = try c.decodeIfPresent([ProximoPasso].self, forKey: .proximosPassos) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(titulo, forKey: .titulo)
        try c.encode(visaoGeral, forKey: .visaoGeral)
        try c.encode(temas, forKey: .temas)
        try c.encode(citacoes, forKey: .citacoes)
        try c.encode(proximosPassos, forKey: .proximosPassos)
    }
}

extension String {
    /// Remove prefixo "Ata:" / "Ata -" / "Ata da Reunião:" gerado pelo modelo.
    func removendoPrefixoAta() -> String {
        let pattern = #"(?i)^\s*ata(\s+da\s+reuni[ãa]o)?\s*[:\-–—]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.range.location == 0,
              let r = Range(m.range, in: self)
        else { return self }
        let resto = String(self[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return resto.isEmpty ? self : resto
    }

    /// Remove caracteres de emoji preservando texto legível.
    ///
    /// O Whisper às vezes gera emojis (💕, 😊, 🎵) como texto quando processa
    /// silêncio ou ruído de fundo. Esta função remove sem perder o resto.
    func removendoEmojis() -> String {
        String(filter { !$0.ehEmoji })
    }

    /// `true` quando o texto é composto exclusivamente por emojis (sem letras,
    /// números ou pontuação visível).
    var ehSomenteEmoji: Bool {
        removendoEmojis().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension Character {
    /// `true` quando o caractere é um emoji Unicode.
    ///
    /// Verifica as escalares do caractere: se qualquer uma cai num range
    /// conhecido de emoji, o caractere inteiro é emoji. Funciona para emojis
    /// simples (😊) e compostos (👨‍👩‍👧, que usa zero-width joiners).
    var ehEmoji: Bool {
        for scalar in unicodeScalars {
            let block = scalar.value
            if (0x1F600...0x1F64F).contains(block) ||   // Emoticons
               (0x1F300...0x1F5FF).contains(block) ||   // Símbolos e pictogramas
               (0x1F680...0x1F6FF).contains(block) ||   // Transporte e mapas
               (0x1F1E0...0x1F1FF).contains(block) ||   // Bandeiras
               (0x1F900...0x1F9FF).contains(block) ||   // Supplemental symbols
               (0x1FA00...0x1FA6F).contains(block) ||   // Chess symbols
               (0x1FA70...0x1FAFF).contains(block) ||   // Symbols and pictographs ext-A
               (0x2600...0x26FF).contains(block) ||     // Misc symbols
               (0x2700...0x27BF).contains(block) ||     // Dingbats
               (0xFE00...0xFE0F).contains(block) ||     // Variation selectors
               block == 0x200D ||                        // Zero-width joiner
               block == 0x20E3 ||                        // Combining enclosing keycap
               (0xE0020...0xE007F).contains(block)      // Tags
            {
                return true
            }
        }
        return false
    }
}

public struct Tema: Sendable, Codable, Equatable {
    public let titulo: String
    public let detalhe: String
    public init(titulo: String, detalhe: String) {
        self.titulo = titulo
        self.detalhe = detalhe
    }
}

public struct Citacao: Sendable, Codable, Equatable {
    public let texto: String
    public let speaker: String?
    /// Âncora de tempo para o player saltar até a origem da citação.
    public let start: TimeInterval?
    public init(texto: String, speaker: String? = nil, start: TimeInterval? = nil) {
        self.texto = texto
        self.speaker = speaker
        self.start = start
    }
}

public struct ProximoPasso: Sendable, Codable, Equatable {
    public let descricao: String
    public let responsavel: String?
    public init(descricao: String, responsavel: String? = nil) {
        self.descricao = descricao
        self.responsavel = responsavel
    }
}

// MARK: - Arquivo

/// Uma gravação com sua transcrição e seu resumo.
///
/// É um **struct de domínio**, não a entidade de persistência. O `@Model` do
/// SwiftData entra no Passo 8 como detalhe do `SwiftDataRepository` e é mapeado
/// para cá — ver D-1.2 em `DECISIONS.md`. Um `@Model` é classe e não é
/// `Sendable`; se ele atravessasse o protocolo, `ArquivoRepository: Sendable`
/// seria mentira.
public struct Arquivo: Sendable, Identifiable, Codable, Equatable {
    public let id: ArquivoID
    public var titulo: String
    public var criadoEm: Date
    public var duracao: TimeInterval
    /// Caminho **relativo** ao container do app. Nunca absoluto — ver Passo 8.
    public var pastaRelativa: String
    public var espaco: EspacoID
    public var trechos: [Trecho]
    /// Anotações e marcadores criados durante a gravação, ancorados no áudio.
    public var notas: [NotaDaConversa]
    public var resumo: Resumo?
    /// Identificadores das engines que produziram este arquivo, para os
    /// metadados exigidos nos Passos 4 e 7.
    public var engineTranscricao: String?
    public var engineResumo: String?
    /// `nil` enquanto aparece em Todos os arquivos. Quando preenchido, o
    /// registro está na lixeira: seus dados e áudio ainda existem e podem ser
    /// restaurados antes da exclusão definitiva.
    public var apagadoEm: Date?
    /// Só em arquivos importados: o momento em que a pessoa trouxe o arquivo
    /// para dentro do app — distinto de `criadoEm`, que numa importação passa
    /// a valer a data real da gravação (lida do próprio arquivo em disco,
    /// quando disponível), e não o instante da importação.
    ///
    /// `nil` numa gravação feita pelo microfone: ali as duas datas são a
    /// mesma coisa, e um segundo campo só repetiria `criadoEm`.
    public var importadoEm: Date?

    /// Se o usuário estava com fones de ouvido (ou Bluetooth) durante a
    /// gravação. Quando `true`, o áudio do sistema não vaza para o microfone
    /// e o cancelamento de eco não é necessário. `nil` para arquivos
    /// importados ou gravações anteriores à esta feature.
    public var usavaFones: Bool?

    /// O critério certo para ordenar "mais recente primeiro" na biblioteca.
    ///
    /// Não é `criadoEm`: numa importação, `criadoEm` passou a valer a data
    /// real da gravação, que pode ser dias ou meses no passado — ordenar por
    /// ela jogava um arquivo recém-importado para o meio da grade, longe de
    /// onde a pessoa acabou de agir. Esta é a data do **gesto** (gravar ou
    /// importar), que é o que "recente" quer dizer numa lista de atividade.
    public var entradaNaBiblioteca: Date { importadoEm ?? criadoEm }

    /// Identificador da reunião na fonte externa de onde o arquivo veio
    /// (ex.: `"granola:2bf21a40"`). `nil` para gravações e importações de
    /// áudio. É a âncora de idempotência da importação: sem ele a mesma
    /// reunião seria duplicada a cada "importar".
    public let idExterno: String?

    /// Verdadeiro para reuniões importadas de fontes externas (Granola etc.),
    /// que não têm áudio: `pastaRelativa` vazia é a marca — não existe pasta
    /// de mídia no container. O player some da UI e a transcrição vira só
    /// leitura, sem destaque por palavra.
    public var semAudio: Bool { pastaRelativa.isEmpty }

    public init(
        id: ArquivoID = ArquivoID(),
        titulo: String,
        criadoEm: Date = Date(),
        duracao: TimeInterval = 0,
        pastaRelativa: String,
        espaco: EspacoID,
        trechos: [Trecho] = [],
        notas: [NotaDaConversa] = [],
        resumo: Resumo? = nil,
        engineTranscricao: String? = nil,
        engineResumo: String? = nil,
        apagadoEm: Date? = nil,
        idExterno: String? = nil,
        importadoEm: Date? = nil,
        usavaFones: Bool? = nil
    ) {
        self.id = id
        self.titulo = titulo
        self.criadoEm = criadoEm
        self.duracao = duracao
        self.pastaRelativa = pastaRelativa
        self.espaco = espaco
        self.trechos = trechos
        self.notas = notas
        self.resumo = resumo
        self.engineTranscricao = engineTranscricao
        self.engineResumo = engineResumo
        self.apagadoEm = apagadoEm
        self.idExterno = idExterno
        self.importadoEm = importadoEm
        self.usavaFones = usavaFones
    }
}
