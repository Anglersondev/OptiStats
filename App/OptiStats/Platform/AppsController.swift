import Foundation
import AppKit
import OptiStatsCore

/// Operações sobre aplicativos (NSRunningApplication) e app em primeiro plano.
/// A identidade é sempre revalidada (PID + horário de início) antes de qualquer ação: nunca age sobre PID reciclado.
final class MacAppController: AppController, FrontmostAppProviding {
    private let lock = NSLock()
    private var frontmostID: String?
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private let activityStartedAt = ProcessInfo.processInfo.systemUptime
    private var lastActive: [String: TimeInterval] = [:]

    init() {
        frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Observador de notificação (sem timer): mantém o app em primeiro plano em cache para leitura em qualquer fila.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self else { return }
            self.lock.lock()
            if let previous = self.frontmostID { self.lastActive[previous] = ProcessInfo.processInfo.systemUptime }
            self.frontmostID = app?.bundleIdentifier
            if self.lastActive.count > 128, let oldest = self.lastActive.min(by: { $0.value < $1.value })?.key {
                self.lastActive.removeValue(forKey: oldest)
            }
            self.lock.unlock()
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self.lock.lock(); self.lastActive[id] = ProcessInfo.processInfo.systemUptime; self.lock.unlock()
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self.lock.lock(); self.lastActive.removeValue(forKey: id); self.lock.unlock()
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
    }

    var frontmostBundleIdentifier: String? {
        lock.lock(); defer { lock.unlock() }
        return frontmostID
    }

    func backgroundIdleSeconds(bundleIdentifier: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard bundleIdentifier != frontmostID else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - (lastActive[bundleIdentifier] ?? activityStartedAt))
    }

    func liveIdentity(matching identity: ProcessIdentity) -> ProcessIdentity? {
        guard let start = ProcReader.startTime(pid: identity.pid), abs(start - identity.startTime) < 0.001 else { return nil }
        return ProcessIdentity(pid: identity.pid, startTime: start)
    }

    func isFrontmost(_ identity: ProcessIdentity) -> Bool {
        guard liveIdentity(matching: identity) != nil else { return false }
        return onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid }
    }

    func requestGracefulQuit(_ identity: ProcessIdentity) -> Bool {
        guard liveIdentity(matching: identity) != nil else { return false }
        return onMain {
            guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated else { return false }
            if let id = app.bundleIdentifier, ProtectionPolicy.essentialLauncherBundleIDs.contains(id) { return false }
            return app.terminate()   // pedido normal (equivale a Cmd+Q); nunca forceTerminate
        }
    }

    func isRunning(_ identity: ProcessIdentity) -> Bool {
        guard liveIdentity(matching: identity) != nil else { return false }
        if let app = NSRunningApplication(processIdentifier: identity.pid) { return !app.isTerminated }
        return true   // processo vivo sem NSRunningApplication (não é app de interface)
    }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}
