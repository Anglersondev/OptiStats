import Cocoa
import OptiStatsCore

/// Janela de Preferências em AppKit (abas na barra de ferramentas). Descartada ao fechar:
/// as abas cancelam demandas e assinaturas ao serem desalocadas.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    var onClose: (() -> Void)?
    /// Abre o popover de Memória (onde fica o otimizador), usado pela aba "RAM avançada".
    var onOpenMemoryOptimizer: (() -> Void)?

    /// Posição das abas na barra de ferramentas.
    enum Tab: Int { case general = 0, diskCleanup = 8, memoryAdvanced = 9, debloat = 10 }

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func show(tab: Tab? = nil) {
        if window == nil { buildWindow(selectedIndex: tab?.rawValue ?? 0) }
        else if let tab, let tabs, tab.rawValue < tabs.tabViewItems.count { tabs.selectedTabViewItemIndex = tab.rawValue }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makePanes() -> [PrefsPaneViewController] {
        let ram = MemoryAdvancedPane(env: env)
        ram.onOpenOptimizer = { [weak self] in self?.onOpenMemoryOptimizer?() }
        return [GeneralPrefsPane(env: env), MenuBarPrefsPane(env: env), SamplingPrefsPane(env: env),
                SensorsPrefsPane(env: env), OptimizerPrefsPane(env: env), FansPrefsPane(env: env),
                DiagnosticsPrefsPane(env: env), PrivacyPrefsPane(env: env),
                DiskCleanupPane(env: env), ram, DebloatPane(env: env)]
    }

    private func buildWindow(selectedIndex: Int) {
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar
        for pane in makePanes() {
            pane.onLanguageChanged = { [weak self] in self?.languageChanged() }
            tabVC.addChild(pane)
            tabVC.tabViewItems.last?.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
        }
        if selectedIndex >= 0 && selectedIndex < tabVC.tabViewItems.count {
            tabVC.selectedTabViewItemIndex = selectedIndex
        }
        let w = NSWindow(contentViewController: tabVC)
        w.styleMask = [.titled, .closable]
        w.title = L("prefs.window.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        tabs = tabVC
        window = w
    }

    /// Troca de idioma: reconstrói a janela inteira na mesma aba, depois do clique atual.
    private func languageChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let old = self.window else { return }
            let index = self.tabs?.selectedTabViewItemIndex ?? 0
            old.delegate = nil
            self.window = nil
            self.tabs = nil
            old.close()
            self.buildWindow(selectedIndex: index)
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
        tabs = nil
        onClose?()
    }
}
