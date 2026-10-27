import Foundation

public enum ByteStyle { case binary, decimal }

/// Formatação determinística de bytes (independente de `ByteCountFormatter`, que difere entre plataformas).
/// Memória segue o Monitor de Atividade (base 1024, rótulo "GB"); armazenamento segue o Finder (base 1000).
public enum ByteFormat {
    public static func string(_ bytes: UInt64, style: ByteStyle = .binary, locale: Locale = .current,
                              maxDecimals: Int = 2) -> String {
        let base: Double = style == .binary ? 1024 : 1000
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var i = 0
        while value >= base && i < units.count - 1 { value /= base; i += 1 }
        let decimals = i == 0 ? 0 : (value >= 100 ? min(maxDecimals, 0) : (value >= 10 ? min(maxDecimals, 1) : maxDecimals))
        return decimal(value, decimals: decimals, locale: locale) + " " + units[i]
    }

    public static func rate(_ bytesPerSecond: Double, style: ByteStyle = .decimal, locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return string(UInt64(bytesPerSecond), style: style, locale: locale, maxDecimals: 1) + "/s"
    }

    /// Número com casas fixas e separador decimal do `locale` (pt-BR usa vírgula).
    public static func decimal(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        let d = max(0, decimals)
        var s = String(format: "%.\(d)f", value)
        if let sep = locale.decimalSeparator, sep != "." { s = s.replacingOccurrences(of: ".", with: sep) }
        return s
    }

    public static func percent(_ fraction: Double, decimals: Int = 0, locale: Locale = .current) -> String {
        guard fraction.isFinite else { return "—" }
        return decimal(fraction * 100, decimals: decimals, locale: locale) + "%"
    }
}
