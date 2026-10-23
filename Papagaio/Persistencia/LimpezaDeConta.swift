import Foundation
import PapagaioCore

/// Remove todo estado auxiliar de uma conversa depois que SwiftData e a pasta
/// de gravação já foram excluídos com sucesso.
@MainActor
enum LimpezaDeArquivo {
    static func executar(_ id: ArquivoID, em defaults: UserDefaults = .standard) {
        TarefasDaConversa.remover(id, em: defaults)
        MidiasDaConversa.remover(id, em: defaults)
        PreferenciasVisuaisDoArquivo.remover(id, em: defaults)
        AparenciaDoCartao.remover(id, em: defaults)
        LixeiraDeMidia.removerRegistros(do: id, em: defaults)
        LixeiraDeTarefas.removerRegistros(do: id, em: defaults)
        LixeiraDePastas.removerReferencias(ao: id, em: defaults)
        FalantePreservadoParaTrecho.limpar(id, em: defaults)
    }
}

/// Caminho único da exclusão de dados do perfil pessoal local.
///
/// Antes a cascata vivia espalhada na `ContentView`: cada store novo era um
/// convite para esquecer uma limpeza. Aqui todo store que guarda dados da
/// conta se registra — um lugar só para auditar o que sai quando a pessoa
/// exclui a conta.
///
/// Cada store é limpo pelos IDs que pertenciam ao espaço excluído. Assim,
/// conversas de equipes e de outros espaços não perdem seus dados auxiliares.
/// Preferências globais, pastas compartilhadas, fotos e modelos baixados ficam
/// de fora de propósito porque ainda podem ser usados pelos espaços mantidos.
@MainActor
enum LimpezaDeConta {
    static func executar(
        arquivos: some Sequence<ArquivoID>,
        em defaults: UserDefaults = .standard
    ) {
        for arquivoID in Set(arquivos) {
            LimpezaDeArquivo.executar(arquivoID, em: defaults)
        }

        // O espaço individual renasce na próxima abertura da biblioteca.
        defaults.removeObject(forKey: "espacoIndividual")
        EstadoDasReunioesCalendar(defaults: defaults).removerTodos()
    }
}

/// Cofre mínimo necessário para a exclusão local das integrações. A operação
/// não chama endpoints remotos: seu contrato é impedir que um perfil criado
/// depois herde tokens do Google Calendar ou do Granola.
protocol CofreDeCredenciaisDaConta: Sendable {
    func apagar(conta: String)
}

extension CofreDeTokens: CofreDeCredenciaisDaConta {}

enum LimpezaDeCredenciaisDaConta {
    static func executar(
        google: any CofreDeCredenciaisDaConta = CofreDeTokens(servico: "papagaio:google-calendar"),
        granola: any CofreDeCredenciaisDaConta = CofreDeTokens(servico: "papagaio:granola")
    ) {
        for conta in ["access_token", "access_token_expires", "refresh_token", "pkce"] {
            google.apagar(conta: conta)
        }
        for conta in ["access_token", "access_token_expires", "refresh_token", "client", "pkce"] {
            granola.apagar(conta: conta)
        }
    }
}
