import Contacts
import EventKit
import Foundation
import PapagaioCore

/// Vocabulário curto usado apenas como contexto inicial do Whisper. É um prior
/// para nomes próprios, não uma correção automática: o texto reconhecido ainda
/// precisa ser produzido pelo áudio.
enum PromptDeEntidades {
#if OMU_PERF
    static func construir(para arquivo: Arquivo, termosSinteticos: [String]? = nil) async -> String? {
        let termos: [String]
        if let termosSinteticos {
            termos = termosSinteticos
        } else {
            async let termosDoCalendario = termosDoCalendario(
                inicio: arquivo.criadoEm,
                fim: arquivo.criadoEm.addingTimeInterval(max(arquivo.duracao, 1))
            )
            async let termosDosContatos = termosDosContatos()
            termos = await termosDoCalendario + termosDosContatos
        }
        return montarPrompt(termos)
    }
#else
    static func construir(para arquivo: Arquivo) async -> String? {
        async let termosDoCalendario = termosDoCalendario(
            inicio: arquivo.criadoEm,
            fim: arquivo.criadoEm.addingTimeInterval(max(arquivo.duracao, 1))
        )
        async let termosDosContatos = termosDosContatos()
        let termosCalendario = await termosDoCalendario
        let termosContato = await termosDosContatos
        return montarPrompt(termosCalendario + termosContato)
    }
#endif

    private static func montarPrompt(_ termos: [String]) -> String? {
        let unicos = termos.reduce(into: [String: String]()) { resultado, termo in
            let limpo = termo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpo.isEmpty else { return }
            resultado[limpo.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)] = limpo
        }
        let prompt = unicos.values.sorted().prefix(40).joined(separator: ", ")
        return prompt.isEmpty ? nil : prompt
    }

    private static func termosDoCalendario(inicio: Date, fim: Date) async -> [String] {
        let store = EKEventStore()
        guard await acessoAoCalendario(store) else { return [] }
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
        let store = CNContactStore()
        guard await acessoAosContatos(store) else { return [] }
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
