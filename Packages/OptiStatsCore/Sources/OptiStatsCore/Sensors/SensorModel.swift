import Foundation

public enum SensorKind: String, Codable, CaseIterable {
    case temperature, voltage, current, power, energy, fan

    public var unit: MetricUnit {
        switch self {
        case .temperature: return .celsius
        case .voltage: return .volts
        case .current: return .amps
        case .power: return .watts
        case .energy: return .wattHours
        case .fan: return .rpm
        }
    }

    /// Faixa de plausibilidade; fora dela a leitura é descartada (vira "indisponível", não zero).
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .temperature: return -20...130
        case .voltage: return 0...60
        case .current: return -30...30
        case .power: return -300...400
        case .energy: return 0...100_000
        case .fan: return 0...20_000
        }
    }
}

public enum SensorSource: String, Codable {
    case smc, hid, ioReport, powerSources, ioRegistry, derived
}

/// Papel físico do sensor. Os "núcleos" de temperatura são ZONAS/termistores do inventário do SMC/HID
/// e não temperaturas isoladas de um núcleo físico.
public enum SensorRole: String, Codable {
    case cpuEfficiencyZone, cpuPerformanceZone, cpuSuperZone
    case gpuZone
    case socZone, memoryZone, ambient, airflow, storage, battery, wireless, thunderbolt
    case dcIn, rail, systemTotal, display, other
}

public struct SensorDescriptor: Hashable, Codable {
    /// ID estável: "<fonte>:<chave>", ex.: "smc:Tp09", "hid:pACC MTR Temp Sensor0".
    public var id: String
    public var key: String
    public var name: String
    public var kind: SensorKind
    public var role: SensorRole
    public var source: SensorSource

    public init(key: String, name: String, kind: SensorKind, role: SensorRole, source: SensorSource) {
        self.id = source.rawValue + ":" + key
        self.key = key; self.name = name; self.kind = kind; self.role = role; self.source = source
    }
}

public struct SensorReading: Equatable {
    public var descriptor: SensorDescriptor
    public var value: Double?
    public var quality: MetricQuality
    public var timestamp: TimeInterval
    public var note: String?

    public init(descriptor: SensorDescriptor, value: Double?, quality: MetricQuality, timestamp: TimeInterval, note: String? = nil) {
        self.descriptor = descriptor; self.value = value; self.quality = quality; self.timestamp = timestamp; self.note = note
    }

    public func isStale(now: TimeInterval, expectedInterval: TimeInterval) -> Bool {
        now - timestamp > max(expectedInterval * 3, 5)
    }
}

public enum SensorValidator {
    /// Devolve o valor se plausível; NaN/inf/fora de faixa/zero de "chave ausente" (temperatura 0) → nil.
    public static func validate(_ value: Double?, kind: SensorKind) -> Double? {
        guard let v = value, v.isFinite else { return nil }
        if kind == .temperature && v == 0 { return nil }   // SMC devolve 0 para termistor inexistente
        return kind.plausibleRange.contains(v) ? v : nil
    }

    public static func reading(_ d: SensorDescriptor, raw: Double?, at t: TimeInterval,
                               quality: MetricQuality = .observed) -> SensorReading {
        if let v = validate(raw, kind: d.kind) {
            return SensorReading(descriptor: d, value: v, quality: quality, timestamp: t)
        }
        return SensorReading(descriptor: d, value: nil, quality: .unavailable, timestamp: t)
    }
}

/// Agregações calculadas (média/mais quente). Rotuladas como `.calculated` e nunca como sensor físico.
public enum SensorAggregator {
    public static func cpuZones(_ r: [SensorReading]) -> [SensorReading] {
        r.filter { [.cpuEfficiencyZone, .cpuPerformanceZone, .cpuSuperZone].contains($0.descriptor.role) && $0.value != nil }
    }
    public static func gpuZones(_ r: [SensorReading]) -> [SensorReading] {
        r.filter { $0.descriptor.role == .gpuZone && $0.value != nil }
    }

    public static func average(_ r: [SensorReading]) -> Double? {
        let v = r.compactMap(\.value)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    public static func hottest(_ r: [SensorReading]) -> Double? { r.compactMap(\.value).max() }

    public static func aggregates(from readings: [SensorReading], at t: TimeInterval) -> [SensorReading] {
        func make(_ key: String, _ name: String, _ value: Double?) -> SensorReading? {
            guard let value else { return nil }
            let d = SensorDescriptor(key: key, name: name, kind: .temperature, role: .other, source: .derived)
            return SensorReading(descriptor: d, value: value, quality: .calculated, timestamp: t)
        }
        let cpu = cpuZones(readings), gpu = gpuZones(readings)
        return [make("avg-cpu", "Average CPU", average(cpu)), make("max-cpu", "Hottest CPU", hottest(cpu)),
                make("avg-gpu", "Average GPU", average(gpu)), make("max-gpu", "Hottest GPU", hottest(gpu))].compactMap { $0 }
    }
}
