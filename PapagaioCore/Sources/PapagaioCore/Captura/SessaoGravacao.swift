import AVFoundation
import Foundation

/// Uma sessão de gravação — backend portado do Eko (`RecordingController`).
///
/// Em vez de `AVAudioEngine` + ring buffers + conversão em tempo real, o
/// microfone é gravado direto por `AVAudioRecorder` num `.wav` PCM 16 kHz
/// mono (16 bits) e o áudio do sistema pelo `SystemAudioTap` num `.m4a` AAC
/// **na taxa nativa do tap**. Nenhuma mixagem é escrita em disco: a
/// reprodução junta os dois canais só no playback — ver `ReprodutorDeArquivo`.
///
/// **A falha do tap do sistema não derruba a gravação.** Se o tap não subir
/// (permissão negada, API indisponível), a sessão continua só com microfone e
/// registra o motivo em `avisos`.
@MainActor
public final class SessaoGravacao: NSObject, AVAudioRecorderDelegate {
    public struct Resultado: Sendable {
        public let id: UUID
        /// Caminho relativo ao container — é isto que vai para o modelo.
        public let pastaRelativa: String
        public let duracao: TimeInterval
        /// `true` quando o canal do sistema foi capturado (o tap subiu).
        public let capturouAudioDoSistema: Bool
        /// Tamanho em bytes do arquivo principal de áudio (`microfone.wav`).
        public let bytesMixagem: Int
        public let avisos: [String]

        public init(
            id: UUID,
            pastaRelativa: String,
            duracao: TimeInterval,
            capturouAudioDoSistema: Bool,
            bytesMixagem: Int,
            avisos: [String]
        ) {
            self.id = id
            self.pastaRelativa = pastaRelativa
            self.duracao = duracao
            self.capturouAudioDoSistema = capturouAudioDoSistema
            self.bytesMixagem = bytesMixagem
            self.avisos = avisos
        }
    }

    public let id: UUID
    private let armazenamento: Armazenamento

    /// Nível do microfone para a waveform ao vivo. Escrito pelo medidor do
    /// `AVAudioRecorder` a ~4 Hz e lido pela UI.
    public let nivelMicrofone = NivelAudio()

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pasta: URL?

    #if os(macOS)
    private var systemTap: SystemAudioTap?
    private var sistemaURL: URL?
    private var capturouSistema = false
    #endif

    /// Tempo de áudio gravado até agora, em segundos (o `currentTime` do
    /// `AVAudioRecorder` — sem relógio de parede, para notas e reprodução
    /// apontarem para o mesmo instante).
    public private(set) var tempoDecorrido: TimeInterval = 0
    private var pausada = false
    private var avisos: [String] = []

    /// Gravação mais curta que isto é clique acidental, não gravação.
    /// É descartada do disco em vez de virar arquivo pequeno na lista.
    public nonisolated static let duracaoMinima: TimeInterval = 1.0

    public init(id: UUID = UUID(), armazenamento: Armazenamento) {
        self.id = id
        self.armazenamento = armazenamento
    }

    // MARK: - Ciclo de vida

    public func iniciar() async throws {
        guard await AudioBiblioteca.pedirPermissaoDeMicrofone() else {
            throw ErroCaptura.semPermissaoMicrofone
        }

        let pasta = try armazenamento.criarPastaDaGravacao(id: id)
        self.pasta = pasta

        // 1. Microfone — obrigatório. Se falhar, a sessão inteira falha.
        let urlMicrofone = try armazenamento.criarArquivoDeAudio(
            id: id,
            nome: Armazenamento.Nome.microfone
        )
        let rec = try AVAudioRecorder(url: urlMicrofone, settings: FormatoAudio.microfoneWAV)
        rec.delegate = self
        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        guard rec.record() else {
            throw ErroCaptura.arquivoInvalido("AVAudioRecorder recusou começar a gravar")
        }
        recorder = rec

        // 2. Áudio do sistema — desejável, não obrigatório. Sem crash, com aviso.
        #if os(macOS)
        iniciarSistemaSePossivel()
        #endif

        // 3. Medidor: nível para a waveform e o tempo para as notas.
        // `Timer.scheduledTimer` é indisponível de contexto async no Swift 6.2
        // (pode nunca disparar); criar o timer e anexá-lo ao RunLoop da main
        // foge disso e garante o modo `.common`.
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(atualizarMedicao),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tempoDecorrido = 0
    }

    #if os(macOS)
    private func iniciarSistemaSePossivel() {
        // Declarado fora do `do` para o `catch` conseguir apagá-lo: o arquivo
        // nasce antes do tap começar, e é justamente quando o tap falha que
        // ele fica para trás.
        var urlCriada: URL?
        do {
            let url = try armazenamento.criarArquivoDeAudio(
                id: id,
                nome: Armazenamento.Nome.sistema
            )
            urlCriada = url
            let tap = SystemAudioTap()
            try tap.start(destinationURL: url)
            systemTap = tap
            sistemaURL = url
            capturouSistema = true
        } catch {
            // O `sistema.m4a` órfão é pior que arquivo nenhum. Ele tem alguns
            // bytes de cabeçalho, então passa no teste de "existe e não está
            // vazio", vira o insumo escolhido pelo pipeline e a transcrição
            // morre inteira com "arquivo de áudio inválido" — mesmo havendo um
            // microfone perfeitamente gravado ao lado.
            if let urlCriada {
                try? FileManager.default.removeItem(at: urlCriada)
            }
            systemTap = nil
            sistemaURL = nil
            capturouSistema = false
            avisos.append(
                "Áudio do sistema indisponível — gravando só o microfone. Motivo: \(error)"
            )
        }
    }
    #endif

    public func pausar() async {
        guard !pausada else { return }
        recorder?.pause()
        pausada = true
        nivelMicrofone.definirNormalizado(0)
    }

    public func continuar() async {
        guard pausada else { return }
        recorder?.record()
        pausada = false
    }

    public func descartar() async {
        encerrarCaptura()
        if let pasta {
            try? FileManager.default.removeItem(at: pasta)
        }
        self.pasta = nil
        pausada = false
        tempoDecorrido = 0
    }

    public func parar() async -> Resultado {
        let duracao = recorder?.currentTime ?? tempoDecorrido
        let urlDoSistema = sistemaURL
        encerrarCaptura()
        pausada = false
        tempoDecorrido = duracao

        var sistemaOk = false
        #if os(macOS)
        sistemaOk = capturouSistema
        if descartarSistemaSeVazio(urlDoSistema) {
            sistemaOk = false
            capturouSistema = false
            avisos.append("Áudio do sistema não capturou nada — a conversa tem só o microfone.")
        }
        #endif

        let bytes = pasta
            .flatMap { $0.appendingPathComponent(Armazenamento.Nome.microfone) }
            .flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil }
            ?? 0

        // Clique acidental: apaga em vez de deixar lixo na biblioteca.
        if duracao < Self.duracaoMinima, let pasta {
            try? FileManager.default.removeItem(at: pasta)
            self.pasta = nil
            return Resultado(
                id: id,
                pastaRelativa: Armazenamento.caminhoRelativo(id: id),
                duracao: 0,
                capturouAudioDoSistema: false,
                bytesMixagem: 0,
                avisos: ["Gravação curta demais (\(String(format: "%.1f", duracao)) s) — descartada."]
            )
        }

        return Resultado(
            id: id,
            pastaRelativa: Armazenamento.caminhoRelativo(id: id),
            duracao: duracao,
            capturouAudioDoSistema: sistemaOk,
            bytesMixagem: bytes,
            avisos: avisos
        )
    }

    #if os(macOS)
    /// Apaga o `sistema.m4a` que ficou sem som e diz se apagou.
    ///
    /// O tap pode **começar sem erro e não gravar nada** — foi o que aconteceu
    /// aqui: um contêiner M4A de 1 KB, só cabeçalho. Ele não é inofensivo:
    /// aparece na aba Mídia como um segundo arquivo de áudio que não toca, e o
    /// pipeline pode elegê-lo como insumo, já que "existe e não está vazio".
    ///
    /// O corte é por tamanho, e não por inspeção de trilha: `AVAsset` custa
    /// caro e este caminho roda no fim de toda gravação. 16 KB é folgado para
    /// cabeçalho de M4A e apertado para qualquer áudio de verdade — mesmo um
    /// segundo de AAC passa disso.
    private func descartarSistemaSeVazio(_ url: URL?) -> Bool {
        guard let url,
              let tamanho = try? FileManager.default
                  .attributesOfItem(atPath: url.path)[.size] as? Int,
              tamanho < 16_384
        else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
    #endif

    private func encerrarCaptura() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        #if os(macOS)
        systemTap?.stop()
        systemTap = nil
        sistemaURL = nil
        #endif
    }

    // MARK: - Medição

    @objc private func atualizarMedicao() {
        guard let recorder, !pausada else { return }
        tempoDecorrido = recorder.currentTime
        recorder.updateMeters()
        let decibeis = recorder.averagePower(forChannel: 0)
        let nivel = max(0, min(1, (decibeis + 50) / 50))
        nivelMicrofone.definirNormalizado(nivel)
    }

    /// `nonisolated` é obrigatório: o protocolo é tão nonisolated, e a classe é
    /// `@MainActor` (Swift 6.2 acusa `#ConformanceIsolation`). O delegate chega
    /// da thread de áudio; o trabalho volta para a main via `Task { @MainActor }`.
    public nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        guard !flag else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.avisos.append("A gravação foi interrompida pelo sistema antes do esperado.")
        }
    }
}
