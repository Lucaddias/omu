import AVFoundation
import CoreAudio
import Foundation

/// Uma sessão de gravação — backend portado do Eko (`RecordingController`).
///
/// Em vez de `AVAudioEngine` + ring buffers + conversão em tempo real, o
/// microfone é gravado direto por `AVAudioRecorder` num `.wav` PCM 16 kHz
/// mono (16 bits) e o áudio do sistema pelo `SystemAudioTap` num `.caf` PCM
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
        /// Se o usuário estava com fones de ouvido (ou Bluetooth) no momento
        /// da gravação. Usado pelo pipeline para decidir se aplica cancelamento
        /// de eco no microfone.
        public let usavaFones: Bool

        public init(
            id: UUID,
            pastaRelativa: String,
            duracao: TimeInterval,
            capturouAudioDoSistema: Bool,
            bytesMixagem: Int,
            avisos: [String],
            usavaFones: Bool = false
        ) {
            self.id = id
            self.pastaRelativa = pastaRelativa
            self.duracao = duracao
            self.capturouAudioDoSistema = capturouAudioDoSistema
            self.bytesMixagem = bytesMixagem
            self.avisos = avisos
            self.usavaFones = usavaFones
        }
    }

    public let id: UUID
    private let armazenamento: Armazenamento

    /// Nível do microfone para a waveform ao vivo. Escrito pelo medidor do
    /// `AVAudioRecorder` a ~4 Hz e lido pela UI.
    public let nivelMicrofone = NivelAudio()
    /// Nível entregue pelo Process Tap da saída do sistema. É separado do
    /// microfone para que a interface revele imediatamente se o interlocutor
    /// está chegando ao app.
    public let nivelSistema = NivelAudio()

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pasta: URL?

    #if os(macOS)
    private var systemTap: SystemAudioTap?
    private var sistemaURL: URL?
    private var capturouSistema = false
    private var estavamFonesNoInicio = false
    #endif

    /// Tempo de áudio gravado até agora, em segundos (o `currentTime` do
    /// `AVAudioRecorder` — sem relógio de parede, para notas e reprodução
    /// apontarem para o mesmo instante).
    public private(set) var tempoDecorrido: TimeInterval = 0
    private var pausada = false
    private var avisos: [String] = []
    /// `true` enquanto `parar()`/`descartar()` encerram o gravador de
    /// propósito — é o que distingue, no delegate, o fim pedido pelo app do
    /// fim imposto pelo sistema.
    private var encerrandoPorPedido = false
    /// O sistema encerrou o gravador sozinho (entrada removida, disco cheio,
    /// erro de codificação). A partir daí `currentTime` volta a 0 e não serve
    /// mais como duração.
    public private(set) var interrompida = false

    /// O tap do sistema fica preso à saída de áudio do início da gravação.
    nonisolated static let avisoDeTrocaDeSaida =
        "A saída de áudio do Mac mudou durante a gravação (fones conectados ou desconectados). "
        + "A partir desse ponto o áudio do interlocutor pode não ter sido gravado."

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
            // Falhar aqui deixava um `AVAudioRecorder` preparado e vivo,
            // segurando o dispositivo de entrada: a tentativa seguinte
            // encontrava o microfone ocupado e falhava também, e assim por
            // diante. Soltar o recurso antes de propagar o erro quebra esse
            // ciclo — a próxima tentativa começa limpa.
            rec.stop()
            try? FileManager.default.removeItem(at: pasta)
            self.pasta = nil
            throw ErroCaptura.arquivoInvalido("AVAudioRecorder recusou começar a gravar")
        }
        recorder = rec

        // 2. Áudio do sistema — desejável, não obrigatório. Sem crash, com aviso.
        #if os(macOS)
        estavamFonesNoInicio = Self.detectarFonesDeOuvido()
        iniciarSistemaSePossivel()
        #endif

        // 3. Medidor: nível para a waveform e o tempo para as notas.
        // `Timer.scheduledTimer` é indisponível de contexto async no Swift 6.2
        // (pode nunca disparar); criar o timer e anexá-lo ao RunLoop da main
        // foge disso e garante o modo `.common`.
        //
        // Bloco com `[weak self]` no lugar de `target: self`: o timer de
        // destino retém a sessão, e um caminho de erro que nunca chegasse a
        // `parar()`/`descartar()` a manteria viva para sempre junto com o
        // recorder e o tap — o `ReprodutorDeArquivo` já usa o padrão fraco.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.atualizarMedicao()
            }
        }
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
            let tap = SystemAudioTap(nivel: nivelSistema)
            try tap.start(destinationURL: url)
            systemTap = tap
            sistemaURL = url
            capturouSistema = true
        } catch {
            // O `sistema.caf` órfão é pior que arquivo nenhum. Ele tem alguns
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
        registrarTempoDoGravador()
        recorder?.pause()
        #if os(macOS)
        // O tap não pausa o stream — pausa a escrita. Sem isso o canal do
        // sistema acumula o tempo de pausa e se desalinha do microfone.
        systemTap?.pausar()
        nivelSistema.definirNormalizado(0)
        #endif
        pausada = true
        nivelMicrofone.definirNormalizado(0)
    }

    public func continuar() async {
        guard pausada else { return }
        #if os(macOS)
        // Retoma a escrita antes do recorder para não perder o primeiro
        // buffer que o microfone ainda não pediu.
        systemTap?.continuar()
        #endif
        recorder?.record()
        pausada = false
    }

    public func descartar() async {
        _ = encerrarCaptura()
        if let pasta {
            try? FileManager.default.removeItem(at: pasta)
        }
        self.pasta = nil
        pausada = false
        tempoDecorrido = 0
    }

    public func parar() async -> Resultado {
        // `currentTime` volta a 0 quando o gravador já parou sozinho; por isso
        // ele só pode aumentar o maior tempo já observado, nunca substituí-lo.
        registrarTempoDoGravador()
        let urlDoSistema = sistemaURL
        let urlDoMicrofone = pasta?.appendingPathComponent(Armazenamento.Nome.microfone)
        let estatisticasDoSistema = encerrarCaptura()
        pausada = false
        // Com o gravador fechado, o cabeçalho do WAV está completo: o arquivo
        // é a medida real do que foi gravado — inclusive quando o sistema
        // interrompeu a gravação no meio.
        let duracao = Self.duracaoFinal(
            observada: tempoDecorrido,
            doArquivo: urlDoMicrofone.flatMap(Self.duracaoDoMicrofone(em:))
        )
        tempoDecorrido = duracao

        var sistemaOk = false
        #if os(macOS)
        sistemaOk = capturouSistema
        if let estatisticasDoSistema, estatisticasDoSistema.callbacks == 0 {
            sistemaOk = false
            capturouSistema = false
            if let urlDoSistema { try? FileManager.default.removeItem(at: urlDoSistema) }
            avisos.append("Áudio do sistema não recebeu callbacks. Verifique a permissão de Captura de Áudio do Sistema para este Ōmu.")
        } else if let pico = estatisticasDoSistema?.peak, pico < 0.000_1 {
            sistemaOk = false
            capturouSistema = false
            if let urlDoSistema { try? FileManager.default.removeItem(at: urlDoSistema) }
            // Silêncio no canal do sistema é o caso normal de uma reunião
            // presencial (nada tocou no Mac) — não é diagnóstico de defeito.
            // A mensagem de permissão/rota fica só para callbacks zero, acima.
            avisos.append("Nenhum áudio do sistema durante a gravação — a conversa tem só o microfone.")
        } else if descartarSistemaSeVazio(urlDoSistema) {
            sistemaOk = false
            capturouSistema = false
            avisos.append("Áudio do sistema não capturou nada — a conversa tem só o microfone.")
        }
        if sistemaOk, estatisticasDoSistema?.saidaMudou == true {
            avisos.append(Self.avisoDeTrocaDeSaida)
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
            avisos: avisos,
            usavaFones: estavamFonesNoInicio
        )
    }

    #if os(macOS)
    /// Apaga o `sistema.caf` que ficou sem som e diz se apagou.
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

    /// Detecta se o dispositivo de saída padrão é um fone de ouvido ou
    /// Bluetooth, consultando o CoreAudio.
    private static func detectarFonesDeOuvido() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize, &deviceID
        )

        guard deviceID != kAudioDeviceUnknown else { return false }

        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize, &transportType
        )
        guard status == noErr else { return false }

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB:
            return true
        default:
            return false
        }
    }

    /// Duração que a gravação declara ao terminar: o maior valor entre o que
    /// o gravador chegou a reportar e o que de fato está no arquivo.
    ///
    /// Uma gravação interrompida pelo sistema reporta 0 no gravador; decidir
    /// o descarte por esse 0 apagava minutos de áudio já gravados.
    nonisolated static func duracaoFinal(
        observada: TimeInterval,
        doArquivo: TimeInterval?
    ) -> TimeInterval {
        let candidatos = [observada, doArquivo ?? 0].filter { $0.isFinite && $0 > 0 }
        return candidatos.max() ?? 0
    }

    /// Duração real do `microfone.wav`, lida do próprio arquivo.
    ///
    /// Se o cabeçalho não puder ser lido (gravador encerrado à força antes de
    /// fechá-lo), estima pelo tamanho: PCM 16 bits mono a 16 kHz são 32.000
    /// bytes por segundo depois dos 44 bytes de cabeçalho.
    public nonisolated static func duracaoDoMicrofone(em url: URL) -> TimeInterval? {
        if let arquivo = try? AVAudioFile(forReading: url),
           arquivo.fileFormat.sampleRate > 0,
           arquivo.length > 0 {
            return Double(arquivo.length) / arquivo.fileFormat.sampleRate
        }
        guard let tamanho = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int
        else { return nil }
        let cabecalhoWAV = 44
        let bytesPorSegundo = FormatoAudio.taxaCanonica * 2
        let conteudo = tamanho - cabecalhoWAV
        return conteudo > 0 ? Double(conteudo) / bytesPorSegundo : nil
    }

    private func registrarTempoDoGravador() {
        guard let recorder else { return }
        tempoDecorrido = max(tempoDecorrido, recorder.currentTime)
    }

    private func encerrarCaptura() -> SystemAudioTap.Statistics? {
        timer?.invalidate()
        timer = nil
        encerrandoPorPedido = true
        recorder?.stop()
        recorder = nil
        #if os(macOS)
        let estatisticas = systemTap?.stop()
        systemTap = nil
        sistemaURL = nil
        return estatisticas
        #else
        return nil
        #endif
    }

    // MARK: - Medição

    private func atualizarMedicao() {
        guard let recorder, !pausada, !interrompida else { return }
        tempoDecorrido = max(tempoDecorrido, recorder.currentTime)
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
        Task { @MainActor [weak self] in
            // O mesmo delegate dispara quando o próprio app chama `stop()`.
            guard let self, !self.encerrandoPorPedido else { return }
            self.marcarInterrupcao(
                "A gravação foi interrompida pelo sistema antes do esperado. O áudio gravado até ali foi preservado."
            )
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder, error: Error?
    ) {
        let motivo = error?.localizedDescription ?? "erro desconhecido"
        Task { @MainActor [weak self] in
            guard let self, !self.encerrandoPorPedido else { return }
            self.marcarInterrupcao(
                "A gravação parou por um erro ao escrever o áudio (\(motivo)). O áudio gravado até ali foi preservado."
            )
        }
    }

    private func marcarInterrupcao(_ aviso: String) {
        guard !interrompida else { return }
        interrompida = true
        nivelMicrofone.definirNormalizado(0)
        avisos.append(aviso)
    }
}
