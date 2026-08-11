import Darwin
import Dispatch
import Foundation

/// Mantém os modelos residentes em memória entre execuções e os descarrega sob
/// pressão de memória.
///
/// Por que residente: carregar 10,7 GB do disco leva 10–30 s. Fazer isso a cada
/// resumo transformaria uma operação de segundos numa de meio minuto.
///
/// Por que descarregar: 10,7 GB num Mac de 18 GB é a maior parte da RAM. Sem
/// reagir à pressão, o app vira o candidato óbvio do jetsam — e é o processo do
/// usuário que morre, não o modelo.
public actor CicloDeVidaDeModelos {
    /// Um recurso caro que sabe se descarregar.
    public protocol Residente: AnyObject, Sendable {
        var identificador: String { get }
        func descarregar() async
    }

    private var residentes: [String: any Residente] = [:]
    private var monitor: DispatchSourceMemoryPressure?
    private var ultimoDescarte: Date?
    private var observadorDeSaida: (any NSObjectProtocol)?

    public init() {}

    /// Começa a observar pressão de memória. Idempotente.
    public func iniciarMonitoramento() {
        guard monitor == nil else { return }

        let fonte = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        // O evento em si não é consultado: `.warning` e `.critical` levam ao
        // mesmo lugar. Não há meio termo útil com um modelo de 10,7 GB — ou ele
        // está na memória, ou não está.
        fonte.setEventHandler { [weak self] in
            Task { await self?.descarregarTudo() }
        }
        fonte.resume()
        monitor = fonte
    }

    public func pararMonitoramento() {
        monitor?.cancel()
        monitor = nil
    }

    public func registrar(_ residente: any Residente) {
        residentes[residente.identificador] = residente
    }

    public func remover(_ identificador: String) {
        residentes[identificador] = nil
    }

    public var identificadoresResidentes: [String] {
        Array(residentes.keys).sorted()
    }

    public var descartouRecentemente: Date? { ultimoDescarte }

    /// Descarrega tudo. Chamado sob pressão crítica e disponível para a UI.
    public func descarregarTudo() async {
        for (_, residente) in residentes {
            await residente.descarregar()
        }
        residentes.removeAll()
        ultimoDescarte = Date()
    }

    /// Descarrega os modelos **antes** de o processo sair.
    ///
    /// Sem isto o app aborta ao ser fechado. O ggml guarda os dispositivos
    /// Metal numa lista estática; ao sair, o destrutor dessa lista roda com o
    /// contexto do llama ainda vivo, encontra buffers pendurados no conjunto
    /// de residência e dispara `GGML_ASSERT([rsets->data count] == 0)` —
    /// `ggml_abort`, SIGABRT, com o stack apontando para `exit`. Liberar
    /// contexto e modelo enquanto o app ainda está de pé esvazia esse
    /// conjunto, e o destrutor estático encontra tudo zerado.
    ///
    /// `atexit` não serve: roda tarde demais, junto dos destrutores estáticos.
    /// O aviso do AppKit chega antes de qualquer um deles.
    public func encerrarNaSaidaDoApp() {
        guard observadorDeSaida == nil else { return }
        observadorDeSaida = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Síncrono de propósito: depois deste retorno o processo sai, e uma
            // Task assíncrona não teria tempo de rodar.
            let espera = DispatchSemaphore(value: 0)
            Task {
                await self.descarregarTudo()
                espera.signal()
            }
            espera.wait()
        }
    }

    /// Memória física em uso pelo processo, para diagnóstico e testes.
    public static var memoriaDoProcesso: Int64 {
        var info = task_vm_info_data_t()
        var contagem = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let resultado = withUnsafeMutablePointer(to: &info) { ponteiro in
            ponteiro.withMemoryRebound(to: integer_t.self, capacity: Int(contagem)) { reapontado in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reapontado, &contagem)
            }
        }
        guard resultado == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }
}
