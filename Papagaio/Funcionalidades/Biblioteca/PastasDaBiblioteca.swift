import Foundation
import PapagaioCore

/// O ciclo de vida das pastas num lugar só: apagar e restaurar (com a
/// lixeira no meio) e preparar o pacote para exportação.
///
/// Vivia espalhado em funções privadas da `BibliotecaHomeView`, misturado com
/// painéis e composição — e sem teste nenhum. A view ficou só com o que é
/// dela: os painéis do sistema e a invalidação visual depois de cada ação.
@MainActor
enum PastasDaBiblioteca {
    enum Erro: LocalizedError {
        case pastaVazia

        var errorDescription: String? {
            "Esta pasta não contém conversas para exportar.".localized
        }
    }

    /// Apagar a pasta leva as conversas dela para a lixeira, junto.
    ///
    /// A alternativa — apagar só o rótulo e deixar as conversas soltas em
    /// "Todas" — parece mais gentil e é pior: quem apaga a pasta "Cliente X"
    /// quer o projeto fora da vista, e encontraria as mesmas conversas
    /// espalhadas na grade um segundo depois. Na lixeira nada se perde, e a
    /// pasta ali dentro permite trazer de volta o conjunto ou um arquivo só.
    @discardableResult
    static func apagar(_ nome: String, biblioteca: Biblioteca) async -> Bool {
        let conversas = biblioteca.arquivos.filter {
            PreferenciasVisuaisDoArquivo.pasta($0.id) == nome
        }
        for arquivo in conversas {
            guard await biblioteca.moverParaLixeira(arquivo) else {
                // A pasta e os rótulos continuam intactos. Conversas que já
                // foram movidas ainda apontam para esta pasta, portanto uma
                // nova tentativa completa o conjunto sem deixar rótulo órfão
                // nem retrato parcial na lixeira de pastas.
                return false
            }
        }
        // Depois de mover: `apagarPasta` lê quem ainda tem o rótulo para
        // montar o retrato, e o rótulo sobrevive à ida para a lixeira.
        PreferenciasVisuaisDoArquivo.apagarPasta(nome)
        return true
    }

    /// As conversas de uma pasta apagada, na ordem da lixeira — a mesma ordem
    /// dos outros cartões da tela.
    static func conversas(da pasta: PastaNaLixeira, biblioteca: Biblioteca) -> [Arquivo] {
        biblioteca.arquivosNaLixeira.filter { pasta.conversas.contains($0.id.rawValue) }
    }

    /// Devolve a pasta e tudo o que ainda estava dentro dela.
    @discardableResult
    static func restaurar(_ pasta: PastaNaLixeira, biblioteca: Biblioteca) async -> Bool {
        LixeiraDePastas.recriar(pasta)
        var restaurouTudo = true
        for arquivo in conversas(da: pasta, biblioteca: biblioteca) {
            if await biblioteca.restaurarDaLixeira(arquivo) {
                LixeiraDePastas.devolverRotulo(pasta.nome, para: arquivo.id)
            } else {
                restaurouTudo = false
            }
        }
        if restaurouTudo { LixeiraDePastas.remover(pasta) }
        return restaurouTudo
    }

    /// Restaura primeiro as pastas, aguardando seus arquivos e devolvendo os
    /// rótulos. Só depois trata conversas avulsas. O fluxo anterior disparava
    /// a biblioteca em paralelo e apagava o retrato da pasta cedo demais.
    static func restaurarTudo(biblioteca: Biblioteca) async {
        for pasta in LixeiraDePastas.itens() {
            _ = await restaurar(pasta, biblioteca: biblioteca)
        }

        let aindaVinculados = Set(
            LixeiraDePastas.itens().flatMap(\.conversas).map(ArquivoID.init(rawValue:))
        )
        for arquivo in biblioteca.arquivosNaLixeira where !aindaVinculados.contains(arquivo.id) {
            guard await biblioteca.restaurarDaLixeira(arquivo) else { break }
        }
    }

    /// Traz uma conversa de volta sem restaurar a pasta.
    ///
    /// Ela volta para "Todas", sem rótulo: a pasta não existe mais, e inventar
    /// uma para ela criaria uma pasta que a pessoa não pediu.
    static func restaurarConversa(_ arquivo: Arquivo, biblioteca: Biblioteca) async {
        guard await biblioteca.restaurarDaLixeira(arquivo) else { return }
        LixeiraDePastas.desvincular(arquivo.id)
    }

    /// As conversas de uma pasta, como arquivos prontos para sair do app.
    ///
    /// Um dossiê por conversa, com documento, áudios e anexos.
    static func pacote(_ nome: String, biblioteca: Biblioteca) async throws -> URL {
        let conversas = biblioteca.arquivos
            .filter { PreferenciasVisuaisDoArquivo.pasta($0.id) == nome }
            .map { (arquivo: $0, audio: biblioteca.audio(de: $0)) }

        guard !conversas.isEmpty else { throw Erro.pastaVazia }
        return try await Task.detached {
            try DossieDaConversa.pastaComTudo(nome: nome, conversas: conversas)
        }.value
    }
}
