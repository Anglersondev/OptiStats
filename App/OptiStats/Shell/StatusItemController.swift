import Cocoa
import OptiStatsCore

/// Um NSStatusItem por indicador visível (ou um único item no modo compacto).
/// Eficiência: sem timers; assina o MetricsStore e só toca no botão quando o texto realmente muda.
final class StatusItemController: NSObject {
    private final class Entry {
        let signature: String
        let configs: [WidgetConfig]
        let item: NSStatusItem
        var lastTitle: String?
        var lastDetail: String?
        /// Layout empilhado: largura mínima já usada por coluna (só cresce, para o ícone não "pular") e faixas de clique.
        var columnWidths: [CGFloat] = []
        var columnRanges: [ClosedRange<CGFloat>] = []
        var imageWidth: CGFloat = 0
        /// Item com dois indicadores empilhados (um em cima do outro): sempre desenhado como imagem.
        var isPair: Bool { signature.hasPrefix("pair|") }
        init(signature: String, configs: [WidgetConfig], item: NSStatusItem) {
            self.signature = signature; self.configs = configs; self.item = item
        }
        var primaryKind: WidgetKind { configs.first?.kind ?? .ram }
    }

    private let env: AppEnvironment
    private var entries: [Entry] = []
    private var tokens: [SubscriptionToken] = []
    private var refreshScheduled = false
    private var host: PopoverHost?
    /// Painéis em fechamento: precisam viver até `popoverDidClose` para zerar a demanda.
    private var closing: [PopoverHost] = []
    private weak var hostEntry: Entry?
    private var lastPopoverClose: (entry: ObjectIdentifier, time: TimeInterval)?
    private var labels = MenuBarLabels()

    var onOpenPreferences: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onOpenMaintenance: (() -> Void)?

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    deinit {
        tokens.forEach { $0.cancel() }
        entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
    }

    // MARK: Reconstrução

    /// Chamado sempre que as preferências são aplicadas. Recria os itens só se a estrutura mudou.
    func preferencesDidChange() {
        labels = makeLabels()
        let prefs = env.preferences.current
        let desired = desiredEntries(prefs)
        let wanted = desired.map { $0.signature }
        let current = entries.map { $0.signature }
        if wanted != current {
            rebuild(desired)
        }
        refreshAll(force: true)
    }

    private func desiredEntries(_ prefs: Preferences) -> [(signature: String, configs: [WidgetConfig])] {
        let layout = prefs.menuBar.layout
        if prefs.menuBar.combined {
            let kinds = prefs.visibleKinds()
            guard !kinds.isEmpty else { return [] }
            let configs = kinds.map { WidgetConfig(kind: $0, enabled: true, label: prefs.menuBar.combinedLabel, decimals: 0) }
            return [(signature: "combined|\(layout.rawValue)|\(prefs.menuBar.combinedLabel.rawValue)|" + kinds.map { $0.rawValue }.joined(separator: ","), configs: configs)]
        }
        var out: [(signature: String, configs: [WidgetConfig])] = []
        var consumed = Set<WidgetKind>()
        let allowed: (WidgetKind) -> Bool = { prefs.monitoringMode == .full || $0.isEssential }
        for w in prefs.activeWidgets() where !consumed.contains(w.kind) {
            if let other = w.stackWith, other != w.kind, allowed(other), !consumed.contains(other) {
                consumed.insert(other)
                let second = prefs.menuBar.widgets.first { $0.kind == other }
                    ?? WidgetConfig(kind: other, enabled: true)
                let sig = "pair|\(w.kind.rawValue)|\(w.label.rawValue)|\(w.decimals)|\(w.content.rawValue)|\(other.rawValue)|\(second.label.rawValue)|\(second.decimals)|\(second.content.rawValue)"
                out.append((signature: sig, configs: [w, second]))
            } else {
                out.append((signature: "\(w.kind.rawValue)|\(layout.rawValue)|\(w.label.rawValue)|\(w.decimals)|\(w.content.rawValue)", configs: [w]))
            }
        }
        return out
    }

    private func rebuild(_ desired: [(signature: String, configs: [WidgetConfig])]) {
        closePopover()
        tokens.forEach { $0.cancel() }
        tokens = []
        entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
        entries = []

        // A ordem do array é a ordem de criação; o macOS decide a posição final.
        for d in desired {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let entry = Entry(signature: d.signature, configs: d.configs, item: item)
            if let button = item.button {
                button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                button.imagePosition = (env.preferences.current.menuBar.layout == .stacked || entry.isPair) ? .imageOnly : .imageLeft
                if env.preferences.current.menuBar.layout == .line, !entry.isPair, d.configs.count == 1, d.configs[0].label == .icon {
                    button.image = Self.symbol(for: d.configs[0].kind)
                }
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            entries.append(entry)
        }

        var metricKinds = Set<MetricKind>()
        for e in entries { for c in e.configs { metricKinds.insert(Self.metricKind(for: c.kind)) } }
        for mk in metricKinds {
            // O handler pode rodar em qualquer fila: volta para a main e coalesce.
            tokens.append(env.store.subscribe(mk) { [weak self] in self?.scheduleRefresh() })
        }
    }

    // MARK: Atualização

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshAll(force: false)
            }
        }
    }

    private func refreshAll(force: Bool) {
        let prefs = env.preferences.current
        for entry in entries { refresh(entry, prefs: prefs, force: force) }
    }

    private func refresh(_ entry: Entry, prefs: Preferences, force: Bool) {
        let texts = entry.configs.map {
            MenuBarFormatter.text(kind: $0.kind, config: $0, store: env.store, prefs: prefs,
                                  labels: labels, locale: Localizer.shared.locale)
        }
        // No modo ícone o rótulo é omitido pelo formatter; o título é só o valor.
        let stacked = prefs.menuBar.layout == .stacked || entry.isPair
        let title = texts.map { $0.display }.joined(separator: " ")
        let detail = texts.map { "\($0.detail): \($0.value)" }.joined(separator: ", ")
        guard let button = entry.item.button else { return }
        if force || entry.lastTitle != title {
            if stacked {
                button.title = ""
                button.image = Self.stackedImage(entry: entry, texts: texts)
            } else {
                button.title = title
            }
            entry.lastTitle = title
        }
        if force || entry.lastDetail != detail {
            button.toolTip = detail
            button.setAccessibilityLabel(detail)
            entry.lastDetail = detail
        }
    }

    // MARK: Cliques

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let entry = entries.first(where: { $0.item.button === sender }) else { return }
        let event = NSApp.currentEvent
        let isContext = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isContext {
            closePopover()
            showContextMenu(for: entry)
        } else {
            togglePopover(for: entry)
        }
    }

    private func togglePopover(for entry: Entry) {
        let id = ObjectIdentifier(entry)
        // O fechamento "transient" acontece no mouse-down; sem isto o mesmo clique reabriria o painel.
        if let last = lastPopoverClose, last.entry == id, ProcessInfo.processInfo.systemUptime - last.time < 0.25 {
            lastPopoverClose = nil
            return
        }
        if let host, host.isShown, hostEntry === entry {
            host.close()
            return
        }
        presentPopover(for: entry, kind: clickedKind(in: entry))
    }

    /// Em itens empilhados/combinados, o clique abre o painel da coluna sob o cursor (os outros ficam no seletor do painel).
    private func clickedKind(in entry: Entry) -> WidgetKind {
        guard entry.configs.count > 1, let button = entry.item.button, let event = NSApp.currentEvent else { return entry.primaryKind }
        if entry.isPair {   // metade de cima abre o primeiro painel, metade de baixo o segundo
            let y = button.convert(event.locationInWindow, from: nil).y
            return y >= button.bounds.midY ? entry.configs[0].kind : entry.configs[1].kind
        }
        let x = button.convert(event.locationInWindow, from: nil).x - max(0, (button.bounds.width - entry.imageWidth) / 2)
        if let i = entry.columnRanges.firstIndex(where: { $0.contains(x) }), i < entry.configs.count { return entry.configs[i].kind }
        return entry.primaryKind
    }

    /// Abre o painel do módulo `kind` (usa o item da barra que o mostra; senão o primeiro). Sem itens: nada.
    func openPopover(for kind: WidgetKind) {
        guard let entry = entries.first(where: { $0.configs.contains { $0.kind == kind } }) ?? entries.first else {
            NSSound.beep(); return
        }
        let shown = entry.configs.contains { $0.kind == kind } ? kind : entry.primaryKind
        presentPopover(for: entry, kind: shown)
    }

    private func presentPopover(for entry: Entry, kind: WidgetKind) {
        closePopover()
        guard let button = entry.item.button else { return }
        let newHost: PopoverHost
        if entry.configs.count > 1 {
            let panels = entry.configs.map { (title: PrefsText.kindName($0.kind), controller: PopoverRegistry.make($0.kind, env: env)) }
            let index = entry.configs.firstIndex { $0.kind == kind } ?? 0
            newHost = PopoverHost(combined: CombinedPopoverContainer(panels: panels, selected: index))
        } else {
            newHost = PopoverHost(controller: PopoverRegistry.make(kind, env: env))
        }
        newHost.onClose = { [weak self, weak entry, weak newHost] in
            guard let self else { return }
            if let entry { self.lastPopoverClose = (ObjectIdentifier(entry), ProcessInfo.processInfo.systemUptime) }
            self.closing.removeAll { $0 === newHost }
            if self.host === newHost { self.host = nil; self.hostEntry = nil }
        }
        host = newHost
        hostEntry = entry
        newHost.show(relativeTo: button)
    }

    private func closePopover() {
        guard let h = host else { return }
        host = nil
        hostEntry = nil
        closing.append(h)
        h.close()
    }

    private func showContextMenu(for entry: Entry) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add(L("shell.menu.refresh"), #selector(menuRefresh))
        menu.addItem(.separator())
        add(L("shell.menu.preferences"), #selector(menuPreferences), ",")
        add(L("shell.menu.maintenance"), #selector(menuMaintenance))
        add(L("shell.menu.about"), #selector(menuAbout))
        menu.addItem(.separator())
        add(L("shell.menu.quit"), #selector(menuQuit), "q")
        // Truque padrão: associa o menu só durante o clique, para que o clique esquerdo continue abrindo o painel.
        entry.item.menu = menu
        entry.item.button?.performClick(nil)
        entry.item.menu = nil
    }

    @objc private func menuRefresh() {
        let kinds = env.preferences.current.visibleKinds()
        var collectors: [CollectorID] = []
        for k in kinds { for c in k.collectors where !collectors.contains(c) { collectors.append(c) } }
        env.refreshNow(collectors)
    }
    @objc private func menuPreferences() { onOpenPreferences?() }
    @objc private func menuAbout() { onOpenAbout?() }
    @objc private func menuMaintenance() { onOpenMaintenance?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Desenho empilhado

    /// Duas linhas por coluna: rótulo pequeno em cima e valor embaixo (ou carga em cima e temperatura embaixo).
    /// Imagem template: segue claro/escuro. Redesenhada só quando o texto muda.
    private static func stackedImage(entry: Entry, texts: [MenuBarText]) -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let botFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let soloFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let gap: CGFloat = 7
        struct Col { var top: String?; var bottom: String }
        if entry.isPair, texts.count == 2 {
            return pairImage(entry: entry, top: texts[0].display, bottom: texts[1].display)
        }
        let cols: [Col] = texts.map { t in
            if let l = t.lines, l.count == 2 { return Col(top: l[0], bottom: l[1]) }
            return Col(top: t.label, bottom: t.value)
        }
        func width(_ s: String?, _ f: NSFont) -> CGFloat { s.map { ($0 as NSString).size(withAttributes: [.font: f]).width } ?? 0 }
        if entry.columnWidths.count != cols.count { entry.columnWidths = Array(repeating: 0, count: cols.count) }
        for (i, c) in cols.enumerated() {
            let w = c.top == nil ? width(c.bottom, soloFont) : max(width(c.top, topFont), width(c.bottom, botFont))
            entry.columnWidths[i] = max(entry.columnWidths[i], ceil(w))
        }
        let widths = entry.columnWidths
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, cols.count - 1))
        var ranges: [ClosedRange<CGFloat>] = []
        var x: CGFloat = 0
        for w in widths { ranges.append((x - gap / 2)...(x + w + gap / 2)); x += w + gap }
        entry.columnRanges = ranges
        entry.imageWidth = total
        let size = NSSize(width: max(1, total), height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (i, c) in cols.enumerated() {
                let w = widths[i]
                func draw(_ s: String, _ f: NSFont, y: CGFloat) {
                    let sw = (s as NSString).size(withAttributes: [.font: f]).width
                    (s as NSString).draw(at: NSPoint(x: x + (w - sw) / 2, y: y), withAttributes: [.font: f, .foregroundColor: NSColor.black])
                }
                if let top = c.top {
                    draw(top, topFont, y: 12)
                    draw(c.bottom, botFont, y: 0.5)
                } else {
                    draw(c.bottom, soloFont, y: 3)
                }
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Dois indicadores, um embaixo do outro, centralizados (ex.: temperatura em cima, ventoinha embaixo).
    private static func pairImage(entry: Entry, top: String, bottom: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        if entry.columnWidths.count != 1 { entry.columnWidths = [0] }
        entry.columnWidths[0] = max(entry.columnWidths[0], ceil(max(width(top), width(bottom))))
        let w = max(1, entry.columnWidths[0])
        entry.columnRanges = [0...w]
        entry.imageWidth = w
        let image = NSImage(size: NSSize(width: w, height: 22), flipped: false) { _ in
            for (s, y) in [(top, CGFloat(11.5)), (bottom, CGFloat(0.5))] {
                (s as NSString).draw(at: NSPoint(x: (w - width(s)) / 2, y: y),
                                     withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Mapeamentos

    private func makeLabels() -> MenuBarLabels {
        var l = MenuBarLabels()
        l.ram = L("shell.label.ram"); l.cpu = L("shell.label.cpu"); l.gpu = L("shell.label.gpu")
        l.temperature = L("shell.label.temperature"); l.fan = L("shell.label.fan"); l.power = L("shell.label.power")
        l.disk = L("shell.label.disk"); l.net = L("shell.label.network"); l.battery = L("shell.label.battery")
        l.systemTotal = L("shell.label.systemTotal"); l.batteryPower = L("shell.label.batteryPower")
        l.dcIn = L("shell.label.dcIn"); l.cpuPower = L("shell.label.cpuPower"); l.gpuPower = L("shell.label.gpuPower")
        l.efficiency = L("shell.label.efficiency"); l.performance = L("shell.label.performance")
        l.superCores = L("shell.label.superCores")
        return l
    }

    static func metricKind(for kind: WidgetKind) -> MetricKind {
        switch kind {
        case .ram: return .memory
        case .cpu, .coreGroups: return .cpu
        case .gpu: return .gpu
        case .temperature, .fan: return .sensors
        case .power: return .power
        case .disk: return .disk
        case .network: return .network
        case .battery: return .battery
        }
    }

    static func symbol(for kind: WidgetKind) -> NSImage? {
        let name: String
        switch kind {
        case .ram: name = "memorychip"
        case .cpu, .coreGroups: name = "cpu"
        case .gpu: name = "display"
        case .temperature: name = "thermometer"
        case .fan: name = "fanblades"
        case .power: name = "bolt"
        case .disk: name = "internaldrive"
        case .network: name = "network"
        case .battery: name = "battery.100"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: L("shell.kind.\(kind.rawValue)"))
        image?.isTemplate = true
        return image
    }
}
