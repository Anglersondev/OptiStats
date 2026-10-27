import Foundation
import Dispatch

/// Relógio monotônico em segundos. Não avança durante o repouso do sistema
/// (mesma base de `DispatchTime`), o que é o desejado para agendar amostragens.
public protocol MonotonicClock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemMonotonicClock: MonotonicClock {
    public init() {}
    public var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Relógio manual para testes e simulações determinísticas.
public final class ManualClock: MonotonicClock {
    private let lock = NSLock()
    private var value: TimeInterval
    public init(start: TimeInterval = 1000) { value = start }
    public var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func advance(by seconds: TimeInterval) {
        lock.lock(); value += seconds; lock.unlock()
    }
    public func set(_ seconds: TimeInterval) {
        lock.lock(); value = seconds; lock.unlock()
    }
}
