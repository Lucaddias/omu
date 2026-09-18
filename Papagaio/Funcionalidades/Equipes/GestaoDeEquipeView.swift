import SwiftUI

struct GestaoDeEquipeView: View {
    let equipeAtiva: EquipeDisponivel?
    let equipes: [EquipeDisponivel]
    let aoSelecionarEquipe: (EquipeDisponivel) -> Void
    let aoAtualizarEquipe: (EquipeDisponivel) -> Void
    let aoExcluirEquipe: (EquipeDisponivel) async throws -> Void
    let nomeDoPerfil: String
    let estadoDaSincronizacao: EstadoDaSincronizacaoCloudKit
    let aoRetomarSincronizacao: () -> Void

    @State private var mostrandoTrocarEquipe = false
    @State private var atualizandoEntradaPorCodigo = false
    @State private var erroDaEntradaPorCodigo: String?
    @State private var entradaPorCodigoAtualizada = false
    @State private var participantes: [ParticipanteDaEquipe] = []
    @State private var carregandoParticipantes = false
    @State private var erroDosParticipantes: String?
    @State private var paginaDosParticipantes = 0
    @State private var configuracoes: ConfiguracoesDaEquipe = .init()
    @State private var salvandoConfiguracoes = false
    @State private var erroDasConfiguracoes: String?
    @State private var participanteParaEditar: ParticipanteDaEquipe?
    @State private var participanteParaRenomear: ParticipanteDaEquipe?
    @State private var participanteParaRemover: ParticipanteDaEquipe?
    @State private var confirmandoRotacaoDoCodigo = false
    @State private var rotacionandoCodigo = false
    @State private var confirmandoExclusaoDaEquipe = false
    @State private var excluindoEquipe = false
    @State private var erroDaOperacaoCritica: String?
    private let servicoDeEquipes: ServicoDeEquipesCloudKit

    init(
        equipeAtiva: EquipeDisponivel?,
        equipes: [EquipeDisponivel],
        aoSelecionarEquipe: @escaping (EquipeDisponivel) -> Void,
        aoAtualizarEquipe: @escaping (EquipeDisponivel) -> Void = { _ in },
        aoExcluirEquipe: @escaping (EquipeDisponivel) async throws -> Void = { _ in },
        nomeDoPerfil: String = "",
        estadoDaSincronizacao: EstadoDaSincronizacaoCloudKit = .local,
        aoRetomarSincronizacao: @escaping () -> Void = {},
        servicoDeEquipes: ServicoDeEquipesCloudKit = ServicoDeEquipesCloudKit()
    ) {
        self.equipeAtiva = equipeAtiva
        self.equipes = equipes
        self.aoSelecionarEquipe = aoSelecionarEquipe
        self.aoAtualizarEquipe = aoAtualizarEquipe
        self.aoExcluirEquipe = aoExcluirEquipe
        self.nomeDoPerfil = nomeDoPerfil
        self.estadoDaSincronizacao = estadoDaSincronizacao
        self.aoRetomarSincronizacao = aoRetomarSincronizacao
        self.servicoDeEquipes = servicoDeEquipes
    }

    var body: some View {
        ScrollView {
            if let equipeAtiva {
                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                    cabecalho(equipeAtiva)
                    estadoDoICloud
                    codigoDaEquipe(equipeAtiva)
                    participantesDaEquipe(equipeAtiva)
                    if podeGerenciar(equipeAtiva) {
                        configuracoesDaEquipe(equipeAtiva)
                        acoesIrreversiveis(equipeAtiva)
                    } else {
                        avisoDeMembro
                    }
                    if podeAtualizarEntradaPorCodigo(equipeAtiva) {
                        atualizacaoDeEquipeExistente(equipeAtiva)
                    }
                }
                .larguraDeConteudoPapagaio()
                .padding(.horizontal, PapagaioTema.espacamentoDePagina)
                .padding(.vertical, PapagaioTema.espacamentoDePagina)
            } else {
                CartaoDeEstadoVazio(
                    simbolo: "person.3",
                    titulo: "Nenhuma equipe ainda".localized,
                    mensagem: "Crie uma equipe ou entre com um código no seu perfil.".localized
                )
                .padding(.vertical, PapagaioTema.espacamentoDePagina)
            }
        }
        .background(PapagaioTema.fundo)
        .sheet(isPresented: $mostrandoTrocarEquipe) {
            SeletorDeEquipeView(
                equipeAtiva: equipeAtiva,
                equipes: equipes,
                aoCancelar: { mostrandoTrocarEquipe = false },
                aoSelecionar: { equipe in
                    aoSelecionarEquipe(equipe)
                    mostrandoTrocarEquipe = false
                }
            )
        }
        .task(id: equipeAtiva?.id) {
            guard let equipeAtiva else { return }
            configuracoes = equipeAtiva.configuracoes
            paginaDosParticipantes = 0
            await carregarParticipantes(da: equipeAtiva)
        }
        .confirmationDialog(
            "Trocar o código de entrada?".localized,
            isPresented: $confirmandoRotacaoDoCodigo,
            titleVisibility: .visible
        ) {
            Button("Trocar código e revogar acessos".localized, role: .destructive) {
                guard let equipeAtiva else { return }
                Task { await rotacionarCodigo(da: equipeAtiva) }
            }
        } message: {
            Text("O código e o link atuais deixarão de funcionar. Por segurança, os participantes aceitos precisarão entrar novamente com o novo código.".localized)
        }
        .confirmationDialog(
            "Excluir esta equipe para todos?".localized,
            isPresented: $confirmandoExclusaoDaEquipe,
            titleVisibility: .visible
        ) {
            Button("Excluir equipe e dados".localized, role: .destructive) {
                guard let equipeAtiva else { return }
                Task { await excluir(equipeAtiva) }
            }
        } message: {
            Text("A zona do CloudKit, as conversas compartilhadas e os dados deste Mac serão apagados. Outros Macs atualizados removem suas cópias ao se conectarem ao iCloud. Esta ação não pode ser desfeita.".localized)
        }
    }

    private func cabecalho(_ equipe: EquipeDisponivel) -> some View {
        HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.largo) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Gerenciar equipe".localized)
                    .font(PapagaioTema.Tipo.tituloDePagina)
                    .foregroundStyle(PapagaioTema.texto)
                Text("Compartilhe o código para dar acesso ao espaço compartilhado.".localized)
                    .font(.title3)
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
            Spacer()
            Button("\("Mudar".localized): \(equipe.nome)", systemImage: "arrow.triangle.2.circlepath") {
                mostrandoTrocarEquipe = true
            }
            .buttonStyle(BotaoDeContornoPapagaio())
        }
    }

    private var estadoDoICloud: some View {
        HStack(spacing: PapagaioTema.Espaco.medio) {
            switch estadoDaSincronizacao {
            case .local:
                Label("Espaço local".localized, systemImage: "internaldrive")
            case .enviando:
                ProgressView()
                Text("Sincronizando com o iCloud…".localized)
            case .sincronizado:
                Label("Sincronizado com o iCloud".localized, systemImage: "checkmark.icloud")
                    .foregroundStyle(PapagaioTema.sucesso)
            case let .falhou(mensagem):
                Label(mensagem.localized, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(PapagaioTema.perigo)
                Spacer()
                Button("Tentar agora".localized, action: aoRetomarSincronizacao)
                    .buttonStyle(BotaoDeContornoPapagaio())
            }
            if !sincronizacaoFalhou {
                Spacer()
            }
        }
        .font(.callout)
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }

    private var sincronizacaoFalhou: Bool {
        if case .falhou = estadoDaSincronizacao { return true }
        return false
    }

    private func codigoDaEquipe(_ equipe: EquipeDisponivel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Label("Código de entrada".localized, systemImage: "number").font(.headline)
            Text(equipe.codigoDeEntrada ?? "Código indisponível para equipes criadas antes desta atualização.".localized)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            Text("Compartilhe este código com quem deve entrar. Ao informá-lo no Ōmu, a pessoa recebe acesso de leitura e escrita à equipe nesta Apple Account.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }

    private func participantesDaEquipe(_ equipe: EquipeDisponivel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Label("Participantes".localized, systemImage: "person.3")
                    .font(.headline)
                Spacer()
                Button("Atualizar".localized, systemImage: "arrow.clockwise") {
                    Task { await carregarParticipantes(da: equipe) }
                }
                .buttonStyle(BotaoDeContornoPapagaio())
                .disabled(carregandoParticipantes)
            }
            Text("A lista vem diretamente do compartilhamento do iCloud. O CloudKit não disponibiliza os e-mails das Apple Accounts.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
            if carregandoParticipantes {
                ProgressView("Carregando participantes…".localized)
            } else if let erroDosParticipantes {
                Label(erroDosParticipantes.localized, systemImage: "exclamationmark.icloud")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.perigo)
            } else {
                TabelaDaEquipe(
                    membros: participantes,
                    pagina: paginaDosParticipantes,
                    podeGerenciar: podeGerenciar(equipe),
                    aoEditarNome: { participanteParaRenomear = $0 },
                    aoEditar: { participanteParaEditar = $0 },
                    aoRemover: { participanteParaRemover = $0 },
                    aoAlternarPagina: { deslocamento in
                        paginaDosParticipantes = max(0, paginaDosParticipantes + deslocamento)
                    }
                )
            }
        }
        .sheet(item: $participanteParaEditar) { participante in
            EditorDePermissaoDaEquipe(
                participante: participante,
                aoSalvar: { permissao in
                    Task { await atualizarPermissao(permissao, do: participante, na: equipe) }
                },
                aoCancelar: { participanteParaEditar = nil }
            )
        }
        .sheet(item: $participanteParaRenomear) { participante in
            EditorDeNomeDaEquipe(
                participante: participante,
                nomeInicial: participante.eAtual && !nomeDoPerfil.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nomeDoPerfil : participante.nome,
                aoSalvar: { nome in
                    Task { await atualizarNome(nome, do: participante, na: equipe) }
                },
                aoCancelar: { participanteParaRenomear = nil }
            )
        }
        .confirmationDialog(
            "Remover %@?".localized(participanteParaRemover?.nome ?? "este participante".localized),
            isPresented: Binding(
                get: { participanteParaRemover != nil },
                set: { if !$0 { participanteParaRemover = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remover acesso".localized, role: .destructive) {
                guard let participante = participanteParaRemover else { return }
                participanteParaRemover = nil
                Task { await remover(participante, da: equipe) }
            }
        } message: {
            Text("Essa Apple Account não poderá mais ler nem alterar as conversas da equipe.".localized)
        }
    }

    private func configuracoesDaEquipe(_ equipe: EquipeDisponivel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Label("Configurações da equipe".localized, systemImage: "gearshape")
                .font(.headline)
            Picker("Visibilidade dos arquivos".localized, selection: $configuracoes.visibilidadeDosArquivos) {
                ForEach(VisibilidadeDosArquivosDaEquipe.allCases) { Text($0.rawValue.localized).tag($0) }
            }
            Picker("Recebimento de arquivos".localized, selection: $configuracoes.recebimentoDeArquivos) {
                ForEach(RecebimentoDeArquivosDaEquipe.allCases) { Text($0.rawValue.localized).tag($0) }
            }
            Text("Estas preferências são compartilhadas no iCloud. A política de revisão de recebimento será aplicada ao fluxo de arquivos em uma próxima etapa; ainda não bloqueia automaticamente envios.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
            if let erroDasConfiguracoes {
                Label(erroDasConfiguracoes.localized, systemImage: "exclamationmark.icloud")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.perigo)
            }
            Button("Salvar configurações".localized) {
                Task { await salvarConfiguracoes(da: equipe) }
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .disabled(salvandoConfiguracoes || configuracoes == equipe.configuracoes)
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }

    private func acoesIrreversiveis(_ equipe: EquipeDisponivel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Label("Acesso e exclusão".localized, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.headline)
            Text("Trocar o código cria um novo compartilhamento e exige que os participantes entrem novamente. Excluir a equipe apaga a zona compartilhada e os dados locais deste Mac.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
            if let erroDaOperacaoCritica {
                Label(erroDaOperacaoCritica.localized, systemImage: "exclamationmark.icloud")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.perigo)
            }
            HStack {
                Button("Trocar código de entrada".localized, systemImage: "key") {
                    confirmandoRotacaoDoCodigo = true
                }
                .buttonStyle(BotaoDeContornoPapagaio())
                .disabled(rotacionandoCodigo || excluindoEquipe)
                Button("Excluir equipe".localized, systemImage: "trash", role: .destructive) {
                    confirmandoExclusaoDaEquipe = true
                }
                .buttonStyle(BotaoDeContornoPapagaio())
                .disabled(rotacionandoCodigo || excluindoEquipe)
            }
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }

    private var avisoDeMembro: some View {
        Label("Somente a conta que criou a equipe pode consultar participantes, alterar configurações, trocar o código ou excluir a equipe.".localized, systemImage: "person.crop.circle.badge.exclamationmark")
            .font(.callout)
            .foregroundStyle(PapagaioTema.textoSecundario)
            .padding(PapagaioTema.Espaco.secao)
            .cartaoPapagaio()
    }

    private func atualizacaoDeEquipeExistente(_ equipe: EquipeDisponivel) -> some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            Label("Já usava esta equipe antes do acesso por código?".localized, systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Use esta ação uma vez para que o código também libere a zona compartilhada no iCloud. Convites pendentes por e-mail deixam de valer.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
            if let erroDaEntradaPorCodigo {
                Label(erroDaEntradaPorCodigo.localized, systemImage: "exclamationmark.icloud")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.perigo)
            } else if entradaPorCodigoAtualizada {
                Label("A entrada por código está ativa.".localized, systemImage: "checkmark.icloud")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.sucesso)
            }
            Button("Reconfigurar acesso por código".localized) {
                Task { await ativarEntradaPorCodigo(na: equipe) }
            }
            .buttonStyle(BotaoDeContornoPapagaio())
            .disabled(atualizandoEntradaPorCodigo)
        }
        .padding(PapagaioTema.Espaco.secao)
        .cartaoPapagaio()
    }

    private func ativarEntradaPorCodigo(na equipe: EquipeDisponivel) async {
        atualizandoEntradaPorCodigo = true
        erroDaEntradaPorCodigo = nil
        defer { atualizandoEntradaPorCodigo = false }
        do {
            try await servicoDeEquipes.ativarEntradaPorCodigo(na: equipe)
            entradaPorCodigoAtualizada = true
        } catch {
            erroDaEntradaPorCodigo = error.localizedDescription
        }
    }

    private func podeAtualizarEntradaPorCodigo(_ equipe: EquipeDisponivel) -> Bool {
        equipe.precisaReconfigurarEntradaPorCodigo
    }

    private func podeGerenciar(_ equipe: EquipeDisponivel) -> Bool {
        equipe.bancoCloudKit == BancoCloudKitDaEquipe.privado.rawValue
    }

    private func carregarParticipantes(da equipe: EquipeDisponivel) async {
        carregandoParticipantes = true
        erroDosParticipantes = nil
        defer { carregandoParticipantes = false }
        do {
            if podeGerenciar(equipe) {
                participantes = try await servicoDeEquipes.participantes(da: equipe)
            } else {
                participantes = [try await servicoDeEquipes.meuParticipante(
                    da: equipe,
                    nomePadrao: nomeDoPerfil
                )]
            }
            var atualizada = equipe
            atualizada.quantidadeDeMembros = participantes.count
            aoAtualizarEquipe(atualizada)
        } catch {
            erroDosParticipantes = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func atualizarNome(
        _ nome: String,
        do participante: ParticipanteDaEquipe,
        na equipe: EquipeDisponivel
    ) async {
        do {
            try await servicoDeEquipes.atualizarNome(de: participante.id, para: nome, na: equipe)
            participanteParaRenomear = nil
            await carregarParticipantes(da: equipe)
        } catch {
            erroDosParticipantes = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func atualizarPermissao(
        _ permissao: ParticipanteDaEquipe.Permissao,
        do participante: ParticipanteDaEquipe,
        na equipe: EquipeDisponivel
    ) async {
        do {
            try await servicoDeEquipes.atualizarPermissao(do: participante.id, para: permissao, na: equipe)
            participanteParaEditar = nil
            await carregarParticipantes(da: equipe)
        } catch {
            erroDosParticipantes = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func remover(_ participante: ParticipanteDaEquipe, da equipe: EquipeDisponivel) async {
        do {
            try await servicoDeEquipes.removerParticipante(participante.id, da: equipe)
            await carregarParticipantes(da: equipe)
        } catch {
            erroDosParticipantes = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func salvarConfiguracoes(da equipe: EquipeDisponivel) async {
        salvandoConfiguracoes = true
        erroDasConfiguracoes = nil
        defer { salvandoConfiguracoes = false }
        do {
            try await servicoDeEquipes.atualizarConfiguracoes(configuracoes, da: equipe)
            var atualizada = equipe
            atualizada.configuracoes = configuracoes
            aoAtualizarEquipe(atualizada)
        } catch {
            erroDasConfiguracoes = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func rotacionarCodigo(da equipe: EquipeDisponivel) async {
        rotacionandoCodigo = true
        erroDaOperacaoCritica = nil
        defer { rotacionandoCodigo = false }
        do {
            let atualizada = try await servicoDeEquipes.rotacionarCodigo(da: equipe)
            aoAtualizarEquipe(atualizada)
            await carregarParticipantes(da: atualizada)
        } catch {
            erroDaOperacaoCritica = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

    private func excluir(_ equipe: EquipeDisponivel) async {
        excluindoEquipe = true
        erroDaOperacaoCritica = nil
        defer { excluindoEquipe = false }
        do {
            try await aoExcluirEquipe(equipe)
        } catch {
            erroDaOperacaoCritica = DiagnosticoDaSincronizacaoCloudKit.mensagem(para: error)
        }
    }

}

private struct EditorDePermissaoDaEquipe: View {
    let participante: ParticipanteDaEquipe
    let aoSalvar: (ParticipanteDaEquipe.Permissao) -> Void
    let aoCancelar: () -> Void
    @State private var permissao: ParticipanteDaEquipe.Permissao

    init(
        participante: ParticipanteDaEquipe,
        aoSalvar: @escaping (ParticipanteDaEquipe.Permissao) -> Void,
        aoCancelar: @escaping () -> Void
    ) {
        self.participante = participante
        self.aoSalvar = aoSalvar
        self.aoCancelar = aoCancelar
        _permissao = State(initialValue: participante.permissao)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            Text("Permissão de %@".localized(participante.nome))
                .font(.title2.weight(.bold))
            Picker("Acesso".localized, selection: $permissao) {
                ForEach(ParticipanteDaEquipe.Permissao.allCases) { Text($0.rawValue.localized).tag($0) }
            }
            HStack {
                Button("Cancelar".localized, action: aoCancelar)
                Spacer()
                Button("Salvar".localized) { aoSalvar(permissao) }
                    .buttonStyle(BotaoDeContornoPapagaio())
            }
        }
        .padding(PapagaioTema.Espaco.pagina)
        .frame(width: 420)
    }
}

private struct EditorDeNomeDaEquipe: View {
    let participante: ParticipanteDaEquipe
    let aoSalvar: (String) -> Void
    let aoCancelar: () -> Void
    @State private var nome: String

    init(
        participante: ParticipanteDaEquipe,
        nomeInicial: String,
        aoSalvar: @escaping (String) -> Void,
        aoCancelar: @escaping () -> Void
    ) {
        self.participante = participante
        self.aoSalvar = aoSalvar
        self.aoCancelar = aoCancelar
        _nome = State(initialValue: nomeInicial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.secao) {
            Text("Nome na equipe".localized)
                .font(.title2.weight(.bold))
            TextField("Nome".localized, text: $nome)
            Text("Este nome será exibido para todas as pessoas desta equipe.".localized)
                .font(.callout)
                .foregroundStyle(PapagaioTema.textoSecundario)
            HStack {
                Button("Cancelar".localized, action: aoCancelar)
                Spacer()
                Button("Salvar".localized) { aoSalvar(nome) }
                    .buttonStyle(BotaoDeContornoPapagaio())
                    .disabled(nome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(PapagaioTema.Espaco.pagina)
        .frame(width: 420)
    }
}

#Preview("Gerenciar equipe") {
    GestaoDeEquipeView(
        equipeAtiva: .init(
            id: "produto",
            nome: "Produto",
            papel: "Administrador",
            quantidadeDeMembros: 4,
            codigoDeEntrada: "A7K2M9"
        ),
        equipes: [
            .init(
                id: "produto",
                nome: "Produto",
                papel: "Administrador",
                quantidadeDeMembros: 4,
                codigoDeEntrada: "A7K2M9"
            )
        ],
        aoSelecionarEquipe: { _ in }
    )
    .frame(width: 1_200, height: 760)
}
