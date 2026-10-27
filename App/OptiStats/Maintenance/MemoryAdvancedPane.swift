import Cocoa
import OptiStatsCore

/// Um agente de inicialização (arquivo .plist de launchd). Somente leitura.
struct LaunchItem: Equatable {
    enum Scope { case user, global }
    let label: String
    let plistPath: String
    let programPath: String?
    let runAtLoad: Bool
    let disabledInPlist: Bool
    let scope: Scope
}

enum LaunchItemScanner {
    /// Lê ~/Library/LaunchAgents (da pessoa) e /Library/LaunchAgents (globais). Nunca escreve. Rodar fora da main.
    static func scan() -> [LaunchItem] {
        let dirs: [(String, LaunchItem.Scope)] = [(NSHomeDirectory() + "/Library/LaunchAgents", .user),
                                                  ("/Library/LaunchAgents", .global)]
        var out: [LaunchItem] = []
        let fm = FileManager()
        for (dir, scope) in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = dir + "/" + name
                guard let data = fm.contents(atPath: path),
                      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dict = obj as? [String: Any] else { continue }
                let label = (dict["Label"] as? String) ?? (name as NSString).deletingPathExtension
                var program = dict["Program"] as? String
                if program == nil, let args = dict["ProgramArguments"] as? [String] { program = args.first }
                out.append(LaunchItem(label: label, plistPath: path, programPath: program,
                                      runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false,
                                      disabledInPlist: (dict["Disabled"] as? Bool) ?? false, scope: scope))
            }
        }
        return out
    }

    /// Memória atual (footprint) dos processos que casam com o item; nil se nada casar.
    static func footprint(for item: LaunchItem, in snap: ProcessListSnapshot?) -> UInt64? {
        guard let snap else { return nil }
        let exe = item.programPath
        let bundle = ProcessGrouper.outermostAppBundlePath(from: exe)
        var total: UInt64 = 0
        var matched = false
        for group in snap.byMemory {
            if let b = bundle, group.bundlePath == b {
                total += group.footprintBytes; matched = true; continue
            }
            for m in group.members where (exe != nil && m.executablePath == exe) || m.bundleIdentifier == item.label {
                total += m.footprintBytes ?? 0; matched = true
            }
        }
        return matched ? total : nil
    }
}

/// Aba "RAM avançada": o macOS gerencia a RAM sozinho; aqui só se vê o que inicia sozinho (somente leitura).
final class MemoryAdvancedPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.launch", qos: .utility)

    var onOpenOptimizer: (() -> Void)?
    private var items: [LaunchItem]?
    private var token: SubscriptionToken?
    private var hadProcesses = false

    override var paneTitle: String { L("maint.tab.ram") }
    override var symbolName: String { "memorychip" }

    override func build() {
        addSection(L("maint.ram.title"))
        addNote(L("maint.ram.honest"))

        let optimizer = button(L("maint.ram.openOptimizer")) { [weak self] in self?.onOpenOptimizer?() }
        let loginSettings = button(L("maint.ram.openLoginItems")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        let refresh = button(L("maint.ram.refresh")) { [weak self] in self?.reload() }
        stack.addArrangedSubview(NSStackView.horizontal([optimizer, loginSettings, refresh], spacing: 8))

        addSection(L("maint.ram.agents"))
        addNote(L("maint.ram.agentsNote"))
        guard let items else { addNote(L("maint.ram.loading")); return }
        if items.isEmpty { addNote(L("maint.ram.none")) }
        let snap = env.store.processes
        for scope in [LaunchItem.Scope.user, .global] {
            let list = items.filter { $0.scope == scope }
            guard !list.isEmpty else { continue }
            addNote(scope == .user ? L("maint.ram.scopeUser") : L("maint.ram.scopeGlobal"), color: Theme.primaryText)
            for item in list { stack.addFullWidth(row(item, snap)) }
        }
    }

    private func row(_ item: LaunchItem, _ snap: ProcessListSnapshot?) -> NSView {
        let title = NSTextField.label(item.label, font: Theme.body(), color: Theme.primaryText)
        title.toolTip = item.plistPath
        var detail: [String] = []
        if item.runAtLoad { detail.append(L("maint.ram.runAtLoad")) }
        if item.disabledInPlist { detail.append(L("maint.ram.disabledFlag")) }
        let sub = NSTextField.label(detail.joined(separator: " · "), font: Theme.body(10.5), color: Theme.secondaryText)
        let left = NSStackView.vertical([title, sub], spacing: 1)
        let mem = LaunchItemScanner.footprint(for: item, in: snap)
        let value = MaintUI.sizeLabel(mem.map { Fmt.bytes($0) } ?? Fmt.dash)
        value.toolTip = mem == nil ? L("maint.ram.notRunning") : nil
        let finder = button(L("maint.showInFinder")) { MaintUI.revealInFinder(item.plistPath) }
        finder.controlSize = .small
        return MaintUI.spread(left, [value, finder])
    }

    private func reload() {
        Self.queue.async { [weak self] in
            let found = LaunchItemScanner.scan()
            DispatchQueue.main.async {
                self?.items = found
                self?.rebuildSoon()
            }
        }
    }

    override func paneDidAppear() {
        env.setDemand(consumer: "maintenance.ram", collectors: [.processes], visibility: .popover)
        hadProcesses = env.store.processes != nil
        token = env.store.subscribe(.processes) { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.hadProcesses else { return }
                self.hadProcesses = true
                self.rebuildSoon()
            }
        }
        reload()
    }

    override func paneDidDisappear() {
        token?.cancel(); token = nil
        env.setDemand(consumer: "maintenance.ram", collectors: [.processes], visibility: nil)
    }
}
