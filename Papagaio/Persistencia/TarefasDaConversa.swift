import Foundation
import PapagaioCore

enum TarefasDaConversa {
    /// As tarefas guardadas, acrescidas das sugestões do resumo que ainda
    /// não foram oferecidas.
    ///
    /// Antes, a primeira abertura gravava o resultado mesmo vazio: quem abria
    /// a conversa enquanto ela ainda transcrevia ficava com `[]` salvo e nunca
    /// mais via as sugestões, nem depois de "Gerar novo resumo". Agora a lista
    /// vazia não é gravada, e ao lado das tarefas fica a **assinatura** dos
    /// próximos passos já oferecidos — um passo novo vira sugestão uma única
    /// vez, sem tocar nas tarefas existentes nem ressuscitar as descartadas.
    static func carregar(
        _ arquivoID: ArquivoID,
        base proximosPassos: [ProximoPasso],
        tituloDaConversa: String,
        dataDaConversa: Date,
        em defaults: UserDefaults = .standard
    ) -> [TarefaDaConversa] {
        let guardadas = defaults.data(forKey: chave(arquivoID))
            .flatMap { try? JSONDecoder().decode([TarefaDaConversa].self, from: $0) }

        var oferecidos: Set<String>
        if let conhecidos = passosOferecidos(arquivoID, em: defaults) {
            oferecidos = conhecidos
        } else if let guardadas, !guardadas.isEmpty {
            // Dados de antes da assinatura, com tarefas: as sugestões do
            // resumo atual já passaram pela pessoa (aceitas, editadas ou
            // descartadas) — oferecê-las de novo duplicaria tudo.
            oferecidos = Set(proximosPassos.map(assinatura))
            guardar(oferecidos, de: arquivoID, em: defaults)
        } else {
            oferecidos = []
        }

        var novos: [ProximoPasso] = []
        for passo in proximosPassos {
            let marca = assinatura(passo)
            guard !marca.isEmpty, oferecidos.insert(marca).inserted else { continue }
            novos.append(passo)
        }
        guard !novos.isEmpty else {
            // Marca que a conversa já foi carregada por este caminho, para
            // que tarefas criadas à mão antes do resumo não bloqueiem as
            // sugestões quando ele chegar.
            if passosOferecidos(arquivoID, em: defaults) == nil {
                guardar(oferecidos, de: arquivoID, em: defaults)
            }
            return guardadas ?? []
        }

        // O resumo não informa prazo nem prioridade (`ProximoPasso` só tem
        // descrição e responsável). Inventar "data da conversa + 7 dias" fazia
        // toda conversa antiga nascer com as tarefas vencidas e promovidas a
        // prioridade alta.
        let sugestoes = novos.map { passo in
            TarefaDaConversa(
                titulo: passo.descricao,
                origem: tituloDaConversa,
                prioridade: .media,
                status: .naoIniciado,
                responsavel: TarefaDaConversa.responsavelSaneado(passo.responsavel),
                prazo: nil,
                // Extraída da transcrição, não escrita pela pessoa — fica como
                // sugestão até ela aceitar, editar ou descartar.
                sugestaoPendente: true
            )
        }
        let tarefas = (guardadas ?? []) + sugestoes
        salvar(tarefas, para: arquivoID, em: defaults)
        guardar(oferecidos, de: arquivoID, em: defaults)
        return tarefas
    }

    static func salvar(
        _ tarefas: [TarefaDaConversa],
        para arquivoID: ArquivoID,
        em defaults: UserDefaults = .standard
    ) {
        guard let dados = try? JSONEncoder().encode(tarefas) else { return }
        defaults.set(dados, forKey: chave(arquivoID))
    }

    static func remover(_ arquivoID: ArquivoID, em defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: chave(arquivoID))
        defaults.removeObject(forKey: chaveDosOferecidos(arquivoID))
    }

    static func removerTodas(em defaults: UserDefaults = .standard) {
        for chave in defaults.dictionaryRepresentation().keys
        where chave.hasPrefix("tarefasDaConversa.") || chave.hasPrefix(prefixoDosOferecidos) {
            defaults.removeObject(forKey: chave)
        }
    }

    /// A cópia de uma conversa herda o que já foi oferecido na original: sem
    /// isto, sugestões descartadas lá reapareceriam na duplicata.
    static func copiarPassosOferecidos(
        de origem: ArquivoID,
        para copia: ArquivoID,
        passosAtuais: [ProximoPasso],
        em defaults: UserDefaults = .standard
    ) {
        let oferecidos = passosOferecidos(origem, em: defaults) ?? Set(passosAtuais.map(assinatura))
        guardar(oferecidos, de: copia, em: defaults)
    }

    // MARK: - Assinatura dos passos oferecidos

    private static let prefixoDosOferecidos = "passosOferecidosComoTarefa."

    private static func assinatura(_ passo: ProximoPasso) -> String {
        passo.descricao
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func passosOferecidos(_ arquivoID: ArquivoID, em defaults: UserDefaults) -> Set<String>? {
        (defaults.array(forKey: chaveDosOferecidos(arquivoID)) as? [String]).map(Set.init)
    }

    private static func guardar(_ oferecidos: Set<String>, de arquivoID: ArquivoID, em defaults: UserDefaults) {
        defaults.set(oferecidos.sorted(), forKey: chaveDosOferecidos(arquivoID))
    }

    private static func chaveDosOferecidos(_ arquivoID: ArquivoID) -> String {
        "\(prefixoDosOferecidos)\(arquivoID.rawValue.uuidString)"
    }

    private static func chave(_ arquivoID: ArquivoID) -> String {
        "tarefasDaConversa.\(arquivoID.rawValue.uuidString)"
    }
}
