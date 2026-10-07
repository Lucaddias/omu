import Contacts
import EventKit
import Foundation
import PapagaioCore

/// Vocabulário curto usado apenas como contexto inicial do Whisper. É um prior
/// para nomes próprios, não uma correção automática: o texto reconhecido ainda
/// precisa ser produzido pelo áudio.
enum PromptDeEntidades {
    static let chaveDaPreferencia = "usarContatosECalendarioNaTranscricao"
    static let limiteDeTermos = 40

    /// Vale a escolha feita nos Ajustes; sem escolha, o que o macOS já tinha
    /// autorizado antes de a preferência existir. O processamento nunca pede
    /// acesso por conta própria — o pedido aparecia no meio da primeira
    /// transcrição, sem explicação (PS-03).
    static func habilitado(em defaults: UserDefaults = .standard) -> Bool {
        if let escolha = defaults.object(forKey: chaveDaPreferencia) as? Bool { return escolha }
        return calendarioAutorizado || contatosAutorizados
    }

    /// Chamado ao ligar a preferência: é aqui, com a pessoa olhando para a
    /// explicação, que o macOS pergunta. Devolve se ao menos uma das fontes
    /// ficou disponível.
    @discardableResult
    static func pedirAcesso() async -> Bool {
        let calendario = await acessoAoCalendario(EKEventStore())
        let contatos = await acessoAosContatos(CNContactStore())
        return calendario || contatos
    }

#if OMU_PERF
    static func construir(para arquivo: Arquivo, termosSinteticos: [String]? = nil) async -> String? {
        if let termosSinteticos {
            // A medição compara execuções: o vocabulário sintético mantém a
            // ordem alfabética de sempre.
            return montarPrompt(daFicha: termosSinteticos.sorted(), doEvento: [], contatos: [])
        }
        return await construirComFontesReais(para: arquivo)
    }
#else
    static func construir(para arquivo: Arquivo) async -> String? {
        await construirComFontesReais(para: arquivo)
    }
#endif

    private static func construirComFontesReais(para arquivo: Arquivo) async -> String? {
        let ficha = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
        let daFicha = (ficha.entrevistado + "\n" + ficha.entrevistadores)
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
            .map(String.init)
        guard habilitado() else {
            return montarPrompt(daFicha: daFicha, doEvento: [], contatos: [])
        }
        async let termosDoCalendario = termosDoCalendario(
            inicio: arquivo.criadoEm,
            fim: arquivo.criadoEm.addingTimeInterval(max(arquivo.duracao, 1))
        )
        async let termosDosContatos = termosDosContatos()
        return montarPrompt(
            daFicha: daFicha,
            doEvento: await termosDoCalendario,
            contatos: await termosDosContatos
        )
    }

    /// Monta o vocabulário por prioridade: quem está na ficha, depois o
    /// evento do calendário naquele horário. Os contatos só entram para
    /// completar um nome que já é candidato ("Ana" → "Ana Beatriz Souza");
    /// a agenda inteira no prompt puxava o Whisper para grafias de pessoas
    /// que nem estavam na reunião.
    static func montarPrompt(daFicha: [String], doEvento: [String], contatos: [String]) -> String? {
        func chave(_ texto: String) -> String {
            texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var vistos = Set<String>()
        var termos: [String] = []
        func acrescentar(_ termo: String) {
            let limpo = termo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpo.isEmpty, termos.count < limiteDeTermos,
                  vistos.insert(chave(limpo)).inserted else { return }
            termos.append(limpo)
        }

        daFicha.forEach(acrescentar)
        doEvento.forEach(acrescentar)

        // Palavras dos candidatos que podem identificar uma pessoa: três
        // letras ou mais, para "de", "da" e iniciais não casarem com todos.
        let palavrasCandidatas = Set(
            termos.flatMap { chave($0).split(whereSeparator: { !$0.isLetter }) }
                .filter { $0.count >= 3 }
                .map(String.init)
        )
        if !palavrasCandidatas.isEmpty {
            for contato in contatos {
                let palavras = chave(contato).split(whereSeparator: { !$0.isLetter }).map(String.init)
                if palavras.contains(where: palavrasCandidatas.contains) {
                    acrescentar(contato)
                }
            }
        }

        return termos.isEmpty ? nil : termos.joined(separator: ", ")
    }

    private static func termosDoCalendario(inicio: Date, fim: Date) async -> [String] {
        guard calendarioAutorizado else { return [] }
        let store = EKEventStore()
        let margem: TimeInterval = 15 * 60
        let predicado = store.predicateForEvents(
            withStart: inicio.addingTimeInterval(-margem),
            end: fim.addingTimeInterval(margem),
            calendars: nil
        )
        return store.events(matching: predicado).flatMap { evento in
            [evento.title] + (evento.attendees ?? []).compactMap(\.name)
        }
        .compactMap { $0 }
    }

    private static func termosDosContatos() async -> [String] {
        guard contatosAutorizados else { return [] }
        let store = CNContactStore()
        let chaves: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let pedido = CNContactFetchRequest(keysToFetch: chaves)
        var termos: [String] = []
        try? store.enumerateContacts(with: pedido) { contato, _ in
            let nome = "\(contato.givenName) \(contato.familyName)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !nome.isEmpty { termos.append(nome) }
            if !contato.organizationName.isEmpty { termos.append(contato.organizationName) }
        }
        return termos
    }

    private static var calendarioAutorizado: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: true
        default: false
        }
    }

    private static var contatosAutorizados: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    private static func acessoAoCalendario(_ store: EKEventStore) async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    private static func acessoAosContatos(_ store: CNContactStore) async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestAccess(for: .contacts) { autorizou, _ in
                    continuation.resume(returning: autorizou)
                }
            }
        default:
            return false
        }
    }
}
