import Foundation

/// Decodificação dos tipos de dados do SMC. Adaptado do formato descrito em `SMC/smc.swift` do Stats (MIT).
/// Tipos inteiros/ponto fixo são big-endian; `flt ` é float de 32 bits em ordem nativa (little-endian no arm64).
public enum SMCDecoder {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func u16() -> Double? { bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil }
        func s16() -> Double? { bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) : nil }
        switch type {
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return u16()
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return s16()
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        // Ponto fixo sem sinal: spXY → divisor 2^Y (X+Y=15 bits).
        case "sp1e": return u16().map { $0 / 16384 }
        case "sp3c": return u16().map { $0 / 4096 }
        case "sp4b": return u16().map { $0 / 2048 }
        case "sp5a": return u16().map { $0 / 1024 }
        case "sp69": return u16().map { $0 / 512 }
        case "sp78": return s16().map { $0 / 256 }
        case "sp87": return s16().map { $0 / 128 }
        case "sp96": return s16().map { $0 / 64 }
        case "spa5": return u16().map { $0 / 32 }
        case "spb4": return s16().map { $0 / 16 }
        case "spf0": return s16()
        default: return nil
        }
    }

    /// Codifica um FourCC ("Tp09") em UInt32 big-endian, como o SMC espera.
    public static func fourCC(_ s: String) -> UInt32? {
        let u = Array(s.utf8)
        guard u.count == 4 else { return nil }
        return u.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
