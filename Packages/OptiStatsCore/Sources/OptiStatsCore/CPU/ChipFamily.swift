import Foundation

public enum ChipTier: String, Codable, Equatable {
    case base, pro, max, ultra
}

/// Chip Apple Silicon identificado em tempo de execução a partir de `machdep.cpu.brand_string`
/// (ex.: "Apple M4 Pro"). Gerações futuras são aceitas genericamente: nada é fixo em M4 Pro.
public struct ChipFamily: Equatable, Codable {
    public var generation: Int
    public var tier: ChipTier
    public var brand: String

    public var displayName: String { brand }
    public var isKnownGeneration: Bool { (1...6).contains(generation) }

    public static func parse(brand: String) -> ChipFamily? {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("apple m") else { return nil }
        let rest = lower.dropFirst("apple m".count)
        let digits = rest.prefix(while: { $0.isNumber })
        guard let gen = Int(digits), gen > 0 else { return nil }
        let suffix = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let tier: ChipTier
        switch suffix {
        case "": tier = .base
        case "pro": tier = .pro
        case "max": tier = .max
        case "ultra": tier = .ultra
        default: tier = .base
        }
        return ChipFamily(generation: gen, tier: tier, brand: trimmed)
    }
}
