import Foundation

public enum FanMode: String, Codable, Equatable {
    case automatic    // controlado pelo macOS
    case manual       // alguém (outro app, helper) forçou
    case unknown
}

public struct FanReading: Equatable {
    public var index: Int
    public var name: String?
    public var rpm: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    public var mode: FanMode
    public var timestamp: TimeInterval

    public init(index: Int, name: String? = nil, rpm: Double?, minRPM: Double?, maxRPM: Double?,
                mode: FanMode, timestamp: TimeInterval) {
        self.index = index; self.name = name; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.mode = mode; self.timestamp = timestamp
    }

    /// Porcentagem da faixa, SOMENTE se mínimo e máximo forem conhecidos e coerentes.
    public var percentOfRange: Double? {
        guard let r = rpm, let lo = minRPM, let hi = maxRPM, hi > lo, hi > 0 else { return nil }
        return min(1, max(0, r / hi))
    }
}

public enum FanControlCapability: Equatable {
    case unavailable(reason: String)
    /// Existe um caminho de escrita, mas NÃO foi validado neste hardware/macOS. Bloqueado por padrão.
    case experimentalUnvalidated
    case validated
}

public enum FanCommand: Equatable {
    case restoreAutomatic(reason: String)
    case setTarget(rpm: Double)
    case heartbeat(ttl: TimeInterval)
}

public enum ActuatorResult: Equatable {
    case ok, unsupported, denied, failed(String)
}

/// Fronteira com o hardware. Nesta versão só existe a implementação "indisponível" (somente leitura).
public protocol FanActuator: AnyObject {
    var capability: FanControlCapability { get }
    func apply(_ command: FanCommand) -> ActuatorResult
}

public final class UnavailableFanActuator: FanActuator {
    public let capability: FanControlCapability
    public init(reason: String) { capability = .unavailable(reason: reason) }
    public func apply(_ command: FanCommand) -> ActuatorResult {
        if case .restoreAutomatic = command { return .ok }   // restaurar "automático" é sempre seguro
        return .unsupported
    }
}
