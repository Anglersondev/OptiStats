import Cocoa
import OptiStatsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment!
    private var statusController: StatusItemController!
    private var preferencesController: PreferencesWindowController?
    private var aboutController: AboutWindowController?
    private var processBrowser: ProcessBrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let env = AppEnvironment()
        AppEnvironment.current = env
        self.env = env

        let controller = StatusItemController(env: env)
        controller.onOpenPreferences = { [weak self] in self?.showPreferences() }
        controller.onOpenAbout = { [weak self] in self?.showAbout() }
        controller.onOpenMaintenance = { [weak self] in self?.showMaintenance() }
        statusController = controller
        // A barra reage a mudanças de preferências (visibilidade, ordem, rótulos, unidade...).
        env.openProcessBrowser = { [weak self] in self?.showProcessBrowser() }
        env.openPreferences = { [weak self] in self?.showPreferences() }
        env.openMaintenance = { [weak self] in self?.showMaintenance() }
        env.openAbout = { [weak self] in self?.showAbout() }
        env.onPreferencesApplied = { [weak controller] in controller?.preferencesDidChange() }

        env.start()   // registra coletores e chama applyPreferences() -> controller.preferencesDidChange()
        controller.preferencesDidChange()
    }

    func applicationWillTerminate(_ notification: Notification) {
        env?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Janelas

    func showPreferences(tab: PreferencesWindowController.Tab? = nil) {
        if preferencesController == nil {
            let pc = PreferencesWindowController(env: env)
            pc.onClose = { [weak self] in self?.preferencesController = nil }
            pc.onOpenMemoryOptimizer = { [weak self] in self?.statusController.openPopover(for: .ram) }
            preferencesController = pc
        }
        preferencesController?.show(tab: tab)
    }

    /// Manutenção vive como abas dentro de Preferências (Disco e cache, RAM avançada, Debloat).
    func showMaintenance() { showPreferences(tab: .diskCleanup) }

    func showProcessBrowser() {
        if processBrowser == nil { processBrowser = ProcessBrowserWindowController() }
        processBrowser?.show()
    }

    func showAbout() {
        if aboutController == nil {
            let ac = AboutWindowController()
            ac.onClose = { [weak self] in self?.aboutController = nil }
            aboutController = ac
        }
        aboutController?.show()
    }

    // MARK: Menu principal mínimo
    // Aplicativo sem Dock não exibe a barra de menus, mas os atalhos de edição (copiar/colar) e ⌘Q
    // dependem de um menu principal existir.

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("shell.menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
