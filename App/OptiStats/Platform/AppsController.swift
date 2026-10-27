import Foundation
import AppKit
import OptiStatsCore

/// Operações sobre aplicativos (NSRunningApplication) e app em primeiro plano.
/// A identidade é sempre revalidada (PID + horário de início) antes de qualquer ação: nunca age sobre PID reciclado.
final class MacAppController: AppController, FrontmostAppProviding {
    private let lock = NSLock()
    private var frontmostID: String?
    private var observer: NSObjectProtocol?

    init() {
        frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Observador de notificação (sem timer): mantém o app em primeiro plano em cache para leitura em qualquer fila.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.lock(); self?.frontmostID = app?.bundleIdentifier; self?.lock.unlock()
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var frontmostBundleIdentifier: String? {
        lock.lock(); defer { lock.unlock() }
        return frontmostID
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
