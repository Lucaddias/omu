import CloudKit
import Foundation

/// Workspaces colaborativos no container do Papagaio.
///
/// Cada equipe vive numa zona privada própria e a zona inteira recebe um
/// `CKShare`. Assim, os próximos tipos de registro (conversa, tarefa e mídia)
/// entram no mesmo escopo sem que seja necessário compartilhar item a item.
actor ServicoDeEquipesCloudKit {
    static let identificadorDoContainer = "iCloud.com.papagaio.Papagaio"

    private enum Campo {
        static let id = "id"
        static let nome = "nome"
        static let espacoID = "espacoID"
        static let codigoDeEntrada = "codigoDeEntrada"
        static let configuracoes = "configuracoes"
        static let nomesDosParticipantes = "nomesDosParticipantes"
        static let urlDoCompartilhamento = "urlDoCompartilhamento"
        static let equipeID = "equipeID"
        static let excluidaEm = "excluidaEm"
        static let estadoDaExclusao = "estadoDaExclusao"
    }

    private enum TipoDeRegistro {
        static let equipe = "Equipe"
        static let codigoDeEquipe = "CodigoDeEquipe"
        /// Marcador fora da zona. A zona é apagada na exclusão, por isso não
        /// pode carregar o sinal que manda os demais Macs limparem o cache.
        static let equipeExcluida = "EquipeExcluida"
    }

    private let container: CKContainer

    private enum EstadoDoMarcadorDeExclusao: String {
        case preparando
        case concluida
    }

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.papagaio.Papagaio")) {
        self.container = container
    }

    /// Cria o workspace e o compartilhamento da zona de uma equipe nova.
    ///
    /// O código de entrada resolve o link do compartilhamento e concede acesso
    /// de edição à zona inteira para a Apple Account que o informar no Ōmu.
    func criarWorkspace(para equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()

        let zonaID = CKRecordZone.ID(
            zoneName: Self.nomeDaZona(para: equipe.id)
        )
        let banco = container.privateCloudDatabase
        _ = try await banco.save(CKRecordZone(zoneID: zonaID))

        do {
            let espacoID = UUID(uuidString: equipe.espacoID ?? "") ?? UUID()
            let registro = registroDaEquipe(equipe, espacoID: espacoID, na: zonaID)
            let salvos = try await LoteCloudKit.salvar(
                [registro, novoCompartilhamento(da: zonaID, titulo: equipe.nome)],
                em: banco
            )
            guard let compartilhamento = salvos.lazy.compactMap({ $0 as? CKShare }).first,
                  let url = compartilhamento.url
            else {
                throw ErroDeEquipeCloudKit.conviteIndisponivel
            }
            let codigo = try await publicarCodigo(preferindo: equipe.codigoDeEntrada, para: url)
            if codigo != equipe.codigoDeEntrada.map(Self.normalizar) {
                try await gravarCodigo(codigo, noRegistroDa: zonaID)
            }

            return EquipeDisponivel(
                id: equipe.id,
                nome: equipe.nome,
                papel: equipe.papel,
                quantidadeDeMembros: equipe.quantidadeDeMembros,
                espacoID: espacoID.uuidString,
                zonaCloudKit: zonaID.zoneName,
                donoDaZonaCloudKit: zonaID.ownerName,
                compartilhamentoCloudKit: compartilhamento.recordID.recordName,
                bancoCloudKit: BancoCloudKitDaEquipe.privado.rawValue,
                codigoDeEntrada: codigo,
                configuracoes: equipe.configuracoes
            )
        } catch {
            // Sem compartilhamento ou sem código a equipe não receberia
            // ninguém, e o chamador não chega a guardá-la. A zona não pode
            // sobrar ocupando o iCloud do proprietário.
            _ = try? await banco.deleteRecordZone(withID: zonaID)
            throw error
        }
    }

    /// Resolve o código informado e aceita a zona compartilhada da equipe.
    func entrarNaEquipe(com codigo: String) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        let codigoNormalizado = Self.normalizar(codigo)
        guard !codigoNormalizado.isEmpty else { throw ErroDeEquipeCloudKit.codigoInvalido }

        // O registro de ID derivado é o único que o servidor garante ser
        // exclusivo daquele código. Códigos publicados por versões anteriores
        // têm ID aleatório e só aparecem na consulta.
        var registros: [CKRecord] = []
        do {
            let direto = try await container.publicCloudDatabase.record(for: Self.idDoCodigo(codigoNormalizado))
            if Self.url(no: direto) != nil { registros = [direto] }
        } catch let erro as CKError where erro.code == .unknownItem {
            // Segue para os registros legados.
        }
        if registros.isEmpty {
            registros = try await registrosLegados(doCodigo: codigoNormalizado)
        }

        // Qualquer conta pode criar um registro de código no banco público.
        // Um registro só vale se foi criado pelo dono do compartilhamento
        // para o qual aponta — isso impede que alguém aponte um código para a
        // zona de terceiros. E o código precisa levar a um único
        // compartilhamento: havendo dois, não há como saber qual é o
        // legítimo, e entrar no errado sincronizaria conversas para lá.
        var candidatos: [String: CKShare.Metadata] = [:]
        for registro in registros {
            // Um código ainda publicado pode apontar para um compartilhamento
            // que o proprietário já substituiu ou apagou: ele não é candidato.
            guard let url = Self.url(no: registro),
                  let metadados = try? await container.shareMetadata(for: url)
            else { continue }
            // O dono de um compartilhamento de zona é o dono da zona; a
            // identidade do proprietário fica como segunda fonte.
            let donoDaZona = metadados.share.recordID.zoneID.ownerName
            let dono = donoDaZona == CKCurrentUserDefaultName
                ? metadados.ownerIdentity.userRecordID?.recordName
                : donoDaZona
            guard Self.registroDeCodigoEhDoDono(
                criador: registro.creatorUserRecordID?.recordName,
                donoDoCompartilhamento: dono
            ) else { continue }
            candidatos[url.absoluteString] = metadados
        }
        guard let metadados = candidatos.values.first else {
            throw ErroDeEquipeCloudKit.codigoInvalido
        }
        guard candidatos.count == 1 else {
            throw ErroDeEquipeCloudKit.codigoAmbiguo
        }

        var equipe = try await aceitar(metadados)
        // O registro da equipe dentro da zona pode trazer um código antigo
        // (zonas cujo código foi trocado antes de `rotacionarCodigo` passar
        // a atualizá-lo). O que acabou de dar acesso é o digitado.
        equipe.codigoDeEntrada = codigoNormalizado
        return equipe
    }

    /// Sai de uma zona compartilhada recém-aceita que não deve ser usada
    /// (código não confere, ou a equipe conflita com outra já conhecida).
    /// Para um participante, apagar a zona no banco compartilhado é o que
    /// encerra a própria participação — o conteúdo do dono não é tocado.
    func abandonarZonaCompartilhada(de equipe: EquipeDisponivel) async {
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.compartilhado.rawValue,
              let zona = try? referenciaDaZona(de: equipe),
              zona.ownerName != CKCurrentUserDefaultName
        else { return }
        _ = try? await container.sharedCloudDatabase.deleteRecordZone(withID: zona)
    }

    /// Um registro de código só é aceito quando quem o criou é o dono do
    /// compartilhamento para o qual ele aponta.
    nonisolated static func registroDeCodigoEhDoDono(
        criador: String?,
        donoDoCompartilhamento: String?
    ) -> Bool {
        guard let criador, let donoDoCompartilhamento, !criador.isEmpty else { return false }
        return criador == donoDoCompartilhamento
    }

    /// Completa equipes aceitas por versões que ainda guardavam só o nome da
    /// zona. Isso recupera o dono real no banco compartilhado e permite que a
    /// referência seja persistida novamente pelo chamador.
    func completarReferenciaDaZonaCompartilhada(
        da equipe: EquipeDisponivel
    ) async throws -> EquipeDisponivel {
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.compartilhado.rawValue,
              equipe.donoDaZonaCloudKit == nil,
              let nomeDaZona = equipe.zonaCloudKit
        else { return equipe }

        try await garantirContaICloudDisponivel()
        let zonas = try await container.sharedCloudDatabase.allRecordZones()
        let correspondentes = zonas.filter { $0.zoneID.zoneName == nomeDaZona }
        guard correspondentes.count == 1 else {
            throw ErroDeEquipeCloudKit.zonaCompartilhadaIndisponivel
        }

        var corrigida = equipe
        corrigida.donoDaZonaCloudKit = correspondentes[0].zoneID.ownerName
        return corrigida
    }

    /// Somente a conta proprietária altera as preferências compartilhadas.
    func atualizarConfiguracoes(_ configuracoes: ConfiguracoesDaEquipe, da equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let id = CKRecord.ID(recordName: "equipe", zoneID: zona)
        let registro = try await container.privateCloudDatabase.record(for: id)
        registro[Campo.configuracoes] = try JSONEncoder().encode(configuracoes) as NSData
        _ = try await container.privateCloudDatabase.save(registro)
    }

    /// Lê o `CKShare` real. A identidade retornada é a que o CloudKit permite
    /// mostrar; e-mail não é um dado disponível para o app nesse fluxo.
    func participantes(da equipe: EquipeDisponivel) async throws -> [ParticipanteDaEquipe] {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let compartilhamento = try await compartilhamento(da: equipe)
        let idAtual = try await container.userRecordID().recordName
        let nomes = try await nomesDosParticipantes(da: equipe, no: container.privateCloudDatabase)
        return Self.participantes(no: compartilhamento, nomes: nomes, idAtual: idAtual)
    }

    /// Participantes não têm permissão para enumerar os demais membros do
    /// share. Ainda assim recebem a própria linha, para editar somente o
    /// nome que o grupo exibe para a Apple Account atual.
    func meuParticipante(
        da equipe: EquipeDisponivel,
        nomePadrao: String
    ) async throws -> ParticipanteDaEquipe {
        try await garantirContaICloudDisponivel()
        let idAtual = try await container.userRecordID().recordName
        let zona = try referenciaDaZona(de: equipe)
        let registro = try await container.sharedCloudDatabase.record(
            for: CKRecord.ID(recordName: "equipe", zoneID: zona)
        )
        let nomes = Self.nomes(no: registro)
        return ParticipanteDaEquipe(
            id: idAtual,
            nome: nomes[idAtual] ?? Self.nomeLimpo(nomePadrao, fallback: "Meu perfil".localized),
            eProprietario: false,
            eAtual: true,
            permissao: .escrita
        )
    }

    /// O proprietário pode nomear qualquer participante; os demais só podem
    /// alterar a identidade que representa a própria Apple Account.
    func atualizarNome(
        de participanteID: String,
        para nome: String,
        na equipe: EquipeDisponivel
    ) async throws {
        try await garantirContaICloudDisponivel()
        let nomeLimpo = Self.nomeLimpo(nome, fallback: "")
        guard !nomeLimpo.isEmpty else { throw ErroDeEquipeCloudKit.nomeInvalido }
        let idAtual = try await container.userRecordID().recordName
        let zona = try referenciaDaZona(de: equipe)
        let banco: CKDatabase

        if equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue {
            // A zona privada só é acessível à conta proprietária; não
            // dependemos de `userIdentity` do CKShare, que pode vir omitida.
            banco = container.privateCloudDatabase
        } else {
            guard participanteID == idAtual else { throw ErroDeEquipeCloudKit.apenasProprioNome }
            banco = container.sharedCloudDatabase
        }

        let id = CKRecord.ID(recordName: "equipe", zoneID: zona)
        let registro = try await banco.record(for: id)
        var nomes = Self.nomes(no: registro)
        nomes[participanteID] = nomeLimpo
        registro[Campo.nomesDosParticipantes] = try JSONEncoder().encode(nomes) as NSData
        try await LoteCloudKit.salvar([registro], em: banco)
    }

    /// Atualiza a permissão de uma Apple Account já aceita na equipe.
    func atualizarPermissao(
        do participanteID: String,
        para permissao: ParticipanteDaEquipe.Permissao,
        na equipe: EquipeDisponivel
    ) async throws {
        let compartilhamento = try await compartilhamento(da: equipe)
        let idAtual = try await container.userRecordID().recordName
        guard let participante = compartilhamento.participants.first(where: {
            Self.idDoParticipante($0, idAtual: idAtual) == participanteID
        }) else {
            throw ErroDeEquipeCloudKit.membroNaoEncontrado
        }
        guard participante.role != .owner else {
            throw ErroDeEquipeCloudKit.proprietarioNaoPodeSerAlterado
        }
        participante.permission = permissao == .leitura ? .readOnly : .readWrite
        _ = try await container.privateCloudDatabase.save(compartilhamento)
    }

    /// Revoga o acesso de uma Apple Account aceita. O CloudKit repete o
    /// proprietário em `participants`; removê-lo invalidaria a equipe inteira.
    func removerParticipante(_ participanteID: String, da equipe: EquipeDisponivel) async throws {
        let compartilhamento = try await compartilhamento(da: equipe)
        let idAtual = try await container.userRecordID().recordName
        guard let participante = compartilhamento.participants.first(where: {
            Self.idDoParticipante($0, idAtual: idAtual) == participanteID
        }) else {
            throw ErroDeEquipeCloudKit.membroNaoEncontrado
        }
        guard participante.role != .owner else {
            throw ErroDeEquipeCloudKit.proprietarioNaoPodeSerRemovido
        }
        compartilhamento.removeParticipant(participante)
        _ = try await container.privateCloudDatabase.save(compartilhamento)
    }

    /// Trocar um código precisa trocar o `CKShare`, não só o registro público:
    /// um URL de share antigo continuaria concedendo acesso. Por consequência,
    /// pessoas já aceitas precisam entrar novamente com o novo código.
    ///
    /// O compartilhamento de uma zona tem sempre o mesmo ID, e o CloudKit
    /// recusa salvar e apagar o mesmo registro numa operação. A troca é feita
    /// em etapas, cada uma segura de repetir: se a rede cair no meio, chamar
    /// de novo termina o que faltou.
    func rotacionarCodigo(da equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let banco = container.privateCloudDatabase

        try await invalidarCodigo(equipe.codigoDeEntrada)
        // Apagar o share anterior é o que invalida o URL antigo e revoga os
        // participantes. Só então o servidor aceita um share novo na zona.
        try await LoteCloudKit.apagar([try idDoCompartilhamento(de: equipe, na: zona)], em: banco)
        let salvos = try await LoteCloudKit.salvar(
            [novoCompartilhamento(da: zona, titulo: equipe.nome)],
            em: banco
        )
        guard let novo = salvos.first as? CKShare, let url = novo.url else {
            throw ErroDeEquipeCloudKit.conviteIndisponivel
        }
        let novoCodigo = try await publicarCodigo(preferindo: nil, para: url)
        try await gravarCodigo(novoCodigo, noRegistroDa: zona)

        var atualizada = equipe
        atualizada.codigoDeEntrada = novoCodigo
        atualizada.compartilhamentoCloudKit = novo.recordID.recordName
        atualizada.quantidadeDeMembros = 1
        return atualizada
    }

    /// Exclusão global é uma operação do proprietário. O marcador passa por
    /// `preparando` antes de apagar a zona e só vira `concluida` depois: não
    /// podemos atomizar escrita pública e remoção de zona privada, portanto
    /// outros Macs só limpam conteúdo após a confirmação remota final.
    func excluirEquipeGlobalmente(_ equipe: EquipeDisponivel) async throws {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        // O marcador tem ID fixo. Uma tentativa interrompida já o deixou no
        // servidor, e um registro novo com o mesmo ID seria recusado
        // (`serverRecordChanged`): a repetição continua a partir do que existe.
        var marcador: CKRecord? = try await marcadorDeExclusao(para: equipe.id) ?? CKRecord(
            recordType: TipoDeRegistro.equipeExcluida,
            recordID: Self.idDoMarcadorDeExclusao(para: equipe.id)
        )
        let jaConcluida = marcador.map(Self.exclusaoConcluida(no:)) ?? false
        if let existente = marcador, !jaConcluida {
            existente[Campo.equipeID] = equipe.id as NSString
            existente[Campo.excluidaEm] = Date() as NSDate
            existente[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.preparando.rawValue as NSString
            marcador = try await salvarMarcadorDeExclusao(existente)
        }
        try await invalidarCodigo(equipe.codigoDeEntrada)
        do {
            try await container.privateCloudDatabase.deleteRecordZone(withID: try referenciaDaZona(de: equipe))
        } catch let erro as CKError where erro.code == .zoneNotFound || erro.code == .unknownItem {
            // Repetir a confirmação depois de uma queda entre as duas bases
            // é seguro: a zona já saiu, falta só tornar o marcador visível.
        }
        guard !jaConcluida, let marcador else { return }
        marcador[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.concluida.rawValue as NSString
        _ = try await salvarMarcadorDeExclusao(marcador)
    }

    /// Grava o marcador público. Devolve `nil` quando o registro com esse ID
    /// pertence a outra conta: o ID é previsível e qualquer pessoa pode
    /// ocupá-lo antes; isso não pode impedir o dono de apagar a própria zona
    /// (os outros Macs não confiam num marcador que não seja do dono — ver
    /// `equipeFoiExcluida`).
    private func salvarMarcadorDeExclusao(_ marcador: CKRecord) async throws -> CKRecord? {
        do {
            let resultado = try await container.publicCloudDatabase.modifyRecords(
                saving: [marcador],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            return try resultado.saveResults[marcador.recordID]?.get() ?? marcador
        } catch let erro as CKError where erro.code == .permissionFailure {
            return nil
        }
    }

    /// Chamado por cada instalação antes de voltar a usar uma equipe salva.
    /// O resultado positivo é definitivo: a cópia local daquela equipe deve
    /// sair inclusive da lixeira e do disco.
    ///
    /// O marcador mora no banco público, onde qualquer conta autenticada
    /// cria registros, e o ID dele é previsível. Sozinho ele não prova nada:
    /// só vale se foi criado pelo dono da zona **e** se a zona realmente
    /// deixou de existir — coisa que só o dono consegue provocar.
    func equipeFoiExcluida(_ equipe: EquipeDisponivel) async throws -> Bool {
        guard let marcador = try await marcadorDeExclusao(para: equipe.id) else {
            return false
        }
        guard Self.marcadorAutorizaLimpeza(
            estado: marcador[Campo.estadoDaExclusao] as? String,
            criador: marcador.creatorUserRecordID?.recordName,
            donoDaZona: equipe.donoDaZonaCloudKit
        ) else { return false }
        return try await zonaDeixouDeExistir(equipe)
    }

    /// A parte decidível sem rede da regra acima.
    nonisolated static func marcadorAutorizaLimpeza(
        estado: String?,
        criador: String?,
        donoDaZona: String?
    ) -> Bool {
        guard estado == EstadoDoMarcadorDeExclusao.concluida.rawValue,
              let criador, !criador.isEmpty,
              // Equipes antigas, sem o dono guardado, não têm contra o que
              // conferir: na dúvida, nada é apagado.
              let donoDaZona, !donoDaZona.isEmpty
        else { return false }
        return criador == donoDaZona
    }

    private func zonaDeixouDeExistir(_ equipe: EquipeDisponivel) async throws -> Bool {
        let zona = try referenciaDaZona(de: equipe)
        let banco = equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        do {
            _ = try await banco.recordZone(for: zona)
            return false
        } catch let erro as CKError
            where [.zoneNotFound, .unknownItem, .userDeletedZone].contains(erro.code) {
            return true
        }
    }

    /// Converte uma equipe criada antes da entrada por código: libera o
    /// compartilhamento para quem tiver o código e publica um código para
    /// ela. A ação é do proprietário porque muda quem pode entrar na zona.
    @discardableResult
    func ativarEntradaPorCodigo(na equipe: EquipeDisponivel) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }

        let zona = try referenciaDaZona(de: equipe)
        let compartilhamento = try await compartilhamento(da: equipe)
        compartilhamento.publicPermission = Self.permissaoDaEntradaPorCodigo
        guard let url = (try await container.privateCloudDatabase.save(compartilhamento) as? CKShare)?.url else {
            throw ErroDeEquipeCloudKit.conviteIndisponivel
        }
        let codigo = try await publicarCodigo(preferindo: equipe.codigoDeEntrada, para: url)
        try await gravarCodigo(codigo, noRegistroDa: zona)

        var atualizada = equipe
        atualizada.codigoDeEntrada = codigo
        return atualizada
    }

    /// Aceita um convite entregue pelo sistema e devolve a equipe para a lista
    /// local do participante. Os registros passam a aparecer no banco
    /// compartilhado dessa conta.
    func aceitar(_ metadados: CKShare.Metadata) async throws -> EquipeDisponivel {
        try await garantirContaICloudDisponivel()
        // O CloudKit recusa o aceite do próprio dono. Quem criou a equipe e a
        // abre em outro Mac já tem a zona no banco privado: basta referenciá-la.
        if metadados.participantRole == .owner {
            return try await equipeDoProprietario(a: metadados.share)
        }

        var compartilhamento = metadados.share
        let jaAceito = metadados.participantStatus == .accepted
        if !jaAceito {
            compartilhamento = try await container.accept(metadados)
        }
        let registro: CKRecord
        do {
            registro = try await registroDaEquipeCompartilhada(na: compartilhamento.recordID.zoneID)
        } catch where jaAceito {
            // O status dizia "aceito", mas a zona não está no banco
            // compartilhado desta conta. Um aceite explícito a traz de volta.
            compartilhamento = try await container.accept(metadados)
            registro = try await registroDaEquipeCompartilhada(na: compartilhamento.recordID.zoneID)
        }
        return try equipe(
            de: registro,
            compartilhamento: compartilhamento,
            papel: "Membro",
            banco: .compartilhado
        )
    }

    private func equipeDoProprietario(a compartilhamento: CKShare) async throws -> EquipeDisponivel {
        let registro = try await container.privateCloudDatabase.record(
            for: CKRecord.ID(recordName: "equipe", zoneID: compartilhamento.recordID.zoneID)
        )
        return try equipe(
            de: registro,
            compartilhamento: compartilhamento,
            papel: "Administrador",
            banco: .privado
        )
    }

    /// Logo depois do aceite a zona pode levar alguns instantes para aparecer
    /// no banco compartilhado. Sem esperar, quem acabou de entrar recebia
    /// "zona não existe" e precisava digitar o código outra vez.
    private func registroDaEquipeCompartilhada(na zonaID: CKRecordZone.ID) async throws -> CKRecord {
        let id = CKRecord.ID(recordName: "equipe", zoneID: zonaID)
        let esperas: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        for espera in esperas {
            do {
                return try await container.sharedCloudDatabase.record(for: id)
            } catch let erro as CKError where erro.code == .zoneNotFound || erro.code == .unknownItem {
                try await Task.sleep(for: espera)
            }
        }
        return try await container.sharedCloudDatabase.record(for: id)
    }

    private func equipe(
        de registro: CKRecord,
        compartilhamento: CKShare,
        papel: String,
        banco: BancoCloudKitDaEquipe
    ) throws -> EquipeDisponivel {
        guard
            let id = registro[Campo.id] as? String,
            let nome = registro[Campo.nome] as? String,
            let espacoID = registro[Campo.espacoID] as? String,
            UUID(uuidString: espacoID) != nil
        else {
            throw ErroDeEquipeCloudKit.registroDaEquipeInvalido
        }
        let zonaID = compartilhamento.recordID.zoneID

        return EquipeDisponivel(
            id: id,
            nome: nome,
            papel: papel,
            // O compartilhamento devolvido pelo CloudKit contém as pessoas
            // que já aceitaram o convite. A versão anterior gravava zero de
            // propósito, embora esta conta já fosse participante.
            quantidadeDeMembros: compartilhamento.participants.count,
            espacoID: espacoID,
            zonaCloudKit: zonaID.zoneName,
            donoDaZonaCloudKit: zonaID.ownerName,
            compartilhamentoCloudKit: compartilhamento.recordID.recordName,
            bancoCloudKit: banco.rawValue,
            codigoDeEntrada: registro[Campo.codigoDeEntrada] as? String,
            configuracoes: configuracoes(no: registro)
        )
    }

    nonisolated static func nomeDaZona(para equipeID: String) -> String {
        "equipe.\(equipeID)"
    }

    nonisolated static func normalizar(_ codigo: String) -> String {
        codigo.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Quem possuir o código pode entrar e sincronizar alterações. O código
    /// precisa ser tratado como uma chave de acesso pela equipe.
    nonisolated static var permissaoDaEntradaPorCodigo: CKShare.ParticipantPermission {
        .readWrite
    }

    private func garantirContaICloudDisponivel() async throws {
        guard try await container.accountStatus() == .available else {
            throw ErroDeEquipeCloudKit.contaICloudIndisponivel
        }
    }

    private func registroDaEquipe(
        _ equipe: EquipeDisponivel,
        espacoID: UUID,
        na zonaID: CKRecordZone.ID
    ) -> CKRecord {
        let registro = CKRecord(
            recordType: TipoDeRegistro.equipe,
            recordID: CKRecord.ID(recordName: "equipe", zoneID: zonaID)
        )
        registro[Campo.id] = equipe.id as NSString
        registro[Campo.nome] = equipe.nome as NSString
        registro[Campo.espacoID] = espacoID.uuidString as NSString
        registro[Campo.codigoDeEntrada] = equipe.codigoDeEntrada.map(Self.normalizar) as NSString?
        registro[Campo.configuracoes] = (try? JSONEncoder().encode(equipe.configuracoes)) as NSData?
        return registro
    }

    private func novoCompartilhamento(da zonaID: CKRecordZone.ID, titulo: String) -> CKShare {
        let compartilhamento = CKShare(recordZoneID: zonaID)
        compartilhamento[CKShare.SystemFieldKey.title] = titulo as NSString
        compartilhamento.publicPermission = Self.permissaoDaEntradaPorCodigo
        return compartilhamento
    }

    /// Publica o código no banco público e devolve o que ficou valendo.
    ///
    /// O ID do registro deriva do código. Assim o servidor recusa um código
    /// já usado por outra equipe — antes dois registros podiam compartilhar o
    /// mesmo código e a entrada escolhia um deles ao acaso — e a resolução
    /// vira uma leitura direta, sem depender de índice de consulta.
    private func publicarCodigo(preferindo preferido: String?, para url: URL) async throws -> String {
        var candidato = preferido.map(Self.normalizar) ?? ""
        for _ in 0..<5 {
            if candidato.isEmpty { candidato = EquipeDisponivel.novoCodigoDeEntrada() }
            let registro = CKRecord(
                recordType: TipoDeRegistro.codigoDeEquipe,
                recordID: Self.idDoCodigo(candidato)
            )
            registro[Campo.codigoDeEntrada] = candidato as NSString
            registro[Campo.urlDoCompartilhamento] = url.absoluteString as NSString
            do {
                _ = try await container.publicCloudDatabase.save(registro)
                return candidato
            } catch let erro as CKError where erro.code == .serverRecordChanged {
                candidato = ""
            }
        }
        throw ErroDeEquipeCloudKit.conviteIndisponivel
    }

    private nonisolated static func url(no registro: CKRecord) -> URL? {
        (registro[Campo.urlDoCompartilhamento] as? String).flatMap(URL.init(string:))
    }

    /// Registros de código criados antes do ID derivado. Sem o tipo ou o
    /// índice publicado no ambiente não existe código legado consultável.
    private func registrosLegados(doCodigo normalizado: String) async throws -> [CKRecord] {
        let consulta = CKQuery(
            recordType: TipoDeRegistro.codigoDeEquipe,
            predicate: NSPredicate(format: "%K == %@", Campo.codigoDeEntrada, normalizado)
        )
        do {
            let resultado = try await container.publicCloudDatabase.records(matching: consulta)
            return resultado.matchResults.compactMap { try? $0.1.get() }
        } catch let erro as CKError where erro.code == .unknownItem || erro.code == .invalidArguments {
            return []
        }
    }

    private func invalidarCodigo(_ codigo: String?) async throws {
        guard let normalizado = codigo.map(Self.normalizar), !normalizado.isEmpty else { return }
        let legados = try await registrosLegados(doCodigo: normalizado).map(\.recordID)
        try await LoteCloudKit.apagar(
            Array(Set(legados + [Self.idDoCodigo(normalizado)])),
            em: container.publicCloudDatabase
        )
    }

    /// Mantém no registro da equipe o código que está publicado, para que
    /// quem entrar depois de uma troca receba o código vigente.
    private func gravarCodigo(_ codigo: String, noRegistroDa zona: CKRecordZone.ID) async throws {
        let banco = container.privateCloudDatabase
        let registro = try await banco.record(for: CKRecord.ID(recordName: "equipe", zoneID: zona))
        registro[Campo.codigoDeEntrada] = codigo as NSString
        try await LoteCloudKit.salvar([registro], em: banco)
    }

    private func marcadorDeExclusao(para equipeID: String) async throws -> CKRecord? {
        do {
            return try await container.publicCloudDatabase.record(
                for: Self.idDoMarcadorDeExclusao(para: equipeID)
            )
        } catch let erro as CKError where erro.code == .unknownItem {
            return nil
        }
    }

    private nonisolated static func exclusaoConcluida(no marcador: CKRecord) -> Bool {
        (marcador[Campo.estadoDaExclusao] as? String) == EstadoDoMarcadorDeExclusao.concluida.rawValue
    }

    private func compartilhamento(da equipe: EquipeDisponivel) async throws -> CKShare {
        try await garantirContaICloudDisponivel()
        guard equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue else {
            throw ErroDeEquipeCloudKit.apenasAdministrador
        }
        let zona = try referenciaDaZona(de: equipe)
        let id = try idDoCompartilhamento(de: equipe, na: zona)
        do {
            guard let compartilhamento = try await container.privateCloudDatabase.record(for: id) as? CKShare else {
                throw ErroDeEquipeCloudKit.compartilhamentoInvalido
            }
            return compartilhamento
        } catch let erro as CKError where erro.code == .unknownItem {
            // Uma troca de código interrompida deixa a zona sem share.
            throw ErroDeEquipeCloudKit.compartilhamentoInvalido
        }
    }

    private nonisolated static func participantes(
        no compartilhamento: CKShare,
        nomes: [String: String],
        idAtual: String
    ) -> [ParticipanteDaEquipe] {
        let idDoDono = idDoParticipante(compartilhamento.owner, idAtual: idAtual)
        let dono = ParticipanteDaEquipe(
            id: idDoDono,
            nome: nomeDoParticipante(
                compartilhamento.owner,
                id: idDoDono,
                nomes: nomes,
                fallback: "Proprietário".localized
            ),
            eProprietario: true,
            eAtual: idDoDono == idAtual,
            permissao: .escrita
        )
        let aceitos = compartilhamento.participants.compactMap { participante -> ParticipanteDaEquipe? in
            // O CloudKit pode repetir o proprietário em `participants`. A
            // role é a fonte de verdade, e a comparação pelo ID protege SDKs
            // que tenham omitido a role em metadados antigos.
            let id = idDoParticipante(participante, idAtual: idAtual)
            guard participante.role != .owner, id != dono.id else { return nil }
            return ParticipanteDaEquipe(
                id: id,
                nome: nomeDoParticipante(participante, id: id, nomes: nomes, fallback: "Membro da equipe".localized),
                eProprietario: false,
                eAtual: id == idAtual,
                permissao: participante.permission == .readOnly ? .leitura : .escrita
            )
        }
        return [dono] + aceitos.sorted { $0.nome.localizedStandardCompare($1.nome) == .orderedAscending }
    }

    /// Para a própria conta o CloudKit devolve o marcador `__defaultOwner__`
    /// em vez do ID real. Sem a troca, a linha "você" nunca era reconhecida e
    /// o nome gravado ficava preso a uma chave que nenhum outro Mac enxerga.
    private nonisolated static func idDoParticipante(
        _ participante: CKShare.Participant,
        idAtual: String
    ) -> String {
        guard let id = participante.userIdentity.userRecordID?.recordName else {
            return participante.userIdentity.lookupInfo?.emailAddress ?? UUID().uuidString
        }
        return id == CKCurrentUserDefaultName ? idAtual : id
    }

    private nonisolated static func nomeDoParticipante(
        _ participante: CKShare.Participant,
        id: String,
        nomes: [String: String],
        fallback: String
    ) -> String {
        // Versões anteriores gravavam o nome do dono sob `__defaultOwner__`.
        let gravado = nomes[id] ?? (participante.role == .owner ? nomes[CKCurrentUserDefaultName] : nil)
        let doICloud = participante.userIdentity.nameComponents?.formatted(.name(style: .medium))
        return [gravado, doICloud]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallback
    }

    private func nomesDosParticipantes(
        da equipe: EquipeDisponivel,
        no banco: CKDatabase
    ) async throws -> [String: String] {
        let zona = try referenciaDaZona(de: equipe)
        let registro = try await banco.record(for: CKRecord.ID(recordName: "equipe", zoneID: zona))
        return Self.nomes(no: registro)
    }

    private nonisolated static func nomes(no registro: CKRecord) -> [String: String] {
        guard let dados = registro[Campo.nomesDosParticipantes] as? Data,
              let nomes = try? JSONDecoder().decode([String: String].self, from: dados)
        else { return [:] }
        return nomes
    }

    private nonisolated static func nomeLimpo(_ nome: String, fallback: String) -> String {
        let limpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? fallback : limpo
    }

    private nonisolated static func idDoMarcadorDeExclusao(para equipeID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "equipe-excluida.\(equipeID)")
    }

    private nonisolated static func idDoCodigo(_ normalizado: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "codigo.\(normalizado)")
    }

    private func configuracoes(no registro: CKRecord) -> ConfiguracoesDaEquipe {
        guard let dados = registro[Campo.configuracoes] as? Data,
              let configuracoes = try? JSONDecoder().decode(ConfiguracoesDaEquipe.self, from: dados)
        else { return .init() }
        return configuracoes
    }

    private func referenciaDaZona(de equipe: EquipeDisponivel) throws -> CKRecordZone.ID {
        guard let zona = equipe.zonaCloudKit
        else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        if let dono = equipe.donoDaZonaCloudKit {
            return CKRecordZone.ID(zoneName: zona, ownerName: dono)
        }
        return CKRecordZone.ID(zoneName: zona)
    }

    private func idDoCompartilhamento(
        de equipe: EquipeDisponivel,
        na zona: CKRecordZone.ID
    ) throws -> CKRecord.ID {
        guard let nome = equipe.compartilhamentoCloudKit else {
            throw ErroDeEquipeCloudKit.equipeAindaLocal
        }
        return CKRecord.ID(recordName: nome, zoneID: zona)
    }
}

enum BancoCloudKitDaEquipe: String {
    case privado
    case compartilhado
}

enum ErroDeEquipeCloudKit: LocalizedError {
    case contaICloudIndisponivel
    case equipeAindaLocal
    case registroDaEquipeInvalido
    case codigoInvalido
    case conviteIndisponivel
    case apenasAdministrador
    case compartilhamentoInvalido
    case zonaCompartilhadaIndisponivel
    case membroNaoEncontrado
    case proprietarioNaoPodeSerAlterado
    case proprietarioNaoPodeSerRemovido
    case nomeInvalido
    case apenasProprioNome
    case codigoAmbiguo
    case conviteConflitaComEquipeLocal

    var errorDescription: String? {
        switch self {
        case .contaICloudIndisponivel:
            "Entre no iCloud neste Mac para usar equipes compartilhadas.".localized
        case .equipeAindaLocal:
            "Esta equipe ainda não foi publicada no CloudKit.".localized
        case .registroDaEquipeInvalido:
            "O convite não contém uma equipe válida do Ōmu.".localized
        case .zonaCompartilhadaIndisponivel:
            "Não encontrei a zona compartilhada desta equipe no iCloud. Entre novamente com o código da equipe.".localized
        case .codigoInvalido:
            "Não encontramos uma equipe com esse código.".localized
        case .codigoAmbiguo:
            "Este código aponta para mais de uma equipe. Peça a quem administra a equipe para gerar um código novo.".localized
        case .conviteConflitaComEquipeLocal:
            "Este convite usa a identidade de uma equipe que já existe neste Mac em outro lugar do iCloud. Ele foi recusado.".localized
        case .conviteIndisponivel:
            "Não foi possível preparar o convite desta equipe.".localized
        case .apenasAdministrador:
            "Somente quem criou a equipe pode alterar estas configurações.".localized
        case .compartilhamentoInvalido:
            "O compartilhamento desta equipe não é válido.".localized
        case .membroNaoEncontrado:
            "Esse membro não faz mais parte do compartilhamento.".localized
        case .proprietarioNaoPodeSerAlterado:
            "A permissão do proprietário da equipe não pode ser alterada.".localized
        case .proprietarioNaoPodeSerRemovido:
            "O proprietário da equipe não pode ser removido.".localized
        case .nomeInvalido:
            "Informe um nome para mostrar na equipe.".localized
        case .apenasProprioNome:
            "Você só pode alterar o próprio nome nesta equipe.".localized
        }
    }
}
