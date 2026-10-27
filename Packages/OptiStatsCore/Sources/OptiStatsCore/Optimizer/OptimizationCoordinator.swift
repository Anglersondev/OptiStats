import Foundation

/// Operações sobre aplicativos em execução (implementadas com NSRunningApplication na camada do app).
public protocol AppController: AnyObject {
    /// Revalida a identidade: devolve a identidade atual do PID se ainda for o mesmo processo; nil se sumiu/foi reciclado.
    func liveIdentity(matching identity: ProcessIdentity) -> ProcessIdentity?
    func isFrontmost(_ identity: ProcessIdentity) -> Bool
    /// Pede encerramento NORMAL (equivalente a Cmd+Q). Nunca força. false se o pedido não pôde ser feito.
    func requestGracefulQuit(_ identity: ProcessIdentity) -> Bool
    func isRunning(_ identity: ProcessIdentity) -> Bool
}

public protocol MemoryProbe: AnyObject {
    func captureMemory() -> MemorySnapshot?
}

public protocol AsyncSleeper {
    func sleep(seconds: TimeInterval) async
}

public struct TaskSleeper: AsyncSleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

public final class CancelToken {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

public enum SkipReason: Equatable {
    case cancelled
    case identityChanged       // processo sumiu ou PID reciclado
    case noLeaderProcess
    case protectedNow(ProtectionVerdict)
}

public enum QuitOutcome: Equatable {
    case quit
    /// O app recebeu o pedido mas ainda está aberto (ex.: perguntando sobre documento não salvo). Não insistimos.
    case stillRunning
    case requestFailed
    case skipped(SkipReason)
}

public struct OptimizationItem: Equatable {
    public var group: AppGroup
    public var estimatedBytes: UInt64
    public init(group: AppGroup) { self.group = group; self.estimatedBytes = group.footprintBytes }
}

public struct ItemResult: Equatable {
    public var item: OptimizationItem
    public var outcome: QuitOutcome
}

public struct OptimizationConfig: Equatable {
    public var quitTimeout: TimeInterval = 8
    public var pollInterval: TimeInterval = 0.5
    public var settleDelay: TimeInterval = 4
    public init() {}
}

/// Resultado honesto: variações GLOBAIS observadas, sem atribuí-las a este app.
public struct ReclaimReport: Equatable {
    public var before: MemorySnapshot?
    public var after: MemorySnapshot?
    public var results: [ItemResult]

    public var quitCount: Int { results.filter { $0.outcome == .quit }.count }
    public var actionTaken: Bool { results.contains { if case .skipped = $0.outcome { return false } else { return true } } }

    /// Variação observada em "disponível" (pode ser negativa). nil se faltar uma das fotos.
    public var availableDelta: Int64? {
        guard let b = before, let a = after else { return nil }
        return Int64(a.availableBytes) - Int64(b.availableBytes)
    }
    public var swapUsedDelta: Int64? {
        guard let b = before?.swap, let a = after?.swap else { return nil }
        return Int64(a.usedBytes) - Int64(b.usedBytes)
    }

    public enum Summary: Equatable {
        /// Nenhuma ação executada: ganho "não atribuível / nenhum".
        case noActionTaken
        /// Processos foram encerrados; `availableDelta` é a variação GLOBAL observada (não atribuída).
        case closedApps(count: Int, availableDelta: Int64?)
        case requestedButStillOpen(count: Int)
    }

    public var summary: Summary {
        if !actionTaken { return .noActionTaken }
        if quitCount > 0 { return .closedApps(count: quitCount, availableDelta: availableDelta) }
        return .requestedButStillOpen(count: results.filter { $0.outcome == .stillRunning }.count)
    }
}

/// Executa a "Otimização segura": confirmação já dada pelo usuário; aqui só se revalida e se pede encerramento normal.
public final class OptimizationCoordinator {
    private let apps: AppController
    private let probe: MemoryProbe
    private let sleeper: AsyncSleeper
    private let policy: () -> ProtectionPolicy
    private let config: OptimizationConfig

    public init(apps: AppController, probe: MemoryProbe, policy: @escaping () -> ProtectionPolicy,
                sleeper: AsyncSleeper = TaskSleeper(), config: OptimizationConfig = OptimizationConfig()) {
        self.apps = apps; self.probe = probe; self.policy = policy; self.sleeper = sleeper; self.config = config
    }

    public func run(items: [OptimizationItem], cancel: CancelToken = CancelToken()) async -> ReclaimReport {
        let before = probe.captureMemory()
        var results: [ItemResult] = []
        for item in items {
            if cancel.isCancelled { results.append(ItemResult(item: item, outcome: .skipped(.cancelled))); continue }
            results.append(ItemResult(item: item, outcome: await quit(item, cancel: cancel)))
        }
        if results.contains(where: { if case .skipped = $0.outcome { return false } else { return true } }) {
            await sleeper.sleep(seconds: config.settleDelay)
        }
        return ReclaimReport(before: before, after: probe.captureMemory(), results: results)
    }

    private func quit(_ item: OptimizationItem, cancel: CancelToken) async -> QuitOutcome {
        guard let leader = item.group.leader else { return .skipped(.noLeaderProcess) }
        guard let live = apps.liveIdentity(matching: leader), live == leader else { return .skipped(.identityChanged) }
        let frontmost = apps.isFrontmost(live)
        let verdict = policy().verdict(for: item.group, context: AppRuntimeContext(isFrontmost: frontmost))
        if verdict.isProtected { return .skipped(.protectedNow(verdict)) }
        guard apps.requestGracefulQuit(live) else { return .requestFailed }
        var waited: TimeInterval = 0
        while waited < config.quitTimeout {
            if !apps.isRunning(live) { return .quit }
            if cancel.isCancelled { break }
            await sleeper.sleep(seconds: config.pollInterval)
            waited += config.pollInterval
        }
        return apps.isRunning(live) ? .stillRunning : .quit
    }
}
