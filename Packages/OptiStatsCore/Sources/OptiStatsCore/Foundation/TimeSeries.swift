import Foundation

public struct TimedValue: Equatable {
    public var t: TimeInterval
    public var v: Double
    public init(t: TimeInterval, v: Double) { self.t = t; self.v = v }
}

/// Série temporal com retenção por tempo e por quantidade (histórico curto e limitado).
public struct TimeSeries {
    private var buffer: RingBuffer<TimedValue>
    public let retention: TimeInterval

    public init(capacity: Int = 900, retention: TimeInterval = 900) {
        buffer = RingBuffer(capacity: capacity)
        self.retention = retention
    }

    public var count: Int { buffer.count }
    public var latest: TimedValue? { buffer.last }
    public var all: [TimedValue] { buffer.elements }

    /// Valores não finitos (NaN/inf) são descartados, nunca viram zero.
    public mutating func append(t: TimeInterval, v: Double) {
        guard v.isFinite else { return }
        buffer.append(TimedValue(t: t, v: v))
        let cutoff = t - retention
        buffer.dropOldest(while: { $0.t < cutoff })
    }

    public mutating func removeAll() { buffer.removeAll() }

    public func values(since t0: TimeInterval) -> [TimedValue] {
        buffer.elements.filter { $0.t >= t0 }
    }

    public func average(since t0: TimeInterval) -> Double? {
        let v = values(since: t0)
        guard !v.isEmpty else { return nil }
        return v.reduce(0) { $0 + $1.v } / Double(v.count)
    }

    public func maximum(since t0: TimeInterval) -> Double? { values(since: t0).map(\.v).max() }
    public func minimum(since t0: TimeInterval) -> Double? { values(since: t0).map(\.v).min() }

    /// Reduz para no máximo `maxPoints` pontos (média por balde) para desenho de gráficos.
    public func downsampled(since t0: TimeInterval, maxPoints: Int) -> [TimedValue] {
        let src = values(since: t0)
        guard maxPoints > 0, src.count > maxPoints else { return src }
        let bucket = Double(src.count) / Double(maxPoints)
        var out: [TimedValue] = []
        out.reserveCapacity(maxPoints)
        for i in 0..<maxPoints {
            let lo = Int((Double(i) * bucket).rounded(.down))
            let hi = min(src.count, Int((Double(i + 1) * bucket).rounded(.down)))
            guard hi > lo else { continue }
            let slice = src[lo..<hi]
            let avg = slice.reduce(0) { $0 + $1.v } / Double(slice.count)
            out.append(TimedValue(t: slice[slice.endIndex - 1].t, v: avg))
        }
        return out
    }
}
