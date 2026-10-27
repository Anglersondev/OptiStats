import Foundation
import Dispatch

/// Agendador de UM despertar por vez (o coordenador sempre pede o próximo prazo mais cedo).
public protocol WakeScheduler: AnyObject {
    /// `deadline` na base do `MonotonicClock`.
    func schedule(deadline: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void)
    func cancel()
}

public protocol WorkExecutor: AnyObject {
    func execute(_ work: @escaping () -> Void)
}

public final class QueueExecutor: WorkExecutor {
    private let queue: DispatchQueue
    public init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }
    public func execute(_ work: @escaping () -> Void) { queue.async(execute: work) }
}

public final class ImmediateExecutor: WorkExecutor {
    public init() {}
    public func execute(_ work: @escaping () -> Void) { work() }
}

/// Um único `DispatchSourceTimer` reprogramado (nunca um timer por indicador).
public final class DispatchWakeScheduler: WakeScheduler {
    private let clock: MonotonicClock
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var handler: (() -> Void)?

    public init(clock: MonotonicClock, qos: DispatchQoS = .utility) {
        self.clock = clock
        self.queue = DispatchQueue(label: "app.optistats.wake", qos: qos)
    }

    public func schedule(deadline: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            let delay = max(0, deadline - self.clock.now)
            let t: DispatchSourceTimer
            if let existing = self.timer { t = existing } else {
                t = DispatchSource.makeTimerSource(queue: self.queue)
                t.setEventHandler { [weak self] in self?.handler?() }
                self.timer = t
                t.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(Int(leeway * 1000)))
                t.resume()
                return
            }
            t.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(Int(leeway * 1000)))
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            self?.timer?.schedule(deadline: .distantFuture, repeating: .never)
        }
    }

    deinit { timer?.cancel() }
}
