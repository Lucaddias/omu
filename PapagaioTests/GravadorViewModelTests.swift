import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

// Regras do gravador que não dependem de microfone: o que é aceito em cada
// estado e o que nunca pode derrubar uma gravação em curso. O estado inicial é
// injetado; nenhuma sessão de áudio real é aberta.

@MainActor
private func gravadorDeTeste(_ estado: GravadorViewModel.Estado) throws -> (GravadorViewModel, URL) {
    let raiz = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    return (GravadorViewModel(armazenamento: Armazenamento(raiz: raiz), estadoInicial: estado), raiz)
}

// GV-05
@MainActor
@Test("Notas e marcadores são aceitos com a gravação pausada")
func notasDuranteAPausa() throws {
    let (gravador, raiz) = try gravadorDeTeste(.pausado)
    defer { try? FileManager.default.removeItem(at: raiz) }

    gravador.rascunhoDaNota = "  decidir o fornecedor  "
    gravador.adicionarNota()
    gravador.inserirMarcador()

    #expect(gravador.notasDaGravacao.map(\.texto) == ["decidir o fornecedor", "Marcador".localized])
    #expect(gravador.notasDaGravacao.map(\.tipo) == [.nota, .marcador])
    #expect(gravador.rascunhoDaNota.isEmpty)
}

@MainActor
@Test("Fora de uma gravação, nota e marcador continuam sem efeito")
func notasForaDaGravacao() throws {
    let (gravador, raiz) = try gravadorDeTeste(.ocioso)
    defer { try? FileManager.default.removeItem(at: raiz) }

    gravador.rascunhoDaNota = "solta"
    gravador.adicionarNota()
    gravador.inserirMarcador()

    #expect(gravador.notasDaGravacao.isEmpty)
    #expect(gravador.rascunhoDaNota == "solta")
}

// B-03
@MainActor
@Test("Importar durante a gravação é recusado sem mexer no estado dela", arguments: [
    GravadorViewModel.Estado.gravando, .pausado,
])
func importacaoNaoDerrubaGravacao(estado: GravadorViewModel.Estado) async throws {
    let (gravador, raiz) = try gravadorDeTeste(estado)
    defer { try? FileManager.default.removeItem(at: raiz) }

    var produzidos = 0
    gravador.aoProduzirAudio = { _, _, _, _, _, _ in produzidos += 1 }

    await gravador.importar(raiz.appendingPathComponent("qualquer.m4a"))

    #expect(gravador.estado == estado)
    #expect(gravador.gravando)
    #expect(!gravador.importando)
    #expect(produzidos == 0)
    #expect(gravador.avisos.count == 1)
    let gravacoes = raiz.appendingPathComponent(Armazenamento.pastaGravacoes)
    #expect(!FileManager.default.fileExists(atPath: gravacoes.path))
}

@MainActor
@Test("Importação que falha fora de uma gravação vira estado de falha legível")
func importacaoQueFalha() async throws {
    let (gravador, raiz) = try gravadorDeTeste(.ocioso)
    defer { try? FileManager.default.removeItem(at: raiz) }

    await gravador.importar(raiz.appendingPathComponent("inexistente.m4a"))

    guard case let .falhou(mensagem) = gravador.estado else {
        Issue.record("esperava falha, veio \(gravador.estado)")
        return
    }
    #expect(!mensagem.isEmpty)
    #expect(!gravador.importando)
}

// GV-04
@MainActor
@Test("Cancelar com confirmação só descarta quando a pessoa confirma")
func cancelamentoPedeConfirmacao() async throws {
    let (gravador, raiz) = try gravadorDeTeste(.gravando)
    defer { try? FileManager.default.removeItem(at: raiz) }

    var cancelamentos = 0
    var perguntas = 0
    gravador.aoCancelarGravacao = { cancelamentos += 1 }
    gravador.rascunhoDaNota = "nota em andamento"

    gravador.confirmarCancelamento = { perguntas += 1; return false }
    await gravador.cancelarComConfirmacao()
    #expect(perguntas == 1)
    #expect(cancelamentos == 0)
    #expect(gravador.estado == .gravando)
    #expect(gravador.rascunhoDaNota == "nota em andamento")

    gravador.confirmarCancelamento = { perguntas += 1; return true }
    await gravador.cancelarComConfirmacao()
    #expect(perguntas == 2)
    #expect(cancelamentos == 1)
    #expect(gravador.estado == .ocioso)
    #expect(gravador.rascunhoDaNota.isEmpty)
}

@MainActor
@Test("Sem gravação em curso, cancelar com confirmação nem pergunta")
func cancelamentoSemGravacao() async throws {
    let (gravador, raiz) = try gravadorDeTeste(.ocioso)
    defer { try? FileManager.default.removeItem(at: raiz) }

    var perguntas = 0
    gravador.confirmarCancelamento = { perguntas += 1; return true }
    await gravador.cancelarComConfirmacao()
    #expect(perguntas == 0)
}
