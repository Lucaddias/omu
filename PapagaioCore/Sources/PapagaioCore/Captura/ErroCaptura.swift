import Darwin
import Foundation

/// Erros de captura. Todos recuperáveis do ponto de vista do app: o Passo 2
/// exige que a falha do tap do sistema **não derrube** a gravação do microfone.
public enum ErroCaptura: Error, CustomStringConvertible, LocalizedError {
    case coreAudio(String, OSStatus)
    case tapIndisponivel(String)
    case formatoIndisponivel
    case semPermissaoMicrofone
    case semPermissaoAudioDoSistema
    case arquivoInvalido(String)

    public var description: String {
        switch self {
        case let .coreAudio(oQue, status):
            "\(oQue) falhou (OSStatus \(status)\(Self.fourCC(status)))"
        case let .tapIndisponivel(oQue):
            "não foi possível criar o tap de áudio do sistema: \(oQue)"
        case .formatoIndisponivel:
            "não foi possível ler o formato de stream do tap"
        case .semPermissaoMicrofone:
            "permissão de microfone negada"
        case .semPermissaoAudioDoSistema:
            "permissão de captura de áudio do sistema negada"
        case let .arquivoInvalido(motivo):
            "arquivo de áudio inválido: \(motivo)"
        }
    }

    /// Sem isto, `localizedDescription` cai no texto padrão do Foundation e a
    /// notificação mostra "PapagaioCore.ErroCaptura erro 2" — o número da
    /// posição do caso no enum, que não diz nada a quem está usando o app.
    /// `LocalizedError` faz o `description` acima chegar até a tela.
    public var errorDescription: String? { description }

    /// OSStatus do Core Audio quase sempre é um four-char code legível.
    private static func fourCC(_ status: OSStatus) -> String {
        let valor = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((valor >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }
}
