import SwiftUI

/// Representa a identidade que o CloudKit expõe para uma pessoa no `CKShare`.
///
/// Não usamos e-mail aqui: o CloudKit deliberadamente não o revela para todos
/// os participantes de um compartilhamento. O identificador serve somente para
/// que o proprietário execute uma ação sobre o participante certo.
struct ParticipanteDaEquipe: Identifiable, Hashable, Sendable {
    enum Permissao: String, CaseIterable, Identifiable, Sendable {
        case leitura = "Somente leitura"
        case escrita = "Leitura e escrita"

        var id: Self { self }
    }

    let id: String
    let nome: String
    let eProprietario: Bool
    let eAtual: Bool
    let permissao: Permissao

    var descricaoDaPermissao: String {
        eProprietario ? "Proprietário".localized : permissao.rawValue.localized
    }
}

enum StatusDaEquipe: String, CaseIterable, Identifiable, Codable, Sendable {
    case ativo = "Ativo"
    case offline = "Offline"
    case ocupado = "Ocupado"
    case aguardando = "Convite pendente"

    var id: Self { self }
    var titulo: String {
        switch self {
        case .ativo: "Ativo".localized
        case .offline: "Offline".localized
        case .ocupado: "Ocupado".localized
        case .aguardando: "Convite pendente".localized
        }
    }
    var cor: Color {
        switch self {
        case .ativo: PapagaioTema.sucesso
        case .offline, .aguardando: PapagaioTema.textoSecundario.opacity(0.55)
        case .ocupado: PapagaioTema.perigo
        }
    }
}

enum PermissaoDoMembroDaEquipe: String, CaseIterable, Identifiable, Codable, Sendable {
    case leitura = "Somente leitura"
    case escrita = "Leitura e escrita"

    var id: Self { self }
    var titulo: String {
        switch self {
        case .leitura: "Somente leitura".localized
        case .escrita: "Leitura e escrita".localized
        }
    }
}

struct MembroDaEquipe: Identifiable, Equatable, Codable, Sendable {
    var id = UUID().uuidString
    var nome: String
    var email: String
    var cargo: String
    var status: StatusDaEquipe
    var atual: Bool = false
    var permissao: PermissaoDoMembroDaEquipe = .escrita

    var iniciais: String { Papagaio.iniciais(de: nome, vazio: "M") }

    init(
        id: String = UUID().uuidString,
        nome: String,
        email: String,
        cargo: String,
        status: StatusDaEquipe,
        atual: Bool = false,
        permissao: PermissaoDoMembroDaEquipe = .escrita
    ) {
        self.id = id
        self.nome = nome
        self.email = email
        self.cargo = cargo
        self.status = status
        self.atual = atual
        self.permissao = permissao
    }

    private enum CodingKeys: String, CodingKey {
        case id, nome, email, cargo, status, atual, permissao
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        nome = try container.decode(String.self, forKey: .nome)
        email = try container.decode(String.self, forKey: .email)
        cargo = try container.decode(String.self, forKey: .cargo)
        status = try container.decode(StatusDaEquipe.self, forKey: .status)
        atual = try container.decodeIfPresent(Bool.self, forKey: .atual) ?? false
        permissao = try container.decodeIfPresent(
            PermissaoDoMembroDaEquipe.self,
            forKey: .permissao
        ) ?? .escrita
    }
}
