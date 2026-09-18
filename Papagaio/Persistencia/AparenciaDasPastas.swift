import AppKit
import Foundation
import SwiftUI

/// Cor e imagem de cada pasta da biblioteca.
///
/// Guardado por **nome** da pasta, que é o que a identifica no resto do app —
/// não há um id próprio. Renomear transfere o estado completo para a nova
/// chave; a lixeira guarda esse mesmo estado para restaurá-lo.
///
/// A cor existe por um motivo prático, não estético: quem organiza por cliente
/// ou por projeto reconhece a pasta pela cor antes de ler o nome, e a grade de
/// pastas é exatamente o lugar onde se procura sem ler.
enum AparenciaDasPastas {
    private static let prefixoCor = "corDaPasta."
    private static let prefixoCapa = "capaDaPasta."
    private static let prefixoAjuste = "ajusteDaCapaDaPasta."
    private static let prefixoFavorita = "pastaFavorita."

    private static let prefixoCriacao = "pastaCriadaEm."

    /// Marca a data de criação, uma vez só.
    ///
    /// Idempotente de propósito: `criarPasta` é chamada toda vez que uma
    /// conversa é movida, e sem essa guarda a "data de criação" viraria a data
    /// da última movimentação.
    static func registrarCriacao(de pasta: String) {
        let chave = prefixoCriacao + pasta
        guard UserDefaults.standard.object(forKey: chave) == nil else { return }
        UserDefaults.standard.set(Date(), forKey: chave)
    }

    /// `nil` para pastas criadas antes desta versão — quem chama decide o que
    /// mostrar no lugar.
    static func criadaEm(_ pasta: String) -> Date? {
        UserDefaults.standard.object(forKey: prefixoCriacao + pasta) as? Date
    }

    /// Tudo o que define a aparência de uma pasta, num valor só.
    ///
    /// Existe para a lixeira: apagar uma pasta precisa poder ser desfeito, e
    /// desfazer significa devolver cor, imagem, favorito e data de criação —
    /// não só o nome na lista.
    struct Estado: Codable, Equatable {
        var preset: String?
        var corLivre: String?
        var favorita: Bool
        /// Opcional para ler estados gravados antes desta versão.
        var semCor: Bool?
        var criadaEm: Date?
        /// O bookmark cru da imagem, como está gravado.
        var capa: Data?
        /// Opcional para compatibilidade com retratos antigos da lixeira.
        var ajuste: String? = nil
    }

    @MainActor
    static func estado(de pasta: String) -> Estado {
        let padroes = UserDefaults.standard
        return Estado(
            preset: padroes.string(forKey: prefixoCor + pasta),
            corLivre: padroes.string(forKey: prefixoCorLivre + pasta),
            favorita: padroes.bool(forKey: prefixoFavorita + pasta),
            semCor: padroes.bool(forKey: prefixoSemCor + pasta),
            criadaEm: padroes.object(forKey: prefixoCriacao + pasta) as? Date,
            capa: padroes.data(forKey: prefixoCapa + pasta),
            ajuste: padroes.string(forKey: prefixoAjuste + pasta)
        )
    }

    @MainActor
    static func restaurar(_ estado: Estado, para pasta: String) {
        esquecer(pasta)
        let padroes = UserDefaults.standard
        if let ajuste = estado.ajuste { padroes.set(ajuste, forKey: prefixoAjuste + pasta) }
        if let preset = estado.preset { padroes.set(preset, forKey: prefixoCor + pasta) }
        if let corLivre = estado.corLivre { padroes.set(corLivre, forKey: prefixoCorLivre + pasta) }
        if estado.favorita { padroes.set(true, forKey: prefixoFavorita + pasta) }
        if estado.semCor == true { padroes.set(true, forKey: prefixoSemCor + pasta) }
        if let criadaEm = estado.criadaEm { padroes.set(criadaEm, forKey: prefixoCriacao + pasta) }
        if let capa = estado.capa { padroes.set(capa, forKey: prefixoCapa + pasta) }
        decodificadas.removeObject(forKey: pasta as NSString)
    }

    /// Leva cor, imagem, favorito e data de criação para o nome novo.
    @MainActor
    static func renomear(de antigo: String, para novo: String) {
        let guardado = estado(de: antigo)
        esquecer(antigo)
        restaurar(guardado, para: novo)
    }

    /// Some com tudo o que era só desta pasta: cor, imagem, favorito e a data
    /// de criação. Chamado quando a pasta é apagada — deixar os restos faria a
    /// próxima pasta de mesmo nome nascer com a aparência da anterior.
    @MainActor
    static func esquecer(_ pasta: String) {
        removerCapa(de: pasta)
        for prefixo in [prefixoCor, prefixoCorLivre, prefixoFavorita, prefixoCriacao, prefixoSemCor, prefixoAjuste] {
            UserDefaults.standard.removeObject(forKey: prefixo + pasta)
        }
    }

    static func ajuste(de pasta: String) -> AjusteDeImagem {
        let bruto = UserDefaults.standard.string(forKey: prefixoAjuste + pasta)
        return bruto.flatMap(AjusteDeImagem.init(rawValue:)) ?? .preencher
    }

    static func definirAjuste(_ ajuste: AjusteDeImagem, para pasta: String) {
        UserDefaults.standard.set(ajuste.rawValue, forKey: prefixoAjuste + pasta)
    }

    static func favorita(_ pasta: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefixoFavorita + pasta)
    }

    static func definirFavorita(_ favorita: Bool, para pasta: String) {
        let chave = prefixoFavorita + pasta
        if favorita {
            UserDefaults.standard.set(true, forKey: chave)
        } else {
            UserDefaults.standard.removeObject(forKey: chave)
        }
    }

    /// Paleta fechada, e não um seletor livre de cores.
    ///
    /// Cor arbitrária num app com identidade forte produz pasta rosa-choque ao
    /// lado do laranja da marca. Oito tons cobrem qualquer esquema de
    /// organização — mais que isso ninguém distingue de relance, que é
    /// justamente o que a cor serve para fazer.
    enum Cor: String, CaseIterable, Identifiable {
        case padrao, laranja, ambar, verde, agua, azul, roxo, rosa

        var id: String { rawValue }

        var titulo: String {
            switch self {
            case .padrao: "Padrão"
            case .laranja: "Laranja"
            case .ambar: "Âmbar"
            case .verde: "Verde"
            case .agua: "Água"
            case .azul: "Azul"
            case .roxo: "Roxo"
            case .rosa: "Rosa"
            }
        }

        var cor: Color {
            switch self {
            case .padrao: PapagaioTema.destaque
            case .laranja: Color(red: 0.93, green: 0.44, blue: 0.20)
            case .ambar: Color(red: 0.90, green: 0.70, blue: 0.16)
            case .verde: Color(red: 0.30, green: 0.66, blue: 0.40)
            case .agua: Color(red: 0.22, green: 0.66, blue: 0.66)
            case .azul: Color(red: 0.26, green: 0.51, blue: 0.85)
            case .roxo: Color(red: 0.53, green: 0.40, blue: 0.82)
            case .rosa: Color(red: 0.85, green: 0.38, blue: 0.58)
            }
        }
    }

    private static let prefixoCorLivre = "corLivreDaPasta."

    /// A cor que a pasta realmente usa: a escolhida à mão, se houver, senão a
    /// da paleta.
    ///
    /// Todo lugar que pinta algo de uma pasta — o cartão dela, a pastilha na
    /// conversa, a faixa do cartão de conversa — lê daqui. Ler o `enum` direto
    /// faria a cor livre valer só na tela onde foi escolhida.
    static func corResolvida(de pasta: String) -> Color {
        if semCor(de: pasta) { return PapagaioTema.superficieSuave }
        return corLivre(de: pasta) ?? cor(de: pasta).cor
    }

    private static let prefixoSemCor = "pastaSemCor."

    /// "Sem cor" é uma escolha explícita — ver `AparenciaDoCartao.semCor`.
    static func semCor(de pasta: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefixoSemCor + pasta)
    }

    static func definirSemCor(_ ativo: Bool, para pasta: String) {
        let chave = prefixoSemCor + pasta
        if ativo {
            UserDefaults.standard.set(true, forKey: chave)
        } else {
            UserDefaults.standard.removeObject(forKey: chave)
        }
    }

    static func corLivre(de pasta: String) -> Color? {
        guard let hex = UserDefaults.standard.string(forKey: prefixoCorLivre + pasta) else {
            return nil
        }
        return Color(hexadecimal: hex)
    }

    static func definirCorLivre(_ cor: Color?, para pasta: String) {
        let chave = prefixoCorLivre + pasta
        guard let cor, let hex = cor.hexadecimal else {
            UserDefaults.standard.removeObject(forKey: chave)
            return
        }
        UserDefaults.standard.set(hex, forKey: chave)
    }

    static func cor(de pasta: String) -> Cor {
        guard let bruto = UserDefaults.standard.string(forKey: prefixoCor + pasta),
              let cor = Cor(rawValue: bruto)
        else { return .padrao }
        return cor
    }

    static func definirCor(_ cor: Cor, para pasta: String) {
        let chave = prefixoCor + pasta
        if cor == .padrao {
            UserDefaults.standard.removeObject(forKey: chave)
        } else {
            UserDefaults.standard.set(cor.rawValue, forKey: chave)
        }
    }

    // MARK: - Imagem

    /// Mesma estratégia da capa das conversas: bookmark com escopo de
    /// segurança, porque sob sandbox um caminho solto deixa de abrir assim que
    /// o app reinicia.
    @MainActor private static let decodificadas = NSCache<NSString, NSImage>()

    /// Mesma memoização do cartão: resolver bookmark por fileira, a cada
    /// redesenho da grade, era leitura de disco em série.
    @MainActor private static var urlsResolvidas: [String: URL?] = [:]

    @MainActor
    static func capa(de pasta: String) -> URL? {
        let chave = prefixoCapa + pasta
        if let guardada = urlsResolvidas[chave] { return guardada }

        guard let dados = UserDefaults.standard.data(forKey: chave) else {
            urlsResolvidas[chave] = URL?.none
            return nil
        }

        var obsoleto = false
        guard let url = try? URL(
            resolvingBookmarkData: dados,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &obsoleto
        ) else {
            UserDefaults.standard.removeObject(forKey: chave)
            urlsResolvidas[chave] = URL?.none
            return nil
        }
        if obsoleto { try? definirCapa(url, para: pasta) }
        urlsResolvidas[chave] = url
        return url
    }

    @MainActor
    static func definirCapa(_ url: URL, para pasta: String) throws {
        let dados = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(dados, forKey: prefixoCapa + pasta)
        urlsResolvidas[prefixoCapa + pasta] = nil
        decodificadas.removeObject(forKey: pasta as NSString)
    }

    @MainActor
    static func removerCapa(de pasta: String) {
        UserDefaults.standard.removeObject(forKey: prefixoCapa + pasta)
        urlsResolvidas[prefixoCapa + pasta] = nil
        decodificadas.removeObject(forKey: pasta as NSString)
    }

    /// Imagem pronta para desenhar, decodificada no máximo uma vez.
    ///
    /// Sem o cache, `NSImage(contentsOf:)` rodaria a cada avaliação de body do
    /// cartão — leitura de disco por pasta, por atualização da grade.
    @MainActor
    static func imagem(de pasta: String) -> NSImage? {
        let chave = pasta as NSString
        if let guardada = decodificadas.object(forKey: chave) { return guardada }

        guard let url = capa(de: pasta) else { return nil }
        let acessou = url.startAccessingSecurityScopedResource()
        defer { if acessou { url.stopAccessingSecurityScopedResource() } }

        guard let original = NSImage(contentsOf: url) else { return nil }
        let imagem = MiniaturaDeImagem.reduzir(original)
        decodificadas.setObject(imagem, forKey: chave)
        return imagem
    }

    /// Remove aparência e ordenação que pertencem às pastas da conta atual.
    @MainActor
    static func removerTodas(em defaults: UserDefaults = .standard) {
        let prefixos = [
            prefixoCor, prefixoCapa, prefixoAjuste, prefixoFavorita,
            prefixoCriacao, prefixoCorLivre, prefixoSemCor,
        ]
        for chave in defaults.dictionaryRepresentation().keys
        where prefixos.contains(where: chave.hasPrefix) {
            defaults.removeObject(forKey: chave)
        }
        urlsResolvidas.removeAll()
        decodificadas.removeAllObjects()
    }
}
