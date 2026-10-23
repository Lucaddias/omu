import Foundation
import Network
import PapagaioCore

/// Onde o resumo é gerado, por escolha de quem usa.
///
/// Sem escolha feita vale o modo local — o comportamento de sempre. A
/// transcrição só sai do Mac para a nuvem privada da Apple depois de um sim
/// explícito, no cartão de modelos ou nas Configurações.
enum PreferenciaDeResumo {
    static let chave = "modoDeResumo"

    static func escolha(em defaults: UserDefaults = .standard) -> ModoDeResumo? {
        defaults.string(forKey: chave).flatMap(ModoDeResumo.init(rawValue:))
    }

    static func guardar(_ modo: ModoDeResumo, em defaults: UserDefaults = .standard) {
        defaults.set(modo.rawValue, forKey: chave)
    }

    /// O modo que vale agora.
    ///
    /// A nuvem escolhida num Mac (ou num build) que nunca vai alcançá-la
    /// volta para o local: o preflight então diz o que falta baixar, em vez
    /// de deixar todo resumo falhar. Indisponibilidade passageira — Apple
    /// Intelligence ainda se preparando — não desfaz a escolha.
    static func modoAtivo(
        em defaults: UserDefaults = .standard,
        disponibilidade: DisponibilidadeDaNuvemPrivada = NuvemPrivada.disponibilidade
    ) -> ModoDeResumo {
        guard escolha(em: defaults) == .nuvemPrivada else { return .local }
        switch disponibilidade {
        case .disponivel, .sistemaNaoPronto, .indisponivel: return .nuvemPrivada
        case .sistemaAntigo, .semEntitlement, .dispositivoNaoElegivel: return .local
        }
    }
}

/// Por que um resumo pela nuvem ficou para depois, e até quando.
///
/// Vai para o disco junto com o pedido (`PendenciaDeProcessamento`): fechar o
/// app não faz o Ōmu esquecer que deve um resumo, nem gastar a cota tentando
/// antes da hora.
enum EsperaDoResumo: Codable, Equatable {
    /// Sem internet. Volta quando a rede voltar ou nesta hora, o que vier
    /// primeiro.
    case rede(ate: Date)
    /// Limite diário do Apple Intelligence atingido: só depois de renovado.
    case cota(ate: Date)
    /// A nuvem privada está fora do ar.
    case servico(ate: Date)

    /// Entre uma tentativa e outra quando a Apple não diz quando voltar.
    static let intervaloDeNovaTentativa: TimeInterval = 5 * 60
    /// A Apple nem sempre informa quando o limite zera.
    static let esperaDaCotaSemData: TimeInterval = 60 * 60

    var ate: Date {
        switch self {
        case let .rede(ate), let .cota(ate), let .servico(ate): ate
        }
    }

    var cedeARede: Bool {
        if case .rede = self { return true }
        return false
    }

    var mensagem: String {
        switch self {
        case .rede:
            "Sem internet: o resumo será gerado quando a conexão voltar.".localized
        case let .cota(ate):
            "Limite diário do Apple Intelligence atingido. O resumo será gerado depois de %@.".localized(
                ate.formatted(
                    date: Calendar.current.isDateInToday(ate) ? .omitted : .abbreviated,
                    time: .shortened
                )
            )
        case .servico:
            "A nuvem privada da Apple está indisponível. O resumo será tentado de novo em instantes.".localized
        }
    }
}

/// O que fazer quando o resumo pela nuvem privada falha.
///
/// A transcrição já está salva nesse ponto (o pipeline grava antes de
/// resumir), então nenhuma das saídas refaz o Whisper.
enum ReacaoAoErroDaNuvem: Equatable {
    /// Gera o resumo com o modelo deste Mac.
    case resumirNoMac
    /// O pedido continua valendo e é refeito sozinho mais tarde.
    case adiar(EsperaDoResumo)
    /// Repetir não muda o resultado: a pessoa precisa saber o motivo.
    case desistir

    /// - Parameter modeloLocalPronto: o Qwen está em disco e cabe na memória.
    ///   Quem tem os dois caminhos nunca espera pela rede nem pela cota.
    static func para(
        _ erro: ErroDaNuvemPrivada,
        modeloLocalPronto: Bool,
        agora: Date = Date()
    ) -> ReacaoAoErroDaNuvem {
        if modeloLocalPronto { return .resumirNoMac }
        let emBreve = agora.addingTimeInterval(EsperaDoResumo.intervaloDeNovaTentativa)
        switch erro {
        case .semConexao:
            return .adiar(.rede(ate: emBreve))
        case let .cotaEsgotada(reiniciaEm):
            // Uma data já vencida faria a fila tentar em laço.
            let renovacao = reiniciaEm.map { max($0, agora.addingTimeInterval(60)) }
            return .adiar(.cota(
                ate: renovacao ?? agora.addingTimeInterval(EsperaDoResumo.esperaDaCotaSemData)
            ))
        case .servicoIndisponivel:
            return .adiar(.servico(ate: emBreve))
        case .indisponivel, .conteudoRecusado, .idiomaNaoSuportado, .contextoExcedido, .falha:
            return .desistir
        }
    }
}

/// Acorda a fila quando um resumo adiado pode ser tentado de novo: na hora
/// marcada, ou assim que a internet volta.
@MainActor
final class DespertadorDeResumos {
    /// `redeVoltou` distingue a volta da conexão da hora marcada: só a
    /// primeira libera quem esperava pela rede antes do prazo.
    var aoAcordar: (@MainActor (_ redeVoltou: Bool) -> Void)?

    private var temporizador: Task<Void, Never>?
    private var vigiaDeRede: NWPathMonitor?
    private var redeEstavaFora = false

    /// Reagenda do zero para as esperas de agora. Sem espera, desliga tudo.
    func agendar(_ esperas: [EsperaDoResumo]) {
        temporizador?.cancel()
        temporizador = nil
        guard let proxima = esperas.map(\.ate).min() else {
            pararVigia()
            return
        }
        // Um prazo já vencido que a fila não pegou está preso por outro
        // motivo (modelos, disco, outro processamento): insistir a cada
        // segundo não o solta.
        let falta = proxima.timeIntervalSinceNow
        let intervalo = falta > 0 ? falta : EsperaDoResumo.intervaloDeNovaTentativa
        temporizador = Task { [weak self] in
            try? await Task.sleep(for: .seconds(intervalo))
            guard !Task.isCancelled else { return }
            self?.aoAcordar?(false)
        }
        if esperas.contains(where: \.cedeARede) {
            iniciarVigia()
        } else {
            pararVigia()
        }
    }

    private func iniciarVigia() {
        guard vigiaDeRede == nil else { return }
        let vigia = NWPathMonitor()
        redeEstavaFora = false
        vigia.pathUpdateHandler = { [weak self] caminho in
            let conectado = caminho.status == .satisfied
            Task { @MainActor in self?.registrar(conectado: conectado) }
        }
        vigia.start(queue: .global(qos: .utility))
        vigiaDeRede = vigia
    }

    private func pararVigia() {
        vigiaDeRede?.cancel()
        vigiaDeRede = nil
    }

    /// Só a **volta** da rede acorda a fila. O monitor avisa o estado atual
    /// assim que começa: tratar esse primeiro "conectado" como volta faria um
    /// resumo que falhou com a rede de pé ser tentado de novo em laço.
    private func registrar(conectado: Bool) {
        guard conectado else {
            redeEstavaFora = true
            return
        }
        guard redeEstavaFora else { return }
        redeEstavaFora = false
        aoAcordar?(true)
    }
}
