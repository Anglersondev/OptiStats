import Cocoa
import OptiStatsCore

/// Janela de Preferências em AppKit (abas na barra de ferramentas). Descartada ao fechar:
/// as abas cancelam demandas e assinaturas ao serem desalocadas.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var sidebar: PrefsSidebarViewController?
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
        else if let tab, let tabs, tab.rawValue < tabs.tabViewItems.count {
            tabs.selectedTabViewItemIndex = tab.rawValue
            sidebar?.select(tab.rawValue)
        }
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
        // Barra lateral (como os Ajustes do Sistema): todas as abas sempre visíveis, sem o menu de overflow ">>".
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .unspecified
        var titles: [(title: String, symbol: String)] = []
        for pane in makePanes() {
            pane.onLanguageChanged = { [weak self] in self?.languageChanged() }
            tabVC.addChild(pane)
            titles.append((pane.paneTitle, pane.symbolName))
        }
        let index = (selectedIndex >= 0 && selectedIndex < titles.count) ? selectedIndex : 0
        tabVC.selectedTabViewItemIndex = index

        let side = PrefsSidebarViewController(items: titles, selected: index) { [weak tabVC] i in
            tabVC?.selectedTabViewItemIndex = i
        }
        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: side)
        sideItem.minimumThickness = 190
        sideItem.maximumThickness = 190
        sideItem.canCollapse = false
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: tabVC))

        let w = NSWindow(contentViewController: split)
        w.styleMask = [.titled, .closable, .resizable]
        w.title = L("prefs.window.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 190 + PrefsPaneViewController.contentSize.width, height: PrefsPaneViewController.contentSize.height))
        w.minSize = NSSize(width: 760, height: 420)
        w.setFrameAutosaveName("OptiStatsPreferences")
        w.center()
        tabs = tabVC
        sidebar = side
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
            self.sidebar = nil
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
        sidebar = nil
        onClose?()
    }
}

/// Lista lateral de abas (NSTableView em estilo "source list").
final class PrefsSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let items: [(title: String, symbol: String)]
    private let onSelect: (Int) -> Void
    private let table = NSTableView()
    private var initial: Int

    init(items: [(title: String, symbol: String)], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.items = items; self.onSelect = onSelect; self.initial = selected
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        select(initial)
    }

    func select(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [image, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0 { onSelect(row) }
    }
}
