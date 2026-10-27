import Foundation

/// Suspeita de crescimento sustentado de memória. É uma SUSPEITA estatística, nunca "vazamento confirmado".
public struct GrowthSuspicion: Equatable {
    public enum Confidence: String, Equatable { case low, medium }
    public var bytesPerMinute: Double
    public var growthBytes: UInt64
    public var observedSeconds: TimeInterval
    public var sampleCount: Int
    public var rSquared: Double
    public var confidence: Confidence
}

public struct GrowthConfig: Equatable {
    public var minSamples = 8
    public var minObservedSeconds: TimeInterval = 240
    public var minBytesPerMinute: Double = 20 * 1024 * 1024
    public var minGrowthBytes: UInt64 = 300 * 1024 * 1024
    public var minRSquared = 0.85
    /// Fração mínima de deltas positivos (descarta serrilhado de GC de navegadores).
    public var minPositiveDeltaFraction = 0.75
    public var maxSeriesPoints = 240
    public var maxTrackedGroups = 32
    public init() {}
}

/// Mantém série de footprint por grupo de apps e avalia crescimento por regressão linear.
public final class GrowthDetector {
    private let config: GrowthConfig
    private var series: [String: [(t: TimeInterval, bytes: Double)]] = [:]

    public init(config: GrowthConfig = GrowthConfig()) { self.config = config }

    /// Registra a amostra do grupo; mantém só os maiores `maxTrackedGroups` (memória limitada).
    public func record(groups: [AppGroup], at t: TimeInterval) {
        let top = groups.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(config.maxTrackedGroups)
        let alive = Set(top.map(\.id))
        for g in top {
            var s = series[g.id, default: []]
            s.append((t, Double(g.footprintBytes)))
            if s.count > config.maxSeriesPoints { s.removeFirst(s.count - config.maxSeriesPoints) }
            series[g.id] = s
        }
        for key in series.keys where !alive.contains(key) { series.removeValue(forKey: key) }
    }

    /// Série em memória do grupo (segundos, bytes) para gráficos; vazia se não houver dados. Nunca vai a disco.
    public func history(for groupID: String) -> [(t: TimeInterval, bytes: UInt64)] {
        (series[groupID] ?? []).map { ($0.t, UInt64(max(0, $0.bytes))) }
    }

    public func suspicion(for groupID: String) -> GrowthSuspicion? {
        guard let s = series[groupID], s.count >= config.minSamples,
              let first = s.first, let last = s.last else { return nil }
        let span = last.t - first.t
        guard span >= config.minObservedSeconds else { return nil }

        let n = Double(s.count)
        let meanT = s.reduce(0) { $0 + $1.t } / n
        let meanY = s.reduce(0) { $0 + $1.bytes } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in s {
            let dx = p.t - meanT, dy = p.bytes - meanY
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        let slope = sxy / sxx                       // bytes por segundo
        let r2 = (sxy * sxy) / (sxx * syy)
        let perMinute = slope * 60
        let growth = last.bytes - first.bytes

        var positive = 0
        for i in 1..<s.count where s[i].bytes >= s[i - 1].bytes { positive += 1 }
        let fraction = Double(positive) / Double(s.count - 1)

        guard perMinute >= config.minBytesPerMinute, growth >= Double(config.minGrowthBytes),
              r2 >= config.minRSquared, fraction >= config.minPositiveDeltaFraction else { return nil }
        let confident = span >= config.minObservedSeconds * 3 && r2 >= 0.95
        return GrowthSuspicion(bytesPerMinute: perMinute, growthBytes: UInt64(growth), observedSeconds: span,
                               sampleCount: s.count, rSquared: r2, confidence: confident ? .medium : .low)
    }
}
