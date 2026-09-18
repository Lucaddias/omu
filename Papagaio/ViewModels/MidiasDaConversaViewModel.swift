import AppKit
import Foundation
import Observation
import PapagaioCore

/// Os anexos de uma conversa: a lista, os áudios da gravação, a escolha no
/// painel do sistema, a cópia para dentro da pasta e a lixeira de mídia.
///
/// Tudo isto vivia na `ArquivoDetalheView`, onde `NSOpenPanel`, cópia de
/// arquivo, lixeira e tradução de erro do Cocoa dividiam espaço com a
/// composição da tela. A view ficou só com o que é dela: pausar o player
/// antes de o áudio sair do lugar (ver `aoPausarReproducao`).
@MainActor
@Observable
final class MidiasDaConversaViewModel {
    /// Anexos escolhidos pela pessoa.
    private(set) var anexos: [AnexoDeMidiaDaConversa] = []
    /// O áudio da própria gravação entra fixo na lista: depois que a
    /// transcrição e o resumo estão prontos o arquivo costuma virar só peso
    /// em disco, e daqui a pessoa consegue apagá-lo sem sair do app.
    private(set) var anexosDaGravacao: [AnexoDeMidiaDaConversa] = []
    /// Mídia removida desta conversa, ainda recuperável.
    private(set) var naLixeira: [MidiaNaLixeira] = []
    var erro: String?

    /// A transcrição já existe? Remover o áudio da gravação só é liberado
    /// depois dela — sem transcrição o áudio ainda é necessário. Quem sabe se
    /// ela chegou é a tela; ela mantém isto atualizado.
    var transcricaoDisponivel = false
    /// Quem reproduz o áudio pausa aqui antes de o arquivo ir para a lixeira.
    var aoPausarReproducao: (() -> Void)?

    private let arquivoID: ArquivoID
    /// Os anexos são copiados para cá, ao lado do áudio. Guardar só o caminho
    /// de origem deixaria o anexo quebrado assim que a pessoa movesse o
    /// arquivo original.
    private let pastaDaConversa: URL
    private let tituloDaConversa: String
    private let audiosDaGravacao: [URL]

    init(
        arquivoID: ArquivoID,
        pastaDaConversa: URL,
        tituloDaConversa: String,
        audiosDaGravacao: [URL]
    ) {
        self.arquivoID = arquivoID
        self.pastaDaConversa = pastaDaConversa
        self.tituloDaConversa = tituloDaConversa
        self.audiosDaGravacao = audiosDaGravacao
    }

    var todosOsAnexos: [AnexoDeMidiaDaConversa] { anexosDaGravacao + anexos }

    // MARK: - Carga

    func carregar() {
        anexos = MidiasDaConversa.carregar(arquivoID)
        anexosDaGravacao = gravacoes()
        recarregarLixeira()
    }

    // MARK: - Escolha e cópia

    func selecionar() {
        let painel = NSOpenPanel()
        painel.title = "Adicionar mídia".localized
        painel.prompt = "Adicionar".localized
        painel.message = "Escolha fotos, vídeos, áudios, PDFs ou outros arquivos para salvar nesta conversa.".localized
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = true
        painel.resolvesAliases = true

        // `begin` no lugar de `runModal`: o painel deixa de travar a main
        // enquanto a pessoa navega pelos arquivos.
        painel.begin { [weak self] resposta in
            guard resposta == .OK else { return }
            let urls = painel.urls
            Task { @MainActor [weak self] in
                for url in urls {
                    self?.adicionar(url)
                }
            }
        }
    }

    func adicionar(_ url: URL) {
        let acessando = url.startAccessingSecurityScopedResource()
        defer {
            if acessando { url.stopAccessingSecurityScopedResource() }
        }

        do {
            var atualizados: [AnexoDeMidiaDaConversa] = []
            try MidiasDaConversa.copiar(
                url,
                para: pastaDaConversa,
                tituloDaConversa: tituloDaConversa,
                aposCopiar: { destino in
                    let anexo = try MidiasDaConversa.anexo(para: destino)
                    atualizados = anexos.filter { $0.url != anexo.url }
                    atualizados.append(anexo)
                    atualizados.sort { $0.data > $1.data }
                    try MidiasDaConversa.salvar(atualizados, para: arquivoID)
                }
            )
            anexos = atualizados
        } catch {
            erro = Self.mensagemAmigavel(error)
        }
    }

    func abrir(_ anexo: AnexoDeMidiaDaConversa) {
        AberturaDeMidia.abrir(anexo.url)
    }

    // MARK: - Remoção (vai para a lixeira)

    func remover(_ anexo: AnexoDeMidiaDaConversa) {
        if anexosDaGravacao.contains(where: { $0.id == anexo.id }) {
            removerAudioDaGravacao(anexo)
            return
        }

        let atualizados = anexos.filter { $0.id != anexo.id }
        do {
            // Vai para a lixeira em vez de sumir: o anexo pode ser a única
            // cópia que a pessoa tem, e ela pode ter clicado sem querer. A
            // lista de bookmarks é gravada dentro da própria operação: se
            // ela falhar, o arquivo volta ao caminho que a lista ainda usa.
            try moverParaLixeira(anexo, daGravacao: false) {
                try MidiasDaConversa.salvar(atualizados, para: arquivoID)
            }
            anexos = atualizados
            // Sem isto o cartão apagado só apareceria na próxima abertura da
            // aba: a lista de removidos é lida do disco, não deduzida daqui.
            recarregarLixeira()
        } catch {
            erro = "Não foi possível remover esse arquivo: %@".localized(error.localizedDescription)
        }
    }

    func restaurar(_ item: MidiaNaLixeira) {
        if LixeiraDeMidia.restaurar(item) {
            carregar()
        } else {
            erro = "Não foi possível restaurar %@.".localized(item.nome)
        }
    }

    func apagarDeVez(_ item: MidiaNaLixeira) {
        do {
            try LixeiraDeMidia.remover(item)
        } catch {
            erro = "Não foi possível apagar %@: %@".localized(item.nome, error.localizedDescription)
        }
        recarregarLixeira()
    }

    /// Remover o áudio cega a reprodução, então só liberamos depois que a
    /// transcrição existe — que é justamente quando o arquivo deixa de ser
    /// necessário. O arquivo vai para a lixeira, de onde volta se for o caso.
    private func removerAudioDaGravacao(_ anexo: AnexoDeMidiaDaConversa) {
        guard transcricaoDisponivel else {
            erro = "O áudio da gravação só pode ser removido depois que a transcrição terminar.".localized
            return
        }

        aoPausarReproducao?()

        do {
            try moverParaLixeira(anexo, daGravacao: true)
            anexosDaGravacao = gravacoes()
            recarregarLixeira()
        } catch {
            erro = "Não foi possível mover o áudio da gravação para a lixeira: %@".localized(error.localizedDescription)
        }
    }

    // MARK: - Apoio

    private func gravacoes() -> [AnexoDeMidiaDaConversa] {
        audiosDaGravacao
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { try? MidiasDaConversa.anexo(para: $0) }
    }

    private func recarregarLixeira() {
        naLixeira = LixeiraDeMidia.itens()
            .filter { $0.arquivoID == arquivoID }
            .sorted { $0.apagadoEm > $1.apagadoEm }
    }

    private func moverParaLixeira(
        _ anexo: AnexoDeMidiaDaConversa,
        daGravacao: Bool,
        aposMover: () throws -> Void = {}
    ) throws {
        try LixeiraDeMidia.mover(
            url: anexo.url,
            nome: anexo.nome,
            tamanho: anexo.tamanho,
            tipo: anexo.tipoVisual,
            daGravacao: daGravacao,
            arquivoID: arquivoID,
            conversaTitulo: tituloDaConversa,
            pastaDaConversa: pastaDaConversa,
            aposMover: aposMover
        )
    }

    /// O erro do Cocoa para "iPhone bloqueado" chega como um código genérico de
    /// arquivo ilegível, que não diz à pessoa o que fazer. Estes três casos
    /// cobrem o que aparece na prática ao arrastar mídia do celular.
    static func mensagemAmigavel(_ error: Error) -> String {
        let nsError = error as NSError
        let texto = "\(nsError.localizedDescription) \(nsError.localizedFailureReason ?? "")"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if texto.contains("iphone") || texto.contains("locked") || texto.contains("bloqueado") {
            return "Você precisa desbloquear seu iPhone antes de importar esse arquivo.".localized
        }
        if nsError.domain == NSCocoaErrorDomain && [257, 260, 513].contains(nsError.code) {
            return "Não consegui acessar esse arquivo. Se ele estiver no iPhone, desbloqueie o aparelho e tente importar de novo.".localized
        }
        return "Não foi possível guardar esse arquivo: %@".localized(error.localizedDescription)
    }
}
