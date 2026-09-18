import AVFoundation
import CoreAudio
import Foundation

/// Diagnóstico do tap de áudio do sistema, rodando **dentro do bundle do
/// Papagaio** — que é quem tem a permissão de TCC concedida.
///
/// Existe porque um bundle novo não herda a permissão: um app de diagnóstico
/// separado recebe zero callbacks e não consegue distinguir "sem permissão" de
/// "configuração errada do aggregate".
///
/// Ativa com `--diagnostico-tap`. Roda a matriz, escreve o resultado no
/// container e encerra. Some quando o R-11 fechar.
enum DiagnosticoTap {
    static var pedido: Bool {
        ProcessInfo.processInfo.arguments.contains("--diagnostico-tap")
    }

    static func executar() {
        var linhas: [String] = []
        let destino = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("diagnostico-tap.txt")

        func log(_ s: String) {
            linhas.append(s)
            try? linhas.joined(separator: "\n").write(to: destino, atomically: true, encoding: .utf8)
            // Também para stdout: com assinatura real o container fica
            // inacessível de fora, e a saída padrão é o único canal de leitura.
            FileHandle.standardOutput.write(Data((s + "\n").utf8))
        }

        let sistema = AudioHardwareSystem.shared
        let saidaUID = (try? sistema.defaultOutputDevice.flatMap { try $0.uid }) ?? nil
        log("container: \(NSHomeDirectory())")
        log("device de saída padrão: \(saidaUID ?? "nenhum")")
        log("")

        func base(_ tapUID: String) -> [String: Any] {
            [
                kAudioAggregateDeviceNameKey: "Papagaio Diag",
                kAudioAggregateDeviceUIDKey: "com.papagaio.diag.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true,
                    ] as [String: Any]
                ],
            ]
        }

        func testar(_ nome: String, excluirProprio: Bool = true, montar: (String) -> [String: Any]) {
            do {
                let descricao: CATapDescription
                if excluirProprio {
                    guard let proc = try sistema.process(
                        for: ProcessInfo.processInfo.processIdentifier
                    ) else {
                        log("\(nome): process(for:) nil"); return
                    }
                    descricao = CATapDescription(monoGlobalTapButExcludeProcesses: [proc.id])
                } else {
                    descricao = CATapDescription(monoGlobalTapButExcludeProcesses: [])
                }
                descricao.name = "Papagaio Diag"
                descricao.isPrivate = true
                descricao.isExclusive = false
                descricao.muteBehavior = .unmuted

                guard let tap = try sistema.makeProcessTap(description: descricao) else {
                    log("\(nome): makeProcessTap nil"); return
                }
                defer { try? sistema.destroyProcessTap(tap) }

                let uid = try tap.uid
                guard let agg = try sistema.makeAggregateDevice(description: montar(uid)) else {
                    log("\(nome): makeAggregateDevice nil"); return
                }
                defer { try? sistema.destroyAggregateDevice(agg) }

                final class Contador: @unchecked Sendable {
                    var chamadas = 0, buffers = 0, quadros = 0
                    var pico: Float = 0
                }
                let contador = Contador()
                var procID: AudioDeviceIOProcID?
                let status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg.id, nil) {
                    _, entrada, _, _, _ in
                    let lista = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: entrada)
                    )
                    contador.chamadas += 1
                    contador.buffers = lista.count
                    for b in lista {
                        guard let dados = b.mData else { continue }
                        let n = Int(b.mDataByteSize) / 4
                        let p = dados.assumingMemoryBound(to: Float.self)
                        contador.quadros += n
                        for i in 0..<n {
                            let v = abs(p[i])
                            if v > contador.pico { contador.pico = v }
                        }
                    }
                }
                guard status == noErr else { log("\(nome): CreateIOProcID \(status)"); return }
                defer {
                    if let procID { AudioDeviceDestroyIOProcID(agg.id, procID) }
                }
                guard AudioDeviceStart(agg.id, procID) == noErr else {
                    log("\(nome): AudioDeviceStart falhou"); return
                }
                Thread.sleep(forTimeInterval: 4)
                AudioDeviceStop(agg.id, procID)
                let veredito = contador.pico > 0.0001 ? "<<<< TEM SINAL" : "silêncio"
                log("\(nome.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                    + "callbacks=\(contador.chamadas) buffers=\(contador.buffers) "
                    + "quadros=\(contador.quadros) pico=\(contador.pico) \(veredito)")
            } catch {
                log("\(nome): ERRO \(error)")
            }
        }

        testar("A sem subdevice") { uid in
            var d = base(uid)
            d[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
            return d
        }
        testar("B subdevice + main") { uid in
            var d = base(uid)
            if let s = saidaUID {
                d[kAudioAggregateDeviceSubDeviceListKey] =
                    [[kAudioSubDeviceUIDKey: s] as [String: Any]]
                d[kAudioAggregateDeviceMainSubDeviceKey] = s
            }
            return d
        }
        testar("C chave clock") { uid in
            var d = base(uid)
            d[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
            if let s = saidaUID { d[kAudioAggregateDeviceClockDeviceKey] = s }
            return d
        }
        testar("D sem tapAutoStart") { uid in
            var d = base(uid)
            d[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
            d[kAudioAggregateDeviceTapAutoStartKey] = false
            return d
        }
        testar("E sem excluir o proprio", excluirProprio: false) { uid in
            var d = base(uid)
            d[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
            return d
        }

        // Só a configuração sem `tapAutoStart` produziu callbacks. As variantes
        // abaixo mantêm isso fixo e variam a *descrição do tap*.
        func testarDescricao(_ nome: String, _ criar: () throws -> CATapDescription?) {
            do {
                guard let descricao = try criar() else { log("\(nome): descrição nil"); return }
                guard let tap = try sistema.makeProcessTap(description: descricao) else {
                    log("\(nome): makeProcessTap nil"); return
                }
                defer { try? sistema.destroyProcessTap(tap) }
                let uid = try tap.uid
                var d = base(uid)
                d[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
                d[kAudioAggregateDeviceTapAutoStartKey] = false
                guard let agg = try sistema.makeAggregateDevice(description: d) else {
                    log("\(nome): aggregate nil"); return
                }
                defer { try? sistema.destroyAggregateDevice(agg) }

                final class Contador: @unchecked Sendable {
                    var chamadas = 0, quadros = 0
                    var pico: Float = 0
                }
                let contador = Contador()
                var procID: AudioDeviceIOProcID?
                guard AudioDeviceCreateIOProcIDWithBlock(&procID, agg.id, nil, {
                    _, entrada, _, _, _ in
                    let lista = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: entrada)
                    )
                    contador.chamadas += 1
                    for b in lista {
                        guard let dados = b.mData else { continue }
                        let n = Int(b.mDataByteSize) / 4
                        let p = dados.assumingMemoryBound(to: Float.self)
                        contador.quadros += n
                        for i in 0..<n {
                            let v = abs(p[i])
                            if v > contador.pico { contador.pico = v }
                        }
                    }
                }) == noErr else { log("\(nome): CreateIOProcID falhou"); return }

                defer {
                    if let procID { AudioDeviceDestroyIOProcID(agg.id, procID) }
                }
                guard AudioDeviceStart(agg.id, procID) == noErr else {
                    log("\(nome): Start falhou"); return
                }
                Thread.sleep(forTimeInterval: 4)
                AudioDeviceStop(agg.id, procID)
                let veredito = contador.pico > 0.0001 ? "<<<< TEM SINAL" : "silêncio"
                log("\(nome.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                    + "callbacks=\(contador.chamadas) quadros=\(contador.quadros) "
                    + "pico=\(contador.pico) \(veredito)")
            } catch {
                log("\(nome): ERRO \(error)")
            }
        }

        log("")
        log("--- variando a descrição do tap (tapAutoStart=false) ---")

        func meuProcesso() throws -> AudioObjectID? {
            // `process(for:)` é `throws` no protocolo, mas o compilador vê a
            // chamada concreta como não-lançante — daí o `try` ficar sem uso.
            (try? sistema.process(for: ProcessInfo.processInfo.processIdentifier))??.id
        }

        testarDescricao("F device-scoped mono") {
            guard let meu = try meuProcesso(), let s = saidaUID else { return nil }
            let d = CATapDescription(excludingProcesses: [meu], deviceUID: s, stream: 0)
            d.name = "Diag F"; d.isPrivate = true; d.isExclusive = false; d.muteBehavior = .unmuted
            d.isMono = true
            return d
        }
        testarDescricao("G global estéreo") {
            guard let meu = try meuProcesso() else { return nil }
            let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [meu])
            d.name = "Diag G"; d.isPrivate = true; d.isExclusive = false; d.muteBehavior = .unmuted
            return d
        }
        testarDescricao("H global, mutedWhenTapped") {
            guard let meu = try meuProcesso() else { return nil }
            let d = CATapDescription(monoGlobalTapButExcludeProcesses: [meu])
            d.name = "Diag H"; d.isPrivate = true; d.isExclusive = false
            d.muteBehavior = .mutedWhenTapped
            return d
        }
        testarDescricao("I device-scoped estéreo") {
            guard let s = saidaUID else { return nil }
            let d = CATapDescription(excludingProcesses: [], deviceUID: s, stream: 0)
            d.name = "Diag I"; d.isPrivate = true; d.isExclusive = false; d.muteBehavior = .unmuted
            return d
        }

        log("")
        log("FIM")
    }
}
