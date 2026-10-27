import Foundation

/// Integra potência (W) em energia (Wh) pela regra do trapézio, SOMENTE entre amostras válidas e próximas.
/// Lacunas (repouso, falhas) não são interpoladas: reduzem a "cobertura" informada.
public struct EnergyAccumulator: Equatable {
    public var wattHours: Double = 0
    public var coveredSeconds: TimeInterval = 0
    public var elapsedSeconds: TimeInterval = 0
    public var gapCount = 0
    public var startedAt: TimeInterval?
    /// 0...1: fração do período observado que realmente teve integração.
    public var coverage: Double { elapsedSeconds > 0 ? min(1, coveredSeconds / elapsedSeconds) : 0 }
}

public final class EnergyIntegrator {
    public private(set) var accumulator = EnergyAccumulator()
    private var last: (t: TimeInterval, w: Double)?
    private let maxGap: TimeInterval

    /// `maxGap`: intervalo máximo entre amostras para integrar (ex.: 3× o intervalo de coleta).
    public init(maxGap: TimeInterval) { self.maxGap = maxGap }

    public func reset() { accumulator = EnergyAccumulator(); last = nil }

    /// Marca descontinuidade (sleep/wake): a próxima amostra vira nova linha de base.
    public func markDiscontinuity() {
        if last != nil { accumulator.gapCount += 1 }
        last = nil
    }

    /// `watts` nil/NaN/negativo = leitura inválida → conta como lacuna.
    public func add(watts: Double?, at t: TimeInterval) {
        if accumulator.startedAt == nil { accumulator.startedAt = t }
        guard let w = watts, w.isFinite, w >= 0 else { markDiscontinuity(); return }
        defer { last = (t, w) }
        guard let prev = last else { return }
        let dt = t - prev.t
        guard dt > 0 else { return }
        accumulator.elapsedSeconds += dt
        if dt <= maxGap {
            accumulator.wattHours += (prev.w + w) / 2 * dt / 3600
            accumulator.coveredSeconds += dt
        } else {
            accumulator.gapCount += 1
        }
    }
}

/// Média móvel de potência sobre uma janela de tempo.
public struct MovingAverage {
    private var points: [(t: TimeInterval, v: Double)] = []
    public let window: TimeInterval
    public init(window: TimeInterval) { self.window = window }
    public mutating func add(_ v: Double, at t: TimeInterval) {
        guard v.isFinite else { return }
        points.append((t, v))
        points.removeAll { $0.t < t - window }
    }
    public var value: Double? { points.isEmpty ? nil : points.reduce(0) { $0 + $1.v } / Double(points.count) }
}

/// Taxa a partir de contadores cumulativos (rede/disco): primeira amostra é linha de base;
/// contador que diminui (reset/overflow) descarta a amostra em vez de gerar taxa negativa ou enorme.
public final class CounterRate {
    private var last: (t: TimeInterval, v: UInt64)?
    private let maxGap: TimeInterval
    public init(maxGap: TimeInterval = 120) { self.maxGap = maxGap }
    public func reset() { last = nil }

    public func update(_ value: UInt64, at t: TimeInterval) -> Double? {
        defer { last = (t, value) }
        guard let prev = last, t > prev.t, t - prev.t <= maxGap, value >= prev.v else { return nil }
        return Double(value - prev.v) / (t - prev.t)
    }
}
