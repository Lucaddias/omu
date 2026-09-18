import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

@MainActor
private func cenarioDeLixeiraDeMidia() throws -> (Armazenamento, URL, UserDefaults, String) {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)

    let suite = "LixeiraDeMidiaTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (Armazenamento(raiz: raiz), raiz, defaults, suite)
}

@MainActor
@Test("Apagar anexo da lixeira remove arquivo e registro juntos")
func apagarAnexoDaLixeiraMantemDiscoERegistroEmSincronia() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("anexo.txt")
    try Data("conteúdo".utf8).write(to: origem)

    let arquivoID = ArquivoID()
    try LixeiraDeMidia.mover(
        url: origem,
        nome: "anexo.txt",
        tamanho: 8,
        tipo: "Documento",
        daGravacao: false,
        arquivoID: arquivoID,
        conversaTitulo: "Conversa",
        pastaDaConversa: conversa,
        em: defaults
    )
    let item = try #require(LixeiraDeMidia.itens(em: defaults).first)

    try LixeiraDeMidia.remover(item, em: defaults, armazenamento: armazenamento)

    #expect(!FileManager.default.fileExists(atPath: item.caminhoNaLixeira))
    #expect(LixeiraDeMidia.itens(em: defaults).isEmpty)
}

@MainActor
@Test("Lixeira não move arquivo externo mesmo com bookmark inválido")
func moverParaLixeiraRecusaArquivoForaDaConversa() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let externo = raiz.appendingPathComponent("fora.txt")
    try Data("preservar".utf8).write(to: externo)

    #expect(throws: LixeiraDeMidia.Erro.self) {
        try LixeiraDeMidia.mover(
            url: externo, nome: "fora.txt", tamanho: 9, tipo: "Documento",
            daGravacao: false, arquivoID: ArquivoID(), conversaTitulo: "Conversa",
            pastaDaConversa: conversa, em: defaults
        )
    }
    #expect(FileManager.default.fileExists(atPath: externo.path))
    #expect(LixeiraDeMidia.itens(em: defaults).isEmpty)
}

@MainActor
@Test("Falha ao atualizar a conversa desfaz o movimento para a lixeira")
func moverParaLixeiraDesfazQuandoPersistenciaDaConversaFalha() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("anexo.txt")
    try Data("conteúdo".utf8).write(to: origem)

    struct FalhaDePersistencia: Error {}
    #expect(throws: FalhaDePersistencia.self) {
        try LixeiraDeMidia.mover(
            url: origem,
            nome: "anexo.txt",
            tamanho: 8,
            tipo: "Documento",
            daGravacao: false,
            arquivoID: ArquivoID(),
            conversaTitulo: "Conversa",
            pastaDaConversa: conversa,
            em: defaults,
            aposMover: { throw FalhaDePersistencia() }
        )
    }

    #expect(FileManager.default.fileExists(atPath: origem.path))
    #expect(LixeiraDeMidia.itens(em: defaults).isEmpty)
}

@MainActor
@Test("Restaurar anexo recria seu bookmark e o mantém visível na conversa")
func restaurarAnexoDaLixeiraRecriaRegistroDaConversa() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("anexo.txt")
    try Data("conteúdo".utf8).write(to: origem)

    let arquivoID = ArquivoID()
    try LixeiraDeMidia.mover(
        url: origem,
        nome: "anexo.txt",
        tamanho: 8,
        tipo: "Documento",
        daGravacao: false,
        arquivoID: arquivoID,
        conversaTitulo: "Conversa",
        pastaDaConversa: conversa,
        em: defaults
    )
    let item = try #require(LixeiraDeMidia.itens(em: defaults).first)

    #expect(LixeiraDeMidia.restaurar(item, em: defaults, armazenamento: armazenamento))

    #expect(FileManager.default.fileExists(atPath: origem.path))
    #expect(LixeiraDeMidia.itens(em: defaults).isEmpty)
    #expect(MidiasDaConversa.carregar(arquivoID, em: defaults).map(\.url.standardizedFileURL) == [origem.standardizedFileURL])
    #expect(MidiasDaConversa.carregar(arquivoID).isEmpty)
    MidiasDaConversa.remover(arquivoID)
}

@MainActor
@Test("Lixeira recusa apagar caminho externo e mantém o registro para revisão")
func lixeiraDeMidiaRecusaCaminhoExterno() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let externo = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("não apagar".utf8).write(to: externo)
    defer { try? FileManager.default.removeItem(at: externo) }

    let item = MidiaNaLixeira(
        arquivoID: ArquivoID(),
        conversaTitulo: "externa",
        nome: externo.lastPathComponent,
        tamanho: 10,
        tipo: "Documento",
        daGravacao: false,
        caminhoOriginal: externo.path,
        caminhoNaLixeira: externo.path
    )
    let dados = try JSONEncoder().encode([item])
    defaults.set(dados, forKey: "midiaNaLixeira")

    #expect(throws: LixeiraDeMidia.Erro.self) {
        try LixeiraDeMidia.remover(item, em: defaults, armazenamento: armazenamento)
    }
    #expect(FileManager.default.fileExists(atPath: externo.path))
    #expect(LixeiraDeMidia.itens(em: defaults).map(\.id) == [item.id])
}

@MainActor
@Test("Restaurar com nome ocupado preserva os dois arquivos e o registro na lixeira")
func restaurarMidiaComColisaoNaoApagaConteudo() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    let arquivoID = ArquivoID()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
        MidiasDaConversa.remover(arquivoID)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("anexo.txt")
    let conteudoOriginal = Data("primeiro anexo".utf8)
    let conteudoNovo = Data("outro anexo com o mesmo nome".utf8)
    try conteudoOriginal.write(to: origem)
    try LixeiraDeMidia.mover(
        url: origem,
        nome: "anexo.txt",
        tamanho: Int64(conteudoOriginal.count),
        tipo: "Documento",
        daGravacao: false,
        arquivoID: arquivoID,
        conversaTitulo: "Conversa",
        pastaDaConversa: conversa,
        em: defaults
    )
    let item = try #require(LixeiraDeMidia.itens(em: defaults).first)
    try conteudoNovo.write(to: origem)

    #expect(!LixeiraDeMidia.restaurar(item, em: defaults, armazenamento: armazenamento))

    #expect(try Data(contentsOf: origem) == conteudoNovo)
    let naLixeira = URL(fileURLWithPath: item.caminhoNaLixeira)
    #expect(try Data(contentsOf: naLixeira) == conteudoOriginal)
    #expect(LixeiraDeMidia.itens(em: defaults).map(\.id) == [item.id])
    #expect(MidiasDaConversa.carregar(arquivoID).isEmpty)
}

@MainActor
@Test("Restauração recusa registro que aponta a origem para a própria lixeira")
func lixeiraDeMidiaNaoApagaArquivoQuandoOrigemCorrompidaApontaParaLixeira() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("anexo.txt")
    try Data("preservar".utf8).write(to: origem)

    try LixeiraDeMidia.mover(
        url: origem,
        nome: "anexo.txt",
        tamanho: 9,
        tipo: "Documento",
        daGravacao: false,
        arquivoID: ArquivoID(),
        conversaTitulo: "Conversa",
        pastaDaConversa: conversa,
        em: defaults
    )
    let valido = try #require(LixeiraDeMidia.itens(em: defaults).first)
    let corrompido = MidiaNaLixeira(
        id: valido.id,
        arquivoID: valido.arquivoID,
        conversaTitulo: valido.conversaTitulo,
        nome: valido.nome,
        tamanho: valido.tamanho,
        tipo: valido.tipo,
        daGravacao: valido.daGravacao,
        caminhoOriginal: valido.caminhoNaLixeira,
        caminhoNaLixeira: valido.caminhoNaLixeira,
        apagadoEm: valido.apagadoEm
    )
    defaults.set(try JSONEncoder().encode([corrompido]), forKey: "midiaNaLixeira")

    #expect(!LixeiraDeMidia.restaurar(corrompido, em: defaults, armazenamento: armazenamento))
    #expect(FileManager.default.fileExists(atPath: valido.caminhoNaLixeira))
    #expect(LixeiraDeMidia.itens(em: defaults).map(\.id) == [corrompido.id])
}

@MainActor
@Test("Esvaziar preserva apenas anexos que não puderam ser removidos")
func esvaziarLixeiraDeMidiaPreservaFalhas() throws {
    let (armazenamento, raiz, defaults, suite) = try cenarioDeLixeiraDeMidia()
    defer {
        try? FileManager.default.removeItem(at: raiz)
        defaults.removePersistentDomain(forName: suite)
    }

    let conversa = armazenamento.raiz
        .appendingPathComponent(Armazenamento.pastaGravacoes, isDirectory: true)
        .appendingPathComponent("Conversa", isDirectory: true)
    try FileManager.default.createDirectory(at: conversa, withIntermediateDirectories: true)
    let origem = conversa.appendingPathComponent("valido.txt")
    try Data("válido".utf8).write(to: origem)
    try LixeiraDeMidia.mover(
        url: origem,
        nome: "valido.txt",
        tamanho: 6,
        tipo: "Documento",
        daGravacao: false,
        arquivoID: ArquivoID(),
        conversaTitulo: "Conversa",
        pastaDaConversa: conversa,
        em: defaults
    )
    let valido = try #require(LixeiraDeMidia.itens(em: defaults).first)

    let externo = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("não apagar".utf8).write(to: externo)
    defer { try? FileManager.default.removeItem(at: externo) }
    let invalido = MidiaNaLixeira(
        arquivoID: ArquivoID(),
        conversaTitulo: "externa",
        nome: externo.lastPathComponent,
        tamanho: 10,
        tipo: "Documento",
        daGravacao: false,
        caminhoOriginal: externo.path,
        caminhoNaLixeira: externo.path
    )
    defaults.set(try JSONEncoder().encode([valido, invalido]), forKey: "midiaNaLixeira")

    #expect(throws: LixeiraDeMidia.Erro.self) {
        try LixeiraDeMidia.esvaziar(em: defaults, armazenamento: armazenamento)
    }
    #expect(!FileManager.default.fileExists(atPath: valido.caminhoNaLixeira))
    #expect(FileManager.default.fileExists(atPath: externo.path))
    #expect(LixeiraDeMidia.itens(em: defaults).map(\.id) == [invalido.id])
}
