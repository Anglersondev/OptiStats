import Foundation
import IOKit
import OptiStatsCore

/// Leitura SOMENTE LEITURA do AppleSMC (métodos "get key info" e "read key"). Nunca escreve no SMC.
/// Layout da estrutura de chamada adaptado de `SMC/smc.swift` do Stats (exelban/stats, MIT; ver THIRD_PARTY_NOTICES.md).
/// Todas as chamadas são serializadas por uma trava: vários coletores podem compartilhar a mesma conexão sem leituras sobrepostas.
final class SMCReader {
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: String)] = [:]
    private var missing: Set<UInt32> = []
    private(set) var lastError: String?

    /// A estrutura precisa ter exatamente 80 bytes (contrato do kernel). Se não, o leitor se desativa.
    private let layoutOK = MemoryLayout<Param>.stride == 80

    deinit { closeLocked() }

    /// Fecha a conexão (libera o recurso). A próxima leitura reabre sob demanda.
    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    private func openLocked() -> Bool {
        if connection != 0 { return true }
        guard layoutOK else { lastError = "layout SMC inesperado"; return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { lastError = "AppleSMC ausente"; return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == KERN_SUCCESS, conn != 0 else { lastError = String(format: "IOServiceOpen 0x%x", r); return false }
        connection = conn
        lastError = nil
        return true
    }

    private func call(_ input: inout Param, _ output: inout Param) -> Bool {
        var outSize = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                          &input, MemoryLayout<Param>.stride, &output, &outSize)
        return r == KERN_SUCCESS && output.result == 0
    }

    private func typeString(_ t: UInt32) -> String {
        let bytes: [UInt8] = [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private func infoLocked(_ code: UInt32) -> (size: UInt32, type: String)? {
        if let c = infoCache[code] { return c }
        if missing.contains(code) { return nil }
        var input = Param(), output = Param()
        input.key = code
        input.data8 = Self.cmdGetKeyInfo
        guard call(&input, &output), output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
            missing.insert(code); return nil
        }
        let info = (size: output.keyInfo.dataSize, type: typeString(output.keyInfo.dataType))
        infoCache[code] = info
        return info
    }

    /// Existe a chave neste Mac?
    func hasKey(_ key: String) -> Bool {
        guard let code = SMCDecoder.fourCC(key) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard openLocked() else { return false }
        return infoLocked(code) != nil
    }

    /// Lê e decodifica uma chave (nil se ausente, tipo desconhecido ou falha). A validação de plausibilidade é do chamador.
    func read(_ key: String) -> Double? {
        guard let code = SMCDecoder.fourCC(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard openLocked(), let info = infoLocked(code) else { return nil }
        var input = Param(), output = Param()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = Self.cmdReadKey
        guard call(&input, &output) else { return nil }
        let count = Int(info.size)
        let bytes: [UInt8] = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(count)) }
        return SMCDecoder.decode(type: info.type, bytes: bytes)
    }

    /// Abre a conexão se necessário e informa se o SMC está acessível.
    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return openLocked()
    }
}
