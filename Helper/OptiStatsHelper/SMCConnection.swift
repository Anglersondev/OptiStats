import Foundation
import IOKit
import OptiStatsCore

/// Conexão de baixo nível com o AppleSMC (leitura e escrita). Só o helper escreve; o app nunca.
/// Layout da estrutura de chamada e comandos (kernel index 2; 5 = ler bytes, 6 = escrever bytes, 9 = info da chave)
/// adaptados de `SMC/smc.swift` do Stats (exelban/stats, MIT; ver THIRD_PARTY_NOTICES.md).
/// A escrita só aceita chaves da lista fixa `FanSMCKeys.writableKeys` (verificação no nível mais baixo).
final class SMCConnection {
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

    struct Value {
        var key: String
        var type: String
        var size: Int
        var bytes: [UInt8]   // exatamente `size` bytes
        var number: Double? { SMCDecoder.decode(type: type, bytes: bytes) }
    }

    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdWriteKey: UInt8 = 6
    private static let cmdGetKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private(set) var lastError: String?
    private let layoutOK = MemoryLayout<Param>.stride == 80

    deinit { close() }

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    /// Abre sob demanda. false se o SMC não estiver acessível.
    func open() -> Bool {
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
        if r != KERN_SUCCESS { lastError = String(format: "IOConnectCallStructMethod 0x%x", r); return false }
        if output.result != 0 { lastError = String(format: "SMC result 0x%x", output.result); return false }
        return true
    }

    private func typeString(_ t: UInt32) -> String {
        let bytes: [UInt8] = [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Lê uma chave (tipo, tamanho e bytes). nil se ausente ou com falha. Sem cache: o helper lê pouco e o estado muda.
    func read(_ key: String) -> Value? {
        guard open(), let code = SMCDecoder.fourCC(key) else { return nil }
        var input = Param(), output = Param()
        input.key = code
        input.data8 = Self.cmdGetKeyInfo
        guard call(&input, &output), output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else { return nil }
        let size = output.keyInfo.dataSize
        let type = typeString(output.keyInfo.dataType)

        var rin = Param(), rout = Param()
        rin.key = code
        rin.keyInfo.dataSize = size
        rin.data8 = Self.cmdReadKey
        guard call(&rin, &rout) else { return nil }
        let bytes: [UInt8] = withUnsafeBytes(of: &rout.bytes) { Array($0.prefix(Int(size))) }
        return Value(key: key, type: type, size: Int(size), bytes: bytes)
    }

    /// Escreve `bytes` (no máximo 32) numa chave da lista fixa. true somente se o SMC aceitou (result == 0).
    func write(_ key: String, bytes: [UInt8], size: Int) -> Bool {
        guard FanSMCKeys.isWritable(key) else { lastError = "chave não permitida"; return false }
        guard open(), let code = SMCDecoder.fourCC(key), size > 0, size <= 32, bytes.count >= size else { return false }
        var input = Param(), output = Param()
        input.key = code
        input.data8 = Self.cmdWriteKey
        input.keyInfo.dataSize = UInt32(size)
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<size { raw[i] = bytes[i] }
        }
        return call(&input, &output)
    }
}
