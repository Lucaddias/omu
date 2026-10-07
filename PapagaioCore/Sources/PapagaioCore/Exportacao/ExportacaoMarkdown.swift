import Foundation

/// Representação portátil de uma gravação para exportação.
///
/// A geração fica no Core para que o conteúdo exportado seja testável sem
/// SwiftUI. A escolha do destino e a cópia do anexo pertencem ao app, pois
/// passam pela autorização do usuário no sandbox.
/// O que só o app sabe sobre a conversa na hora de exportar: os nomes dados
/// às vozes, a ficha e o idioma da interface. Tudo isso vive fora do
/// `Arquivo`; sem estas opções o documento sai com os rótulos de canal, em
/// português.
public struct OpcoesDeExportacao {
    /// Traduz os rótulos fixos do documento ("Criado em", "Transcrição"…).
    public var traduzir: (String) -> String
    /// Rótulo acústico ("S1", "eu-S2") → nome exibido. `nil` mantém a
    /// transcrição por trecho, rotulada só pelo canal.
    public var nomeDeVoz: ((String) -> String)?
    /// Voz guardada para um trecho ou fala que perdeu as palavras numa
    /// correção manual.
    public var falantePreservado: (UUID) -> String?
    /// Linhas da ficha (participantes, descrição…), já com o rótulo traduzido.
    public var ficha: [(rotulo: String, valor: String)]

    public init(
        traduzir: @escaping (String) -> String = { $0 },
        nomeDeVoz: ((String) -> String)? = nil,
        falantePreservado: @escaping (UUID) -> String? = { _ in nil },
        ficha: [(rotulo: String, valor: String)] = []
    ) {
        self.traduzir = traduzir
        self.nomeDeVoz = nomeDeVoz
        self.falantePreservado = falantePreservado
        self.ficha = ficha
    }
}

public enum ExportacaoMarkdown {
    public static func gerar(arquivo: Arquivo, opcoes: OpcoesDeExportacao = OpcoesDeExportacao()) -> String {
        let t = opcoes.traduzir
        var linhas = ["# \(arquivo.resumo?.titulo ?? arquivo.titulo)", ""]
        linhas += [
            "- **\(t("Criado em")):** \(data(arquivo.criadoEm))",
            "- **\(t("Duração")):** \(duracao(arquivo.duracao))",
        ]
        linhas += opcoes.ficha
            .filter { !$0.valor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "- **\($0.rotulo):** \($0.valor)" }

        if let engine = arquivo.engineTranscricao {
            linhas.append("- **\(t("Transcrição")):** \(engine)")
        }
        if let engine = arquivo.engineResumo {
            linhas.append("- **\(t("Resumo")):** \(engine)")
        }

        if let resumo = arquivo.resumo {
            linhas += ["", "## \(t("Visão geral"))", "", resumo.visaoGeral]

            if !resumo.temas.isEmpty {
                linhas += ["", "## \(t("Temas"))", ""]
                linhas += resumo.temas.map { "- **\($0.titulo):** \($0.detalhe)" }
            }

            if !resumo.citacoes.isEmpty {
                linhas += ["", "## \(t("Citações"))", ""]
                linhas += resumo.citacoes.map { citacao in
                    let origem = [nomeDoFalante(citacao.speaker, t), citacao.start.map(tempo)]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    return origem.isEmpty
                        ? "> \(citacao.texto)"
                        : "> \(citacao.texto)  \n> — \(origem)"
                }
            }

            // Próximos passos não vira seção própria: no app eles já entram
            // como tarefas da conversa, e o documento espelha as seções da
            // tela (resumo, transcrição, notas, mídia, tarefas). Ter as duas
            // listas era o mesmo conteúdo escrito duas vezes.
        }

        if !arquivo.notas.isEmpty {
            linhas += ["", "## \(t("Notas"))", ""]
            linhas += arquivo.notas
                .enumerated()
                .sorted { esquerda, direita in
                    esquerda.element.start == direita.element.start
                        ? esquerda.offset < direita.offset
                        : esquerda.element.start < direita.element.start
                }
                .map { _, nota in
                    let tipo = nota.tipo == .marcador ? t("Marcador") : t("Nota")
                    let criticidade = nota.critica ? " · \(t("Crítica"))" : ""
                    let prefixo = "- **[\(tempo(nota.start)) · \(tipo)\(criticidade)]**"
                    return nota.texto.isEmpty ? prefixo : "\(prefixo) \(nota.texto)"
                }
        }

        if !arquivo.trechos.isEmpty {
            linhas += ["", "## \(t("Transcrição"))", ""]
            linhas += transcricao(de: arquivo.trechos, opcoes: opcoes)
        }

        linhas.append("")
        return linhas.joined(separator: "\n")
    }

    /// Uma linha por fala quando há vozes separadas e o app informou os nomes
    /// — é o que a pessoa vê na tela, com "Quem é quem?" aplicado. Sem isso,
    /// uma linha por trecho, rotulada pelo canal.
    private static func transcricao(de trechos: [Trecho], opcoes: OpcoesDeExportacao) -> [String] {
        func linha(inicio: TimeInterval, canal: String?, voz: String?, texto: String) -> String {
            let rotulo = [tempo(inicio), nomeDoFalante(canal, opcoes.traduzir), voz]
                .compactMap { $0 }
                .joined(separator: " · ")
            return "**[\(rotulo)]** \(texto)"
        }

        guard let nomeDeVoz = opcoes.nomeDeVoz else {
            return trechos.map { linha(inicio: $0.start, canal: $0.speaker, voz: nil, texto: $0.texto) }
        }
        guard let falas = FalasDaConversa.agrupar(trechos) else {
            return trechos.map { trecho in
                linha(
                    inicio: trecho.start,
                    canal: trecho.speaker,
                    voz: opcoes.falantePreservado(trecho.id).map(nomeDeVoz),
                    texto: trecho.texto
                )
            }
        }
        return falas.map { fala in
            let acustico = fala.falanteAcustico
                ?? opcoes.falantePreservado(fala.id)
                ?? fala.trechoIds.lazy.compactMap(opcoes.falantePreservado).first
            return linha(inicio: fala.inicio, canal: fala.speaker, voz: acustico.map(nomeDeVoz), texto: fala.texto)
        }
    }

    /// Nome previsível e seguro para o arquivo salvo no painel de exportação.
    public static func nomeDeArquivo(para arquivo: Arquivo) -> String {
        let base = (arquivo.resumo?.titulo ?? arquivo.titulo)
            .folding(options: [.diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "papagaio" : base.lowercased()) + ".md"
    }

    private static func data(_ data: Date) -> String {
        data.formatted(date: .long, time: .shortened)
    }

    private static func duracao(_ segundos: TimeInterval) -> String {
        // `Int(.nan)` e `Int(.infinity)` encerram o processo. Uma duração
        // indefinida (mídia sem duração conhecida) não pode fechar o app ao
        // compartilhar a conversa.
        let total = segundos.isFinite ? Int(min(max(0, segundos), 359_999)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func tempo(_ segundos: TimeInterval) -> String {
        duracao(segundos)
    }

    private static func nomeDoFalante(_ speaker: String?, _ traduzir: (String) -> String) -> String? {
        switch speaker {
        case Speaker.eu: traduzir("Eu")
        case Speaker.interlocutor: traduzir("Interlocutor")
        case let valor? where !valor.isEmpty: valor
        default: nil
        }
    }
}
