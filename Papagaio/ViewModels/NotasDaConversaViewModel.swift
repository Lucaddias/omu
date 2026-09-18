import Foundation
import Observation
import PapagaioCore

/// As notas de uma conversa: o texto livre, os marcadores de tempo e o
/// salvamento com espera.
///
/// A parte delicada aqui é a conciliação entre dois formatos. Durante a
/// gravação as anotações são salvas como notas separadas, cada uma com o seu
/// instante; na tela de detalhe elas viram um bloco de texto único. A migração
/// de um para o outro precisa ser idempotente, senão cada abertura da tela
/// duplicaria as linhas.
/// Formatação aplicada ao texto livre da nota.
///
/// Vive aqui porque só este view model a usa: a aba Notas passou a ser uma
/// linha do tempo de itens carimbados, e a barra de formatação que escrevia
/// markdown cru na tela saiu junto.
enum FormatoDeNota {
    case negrito
    case italico
    case lista
    case imagem
    case anexo
    case link
}

@MainActor
@Observable
final class NotasDaConversaViewModel {
    /// Marcadores mais a nota livre, no formato que o resto do app entende.
    private(set) var notas: [NotaDaConversa] = []
    var texto = ""
    var critica = false
    private(set) var estadoDeSalvamento = "Salvo"

    /// Quem de fato grava. É propriedade, e não parâmetro de `init`, porque a
    /// tela recebe este fechamento de fora e ele só existe depois de montada.
    var aoAtualizar: (([NotaDaConversa]) async -> Void)?

    var marcadores: [NotaDaConversa] {
        notas.filter { $0.tipo == .marcador }
    }

    private var notaLivreID: UUID?
    private var tarefaDeSalvamento: Task<Void, Never>?

    // MARK: - Conciliação com o arquivo

    func sincronizar(com notasDoArquivo: [NotaDaConversa]) {
        let marcadores = notasDoArquivo.filter { $0.tipo == .marcador }
        let notaLivre = notasDoArquivo.first { $0.tipo == .nota && $0.start == 0 }
        let anotacoesDaGravacao = notasDoArquivo
            .filter { $0.tipo == .nota && $0.start > 0 }
            .sorted { $0.start < $1.start }

        var textoInicial = notaLivre?.texto ?? ""
        var migrouAnotacoesDaGravacao = false

        if !anotacoesDaGravacao.isEmpty {
            let linhas = anotacoesDaGravacao.map(Self.linhaDeNotaGravada)
            // O `contains` é o que torna a migração idempotente: uma linha já
            // incorporada ao texto livre não entra de novo.
            let novasLinhas = linhas.filter { !textoInicial.contains($0) }
            if !novasLinhas.isEmpty {
                let separador = textoInicial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                textoInicial += "\(separador)\(novasLinhas.joined(separator: "\n"))"
                migrouAnotacoesDaGravacao = true
            }
        }

        texto = textoInicial
        critica = notaLivre?.critica ?? anotacoesDaGravacao.contains { $0.critica }
        notaLivreID = notaLivre?.id

        notas = marcadores

        if !textoInicial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notas.insert(
                NotaDaConversa(
                    id: notaLivre?.id ?? UUID(),
                    texto: textoInicial,
                    start: 0,
                    critica: critica,
                    tipo: .nota
                ),
                at: 0
            )
            notaLivreID = notas.first { $0.tipo == .nota && $0.start == 0 }?.id
        }

        if migrouAnotacoesDaGravacao {
            salvarAgora()
        }
    }

    private static func linhaDeNotaGravada(_ nota: NotaDaConversa) -> String {
        "[\(nota.start.comoRelogio)] \(nota.texto)"
    }

    // MARK: - Salvamento

    /// Espera 650 ms desde a última tecla antes de gravar, para não escrever a
    /// cada caractere digitado.
    func agendarSalvamento() {
        tarefaDeSalvamento?.cancel()
        estadoDeSalvamento = "Salvando..."
        tarefaDeSalvamento = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            salvarAgora()
        }
    }

    func salvarAgora() {
        let atualizadas = notasComTextoLivre()
        notaLivreID = atualizadas.first(where: { $0.tipo == .nota && $0.start == 0 })?.id
        notas = atualizadas
        estadoDeSalvamento = "Salvando..."

        Task { @MainActor in
            await aoAtualizar?(atualizadas)
            estadoDeSalvamento = "Salvo"
        }
    }

    /// Cancela a espera pendente e grava o que houver. A tela chama isto ao
    /// desaparecer, senão o último trecho digitado se perde.
    func encerrar() {
        tarefaDeSalvamento?.cancel()
        salvarAgora()
    }

    private func notasComTextoLivre() -> [NotaDaConversa] {
        var atualizadas = notas.filter { !($0.tipo == .nota && $0.start == 0) }
        let textoLimpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)

        if !textoLimpo.isEmpty {
            atualizadas.insert(
                NotaDaConversa(
                    id: notaLivreID ?? UUID(),
                    texto: texto,
                    start: 0,
                    critica: critica,
                    tipo: .nota
                ),
                at: 0
            )
        }

        return atualizadas.sorted {
            if $0.start == $1.start { return $0.id.uuidString < $1.id.uuidString }
            return $0.start < $1.start
        }
    }

    // MARK: - Edição

    func inserirMarcador(em instante: TimeInterval) {
        let marcador = NotaDaConversa(
            texto: "Marcador em \(instante.comoRelogio)",
            start: instante,
            critica: critica,
            tipo: .marcador
        )
        notas.append(marcador)
        salvarAgora()
    }

    func alternarCriticidade() {
        critica.toggle()
        salvarAgora()
    }

    func aplicarFormato(_ formato: FormatoDeNota) {
        switch formato {
        case .negrito: acrescentar("**" + "texto em destaque".localized + "**")
        case .italico: acrescentar("_" + "observação".localized + "_")
        case .lista: acrescentar("- " + "item da conversa".localized)
        case .imagem: acrescentar("![" + "descrição da imagem".localized + "](arquivo)")
        case .anexo: acrescentar("[" + "anexo".localized + "](arquivo)")
        case .link: acrescentar("[" + "link".localized + "](https://)")
        }
    }

    private func acrescentar(_ novoTexto: String) {
        let separador = texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        texto += "\(separador)\(novoTexto)"
    }
}
