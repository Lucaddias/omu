import Foundation
import SwiftData

// Entidades de persistência. **Não são os tipos de domínio** — `Arquivo` e
// `Trecho` de `Dominio.swift` são structs `Sendable`, e é isso que atravessa
// `ArquivoRepository` (D-1.2). Aqui vivem as classes `@Model`, que são de
// referência e não são `Sendable`.
//
// Defaults e relações opcionais mantêm o schema tolerante à introdução de novos
// campos e facilitam a evolução da biblioteca local.

@Model
public final class EspacoPersistido {
    public var id: UUID = UUID()
    public var nome: String = ""
    public var criadoEm: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ArquivoPersistido.espaco)
    public var arquivos: [ArquivoPersistido]? = []

    public init(id: UUID = UUID(), nome: String = "") {
        self.id = id
        self.nome = nome
    }
}

@Model
public final class ArquivoPersistido {
    public var id: UUID = UUID()
    public var titulo: String = ""
    public var criadoEm: Date = Date()
    public var duracao: TimeInterval = 0

    /// **Caminho relativo ao container.** Nunca absoluto: o UUID do container
    /// muda entre instalações, e um caminho absoluto salvo hoje aponta para o
    /// nada amanhã.
    public var pastaRelativa: String = ""

    public var engineTranscricao: String?
    public var engineResumo: String?

    /// Soft delete da biblioteca individual. A data opcional preserva o
    /// registro e a pasta de áudio até a pessoa escolher apagar para sempre.
    /// É opcional para manter compatibilidade com registros locais já salvos.
    public var apagadoEm: Date?

    /// Identificador da reunião na fonte externa de origem (`granola:` + id).
    /// Opcional para manter a migração leve: arquivos locais não têm.
    public var idExterno: String?

    /// Só em arquivos importados: quando a pessoa trouxe o arquivo para
    /// dentro do app. `criadoEm`, nesse caso, guarda a data real da
    /// gravação (lida do arquivo em disco); esta guarda a data do gesto de
    /// importar. `nil` numa gravação feita pelo microfone, e também `nil`
    /// em qualquer registro salvo antes deste campo existir.
    public var importadoEm: Date?

    /// Se o usuário estava com fones de ouvido durante a gravação.
    /// `nil` para arquivos importados ou gravações anteriores à esta feature.
    public var usavaFones: Bool?

    /// O título foi escolhido pela pessoa (ou veio do calendário) e não deve
    /// ser trocado pelo título que o resumo inventar. Opcional para manter a
    /// migração leve: registros antigos ficam `nil` (título automático).
    public var tituloManual: Bool?

    /// Título e visão geral do resumo. O resto do `Resumo` vira `InsightPersistido`.
    ///
    /// **Não opcionais, com default.** Um `String?` obrigaria o predicado de
    /// busca a usar `?? ""`, que o CoreData traduz para um `TERNARY` e recusa
    /// com "unimplemented SQL generation for predicate". `temResumo` distingue
    /// "sem resumo" de "resumo vazio".
    public var temResumo: Bool = false
    public var resumoTitulo: String = ""
    public var resumoVisaoGeral: String = ""

    public var espaco: EspacoPersistido?

    @Relationship(deleteRule: .cascade, inverse: \TrechoPersistido.arquivo)
    public var trechos: [TrechoPersistido]? = []

    @Relationship(deleteRule: .cascade, inverse: \InsightPersistido.arquivo)
    public var insights: [InsightPersistido]? = []

    /// Anotações feitas durante a gravação. A relação é opcional e todos os
    /// campos de `NotaPersistida` têm defaults para continuar compatível com
    /// registros locais que ainda não continham notas.
    @Relationship(deleteRule: .cascade, inverse: \NotaPersistida.arquivo)
    public var notas: [NotaPersistida]? = []

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

@Model
public final class TrechoPersistido {
    public var id: UUID = UUID()
    public var start: TimeInterval = 0
    public var fim: TimeInterval = 0
    public var texto: String = ""
    /// `"eu"` | `"interlocutor"` | `nil` — vem do canal de origem.
    public var speaker: String?

    /// Palavras com timestamps codificadas como JSON (`[Palavra]`).
    ///
    /// `Data?` em vez de uma relação nova: mantém a migração leve (coluna
    /// opcional a mais) e o `nil` preserva transcrições legadas. O mapeamento
    /// para o domínio degrada para `[]`, que cai no `Text` inteiro na UI.
    public var palavrasJSON: Data?

    public var arquivo: ArquivoPersistido?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Um item acionável do resumo: tema, citação ou próximo passo.
///
/// O prompt mestre lista `Insight` como entidade própria. Modelar assim (em vez
/// de guardar o `Resumo` como um blob JSON) é o que permite a busca do Passo 9
/// encontrar um próximo passo pelo texto dele.
@Model
public final class InsightPersistido {
    public var id: UUID = UUID()
    /// `tema` | `citacao` | `proximoPasso`
    public var tipo: String = ""
    public var texto: String = ""
    public var detalhe: String?
    /// Âncora de tempo, quando houver — o player do Passo 10 salta para cá.
    public var start: TimeInterval?
    public var speaker: String?
    public var ordem: Int = 0

    public var arquivo: ArquivoPersistido?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Representação SwiftData de `NotaDaConversa`.
///
/// `ordem` desempata notas adicionadas no mesmo instante e preserva a ordem da
/// interface quando o arquivo é salvo novamente.
@Model
public final class NotaPersistida {
    public var id: UUID = UUID()
    public var texto: String = ""
    public var start: TimeInterval = 0
    public var critica: Bool = false
    /// Raw value de `TipoDeNotaDaConversa`.
    public var tipo: String = TipoDeNotaDaConversa.nota.rawValue
    public var ordem: Int = 0

    public var arquivo: ArquivoPersistido?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum TipoDeInsight {
    public static let tema = "tema"
    public static let citacao = "citacao"
    public static let proximoPasso = "proximoPasso"
}
