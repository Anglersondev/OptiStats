import Foundation
import AppKit
import IOKit.ps
import OptiStatsCore

/// Eventos do sistema por notificações (sem timers): repouso/despertar, bloqueio de tela, estado térmico,
/// modo de baixo consumo, troca de fonte de energia (IOPS) e pressão de memória (DispatchSource).
final class MacSystemEvents: SystemEventSource {
    var handler: ((SystemEvent) -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var memorySource: DispatchSourceMemoryPressure?
    private var lastOnBattery: Bool?
    private var running = false
    private let lock = NSLock()

    deinit { stop() }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        lastOnBattery = Self.isOnBattery()

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { [weak self] _ in self?.emit(.willSleep) }
        observe(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.emit(.didWake) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.emit(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.emit(.screenUnlocked) }

        let nc = NotificationCenter.default
        observe(nc, ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            self?.emit(.thermalChanged(thermalLevel(ProcessInfo.processInfo.thermalState)))
        }
        observe(nc, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            self?.emit(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        }

        // Troca de fonte de energia (fonte de run loop do IOKit; não acorda a CPU por conta própria).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let unmanaged = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<MacSystemEvents>.fromOpaque(ctx).takeUnretainedValue().powerSourcesChanged()
        }, context) {
            let source = unmanaged.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        mem.setEventHandler { [weak self, weak mem] in
            guard let self, let mem else { return }
            let data = mem.data
            if data.contains(.critical) { self.emit(.memoryPressure(.critical)) }
            else if data.contains(.warning) { self.emit(.memoryPressure(.warning)) }
            else { self.emit(.memoryPressure(.normal)) }
        }
        mem.resume()
        memorySource = mem
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        running = false
        for o in observers { o.center.removeObserver(o.token) }
        observers.removeAll()
        if let s = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); powerSource = nil }
        memorySource?.cancel(); memorySource = nil
    }

    func currentPowerContext() -> PowerContext {
        PowerContext(onBattery: Self.isOnBattery(),
                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     thermal: thermalLevel(ProcessInfo.processInfo.thermalState))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: nil, using: block)))
    }

    private func emit(_ event: SystemEvent) { handler?(event) }

    fileprivate func powerSourcesChanged() {
        let now = Self.isOnBattery()
        lock.lock()
        let changed = lastOnBattery != now
        lastOnBattery = now
        lock.unlock()
        if changed { emit(.powerSourceChanged(onBattery: now)) }
    }

    static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
        return type == "Battery Power"
    }
}
