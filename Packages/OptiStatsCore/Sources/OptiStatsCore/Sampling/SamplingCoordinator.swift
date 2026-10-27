import Foundation

/// Coordenador central de amostragem: UM agendador, UM prazo por vez, leituras compartilhadas.
///
/// - Cada consumidor (widget da barra, popover, alerta interno) declara uma *demanda* por coletor.
/// - A visibilidade efetiva de um coletor é o máximo das demandas; sem demanda, o coletor é suspenso.
/// - Coletores com prazos próximos são executados no mesmo despertar (coalescência), reduzindo wakeups.
/// - Nunca há duas leituras sobrepostas do mesmo coletor.
public final class SamplingCoordinator {
    private final class Entry {
        let collector: Collector
        let executor: WorkExecutor
        var demands: [String: Visibility] = [:]
        var interval: TimeInterval?
        var nextDue: TimeInterval?
        var running = false
        var startedAt: TimeInterval = 0
        var lastStart: TimeInterval?
        var stats = CollectorStats()
        var recentRuns: [TimeInterval] = []
        init(collector: Collector, executor: WorkExecutor) { self.collector = collector; self.executor = executor }
        var visibility: Visibility { demands.values.max() ?? .hidden }
    }

    private let clock: MonotonicClock
    private let scheduler: WakeScheduler
    private let makeExecutor: (CollectorID) -> WorkExecutor
    private let policy: SamplingPolicy
    private let lock = NSLock()
    private var entries: [CollectorID: Entry] = [:]
    private var config = SamplingConfiguration()
    private var paused = false
    private var scheduledDeadline: TimeInterval?
    private var wakeups = 0

    /// Distância mínima entre uma leitura e uma leitura "imediata" disparada por abertura de painel/atualização manual.
    public var minimumImmediateGap: TimeInterval = 1.0
    /// Leitura que passa disso é marcada como travada (a fila daquele coletor não é reutilizada até terminar).
    public var stallTimeout: TimeInterval = 10

    public init(clock: MonotonicClock, scheduler: WakeScheduler,
                executorFactory: @escaping (CollectorID) -> WorkExecutor, policy: SamplingPolicy = SamplingPolicy()) {
        self.clock = clock; self.scheduler = scheduler; self.makeExecutor = executorFactory; self.policy = policy
    }

    // MARK: Registro e configuração

    public func register(_ collector: Collector) {
        lock.lock(); defer { lock.unlock() }
        entries[collector.id] = Entry(collector: collector, executor: makeExecutor(collector.id))
    }

    public func setConfiguration(_ new: SamplingConfiguration) {
        var toSuspend: [Entry] = []
        lock.lock()
        config = new
        for entry in entries.values { applyDemandLocked(entry, previouslyActive: entry.interval != nil, oldVisibility: entry.visibility, toSuspend: &toSuspend) }
        rescheduleLocked()
        lock.unlock()
        suspend(toSuspend)
    }

    /// `visibility == nil` remove a demanda do consumidor.
    public func setDemand(consumer: String, collector id: CollectorID, visibility: Visibility?) {
        var toSuspend: [Entry] = []
        lock.lock()
        guard let entry = entries[id] else { lock.unlock(); return }
        let wasActive = entry.interval != nil
        let oldVisibility = entry.visibility
        if let v = visibility, v != .hidden { entry.demands[consumer] = v } else { entry.demands.removeValue(forKey: consumer) }
        applyDemandLocked(entry, previouslyActive: wasActive, oldVisibility: oldVisibility, toSuspend: &toSuspend)
        rescheduleLocked()
        lock.unlock()
        suspend(toSuspend)
    }

    private func applyDemandLocked(_ entry: Entry, previouslyActive: Bool, oldVisibility: Visibility? = nil,
                                   toSuspend: inout [Entry]) {
        let newInterval = paused ? nil : policy.interval(for: entry.collector.id, visibility: entry.visibility, config: config)
        entry.interval = newInterval
        entry.stats.interval = newInterval
        entry.stats.isActive = newInterval != nil
        guard let interval = newInterval else {
            entry.nextDue = nil
            if previouslyActive { toSuspend.append(entry) }
            return
        }
        let now = clock.now
        if let last = entry.lastStart {
            // Respeita o intervalo desde a última leitura, mas com abertura de painel pede leitura quase imediata.
            let byInterval = last + interval
            let immediate = last + minimumImmediateGap
            let rising = (oldVisibility ?? .hidden) < entry.visibility || !previouslyActive
            entry.nextDue = max(now, rising ? min(byInterval, immediate) : byInterval)
        } else {
            entry.nextDue = now
        }
    }

    public func effectiveInterval(for id: CollectorID) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.interval
    }

    // MARK: Pausa (repouso / tela bloqueada)

    public func pause() {
        var toSuspend: [Entry] = []
        lock.lock()
        paused = true
        for e in entries.values { e.nextDue = nil; e.interval = nil; e.stats.interval = nil; e.stats.isActive = false; toSuspend.append(e) }
        scheduler.cancel(); scheduledDeadline = nil
        lock.unlock()
        suspend(toSuspend)
    }

    public func resume(settleDelay: TimeInterval = 1.5) {
        var none: [Entry] = []
        lock.lock()
        paused = false
        let now = clock.now
        for e in entries.values {
            applyDemandLocked(e, previouslyActive: false, toSuspend: &none)
            if e.interval != nil { e.nextDue = now + settleDelay; e.lastStart = nil }
        }
        rescheduleLocked()
        lock.unlock()
    }

    // MARK: Atualização manual

    /// "Atualizar agora": respeita limite de taxa. Devolve false se limitada, em execução ou desconhecida.
    @discardableResult
    public func refreshNow(_ id: CollectorID) -> Bool {
        lock.lock()
        guard let e = entries[id], !e.running, !paused else { lock.unlock(); return false }
        let now = clock.now
        if let last = e.lastStart, now - last < minimumImmediateGap { lock.unlock(); return false }
        e.running = true; e.startedAt = now; e.lastStart = now
        lock.unlock()
        dispatch(e)
        return true
    }

    // MARK: Despertar

    private func onWake() {
        var toRun: [Entry] = []
        lock.lock()
        scheduledDeadline = nil
        wakeups += 1
        let now = clock.now
        for e in entries.values {
            guard let due = e.nextDue, let interval = e.interval else { continue }
            let window = min(0.5, interval * 0.1)
            guard due <= now + window else { continue }
            if e.running { e.nextDue = now + interval; continue }   // nunca sobrepor leituras
            e.running = true; e.startedAt = now; e.lastStart = now; e.nextDue = nil
            toRun.append(e)
        }
        rescheduleLocked()
        lock.unlock()
        for e in toRun { dispatch(e) }
    }

    private func dispatch(_ e: Entry) {
        e.executor.execute { [weak self, clock] in
            let t0 = clock.now
            e.collector.collect()
            let t1 = clock.now
            self?.finish(e, started: t0, duration: t1 - t0)
        }
    }

    private func finish(_ e: Entry, started: TimeInterval, duration: TimeInterval) {
        lock.lock()
        e.running = false
        e.stats.runs += 1
        e.stats.totalRunSeconds += duration
        e.stats.lastDuration = duration
        e.stats.lastRunAt = started
        e.recentRuns.append(started)
        if e.recentRuns.count > 240 { e.recentRuns.removeFirst(e.recentRuns.count - 240) }
        if let interval = e.interval, !paused {
            e.nextDue = max(clock.now, (e.lastStart ?? started) + interval)
        } else {
            e.nextDue = nil
        }
        rescheduleLocked()
        lock.unlock()
    }

    private func rescheduleLocked() {
        let next = entries.values.compactMap { $0.nextDue }.min()
        guard let deadline = next, !paused else {
            if scheduledDeadline != nil { scheduler.cancel(); scheduledDeadline = nil }
            return
        }
        if let s = scheduledDeadline, abs(s - deadline) < 0.001 { return }
        scheduledDeadline = deadline
        let interval = entries.values.filter { $0.nextDue == deadline }.compactMap { $0.interval }.min() ?? 5
        let leeway = min(1.0, max(0.05, interval * 0.1))
        scheduler.schedule(deadline: deadline, leeway: leeway) { [weak self] in self?.onWake() }
    }

    private func suspend(_ list: [Entry]) {
        for e in list { e.executor.execute { e.collector.suspend() } }
    }

    // MARK: Observabilidade ("Eficiência do monitor")

    public var wakeupCount: Int { lock.lock(); defer { lock.unlock() }; return wakeups }

    public func stats() -> [CollectorID: CollectorStats] {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now
        var out: [CollectorID: CollectorStats] = [:]
        for (id, e) in entries {
            var s = e.stats
            s.isStalled = e.running && now - e.startedAt > stallTimeout
            s.readsLastMinute = e.recentRuns.filter { $0 >= now - 60 }.count
            out[id] = s
        }
        return out
    }
}
