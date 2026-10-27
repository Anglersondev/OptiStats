import Foundation

/// Qualidade da leitura: nunca apresentar estimativa como medição.
public enum MetricQuality: String, Codable, CaseIterable {
    case observed       // lido diretamente de uma fonte
    case calculated     // derivado de leituras observadas (média, delta, integral)
    case estimated      // aproximação com metodologia declarada
    case unavailable    // sem leitura válida (exibir "—", nunca 0)
}

public enum MetricUnit: String, Codable {
    case percent, celsius, rpm, watts, wattHours, volts, amps, bytes, bytesPerSecond, hertz, count, seconds
    public var symbol: String {
        switch self {
        case .percent: return "%"
        case .celsius: return "°C"
        case .rpm: return "RPM"
        case .watts: return "W"
        case .wattHours: return "Wh"
        case .volts: return "V"
        case .amps: return "A"
        case .bytes: return "B"
        case .bytesPerSecond: return "B/s"
        case .hertz: return "Hz"
        case .count: return ""
        case .seconds: return "s"
        }
    }
}

/// Estado de uma fonte de dados, exibido pela UI em vez de zeros fictícios.
public enum SourceState: Equatable {
    case loading
    case available
    case stale
    case unsupported(reason: String)
    case permissionDenied(hint: String)
    case failed(message: String)
    case paused
    public var isUsable: Bool {
        switch self {
        case .available, .stale: return true
        default: return false
        }
    }
}
