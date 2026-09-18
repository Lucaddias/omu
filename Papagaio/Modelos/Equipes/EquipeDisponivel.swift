import Foundation

enum VisibilidadeDosArquivosDaEquipe: String, CaseIterable, Codable, Identifiable, Sendable {
    case todosOsMembros = "Todos os membros"
    case apenasAdministrador = "Somente administradores"

    var id: Self { self }
    var titulo: String {
        switch self {
        case .todosOsMembros: "Todos os membros".localized
        case .apenasAdministrador: "Somente administradores".localized
        }
    }
}

enum RecebimentoDeArquivosDaEquipe: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatico = "Entrar automaticamente"
    case aguardarRevisao = "Aguardar revisão"

    var id: Self { self }
    var titulo: String {
        switch self {
        case .automatico: "Entrar automaticamente".localized
        case .aguardarRevisao: "Aguardar revisão".localized
        }
    }
}

struct ConfiguracoesDaEquipe: Codable, Hashable, Sendable {
    var visibilidadeDosArquivos: VisibilidadeDosArquivosDaEquipe = .todosOsMembros
    var recebimentoDeArquivos: RecebimentoDeArquivosDaEquipe = .automatico
}

/// Uma equipe do usuário.
///
/// Não existe equipe padrão: um app recém-instalado não tem equipe nenhuma até
/// que a pessoa crie a primeira. Por isso todo consumidor trata `EquipeDisponivel?`
/// em vez de assumir que sempre há uma ativa.
struct EquipeDisponivel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let nome: String
    let papel: String
    var quantidadeDeMembros: Int

    /// Referência do workspace compartilhado. Equipes criadas antes do
    /// CloudKit continuam locais até serem publicadas explicitamente.
    var espacoID: String?
    var zonaCloudKit: String?
    /// A zona compartilhada pertence à Apple Account do criador. O nome não
    /// basta para reconstruir seu `CKRecordZone.ID` no banco compartilhado de
    /// outro participante.
    var donoDaZonaCloudKit: String?
    var compartilhamentoCloudKit: String?
    var bancoCloudKit: String?
    /// Código curto compartilhado que libera a entrada na equipe. Quem o
    /// possuir recebe acesso à zona compartilhada na Apple Account atual.
    var codigoDeEntrada: String?
    var configuracoes: ConfiguracoesDaEquipe

    /// Somente equipes do proprietário que já existiam antes do fluxo atual
    /// precisam reconfigurar o compartilhamento. Equipes novas também usam o
    /// banco privado do proprietário, mas já nascem com código publicado.
    var precisaReconfigurarEntradaPorCodigo: Bool {
        bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue
            && codigoDeEntrada == nil
    }

    /// `0` não significa que a equipe esteja vazia. Ele é usado pelas versões
    /// que ainda não conseguiram ler os participantes do `CKShare`; exibir
    /// "0 membros" nesse caso fazia parecer que o proprietário tinha sumido.
    var resumoDeMembros: String {
        guard quantidadeDeMembros > 0 else {
            return "participantes ainda não carregados".localized
        }
        return quantidadeDeMembros == 1
            ? "1 membro".localized
            : "%d membros".localized(quantidadeDeMembros)
    }

    private enum CodingKeys: String, CodingKey {
        case id, nome, papel, quantidadeDeMembros
        case espacoID, zonaCloudKit, donoDaZonaCloudKit, compartilhamentoCloudKit, bancoCloudKit
        case codigoDeEntrada, configuracoes
    }

    init(
        id: String,
        nome: String,
        papel: String,
        quantidadeDeMembros: Int,
        espacoID: String? = nil,
        zonaCloudKit: String? = nil,
        donoDaZonaCloudKit: String? = nil,
        compartilhamentoCloudKit: String? = nil,
        bancoCloudKit: String? = nil,
        codigoDeEntrada: String? = nil,
        configuracoes: ConfiguracoesDaEquipe = .init()
    ) {
        self.id = id
        self.nome = nome
        self.papel = papel
        self.quantidadeDeMembros = quantidadeDeMembros
        self.espacoID = espacoID
        self.zonaCloudKit = zonaCloudKit
        self.donoDaZonaCloudKit = donoDaZonaCloudKit
        self.compartilhamentoCloudKit = compartilhamentoCloudKit
        self.bancoCloudKit = bancoCloudKit
        self.codigoDeEntrada = codigoDeEntrada
        self.configuracoes = configuracoes
    }

    /// Equipes persistidas antes das preferências de compartilhamento não têm
    /// a chave `configuracoes`. O valor padrão do inicializador não é aplicado
    /// automaticamente pelo `Decodable` sintetizado, por isso a migração
    /// precisa ser explícita e não destrutiva.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        nome = try container.decode(String.self, forKey: .nome)
        papel = try container.decode(String.self, forKey: .papel)
        quantidadeDeMembros = try container.decode(Int.self, forKey: .quantidadeDeMembros)
        espacoID = try container.decodeIfPresent(String.self, forKey: .espacoID)
        zonaCloudKit = try container.decodeIfPresent(String.self, forKey: .zonaCloudKit)
        donoDaZonaCloudKit = try container.decodeIfPresent(String.self, forKey: .donoDaZonaCloudKit)
        compartilhamentoCloudKit = try container.decodeIfPresent(String.self, forKey: .compartilhamentoCloudKit)
        bancoCloudKit = try container.decodeIfPresent(String.self, forKey: .bancoCloudKit)
        codigoDeEntrada = try container.decodeIfPresent(String.self, forKey: .codigoDeEntrada)
        configuracoes = try container.decodeIfPresent(
            ConfiguracoesDaEquipe.self,
            forKey: .configuracoes
        ) ?? .init()
    }

    static func novoCodigoDeEntrada() -> String {
        let alfabeto = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (0..<6).map { _ in String(alfabeto.randomElement()!) }.joined()
    }
}
