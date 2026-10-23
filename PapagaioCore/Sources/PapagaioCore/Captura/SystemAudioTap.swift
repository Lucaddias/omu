@preconcurrency import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captura do áudio do sistema via Core Audio Process Taps (macOS 14.4+).
///
/// A saída é capturada no stream real do dispositivo de saída selecionado pelo
/// macOS e gravada num `.caf` PCM na taxa nativa do tap, sem reamostrar para
/// 16 kHz e sem codificar AAC na thread de áudio. Isso preserva a clareza do
/// interlocutor e mantém o callback seguro para tempo real.
///
/// Três armadilhas documentadas que este código já evita:
/// 1. `AVAudioEngine` NÃO funciona apontado para o aggregate device do tap
///    — por isso usamos `AudioDeviceCreateIOProcIDWithBlock` direto.
/// 2. O aggregate device é construído somente com o sub-tap; adicionar o
///    dispositivo de saída como subdevice reintroduz o caminho que já entregou
///    silêncio no Papagaio.
/// 3. O formato é lido do tap depois de sua criação; ele não é presumido.
enum SystemAudioTapError: LocalizedError {
    case apiUnavailable
    case permissionDenied
    case coreAudioFailure(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            "Este Mac não suporta captura de áudio do sistema (requer macOS 14.4 ou mais recente)."
        case .permissionDenied:
            "Permita a captura de áudio do sistema nas Configurações do Sistema para gravar o interlocutor."
        case .coreAudioFailure(let status, let step):
            "Falha do Core Audio em \(step) (código \(status))."
        }
    }
}

#if os(macOS)
/// Grava o áudio de saída do sistema (o "interlocutor" de uma reunião
/// online) num arquivo AAC próprio, separado do canal de microfone.
/// Se qualquer etapa falhar, a gravação de microfone segue normalmente —
/// sem crash, com aviso.
final class SystemAudioTap {
    struct Statistics: Sendable {
        let callbacks: UInt64
        let frames: UInt64
        /// `nil` quando o formato não é Float32 PCM e, portanto, não foi
        /// possível medir pico sem converter no callback.
        let peak: Float?
        /// A saída padrão do macOS mudou durante a captura (fones conectados
        /// ou desconectados). O tap fica preso ao dispositivo do início: daí
        /// em diante o canal pode ter gravado silêncio.
        var saidaMudou = false

        static let empty = Statistics(callbacks: 0, frames: 0, peak: nil)
    }

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: SystemTrackWriter?
    private var callbackState: SystemTapCallbackState?
    private let nivel: NivelAudio
    private let saidaMudou = OSAllocatedUnfairLock(initialState: false)
    private var ouvinteDaSaida: AudioObjectPropertyListenerBlock?
    private static let filaDoOuvinte = DispatchQueue(label: "Papagaio.SystemAudioTap.saida")

    private static var enderecoDaSaidaPadrao: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private(set) var isRunning = false

    init(nivel: NivelAudio) {
        self.nivel = nivel
    }

    /// Inicia a captura, escrevendo PCM no formato nativo do tap. A conversão
    /// para o formato do Whisper acontece depois, de forma offline, em
    /// `DecodificadorDeAudio`.
    func start(destinationURL: URL) throws {
        guard #available(macOS 14.4, *) else { throw SystemAudioTapError.apiUnavailable }

        // Um tap global já produziu buffers de zeros neste app. O
        // AudioRecorder validado captura o stream de saída concreto do
        // dispositivo padrão, com uma descrição exclusiva sem processos
        // incluídos. `isExclusive` aqui significa que a lista contém processos
        // a excluir; vazia, ela deixa o mix de saída do stream disponível.
        let (outputDeviceUID, outputStream) = try defaultOutputRoute()
        let description = CATapDescription()
        description.processes = []
        description.isExclusive = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true
        description.name = "Papagaio System Audio Tap"
        description.deviceUID = outputDeviceUID
        description.stream = outputStream

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw mapPermissionOrFailure(status, step: "criar o tap")
        }
        tapID = newTapID

        let aggregateUID = UUID().uuidString
        let capturedTapUID: String
        do {
            capturedTapUID = try tapUID()
        } catch {
            cleanupTapOnly()
            throw error
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Papagaio-System-Aggregate-\(aggregateUID)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: capturedTapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            cleanupTapOnly()
            throw SystemAudioTapError.coreAudioFailure(status, "criar o aggregate device")
        }
        aggregateDeviceID = newAggregateID

        // Formato real do tap — lido depois de criado, não assumido. Falhar
        // aqui precisa do `cleanupAll`: neste ponto o process tap e o
        // aggregate device já existem, e propagar o erro sem destruí-los os
        // vazava no Core Audio (a classe não tem `deinit`).
        let format: AudioStreamBasicDescription
        do {
            format = try tapFormat()
        } catch {
            cleanupAll()
            throw error
        }

        let trackWriter: SystemTrackWriter
        do {
            trackWriter = try SystemTrackWriter(url: destinationURL, format: format)
        } catch {
            cleanupAll()
            throw error
        }
        writer = trackWriter
        let state = SystemTapCallbackState(writer: trackWriter, format: format, nivel: nivel)
        callbackState = state

        var newIOProcID: AudioDeviceIOProcID?
        // O writer é imutável durante toda a vida deste IOProc. Não use
        // AVAudioFile aqui: criar buffers e codificar AAC no callback causa
        // dropout e diverge do caminho comprovado do AudioRecorder.
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            guard let buffer = buffers.first, format.mBytesPerFrame > 0 else { return }
            let frames = buffer.mDataByteSize / format.mBytesPerFrame
            guard frames > 0 else { return }
            state.consume(buffer: buffer, frames: frames)
        }
        guard status == noErr, let ioProcID = newIOProcID else {
            cleanupAll()
            throw SystemAudioTapError.coreAudioFailure(status, "criar o IOProc")
        }
        self.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            cleanupAll()
            throw SystemAudioTapError.coreAudioFailure(status, "iniciar o aggregate device")
        }

        isRunning = true
        observarSaidaPadrao()
    }

    /// Só registra a troca: recriar o tap no dispositivo novo no meio da
    /// gravação fica para depois; por ora quem gravou precisa ao menos saber
    /// por que o interlocutor sumiu a partir de um ponto.
    private func observarSaidaPadrao() {
        saidaMudou.withLock { $0 = false }
        let marca = saidaMudou
        let ouvinte: AudioObjectPropertyListenerBlock = { _, _ in
            marca.withLock { $0 = true }
        }
        var endereco = Self.enderecoDaSaidaPadrao
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &endereco, Self.filaDoOuvinte, ouvinte
        )
        if status == noErr { ouvinteDaSaida = ouvinte }
    }

    private func pararDeObservarSaidaPadrao() {
        guard let ouvinte = ouvinteDaSaida else { return }
        var endereco = Self.enderecoDaSaidaPadrao
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &endereco, Self.filaDoOuvinte, ouvinte
        )
        ouvinteDaSaida = nil
    }

    /// Pausa a escrita do canal do sistema.
    ///
    /// O `AVAudioRecorder` do microfone pausa de verdade; o tap não tem como
    /// parar o stream sem derrubar o aggregate device. Sem este corte, o
    /// arquivo do sistema acumula o tempo de pausa e os dois canais se
    /// desalinham para sempre — a duração vem do `currentTime` do recorder,
    /// que exclui a pausa.
    func pausar() {
        callbackState?.pausar()
    }

    func continuar() {
        callbackState?.continuar()
    }

    @discardableResult
    func stop() -> Statistics {
        pararDeObservarSaidaPadrao()
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        var statistics = callbackState?.statistics ?? .empty
        statistics.saidaMudou = saidaMudou.withLock { $0 }
        // O IOProc já foi destruído: nenhum callback toca mais no writer.
        // Fechar aqui, e não no `deinit`, garante que a fila do
        // `ExtAudioFileWriteAsync` foi despejada antes de quem chamou medir o
        // tamanho do arquivo ou abri-lo — o `deinit` depende de o bloco do
        // IOProc já ter soltado a última referência.
        writer?.finalizar()
        callbackState = nil
        writer = nil
        isRunning = false
        return statistics
    }

    private func cleanupTapOnly() {
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func cleanupAll() {
        stop()
    }

    // MARK: - Core Audio helpers

    /// `kAudioTapPropertyFormat` devolve a ASBD real do tap. Ela é usada
    /// diretamente pelo writer, sem conversão para AVFoundation no callback.
    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mBytesPerFrame > 0
        else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler o formato do tap")
        }
        return asbd
    }

    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, uidPointer)
        }
        guard status == noErr else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler o UID do tap")
        }
        return uid as String
    }

    /// Escolhe um stream de saída que realmente anuncie canais PCM. Há
    /// dispositivos com mais de um stream (interfaces multicanal), e assumir
    /// que o índice zero sempre é utilizável pode criar um tap válido, mas sem
    /// sinal. Para a saída estéreo usual — incluindo os AirPods — isto devolve
    /// o único stream de dois canais.
    private func defaultOutputRoute() throws -> (deviceUID: String, stream: UInt) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler o dispositivo de saída padrão")
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &deviceUID) { uidPointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
        }
        guard status == noErr else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler o UID do dispositivo de saída")
        }
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
        guard status == noErr, streamSize >= UInt32(MemoryLayout<AudioObjectID>.size),
              streamSize.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size))
        else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler os streams de saída")
        }

        let streamCount = Int(streamSize) / MemoryLayout<AudioObjectID>.size
        var streamIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: streamCount)
        status = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, &streamIDs)
        guard status == noErr else {
            throw SystemAudioTapError.coreAudioFailure(status, "ler os streams de saída")
        }

        for (index, streamID) in streamIDs.enumerated() {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(
                streamID, &formatAddress, 0, nil, &formatSize, &format
            )
            guard status == noErr else { continue }
            if format.mFormatID == kAudioFormatLinearPCM,
               format.mChannelsPerFrame > 0,
               format.mSampleRate > 0 {
                return (deviceUID as String, UInt(index))
            }
        }

        throw SystemAudioTapError.coreAudioFailure(
            kAudioHardwareUnsupportedOperationError,
            "encontrar um stream PCM de saída com canais ativos"
        )
    }

    private func mapPermissionOrFailure(_ status: OSStatus, step: String) -> Error {
        // TCC nega a criação do tap silenciosamente com um erro de
        // hardware genérico em vez de um código dedicado — trate o caso
        // mais comum (permissão não concedida) com uma mensagem acionável.
        if status == kAudioHardwareNotRunningError || status == kAudioHardwareIllegalOperationError {
            return SystemAudioTapError.permissionDenied
        }
        return SystemAudioTapError.coreAudioFailure(status, step)
    }
}

/// Escritor baseado no mesmo caminho do AudioRecorder: o callback apenas
/// entrega o `AudioBuffer` emprestado ao `ExtAudioFileWriteAsync`. O arquivo
/// é CAF/PCM, portanto não há compressão nem alocação de `AVAudioPCMBuffer`
/// em tempo real.
///
/// Interno (não `private`) para os testes de pausa poderem medir os frames
/// que de fato chegam ao arquivo.
final class SystemTrackWriter {
    private var file: ExtAudioFileRef?

    init(url: URL, format: AudioStreamBasicDescription) throws {
        var fileFormat = format
        var reference: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &reference
        )
        guard createStatus == noErr, let reference else {
            throw SystemAudioTapError.coreAudioFailure(createStatus, "criar o arquivo do áudio do sistema")
        }

        var clientFormat = format
        let configureStatus = ExtAudioFileSetProperty(
            reference,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard configureStatus == noErr else {
            ExtAudioFileDispose(reference)
            throw SystemAudioTapError.coreAudioFailure(configureStatus, "configurar o arquivo do áudio do sistema")
        }

        let prepareStatus = ExtAudioFileWriteAsync(reference, 0, nil)
        guard prepareStatus == noErr else {
            ExtAudioFileDispose(reference)
            throw SystemAudioTapError.coreAudioFailure(prepareStatus, "preparar a escrita do áudio do sistema")
        }
        file = reference
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func append(buffer: AudioBuffer, frames: UInt32) {
        guard let file else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        _ = ExtAudioFileWriteAsync(file, frames, &list)
    }

    /// Fecha o arquivo garantindo que a fila assíncrona do
    /// `ExtAudioFileWriteAsync` foi despejada — o `dispose` é a única chamada
    /// com essa garantia. Em produção isto acontece no `deinit` (via `stop`);
    /// os testes precisam do arquivo completo antes de lê-lo.
    func finalizar() {
        guard let file else { return }
        ExtAudioFileDispose(file)
        self.file = nil
    }
}

/// Estado mutado exclusivamente pela thread do IOProc e lido apenas depois de
/// `AudioDeviceStop`; por isso não exige lock no caminho de tempo real — a
/// única exceção é a bandeira de pausa, escrita pela main e lida no callback,
/// que usa `OSAllocatedUnfairLock` por ser segura em tempo real.
///
/// Interno (não `private`) para os testes de pausa exercitarem o descarte de
/// buffers sem precisar de permissão de TCC nem de um dispositivo real.
final class SystemTapCallbackState {
    private let writer: SystemTrackWriter
    private let format: AudioStreamBasicDescription
    private let nivel: NivelAudio
    private var callbackCount: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var measuredFloatPCM = false
    private var peak: Float = 0
    private let pausado = OSAllocatedUnfairLock(initialState: false)

    init(writer: SystemTrackWriter, format: AudioStreamBasicDescription, nivel: NivelAudio) {
        self.writer = writer
        self.format = format
        self.nivel = nivel
    }

    func pausar() {
        pausado.withLock { $0 = true }
    }

    func continuar() {
        pausado.withLock { $0 = false }
    }

    func finalizarEscrita() {
        writer.finalizar()
    }

    func consume(buffer: AudioBuffer, frames: UInt32) {
        // Pausado: o buffer é descartado por inteiro — não escreve, não conta,
        // não alimenta o medidor de nível. É o que mantém o canal do sistema
        // alinhado com o microfone, que pausa de verdade.
        guard !pausado.withLock({ $0 }) else { return }

        callbackCount &+= 1
        frameCount &+= UInt64(frames)
        writer.append(buffer: buffer, frames: frames)

        guard format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let data = buffer.mData
        else { return }
        measuredFloatPCM = true
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        nivel.registrar(samples, quantidade: count)
        for index in 0..<count {
            peak = max(peak, abs(samples[index]))
        }
    }

    var statistics: SystemAudioTap.Statistics {
        SystemAudioTap.Statistics(
            callbacks: callbackCount,
            frames: frameCount,
            peak: measuredFloatPCM ? peak : nil
        )
    }
}
#endif
