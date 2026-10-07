import AppKit
import CloudKit
import Foundation
import PapagaioCore
import Testing
@testable import Papagaio

/// Testes que falam com o CloudKit real, no ambiente de desenvolvimento do
/// container. Ficam desligados por padrão; para rodar, com iCloud logado:
///
///     TEST_RUNNER_OMU_CLOUDKIT_AO_VIVO=1 xcodebuild test -project Loro.xcodeproj \
///         -scheme Loro -destination 'platform=macOS,arch=arm64' \
///         -only-testing:PapagaioTests/EquipesCloudKitAoVivoTests
///
/// Cobrem o lado do proprietário. Aceite por outra Apple Account, leitura e
/// escrita como participante e remoção de membros exigem uma segunda conta e
/// continuam sendo verificação manual.
private let cloudKitAoVivo = ProcessInfo.processInfo.environment["OMU_CLOUDKIT_AO_VIVO"] == "1"

private let prefixoDeTeste = "teste-aovivo-"

private func registrar(_ texto: String) {
    print("[AOVIVO] \(texto)")
}

private enum ErroAoVivo: Error {
    case tempoEsgotado(Double)
}

private final class RetomadaUnica<T: Sendable>: @unchecked Sendable {
    private let trava = NSLock()
    private var continuacao: CheckedContinuation<T, any Error>?

    init(_ continuacao: CheckedContinuation<T, any Error>) { self.continuacao = continuacao }

    func retomar(_ resultado: Result<T, any Error>) {
        trava.lock()
        let pendente = continuacao
        continuacao = nil
        trava.unlock()
        pendente?.resume(with: resultado)
    }
}

/// Uma chamada do CloudKit que nunca responde não pode prender a suíte: foi
/// exatamente assim que a baixa de conversas falhava fora do primeiro plano.
private func comLimite<T: Sendable>(
    _ segundos: Double,
    _ corpo: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuacao in
        let unica = RetomadaUnica(continuacao)
        Task {
            do { unica.retomar(.success(try await corpo())) } catch { unica.retomar(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(segundos))
            unica.retomar(.failure(ErroAoVivo.tempoEsgotado(segundos)))
        }
    }
}

@Suite("CloudKit ao vivo", .enabled(if: cloudKitAoVivo), .serialized)
struct EquipesCloudKitAoVivoTests {
    let container = CKContainer(identifier: ServicoDeEquipesCloudKit.identificadorDoContainer)

    @Test("Ciclo de vida de uma equipe pelo proprietário")
    func cicloDeVidaDoProprietario() async throws {
        try #require(try await container.accountStatus() == .available, "Entre no iCloud neste Mac")
        let container = container
        let servico = ServicoDeEquipesCloudKit(container: container)
        let sincronizador = SincronizadorDaBibliotecaCloudKit(container: container)
        let privado = container.privateCloudDatabase
        let publico = container.publicCloudDatabase
        let sufixo = String(UUID().uuidString.prefix(6)).lowercased()
        let espaco = EspacoID()
        let nova = EquipeDisponivel(
            id: "\(prefixoDeTeste)\(sufixo)",
            nome: "Teste ao vivo \(sufixo)",
            papel: "Administrador",
            quantidadeDeMembros: 1,
            espacoID: espaco.rawValue.uuidString,
            codigoDeEntrada: EquipeDisponivel.novoCodigoDeEntrada()
        )
        let gemea = EquipeDisponivel(
            id: "\(prefixoDeTeste)\(sufixo)-gemea",
            nome: "Gêmea \(sufixo)",
            papel: "Administrador",
            quantidadeDeMembros: 1,
            espacoID: UUID().uuidString,
            codigoDeEntrada: nova.codigoDeEntrada
        )
        var codigos: Set<String> = [try #require(nova.codigoDeEntrada)]
        registrar("appAtivo=\(await MainActor.run { NSApplication.shared.isActive }) equipe=\(nova.id)")

        do {
            // Criação: zona, compartilhamento e código resolvível.
            var equipe = try await servico.criarWorkspace(para: nova)
            let codigoInicial = try #require(equipe.codigoDeEntrada)
            #expect(equipe.zonaCloudKit == ServicoDeEquipesCloudKit.nomeDaZona(para: nova.id))
            #expect(equipe.compartilhamentoCloudKit == CKRecordNameZoneWideShare)
            registrar("criada com código \(codigoInicial)")

            // O proprietário abre a equipe em outro Mac com o próprio código.
            let noSegundoMac = try await servico.entrarNaEquipe(com: codigoInicial.lowercased())
            #expect(noSegundoMac.id == equipe.id)
            #expect(noSegundoMac.papel == "Administrador")
            #expect(noSegundoMac.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue)
            #expect(noSegundoMac.zonaCloudKit == equipe.zonaCloudKit)
            #expect(noSegundoMac.espacoID == equipe.espacoID)
            #expect(noSegundoMac.codigoDeEntrada == codigoInicial)
            registrar("proprietário entrou com o próprio código")

            // Participantes: o dono é reconhecido como a conta atual e tem nome.
            let participantes = try await servico.participantes(da: equipe)
            let dono = try #require(participantes.first)
            #expect(participantes.count == 1)
            #expect(dono.eProprietario)
            #expect(dono.eAtual)
            #expect(!dono.nome.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(dono.id == (try await container.userRecordID().recordName))

            try await servico.atualizarNome(de: dono.id, para: "  Dona Teste ", na: equipe)
            #expect(try await servico.participantes(da: equipe).first?.nome == "Dona Teste")
            await #expect(throws: ErroDeEquipeCloudKit.self) {
                try await servico.removerParticipante(dono.id, da: equipe)
            }

            var configuracoes = ConfiguracoesDaEquipe()
            configuracoes.visibilidadeDosArquivos = .apenasAdministrador
            try await servico.atualizarConfiguracoes(configuracoes, da: equipe)
            #expect(try await servico.entrarNaEquipe(com: codigoInicial).configuracoes == configuracoes)
            registrar("participantes, nome e configurações conferidos")

            // Um registro recusado pelo servidor tem de virar erro, não sucesso.
            let zonaID = CKRecordZone.ID(zoneName: try #require(equipe.zonaCloudKit))
            let conflitante = CKRecord(
                recordType: "Equipe",
                recordID: CKRecord.ID(recordName: "equipe", zoneID: zonaID)
            )
            do {
                try await LoteCloudKit.salvar([conflitante], em: privado)
                Issue.record("O lote aceitou um registro que o servidor recusou")
            } catch let erro as CKError {
                #expect(erro.code == .serverRecordChanged)
            }

            // Sincronização: envio, baixa completa, baixa incremental com remoção.
            let arquivos = (0..<3).map { Arquivo(titulo: "Conversa \($0)", pastaRelativa: "", espaco: espaco) }
            let equipeParaSincronizar = equipe
            let primeira = try await comLimite(90) {
                for arquivo in arquivos { try await sincronizador.enviar(arquivo, para: equipeParaSincronizar) }
                return try await sincronizador.baixarAlteracoes(da: equipeParaSincronizar, desde: nil)
            }
            #expect(Set(primeira.conversas.map(\.arquivo.id)) == Set(arquivos.map(\.id)))
            #expect(primeira.removidas.isEmpty)
            let marcador = try #require(primeira.marcador)

            var editada = arquivos[0]
            editada.titulo = "Conversa 0 editada"
            let paraEditar = editada
            let segunda = try await comLimite(90) {
                try await sincronizador.enviar(paraEditar, para: equipeParaSincronizar)
                try await sincronizador.remover(arquivos[2], da: equipeParaSincronizar)
                // Remover de novo o que já saiu não pode prender a fila em retentativas.
                try await sincronizador.remover(arquivos[2], da: equipeParaSincronizar)
                return try await sincronizador.baixarAlteracoes(da: equipeParaSincronizar, desde: marcador)
            }
            #expect(segunda.conversas.map(\.arquivo.titulo) == ["Conversa 0 editada"])
            #expect(segunda.removidas == [arquivos[2].id])
            let completa = try await comLimite(90) {
                try await sincronizador.baixar(da: equipeParaSincronizar)
            }
            #expect(Set(completa.map(\.id)) == [arquivos[0].id, arquivos[1].id])
            registrar("envio, baixa completa e baixa incremental com remoção conferidos")

            // Outra equipe pedindo o mesmo código recebe um código diferente.
            let segundaEquipe = try await servico.criarWorkspace(para: gemea)
            let codigoDaGemea = try #require(segundaEquipe.codigoDeEntrada)
            codigos.insert(codigoDaGemea)
            #expect(codigoDaGemea != codigoInicial)
            let entradaNaGemea = try await servico.entrarNaEquipe(com: codigoDaGemea)
            #expect(entradaNaGemea.id == gemea.id)
            #expect(entradaNaGemea.codigoDeEntrada == codigoDaGemea)
            #expect(try await servico.entrarNaEquipe(com: codigoInicial).id == equipe.id)
            try await servico.excluirEquipeGlobalmente(segundaEquipe)
            registrar("colisão de código resolvida: gêmea ficou com \(codigoDaGemea)")

            // Equipe criada por versão anterior: código só existe com ID aleatório.
            let idDoCodigo = CKRecord.ID(recordName: "codigo.\(codigoInicial)")
            let publicado = try await publico.record(for: idDoCodigo)
            let legado = CKRecord(recordType: "CodigoDeEquipe")
            legado["codigoDeEntrada"] = codigoInicial as NSString
            legado["urlDoCompartilhamento"] = publicado["urlDoCompartilhamento"]
            _ = try await publico.save(legado)
            _ = try await publico.deleteRecord(withID: idDoCodigo)
            #expect(try await servico.entrarNaEquipe(com: codigoInicial).id == equipe.id)
            registrar("código legado (ID aleatório) resolvido pela consulta")

            // Marcador de exclusão forjado não apaga equipe cuja zona existe.
            let idDoMarcador = CKRecord.ID(recordName: "equipe-excluida.\(equipe.id)")
            let forjado = CKRecord(recordType: "EquipeExcluida", recordID: idDoMarcador)
            forjado["equipeID"] = equipe.id as NSString
            forjado["excluidaEm"] = Date() as NSDate
            forjado["estadoDaExclusao"] = "concluida" as NSString
            _ = try await publico.save(forjado)
            #expect(try await servico.equipeFoiExcluida(equipe) == false)
            _ = try await publico.deleteRecord(withID: idDoMarcador)
            registrar("marcador de exclusão forjado foi ignorado")

            // Troca de código: novo vale, antigo (inclusive o legado) não.
            let rotacionada = try await servico.rotacionarCodigo(da: equipe)
            let codigoNovo = try #require(rotacionada.codigoDeEntrada)
            codigos.insert(codigoNovo)
            #expect(codigoNovo != codigoInicial)
            #expect(rotacionada.quantidadeDeMembros == 1)
            await #expect(throws: ErroDeEquipeCloudKit.self) {
                try await servico.entrarNaEquipe(com: codigoInicial)
            }
            let aposTroca = try await servico.entrarNaEquipe(com: codigoNovo)
            #expect(aposTroca.id == equipe.id)
            #expect(aposTroca.codigoDeEntrada == codigoNovo)
            #expect(try await servico.participantes(da: rotacionada).count == 1)
            equipe = rotacionada
            registrar("código trocado \(codigoInicial) -> \(codigoNovo); antigo recusado")

            // Trocar outra vez em seguida também funciona.
            let outraTroca = try await servico.rotacionarCodigo(da: equipe)
            let codigoFinal = try #require(outraTroca.codigoDeEntrada)
            codigos.insert(codigoFinal)
            await #expect(throws: ErroDeEquipeCloudKit.self) {
                try await servico.entrarNaEquipe(com: codigoNovo)
            }
            #expect(try await servico.entrarNaEquipe(com: codigoFinal).id == equipe.id)
            equipe = outraTroca

            // Equipe legada sem código ganha um ao reconfigurar o acesso.
            var semCodigo = equipe
            semCodigo.codigoDeEntrada = nil
            let reconfigurada = try await servico.ativarEntradaPorCodigo(na: semCodigo)
            let codigoReconfigurado = try #require(reconfigurada.codigoDeEntrada)
            codigos.insert(codigoReconfigurado)
            #expect(try await servico.entrarNaEquipe(com: codigoReconfigurado).id == equipe.id)
            registrar("equipe sem código recebeu \(codigoReconfigurado)")

            // Exclusão global: confirmada, repetível e os códigos deixam de valer.
            try await servico.excluirEquipeGlobalmente(reconfigurada)
            #expect(try await servico.equipeFoiExcluida(reconfigurada))
            try await servico.excluirEquipeGlobalmente(reconfigurada)
            #expect(try await servico.equipeFoiExcluida(reconfigurada))
            await #expect(throws: ErroDeEquipeCloudKit.self) {
                try await servico.entrarNaEquipe(com: codigoReconfigurado)
            }
            registrar("exclusão global confirmada e repetível")
        } catch {
            Issue.record("O cenário parou em: \(error)")
        }

        // Nada do teste pode sobrar no container, mesmo quando ele falha.
        for id in [nova.id, gemea.id] {
            _ = try? await privado.deleteRecordZone(
                withID: CKRecordZone.ID(zoneName: ServicoDeEquipesCloudKit.nomeDaZona(para: id))
            )
            _ = try? await publico.deleteRecord(withID: CKRecord.ID(recordName: "equipe-excluida.\(id)"))
        }
        for codigo in codigos {
            _ = try? await publico.deleteRecord(withID: CKRecord.ID(recordName: "codigo.\(codigo)"))
            let consulta = CKQuery(
                recordType: "CodigoDeEquipe",
                predicate: NSPredicate(format: "%K == %@", "codigoDeEntrada", codigo)
            )
            if let resultado = try? await publico.records(matching: consulta) {
                for (id, _) in resultado.matchResults { _ = try? await publico.deleteRecord(withID: id) }
            }
        }
    }

    @Test("Faxina: remove zonas deixadas por execuções interrompidas")
    func faxina() async throws {
        let privado = container.privateCloudDatabase
        for zona in try await privado.allRecordZones() {
            let nome = zona.zoneID.zoneName
            guard nome.hasPrefix("sonda.") || nome.hasPrefix("equipe.\(prefixoDeTeste)") else { continue }
            _ = try? await privado.deleteRecordZone(withID: zona.zoneID)
            registrar("faxina: apagou \(nome)")
        }
    }
}
