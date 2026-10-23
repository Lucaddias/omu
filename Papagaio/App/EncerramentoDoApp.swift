import Foundation

/// O que precisa terminar antes de o processo sair.
///
/// O delegate do app não enxerga o estado das cenas; a raiz registra aqui o
/// gravador, e o `applicationShouldTerminate` consulta este ponto único.
@MainActor
enum EncerramentoDoApp {
    private static weak var gravador: GravadorViewModel?

    /// Teto da espera. Finalizar é fechar dois arquivos e gravar um registro;
    /// se algo travar, o app sai assim mesmo — a gravação fica no disco e é
    /// reencontrada na próxima abertura (`Biblioteca.recuperarGravacoesOrfas`).
    static var limite: Duration = .seconds(15)

    static func registrar(_ gravador: GravadorViewModel) {
        self.gravador = gravador
    }

    static var haGravacaoEmCurso: Bool {
        gravador?.gravando ?? false
    }

    /// Finaliza a gravação em curso, ou desiste ao fim do `limite`.
    static func finalizarGravacao() async {
        guard let gravador, gravador.gravando else { return }
        let finalizacao = Task { @MainActor in
            await gravador.finalizarAntesDeEncerrar()
        }
        await aguardar(finalizacao, ate: limite)
    }

    /// Espera a tarefa terminar, mas não mais que o limite: cancelar não
    /// interrompe um `await` que não coopera, então a espera em si é que
    /// precisa ter teto.
    private static func aguardar(_ tarefa: Task<Void, Never>, ate limite: Duration) async {
        await withCheckedContinuation { (continuacao: CheckedContinuation<Void, Never>) in
            let retomada = RetomadaUnica(continuacao)
            Task { @MainActor in
                await tarefa.value
                retomada.retomar()
            }
            Task { @MainActor in
                try? await Task.sleep(for: limite)
                retomada.retomar()
            }
        }
    }

    @MainActor
    private final class RetomadaUnica {
        private var continuacao: CheckedContinuation<Void, Never>?

        init(_ continuacao: CheckedContinuation<Void, Never>) {
            self.continuacao = continuacao
        }

        func retomar() {
            continuacao?.resume()
            continuacao = nil
        }
    }
}
