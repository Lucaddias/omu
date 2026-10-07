import AppKit
import Foundation
import PapagaioCore

enum DossieDaConversa {
    static func gerar(arquivo: Arquivo) -> String {
        var texto = ExportacaoMarkdown.gerar(arquivo: arquivo, opcoes: opcoes(para: arquivo))

        let anexos = MidiasDaConversa.carregar(arquivo.id)
        if !anexos.isEmpty {
            texto += "\n## \("Mídia".localized)\n\n"
            texto += anexos
                .map { "- \($0.nome) — \($0.tipoVisual), \($0.data.formatted(date: .numeric, time: .omitted))" }
                .joined(separator: "\n")
            texto += "\n"
        }

        let tarefas = TarefasGeraisStore.carregar(arquivo)
        if !tarefas.isEmpty {
            texto += "\n## \("Tarefas".localized)\n\n"
            texto += tarefas.map(linhaDaTarefa).joined(separator: "\n")
            texto += "\n"
        }

        return texto
    }

    /// O documento leva o que a tela mostra: as vozes com os nomes de "Quem
    /// é quem?", a ficha da conversa e os rótulos no idioma do app.
    static func opcoes(para arquivo: Arquivo) -> OpcoesDeExportacao {
        let nomes = PreferenciasVisuaisDoArquivo.nomesDeVoz(arquivo.id)
        let ficha = PreferenciasVisuaisDoArquivo.metadados(arquivo.id)
        func pessoas(_ texto: String) -> String {
            texto.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return OpcoesDeExportacao(
            traduzir: { $0.localized },
            nomeDeVoz: { RotuloDeVoz.exibicao($0, nomes: nomes) },
            falantePreservado: { FalantePreservadoParaTrecho.obter(para: $0, arquivo: arquivo.id) },
            ficha: [
                ("Entrevistados".localized, pessoas(ficha.entrevistado)),
                ("Entrevistadores".localized, pessoas(ficha.entrevistadores)),
                ("Modalidade".localized, ficha.formato.isEmpty ? "" : ficha.formato.localized),
                ("Descrição".localized, ficha.descricao.replacingOccurrences(of: "\n", with: " ")),
            ]
        )
    }

    static func nomeDeArquivo(para arquivo: Arquivo) -> String {
        ExportacaoMarkdown.nomeDeArquivo(para: arquivo)
    }

    /// Escreve o fallback Markdown numa raiz temporária exclusiva, para que o
    /// mesmo ciclo de vida dos ZIPs consiga descartá-lo depois do
    /// compartilhamento.
    static func markdownTemporario(arquivo: Arquivo) throws -> URL {
        let fm = FileManager.default
        let raiz = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destino = raiz.appendingPathComponent(nomeDeArquivo(para: arquivo))
        do {
            try fm.createDirectory(at: raiz, withIntermediateDirectories: true)
            try gerar(arquivo: arquivo).write(to: destino, atomically: true, encoding: .utf8)
            return destino
        } catch {
            try? fm.removeItem(at: raiz)
            throw error
        }
    }

    /// Monta um `.zip` com o documento e o áudio da conversa.
    ///
    /// Zip, e não pasta: pasta solta não se anexa em e-mail nem em mensagem.
    /// A compactação sai do `NSFileCoordinator` com a opção `.forUploading`,
    /// que é a mesma coisa que o Finder faz em "Comprimir" — sem dependência
    /// externa e sem escrever um compactador à mão.
    static func pacoteComAudio(arquivo: Arquivo, audioPrincipal: URL) throws -> URL {
        let base = nomeDeArquivo(para: arquivo).replacingOccurrences(of: ".md", with: "")
        let fm = FileManager.default
        let raizDoPacote = fm.temporaryDirectory
            .appendingPathComponent("\(base)-\(UUID().uuidString)", isDirectory: true)
        let pasta = raizDoPacote
            .appendingPathComponent(base, isDirectory: true)
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        // O zip de saída é independente da pasta montada aqui. Esta cópia
        // intermediária pode conter horas de áudio e antes ficava no tmp a
        // cada exportação, mesmo quando tudo dava certo.
        defer { try? fm.removeItem(at: raizDoPacote) }

        try gerar(arquivo: arquivo)
            .write(to: pasta.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)

        // O canal do sistema viaja junto quando existe: sem ele, uma gravação
        // de dois canais chegaria pela metade.
        let candidatos = [
            audioPrincipal,
            audioPrincipal.deletingLastPathComponent().appendingPathComponent(Armazenamento.Nome.sistema),
            audioPrincipal.deletingLastPathComponent().appendingPathComponent(Armazenamento.Nome.sistemaM4ALegado),
        ]
        var audiosCopiados = Set<String>()
        for origem in candidatos
        where FileManager.default.fileExists(atPath: origem.path)
            && audiosCopiados.insert(origem.standardizedFileURL.path).inserted {
            try FileManager.default.copyItem(
                at: origem,
                to: pasta.appendingPathComponent(origem.lastPathComponent)
            )
        }

        // Duas variáveis de erro, e não uma: `&erroDoCoordenador` já está em
        // acesso exclusivo durante a chamada, então escrever nela de dentro do
        // bloco seria acesso sobreposto — o compilador barra.
        var erroDoCoordenador: NSError?
        var erroDaCopia: Error?
        var destino: URL?
        var pastaDeSaida: URL?

        NSFileCoordinator().coordinate(
            readingItemAt: pasta,
            options: [.forUploading],
            error: &erroDoCoordenador
        ) { zipTemporario in
            let pasta = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            pastaDeSaida = pasta
            let alvo = pasta
                .appendingPathComponent("\(base).zip")
            do {
                try FileManager.default.createDirectory(
                    at: pasta, withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: zipTemporario, to: alvo)
                destino = alvo
            } catch {
                erroDaCopia = error
            }
        }

        if let erroDoCoordenador {
            if let pastaDeSaida { try? fm.removeItem(at: pastaDeSaida) }
            throw erroDoCoordenador
        }
        if let erroDaCopia {
            if let pastaDeSaida { try? fm.removeItem(at: pastaDeSaida) }
            throw erroDaCopia
        }
        guard let destino else { throw CocoaError(.fileWriteUnknown) }
        return destino
    }

    /// Uma pasta com **tudo** de cada conversa: documento, áudios e anexos.
    ///
    /// Compartilhar uma pasta é compartilhar o projeto inteiro — mandar só os
    /// documentos deixaria de fora justamente as fotos, os PDFs e o áudio que
    /// alguém anexou ali de propósito. Uma subpasta por conversa, com o nome
    /// dela, porque dez arquivos `microfone.wav` no mesmo nível não se
    /// distinguem.
    static func pastaComTudo(
        nome: String,
        conversas: [(arquivo: Arquivo, audio: URL)]
    ) throws -> URL {
        let fm = FileManager.default
        let nomeSeguro = NomeDeArquivoSeguro.gerar(de: nome)
        let raiz = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(nomeSeguro, isDirectory: true)
        try fm.createDirectory(at: raiz, withIntermediateDirectories: true)

        do {
            for (arquivo, audio) in conversas {
                let base = nomeDeArquivo(para: arquivo).replacingOccurrences(of: ".md", with: "")
                let pastaDaConversa = pastaDisponivel(nome: base, em: raiz)
                try fm.createDirectory(at: pastaDaConversa, withIntermediateDirectories: true)

                try gerar(arquivo: arquivo).write(
                    to: pastaDaConversa.appendingPathComponent("\(base).md"),
                    atomically: true,
                    encoding: .utf8
                )

                // Os dois canais quando existem: uma gravação de microfone e
                // sistema chegaria pela metade só com o principal.
                let audios = [
                    audio,
                    audio.deletingLastPathComponent().appendingPathComponent(Armazenamento.Nome.sistema),
                    audio.deletingLastPathComponent().appendingPathComponent(Armazenamento.Nome.sistemaM4ALegado),
                ]
                var audiosCopiados = Set<String>()
                for origem in audios
                where fm.fileExists(atPath: origem.path)
                    && audiosCopiados.insert(origem.standardizedFileURL.path).inserted {
                    try fm.copyItem(
                        at: origem,
                        to: pastaDaConversa.appendingPathComponent(origem.lastPathComponent)
                    )
                }

                let anexos = MidiasDaConversa.carregar(arquivo.id)
                guard !anexos.isEmpty else { continue }
                let pastaDeMidia = pastaDaConversa.appendingPathComponent("Mídia", isDirectory: true)
                try fm.createDirectory(at: pastaDeMidia, withIntermediateDirectories: true)
                for anexo in anexos where fm.fileExists(atPath: anexo.url.path) {
                    let acesso = anexo.url.startAccessingSecurityScopedResource()
                    defer { if acesso { anexo.url.stopAccessingSecurityScopedResource() } }
                    try fm.copyItem(
                        at: anexo.url,
                        to: pastaDeMidia.appendingPathComponent(anexo.nome)
                    )
                }
            }

            return raiz
        } catch {
            // Não devolvemos pacote parcial e tampouco o abandonamos no tmp.
            try? fm.removeItem(at: raiz.deletingLastPathComponent())
            throw error
        }
    }

    /// Descarta a raiz temporária criada por `pastaComTudo`. A validação
    /// impede que uma URL externa ou a própria pasta temporária do sistema
    /// seja removida por engano.
    static func descartarPastaTemporaria(_ pasta: URL) {
        let fm = FileManager.default
        let temporario = fm.temporaryDirectory.standardizedFileURL
        let raizDoPacote = pasta.deletingLastPathComponent().standardizedFileURL
        let componentesTemporarios = temporario.pathComponents
        guard raizDoPacote.pathComponents.starts(with: componentesTemporarios),
              raizDoPacote.pathComponents.count == componentesTemporarios.count + 1
        else { return }
        try? fm.removeItem(at: raizDoPacote)
    }

    /// Descarta o zip temporário produzido para uma exportação direta. O
    /// arquivo só é seguro de remover depois que a cópia para o destino da
    /// pessoa terminou; compartilhamentos continuam responsáveis por mantê-lo
    /// enquanto o serviço do macOS o consome.
    static func descartarArquivoTemporario(_ arquivo: URL) {
        let fm = FileManager.default
        let temporario = fm.temporaryDirectory.standardizedFileURL
        let raizDoPacote = arquivo.deletingLastPathComponent().standardizedFileURL
        let componentesTemporarios = temporario.pathComponents
        guard raizDoPacote.pathComponents.starts(with: componentesTemporarios),
              raizDoPacote.pathComponents.count == componentesTemporarios.count + 1
        else { return }
        try? fm.removeItem(at: raizDoPacote)
    }

    /// Compacta uma pasta, do mesmo jeito que o "Comprimir" do Finder.
    ///
    /// Zip porque pasta solta não se anexa em e-mail nem em mensagem.
    static func zipar(_ pasta: URL) throws -> URL {
        let fm = FileManager.default
        let nomeDoArquivo = pasta.lastPathComponent
        var erroDoCoordenador: NSError?
        var erroDaCopia: Error?
        var destino: URL?
        var pastaDeSaida: URL?

        NSFileCoordinator().coordinate(
            readingItemAt: pasta,
            options: [.forUploading],
            error: &erroDoCoordenador
        ) { zipTemporario in
            let pasta = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            pastaDeSaida = pasta
            let alvo = pasta
                .appendingPathComponent("\(nomeDoArquivo).zip")
            do {
                try fm.createDirectory(
                    at: pasta, withIntermediateDirectories: true
                )
                try fm.copyItem(at: zipTemporario, to: alvo)
                destino = alvo
            } catch {
                erroDaCopia = error
            }
        }

        if let erroDoCoordenador {
            if let pastaDeSaida { try? fm.removeItem(at: pastaDeSaida) }
            throw erroDoCoordenador
        }
        if let erroDaCopia {
            if let pastaDeSaida { try? fm.removeItem(at: pastaDeSaida) }
            throw erroDaCopia
        }
        guard let destino else { throw CocoaError(.fileWriteUnknown) }
        return destino
    }

    private static func pastaDisponivel(nome: String, em raiz: URL) -> URL {
        let fm = FileManager.default
        var candidato = raiz.appendingPathComponent(nome, isDirectory: true)
        var indice = 2
        while fm.fileExists(atPath: candidato.path) {
            candidato = raiz.appendingPathComponent("\(nome) \(indice)", isDirectory: true)
            indice += 1
        }
        return candidato
    }

    private static func linhaDaTarefa(_ tarefa: TarefaDaConversa) -> String {
        let marca = tarefa.status == .concluida ? "x" : " "
        var detalhes = [tarefa.prioridade.rawValue]
        if let responsavel = tarefa.responsavel, !responsavel.isEmpty {
            detalhes.append(responsavel)
        }
        if let prazo = tarefa.prazo {
            detalhes.append("até \(prazo.formatted(date: .numeric, time: .omitted))")
        }
        return "- [\(marca)] \(tarefa.titulo) — \(detalhes.joined(separator: " · "))"
    }
}
