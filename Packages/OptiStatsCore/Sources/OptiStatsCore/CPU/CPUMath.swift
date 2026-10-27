import Foundation

/// Ticks de CPU de um núcleo (contadores de 32 bits do Mach que podem dar a volta).
public struct CPUTicks: Equatable {
    public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public struct CPULoad: Equatable {
    public var timestamp: TimeInterval
    /// Fração (0...1) do total de CPU lógica. `nice` é contado como usuário.
    public var total: Double
    public var user: Double
    public var system: Double
    public var idle: Double
    /// Uso por CPU lógica (0...1), na ordem de `host_processor_info`.
    public var perCore: [Double]
}

/// Calcula uso por delta. A primeira amostra é só linha de base (retorna nil, nunca 0 falso).
public final class CPULoadCalculator {
    private var previous: [CPUTicks]?
    private var previousTime: TimeInterval?
    private let maxGap: TimeInterval

    /// `maxGap`: acima disso (ex.: após repouso) a linha de base é descartada.
    public init(maxGap: TimeInterval = 120) { self.maxGap = maxGap }

    public func reset() { previous = nil; previousTime = nil }

    public func update(ticks: [CPUTicks], at time: TimeInterval) -> CPULoad? {
        defer { previous = ticks; previousTime = time }
        guard let prev = previous, let pt = previousTime, prev.count == ticks.count, !ticks.isEmpty,
              time > pt, time - pt <= maxGap else { return nil }
        var perCore: [Double] = []
        var sumUser = 0.0, sumSys = 0.0, sumIdle = 0.0, sumTotal = 0.0
        for (a, b) in zip(prev, ticks) {
            let u = Double(b.user &- a.user) + Double(b.nice &- a.nice)
            let s = Double(b.system &- a.system)
            let i = Double(b.idle &- a.idle)
            let t = u + s + i
            if t > 0 { perCore.append(min(1, (u + s) / t)) } else { perCore.append(0) }
            sumUser += u; sumSys += s; sumIdle += i; sumTotal += t
        }
        guard sumTotal > 0 else { return nil }
        let user = sumUser / sumTotal, sys = sumSys / sumTotal, idle = sumIdle / sumTotal
        return CPULoad(timestamp: time, total: min(1, user + sys), user: user, system: sys, idle: idle, perCore: perCore)
    }
}

/// Carga média do sistema (`getloadavg`). Número de processos prontos — NÃO é porcentagem.
public struct LoadAverage: Equatable {
    public var one: Double, five: Double, fifteen: Double
    public init(one: Double, five: Double, fifteen: Double) { self.one = one; self.five = five; self.fifteen = fifteen }
}

/// Conversão de unidades do Mach (`mach_absolute_time`) para nanossegundos.
/// Em Apple Silicon a razão não é 1:1 (tipicamente 125/3), então o campo cru NÃO são nanossegundos.
public struct MachTimebase: Equatable {
    public var numer: UInt32, denom: UInt32
    public init(numer: UInt32, denom: UInt32) { self.numer = numer; self.denom = max(1, denom) }
    public func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let (q, r) = ticks.quotientAndRemainder(dividingBy: UInt64(denom))
        return q &* UInt64(numer) &+ (r &* UInt64(numer)) / UInt64(denom)
    }
}

/// CPU por processo: percentual de UM núcleo (pode passar de 100%, como no Monitor de Atividade).
public final class ProcessCPUCalculator {
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var previousTime: TimeInterval?
    public init() {}

    public struct Result: Equatable {
        public var identity: ProcessIdentity
        /// 1.0 = um núcleo inteiro ocupado.
        public var coresBusy: Double
    }

    /// `cpuTimeNs` = tempo de usuário+sistema acumulado por processo, em ns.
    public func update(cpuTimeNs: [ProcessIdentity: UInt64], at time: TimeInterval) -> [Result] {
        defer { previous = cpuTimeNs; previousTime = time }
        guard let pt = previousTime, time > pt else { return [] }
        let dt = time - pt
        var out: [Result] = []
        for (id, now) in cpuTimeNs {
            guard let before = previous[id], now >= before else { continue }   // processo novo ou reciclado
            out.append(Result(identity: id, coresBusy: Double(now - before) / 1e9 / dt))
        }
        return out.sorted { $0.coresBusy > $1.coresBusy }
    }

    /// Converte para fração do total da máquina (0...1) usando o nº de CPUs lógicas.
    public static func normalizedToMachine(coresBusy: Double, logicalCPUs: Int) -> Double {
        logicalCPUs > 0 ? min(1, coresBusy / Double(logicalCPUs)) : 0
    }
}
