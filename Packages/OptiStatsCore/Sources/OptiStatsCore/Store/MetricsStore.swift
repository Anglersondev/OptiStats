import Foundation

public enum MetricKind: String, CaseIterable, Hashable {
    case cpu, gpu, memory, processes, sensors, power, disk, network, battery, system
}

/// Identificador de série histórica (ex.: "cpu.total", "mem.used"). Aberto a novas séries.
public struct SeriesID: Hashable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value }
    public static let cpuTotal: SeriesID = "cpu.total"
    public static let gpuUtilization: SeriesID = "gpu.util"
    public static let memoryUsed: SeriesID = "mem.used"
    public static let memorySwap: SeriesID = "mem.swap"
    public static let tempCPU: SeriesID = "temp.cpu"
    public static let tempGPU: SeriesID = "temp.gpu"
    public static let powerSystem: SeriesID = "power.system"
    public static let diskRead: SeriesID = "disk.read"
    public static let diskWrite: SeriesID = "disk.write"
    public static let netRx: SeriesID = "net.rx"
    public static let netTx: SeriesID = "net.tx"
    public static func fan(_ index: Int) -> SeriesID { SeriesID("fan.\(index)") }
}

public final class SubscriptionToken {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel() }
    deinit { onCancel() }
}

/// Repositório thread-safe com o ÚLTIMO snapshot imutável de cada fonte + séries curtas.
/// Barra, painéis e histórico leem daqui: nenhuma leitura duplicada de hardware por widget.
public final class MetricsStore {
    private let lock = NSLock()
    private let clock: MonotonicClock
    private var _cpu: CPUSnapshot?
    private var _gpu: GPUSnapshot?
    private var _memory: MemorySnapshot?
    private var _processes: ProcessListSnapshot?
    private var _sensors: SensorsSnapshot?
    private var _sensorsByOwner: [String: [SensorReading]] = [:]
    private var _fans: [FanReading] = []
    private var _power: PowerSnapshot?
    private var _disk: DiskSnapshot?
    private var _network: NetworkSnapshot?
    private var _battery: BatterySnapshot?
    private var _system: SystemProfile?
    private var _series: [SeriesID: TimeSeries] = [:]
    private var _states: [CollectorID: SourceState] = [:]
    private var _memoryHistory = RingBuffer<MemorySnapshot>(capacity: 360)
    private var subscribers: [UUID: (kind: MetricKind, queue: DispatchQueue?, handler: () -> Void)] = [:]

    public let seriesCapacity: Int
    public let seriesRetention: TimeInterval

    public init(clock: MonotonicClock, seriesCapacity: Int = 900, seriesRetention: TimeInterval = 900) {
        self.clock = clock; self.seriesCapacity = seriesCapacity; self.seriesRetention = seriesRetention
    }

    // MARK: Leitura

    public var cpu: CPUSnapshot? { locked { _cpu } }
    public var gpu: GPUSnapshot? { locked { _gpu } }
    public var memory: MemorySnapshot? { locked { _memory } }
    public var processes: ProcessListSnapshot? { locked { _processes } }
    public var sensors: SensorsSnapshot? { locked { _sensors } }
    public var power: PowerSnapshot? { locked { _power } }
    public var disk: DiskSnapshot? { locked { _disk } }
    public var network: NetworkSnapshot? { locked { _network } }
    public var battery: BatterySnapshot? { locked { _battery } }
    public var system: SystemProfile? { locked { _system } }
    public var memoryHistory: [MemorySnapshot] { locked { _memoryHistory.elements } }
    public func series(_ id: SeriesID) -> TimeSeries { locked { _series[id] ?? TimeSeries(capacity: seriesCapacity, retention: seriesRetention) } }
    public func state(_ id: CollectorID) -> SourceState { locked { _states[id] ?? .loading } }
    public var states: [CollectorID: SourceState] { locked { _states } }

    // MARK: Publicação (chamada pelos coletores)

    public func publish(cpu s: CPUSnapshot) {
        mutate(.cpu) { $0._cpu = s; $0.append(.cpuTotal, s.load.timestamp, s.load.total * 100) }
    }
    public func publish(gpu s: GPUSnapshot) {
        mutate(.gpu) { $0._gpu = s; if let u = s.utilization { $0.append(.gpuUtilization, s.timestamp, u * 100) } }
    }
    public func publish(memory s: MemorySnapshot) {
        mutate(.memory) {
            $0._memory = s
            $0._memoryHistory.append(s)
            $0.append(.memoryUsed, s.timestamp, s.usedFraction * 100)
            if let swap = s.swap { $0.append(.memorySwap, s.timestamp, Double(swap.usedBytes)) }
        }
    }
    public func publish(processes s: ProcessListSnapshot) { mutate(.processes) { $0._processes = s } }
    /// Atualização PARCIAL de sensores. Cada coletor é "dono" das suas leituras (`owner`): publicar de novo
    /// substitui apenas as leituras daquele dono, sem apagar as dos outros (temperaturas, lista elétrica, diagnóstico…).
    /// `readings == nil` mantém as leituras do dono; `fans == nil` mantém as ventoinhas.
    public func updateSensors(timestamp: TimeInterval, owner: String, readings: [SensorReading]? = nil, fans: [FanReading]? = nil) {
        mutate(.sensors) { store in
            if let new = readings { store._sensorsByOwner[owner] = new }
            if let f = fans { store._fans = f }
            let merged = store._sensorsByOwner.keys.sorted().flatMap { key in store._sensorsByOwner[key] ?? [] }
            let aggregates = SensorAggregator.aggregates(from: merged, at: timestamp)
            store._sensors = SensorsSnapshot(timestamp: timestamp, readings: merged, aggregates: aggregates, fans: store._fans)
            if let v = aggregates.first(where: { $0.descriptor.key == "avg-cpu" })?.value { store.append(.tempCPU, timestamp, v) }
            if let v = aggregates.first(where: { $0.descriptor.key == "avg-gpu" })?.value { store.append(.tempGPU, timestamp, v) }
            for f in fans ?? [] { if let r = f.rpm { store.append(.fan(f.index), timestamp, r) } }
        }
    }

    public func publish(power s: PowerSnapshot) {
        mutate(.power) {
            $0._power = s
            if let w = s.readings.first(where: { $0.scope == .systemTotal })?.watts { $0.append(.powerSystem, s.timestamp, w) }
        }
    }
    public func publish(disk s: DiskSnapshot) {
        mutate(.disk) {
            $0._disk = s
            if let r = s.readBytesPerSecond { $0.append(.diskRead, s.timestamp, r) }
            if let w = s.writeBytesPerSecond { $0.append(.diskWrite, s.timestamp, w) }
        }
    }
    public func publish(network s: NetworkSnapshot) {
        mutate(.network) {
            $0._network = s
            if let r = s.rxBytesPerSecond { $0.append(.netRx, s.timestamp, r) }
            if let t = s.txBytesPerSecond { $0.append(.netTx, s.timestamp, t) }
        }
    }
    public func publish(battery s: BatterySnapshot) { mutate(.battery) { $0._battery = s } }
    public func publish(system s: SystemProfile) { mutate(.system) { $0._system = s } }

    public func setState(_ state: SourceState, for id: CollectorID) {
        let changed: Bool = locked { let c = _states[id] != state; _states[id] = state; return c }
        if changed { notify(Self.kind(for: id)) }
    }

    public func clearSeries() { locked { _series.removeAll(); _memoryHistory.removeAll() } }

    // MARK: Assinaturas

    /// O handler roda em `queue` (ou na fila de quem publicou). A UI deve coalescer e voltar à main thread.
    public func subscribe(_ kind: MetricKind, queue: DispatchQueue? = nil, _ handler: @escaping () -> Void) -> SubscriptionToken {
        let id = UUID()
        locked { subscribers[id] = (kind, queue, handler) }
        return SubscriptionToken { [weak self] in _ = self?.locked { self?.subscribers.removeValue(forKey: id) } }
    }

    // MARK: Internos

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func append(_ id: SeriesID, _ t: TimeInterval, _ v: Double) {
        // Modificar no dicionário evita compartilhar e copiar o buffer circular a cada amostra.
        _series[id, default: TimeSeries(capacity: seriesCapacity, retention: seriesRetention)].append(t: t, v: v)
    }

    private func mutate(_ kind: MetricKind, _ body: (MetricsStore) -> Void) {
        locked { body(self) }
        notify(kind)
    }

    private func notify(_ kind: MetricKind) {
        let targets: [(DispatchQueue?, () -> Void)] = locked { subscribers.values.filter { $0.kind == kind }.map { ($0.queue, $0.handler) } }
        for (queue, handler) in targets {
            if let q = queue { q.async(execute: handler) } else { handler() }
        }
    }

    static func kind(for id: CollectorID) -> MetricKind {
        switch id {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .processes: return .processes
        case .temperatures, .fans, .sensorList: return .sensors
        case .power: return .power
        case .disk: return .disk
        case .network: return .network
        case .battery: return .battery
        }
    }
}
