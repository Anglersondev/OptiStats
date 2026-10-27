import Cocoa
import OptiStatsCore

/// Janela "Manutenção" (abas na barra de ferramentas, no estilo da janela de Preferências).
/// Descartada ao fechar: as abas cancelam varreduras, demandas e assinaturas ao serem desalocadas.
final class MaintenanceWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    var onClose: (() -> Void)?
    /// Abre o popover de Memória (onde fica o otimizador existente).
    var onOpenMemoryOptimizer: (() -> Void)?

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar
        let ram = MemoryAdvancedPane(env: env)
        ram.onOpenOptimizer = { [weak self] in self?.onOpenMemoryOptimizer?() }
        let panes: [PrefsPaneViewController] = [DiskCleanupPane(env: env), ram, DebloatPane(env: env)]
        for pane in panes {
            tabVC.addChild(pane)
            tabVC.tabViewItems.last?.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
        }
        let w = NSWindow(contentViewController: tabVC)
        w.styleMask = [.titled, .closable]
        w.title = L("maint.window.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
        onClose?()
    }
}
