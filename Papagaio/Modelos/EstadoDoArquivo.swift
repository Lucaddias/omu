import PapagaioCore
import SwiftUI

/// Em que ponto do pipeline um arquivo está.
///
/// Existe porque `Biblioteca.estado(de:)` devolvia **texto livre**, e as duas
/// telas classificavam esse texto de jeitos diferentes e incompatíveis: o cartão
/// por lista negativa de strings literais, o detalhe por `contains("erro")`. O
/// mesmo arquivo aparecia vermelho na biblioteca e neutro no detalhe, e trocar
/// uma palavra em `Fase.descricao` quebrava a cor sem quebrar o build.
///
/// Agora existe uma fonte só: quem decide o estado é a `Biblioteca`, e as views
/// apenas leem `descricao`, `estilo` e `simbolo`.
enum EstadoDoArquivo: Equatable {
    case prontoParaTranscrever
    case naFila(posicao: Int)
    case processando(PipelineDeArquivo.Fase)
    case transcrito
    case transcritoEResumido
    case falhou(String)

    var descricao: String {
        switch self {
        case .prontoParaTranscrever: "pronto para transcrever".localized
        case let .naFila(posicao): "na fila (posição %d)".localized(posicao)
        case let .processando(fase): fase.descricao.localized
        case .transcrito: "transcrito".localized
        case .transcritoEResumido: "transcrito e resumido".localized
        case let .falhou(motivo): motivo.localized
        }
    }

    var estilo: EstiloDoStatus {
        switch self {
        case .processando: .destaque
        case .naFila: .aviso
        case .falhou: .erro
        case .transcritoEResumido: .sucesso
        case .transcrito, .prontoParaTranscrever: .neutro
        }
    }

    var simbolo: String {
        switch self {
        case .processando: "waveform"
        case .naFila: "clock"
        case .falhou: "exclamationmark.triangle"
        case .transcritoEResumido: "checkmark.circle"
        case .transcrito: "text.quote"
        case .prontoParaTranscrever: "text.badge.plus"
        }
    }

    /// Um trabalho em andamento não pode ser reprocessado, duplicado nem
    /// movido para a lixeira enquanto o pipeline lê o áudio dele.
    var ocupado: Bool {
        switch self {
        case .processando, .naFila: true
        default: false
        }
    }
}
