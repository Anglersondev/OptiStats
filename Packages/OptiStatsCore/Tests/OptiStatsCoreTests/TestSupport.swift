import Foundation
@testable import OptiStatsCore

final class ManualWakeScheduler: WakeScheduler {
    private(set) var pendingDeadline: TimeInterval?
    private(set) var scheduleCalls = 0
    private(set) var cancelCalls = 0
    private var handler: (() -> Void)?

    func schedule(deadline: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void) {
        scheduleCalls += 1
        pendingDeadline = deadline
        self.handler = handler
    }
    func cancel() { cancelCalls += 1; pendingDeadline = nil; handler = nil }

    /// Avança o relógio até o prazo pendente e dispara o despertar. Devolve false se nada estava agendado.
    @discardableResult
    func fire(clock: ManualClock) -> Bool {
        guard let d = pendingDeadline, let h = handler else { return false }
        if clock.now < d { clock.set(d) }
        pendingDeadline = nil
        h()
        return true
    }
}

final class FakeCollector: Collector {
    let id: CollectorID
    private(set) var collectCount = 0
    private(set) var suspendCount = 0
    var onCollect: (() -> Void)?
    init(_ id: CollectorID) { self.id = id }
    func collect() { collectCount += 1; onCollect?() }
    func suspend() { suspendCount += 1 }
}

/// Executor que só roda quando mandamos (simula leitura lenta/travada).
final class ManualExecutor: WorkExecutor {
    var queue: [() -> Void] = []
    func execute(_ work: @escaping () -> Void) { queue.append(work) }
    func runAll() { let q = queue; queue = []; q.forEach { $0() } }
}

func makeCoordinator(clock: ManualClock = ManualClock(), executor: @escaping (CollectorID) -> WorkExecutor = { _ in ImmediateExecutor() })
    -> (SamplingCoordinator, ManualWakeScheduler, ManualClock) {
    let sched = ManualWakeScheduler()
    return (SamplingCoordinator(clock: clock, scheduler: sched, executorFactory: executor), sched, clock)
}

let GiB: UInt64 = 1024 * 1024 * 1024
let MiB: UInt64 = 1024 * 1024

func process(_ pid: Int32, _ name: String, path: String? = nil, bundle: String? = nil, uid: UInt32 = 501,
             footprint: UInt64 = 0, start: TimeInterval = 100) -> ProcessSample {
    ProcessSample(identity: ProcessIdentity(pid: pid, startTime: start + Double(pid)), name: name, executablePath: path,
                  bundleIdentifier: bundle, uid: uid, footprintBytes: footprint)
}

func appGroup(_ name: String, bundle: String? = nil, footprint: UInt64, processes: Int = 1, pid: Int32 = 1000,
              path: String? = nil, system: Bool = false) -> AppGroup {
    let p = path ?? "/Applications/\(name).app"
    var members: [ProcessSample] = []
    for i in 0..<max(1, processes) {
        members.append(process(pid + Int32(i), i == 0 ? name : "\(name) Helper", path: i == 0 ? p + "/Contents/MacOS/\(name)" : p + "/Contents/Frameworks/H.app/Contents/MacOS/H",
                               bundle: bundle, footprint: footprint / UInt64(max(1, processes))))
    }
    return AppGroup(id: "app:" + p, displayName: name, bundlePath: p, bundleIdentifier: bundle,
                    leader: members.first?.identity, members: members, isSystemOwned: system)
}

func memorySnapshot(t: TimeInterval, total: UInt64 = 24 * GiB, used: UInt64 = 16 * GiB, pressure: MemoryPressureLevel? = .normal,
                    swapUsed: UInt64 = 0, swapOuts: UInt64 = 0) -> MemorySnapshot {
    MemorySnapshot(timestamp: t, totalBytes: total, appBytes: used, wiredBytes: 0, compressedBytes: 0, usedBytes: used,
                   cachedFilesBytes: 0, freeStrictBytes: 0, availableBytes: total - used, alternativeUsedBytes: used,
                   swap: SwapUsage(totalBytes: 4 * GiB, usedBytes: swapUsed, freeBytes: 4 * GiB - swapUsed), pressure: pressure,
                   counters: MemoryCounters(swapIns: 0, swapOuts: swapOuts, pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0))
}
