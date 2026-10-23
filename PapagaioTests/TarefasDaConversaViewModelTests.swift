import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

// A regra de prazo e o ciclo de vida das tarefas viviam duplicados dentro da
// `ArquivoDetalheView` — e, por isso, sem teste nenhum. Com a migração para o
// `TarefasDaConversaViewModel` (que já existia e ninguém usava), as decisões
// de domínio ficam aqui, exercitáveis sem montar a tela.
//
// Os testes usam um `ArquivoID` aleatório e não tocam nas tarefas reais do
// usuário: cada um escreve só na própria chave de `UserDefaults`.

@MainActor
private func viewModelLimpo() -> TarefasDaConversaViewModel {
    TarefasDaConversaViewModel(arquivoID: ArquivoID())
}

@MainActor
@Test("Prazo a dois dias ou menos promove a tarefa a prioridade alta")
func prazoCurtoPromovePrioridade() {
    let vm = viewModelLimpo()
    vm.tituloDaTarefa = "Entregar proposta"
    vm.prazoDaTarefa = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    vm.adicionar(origem: "Reunião")

    #expect(vm.tarefas.count == 1)
    #expect(vm.tarefas.first?.prioridade == .alta)
}

@MainActor
@Test("Prazo folgado mantém a prioridade escolhida")
func prazoFolgadoMantemPrioridade() {
    let vm = viewModelLimpo()
    vm.tituloDaTarefa = "Revisar contrato"
    vm.prazoDaTarefa = Calendar.current.date(byAdding: .day, value: 10, to: Date()) ?? Date()

    vm.adicionar(origem: "Reunião")

    #expect(vm.tarefas.first?.prioridade == .media)
}

@MainActor
@Test("Concluída não sobe de prioridade mesmo com prazo estourado")
func concluidaNaoSobePorPrazo() {
    let vm = viewModelLimpo()
    vm.tituloDaTarefa = "Já feita"
    vm.statusDaTarefa = .concluida
    vm.prazoDaTarefa = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()

    vm.adicionar(origem: "Reunião")

    #expect(vm.tarefas.first?.prioridade == .media)
    #expect(vm.tarefas.first?.status == .concluida)
}

@MainActor
@Test("Primeira carga cria tarefas dos próximos passos do resumo")
func cargaCriaBaseDosProximosPassos() {
    let vm = viewModelLimpo()
    let passos = [
        ProximoPasso(descricao: "Fechar o contrato", responsavel: "Luca"),
        ProximoPasso(descricao: "Enviar minuta", responsavel: nil),
        ProximoPasso(descricao: "Agendar assinatura", responsavel: nil),
    ]

    vm.carregar(base: passos, tituloDaConversa: "Kickoff", dataDaConversa: Date())

    #expect(vm.tarefas.count == 3)
    // O resumo não informa prazo nem prioridade: nada é inventado.
    #expect(vm.tarefas.allSatisfy { $0.prioridade == .media })
    #expect(vm.tarefas.allSatisfy { $0.prazo == nil })
    #expect(vm.tarefas.allSatisfy { $0.status == .naoIniciado })
    #expect(vm.tarefas.allSatisfy { $0.origem == "Kickoff" })
}

@MainActor
@Test("Abrir a conversa antes do resumo não impede as sugestões depois")
func sugestoesChegamDepoisDoResumo() {
    let arquivoID = ArquivoID()
    defer { TarefasDaConversa.remover(arquivoID) }
    let antes = TarefasDaConversaViewModel(arquivoID: arquivoID)
    antes.carregar(base: [], tituloDaConversa: "Kickoff", dataDaConversa: Date())
    #expect(antes.tarefas.isEmpty)
    // Uma tarefa escrita à mão enquanto a conversa transcreve.
    antes.tituloDaTarefa = "Criada à mão"
    antes.adicionar(origem: "Kickoff")

    let depois = TarefasDaConversaViewModel(arquivoID: arquivoID)
    depois.carregar(
        base: [ProximoPasso(descricao: "Enviar minuta", responsavel: nil)],
        tituloDaConversa: "Kickoff",
        dataDaConversa: Date()
    )

    #expect(depois.tarefas.map(\.titulo) == ["Criada à mão", "Enviar minuta"])
    #expect(depois.sugestoes.map(\.titulo) == ["Enviar minuta"])
}

@MainActor
@Test("Resumo novo acrescenta só os passos inéditos e não ressuscita os descartados")
func resumoNovoAcrescentaSoPassosIneditos() throws {
    let arquivoID = ArquivoID()
    defer { TarefasDaConversa.remover(arquivoID) }
    let primeiro = [
        ProximoPasso(descricao: "Fechar o contrato", responsavel: nil),
        ProximoPasso(descricao: "Enviar minuta", responsavel: nil),
    ]
    let vm = TarefasDaConversaViewModel(arquivoID: arquivoID)
    vm.carregar(base: primeiro, tituloDaConversa: "Kickoff", dataDaConversa: Date())
    let descartada = try #require(vm.tarefas.first { $0.titulo == "Enviar minuta" })
    vm.rejeitarSugestao(descartada)

    let outra = TarefasDaConversaViewModel(arquivoID: arquivoID)
    outra.carregar(
        base: primeiro + [ProximoPasso(descricao: "Agendar assinatura", responsavel: nil)],
        tituloDaConversa: "Kickoff",
        dataDaConversa: Date()
    )

    #expect(outra.tarefas.map(\.titulo) == ["Fechar o contrato", "Agendar assinatura"])
}

@MainActor
@Test("Editar o título de uma tarefa sem prazo não inventa um prazo")
func edicaoNaoInventaPrazo() throws {
    let arquivoID = ArquivoID()
    defer { TarefasDaConversa.remover(arquivoID) }
    let vm = TarefasDaConversaViewModel(arquivoID: arquivoID)
    vm.carregar(
        base: [ProximoPasso(descricao: "Enviar minuta", responsavel: nil)],
        tituloDaConversa: "Kickoff",
        dataDaConversa: Date()
    )
    let sugestao = try #require(vm.tarefas.first)

    vm.iniciarEdicao(sugestao)
    vm.tituloDaTarefa = "Enviar a minuta revisada"
    vm.salvarEdicao()

    #expect(vm.tarefas.first?.titulo == "Enviar a minuta revisada")
    #expect(vm.tarefas.first?.prazo == nil)
}

@MainActor
@Test("Recarga devolve o que foi salvo, sem duplicar a base")
func recargaNaoDuplica() {
    let arquivoID = ArquivoID()
    let vm = TarefasDaConversaViewModel(arquivoID: arquivoID)
    vm.tituloDaTarefa = "Criada à mão"
    vm.adicionar(origem: "Reunião")

    let outra = TarefasDaConversaViewModel(arquivoID: arquivoID)
    outra.carregar(
        base: [ProximoPasso(descricao: "Da base", responsavel: nil)],
        tituloDaConversa: "Reunião",
        dataDaConversa: Date()
    )

    // Já havia tarefas salvas: a base do resumo não entra de novo.
    #expect(outra.tarefas.map(\.titulo) == ["Criada à mão"])
}

@Test("Responsáveis vêm da ficha local com nomes e e-mails pareados")
func responsaveisVemDaFicha() {
    let metadados = MetadadosVisuaisDoArquivo(
        entrevistado: "Ana Silva",
        emailDoEntrevistado: "ana@empresa.com",
        entrevistadores: "João Lima\nMaria Souza",
        emailDosEntrevistadores: "joao@empresa.com\n",
        descricao: "",
        formato: "",
        participantes: 3
    )

    let pessoas = ResponsavelDaTarefa.disponiveis(em: metadados)

    #expect(pessoas.map(\.nome) == ["João Lima", "Maria Souza", "Ana Silva"])
    #expect(pessoas.map(\.email) == ["joao@empresa.com", "", "ana@empresa.com"])
    #expect(Set(pessoas.map(\.id)).count == 3)
}

@Test("Responsáveis repetidos na ficha aparecem uma única vez")
func responsaveisDaFichaNaoDuplicam() {
    let metadados = MetadadosVisuaisDoArquivo(
        entrevistado: "Ána Silva",
        emailDoEntrevistado: "",
        entrevistadores: "ana silva\nPessoa sem nome",
        emailDosEntrevistadores: "\ncontato@empresa.com",
        descricao: "",
        formato: "",
        participantes: nil
    )

    let pessoas = ResponsavelDaTarefa.disponiveis(em: metadados)

    #expect(pessoas.count == 2)
    #expect(pessoas[0].nome == "ana silva")
    #expect(pessoas[1].email == "contato@empresa.com")
}

@Test("Rótulo de canal não vira responsável da tarefa (S-08)")
func rotuloDeCanalNaoEhResponsavel() {
    for rotulo in ["interlocutor", "(interlocutor)", "Desconhecido", "(desconhecido)", "null", "N/A", "  "] {
        #expect(TarefaDaConversa.responsavelSaneado(rotulo) == nil, "\(rotulo) não é uma pessoa")
    }
    // O canal do microfone é a própria pessoa.
    #expect(TarefaDaConversa.responsavelSaneado("eu") == "Eu".localized)
    #expect(TarefaDaConversa.responsavelSaneado("(eu)") == "Eu".localized)
    // Nome de verdade passa como veio.
    #expect(TarefaDaConversa.responsavelSaneado(" Ana Souza ") == "Ana Souza")
}
