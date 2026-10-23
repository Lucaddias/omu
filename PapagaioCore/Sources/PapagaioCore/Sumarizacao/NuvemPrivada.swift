import Foundation
import Security
// O modelo de servidor só existe no SDK do macOS 27 (Xcode 27, Swift 6.4). O
// CI ainda compila com o SDK 26: ali tudo abaixo responde "sistema antigo".
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

/// Onde o resumo é gerado.
///
/// A transcrição é sempre local (Whisper). O que muda é o modelo de linguagem:
/// o Qwen neste Mac, ou o modelo de servidor do Apple Intelligence pelo
/// Private Cloud Compute — que dispensa o download de 6,2 GB e os 18 GB de
/// RAM, mas manda a transcrição para os servidores da Apple.
public enum ModoDeResumo: String, Sendable, Codable, CaseIterable {
    case local
    case nuvemPrivada
}

/// Se este Mac pode usar a nuvem privada agora, e por que não.
public enum DisponibilidadeDaNuvemPrivada: Sendable, Equatable {
    case disponivel
    /// macOS anterior ao 27 (ou app compilado com o SDK antigo).
    case sistemaAntigo
    /// A Apple ainda não concedeu `com.apple.developer.private-cloud-compute`
    /// a este build — caso de builds de desenvolvimento e da CLI.
    case semEntitlement
    /// Mac ou região sem Apple Intelligence.
    case dispositivoNaoElegivel
    /// Apple Intelligence desligado, ou ainda se preparando.
    case sistemaNaoPronto
    /// Motivo que este build não conhece.
    case indisponivel

    public var mensagem: String {
        switch self {
        case .disponivel:
            "A nuvem privada da Apple está disponível."
        case .sistemaAntigo:
            "O resumo pela nuvem privada da Apple exige o macOS 27 ou posterior."
        case .semEntitlement:
            "Esta versão do Ōmu não tem acesso à nuvem privada da Apple."
        case .dispositivoNaoElegivel:
            "Este Mac ou esta região não tem o Apple Intelligence."
        case .sistemaNaoPronto:
            "Ative o Apple Intelligence em Ajustes do Sistema para usar a nuvem privada da Apple."
        case .indisponivel:
            "A nuvem privada da Apple não está disponível agora."
        }
    }
}

/// O estado do limite diário de uso, que a Apple conta na conta iCloud de
/// quem usa — não na do Ōmu. A Apple não publica o número; só diz se a
/// pessoa está perto dele, se chegou nele e quando ele zera.
public struct CotaDaNuvemPrivada: Sendable, Equatable {
    public var proximaDoLimite: Bool
    public var limiteAtingido: Bool
    /// `nil` quando a Apple não informa (longe do limite, em geral).
    public var reiniciaEm: Date?
    /// Há uma oferta de limite maior (iCloud+) para mostrar.
    public var podeAumentar: Bool

    public init(
        proximaDoLimite: Bool = false,
        limiteAtingido: Bool = false,
        reiniciaEm: Date? = nil,
        podeAumentar: Bool = false
    ) {
        self.proximaDoLimite = proximaDoLimite
        self.limiteAtingido = limiteAtingido
        self.reiniciaEm = reiniciaEm
        self.podeAumentar = podeAumentar
    }

    public static let livre = CotaDaNuvemPrivada()
}

/// Falhas do resumo pela nuvem, na língua de quem decide o que fazer com
/// elas: tentar de novo depois, cair no modelo local ou desistir.
public enum ErroDaNuvemPrivada: Error, Equatable, CustomStringConvertible, LocalizedError {
    case indisponivel(DisponibilidadeDaNuvemPrivada)
    case semConexao
    case cotaEsgotada(reiniciaEm: Date?)
    case servicoIndisponivel
    /// As proteções de conteúdo da Apple recusaram a transcrição.
    case conteudoRecusado
    case idiomaNaoSuportado
    /// O pedido não coube na janela do modelo. `tokens` é a contagem real —
    /// o único jeito de conhecê-la, já que o modelo de servidor não conta
    /// tokens antes do envio.
    case contextoExcedido(tokens: Int, limite: Int)
    case falha(String)

    /// O pedido continua valendo: nada mudou no conteúdo, só falta rede,
    /// cota ou o serviço voltar. A conversa fica transcrita e o resumo é
    /// refeito sozinho mais tarde.
    public var adiavel: Bool {
        switch self {
        case .semConexao, .cotaEsgotada, .servicoIndisponivel: true
        case .indisponivel, .conteudoRecusado, .idiomaNaoSuportado, .contextoExcedido, .falha: false
        }
    }

    public var description: String {
        switch self {
        case let .indisponivel(motivo):
            motivo.mensagem
        case .semConexao:
            "sem conexão com a nuvem privada da Apple; o resumo será gerado quando a internet voltar"
        case .cotaEsgotada:
            "o limite diário do Apple Intelligence foi atingido; o resumo será gerado quando ele for renovado"
        case .servicoIndisponivel:
            "a nuvem privada da Apple está indisponível no momento; o resumo será tentado de novo"
        case .conteudoRecusado:
            "a Apple recusou o conteúdo desta conversa; para resumi-la, use o modelo neste Mac"
        case .idiomaNaoSuportado:
            "a nuvem privada da Apple não atende o idioma desta conversa; use o modelo neste Mac"
        case let .contextoExcedido(tokens, limite):
            "a conversa tem \(tokens) tokens e a nuvem privada da Apple aceita \(limite)"
        case let .falha(detalhe):
            "a nuvem privada da Apple não concluiu o resumo: \(detalhe)"
        }
    }

    public var errorDescription: String? { description }
}

/// Porta de entrada para o estado da nuvem privada, sem tipos do
/// `FoundationModels` na assinatura — o app e os testes compilam e rodam
/// iguais no macOS 26.
public enum NuvemPrivada {
    public static let entitlement = "com.apple.developer.private-cloud-compute"

    /// Se o resumo pela nuvem pode ser oferecido agora.
    ///
    /// O entitlement é conferido antes de tocar no modelo: sem ele a Apple
    /// não promete comportamento nenhum, e um build de desenvolvimento não
    /// deve descobrir isso no meio de um resumo.
    public static var disponibilidade: DisponibilidadeDaNuvemPrivada {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(macOS 27.0, *) else { return .sistemaAntigo }
        guard temEntitlement else { return .semEntitlement }
        switch ModeloDeServidor.compartilhado.availability {
        case .available: return .disponivel
        case .unavailable(.deviceNotEligible): return .dispositivoNaoElegivel
        case .unavailable(.systemNotReady): return .sistemaNaoPronto
        case .unavailable: return .indisponivel
        }
#else
        return .sistemaAntigo
#endif
    }

    /// O limite diário de quem está usando este Mac.
    ///
    /// Lê o modelo observável da Apple: uma view que chama isto no `body`
    /// redesenha quando a cota muda.
    public static var cota: CotaDaNuvemPrivada {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(macOS 27.0, *), disponibilidade == .disponivel else { return .livre }
        let uso = ModeloDeServidor.compartilhado.quotaUsage
        var proxima = false
        if case let .belowLimit(detalhe) = uso.status { proxima = detalhe.isApproachingLimit }
        return CotaDaNuvemPrivada(
            proximaDoLimite: proxima,
            limiteAtingido: uso.isLimitReached,
            reiniciaEm: uso.resetDate,
            podeAumentar: uso.limitIncreaseSuggestion != nil
        )
#else
        return .livre
#endif
    }

    /// Abre a tela da Apple com as opções de limite maior, quando há uma.
    @MainActor
    public static func mostrarOpcoesDeLimite() {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(macOS 27.0, *), disponibilidade == .disponivel else { return }
        ModeloDeServidor.compartilhado.quotaUsage.limitIncreaseSuggestion?.show()
#endif
    }

    /// `true` quando a assinatura deste processo carrega o entitlement.
    static var temEntitlement: Bool {
#if DEBUG
        // Para exercitar a interface com a disponibilidade simulada do Xcode
        // (Scheme › Run › Options), que não depende da concessão da Apple.
        if ProcessInfo.processInfo.environment["OMU_NUVEM_SEM_ENTITLEMENT"] == "1" { return true }
#endif
        guard let tarefa = SecTaskCreateFromSelf(nil),
              let valor = SecTaskCopyValueForEntitlement(tarefa, entitlement as CFString, nil)
        else { return false }
        // A chave presente basta, qualquer que seja o tipo do valor; só um
        // `false` explícito nega.
        return (valor as? Bool) ?? true
    }
}

#if compiler(>=6.4) && canImport(FoundationModels)
/// Uma instância só do modelo: é ela que a Apple mantém atualizada com a
/// cota, e é observando ela que a interface redesenha.
@available(macOS 27.0, *)
enum ModeloDeServidor {
    static let compartilhado = PrivateCloudComputeLanguageModel()
}
#endif
