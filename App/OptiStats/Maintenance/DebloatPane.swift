import Cocoa
import OptiStatsCore

/// Aba "Debloat": só serviços do catálogo do Core cujo estado é conhecido. Três níveis escolhidos pela pessoa:
/// somente auditoria (padrão), usuário (launchctl sem sudo) e sistema (opt-in; senha de administrador pelo prompt
/// padrão do macOS, sem helper e sem guardar senha). Antes de qualquer mudança grava um snapshot para "Restaurar".
final class DebloatPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.debloat", qos: .utility)
    private static let confirmWord = "CONFIRMAR"

    private let planner = DebloatPlanner(uid: UInt32(getuid()))
    private var level: DebloatPlanner.Level = .auditOnly
    private var acknowledged = false
    private var userTable: [String: Bool]?
    private var systemTable: [String: Bool]?
    private var loaded = false
    private var busy = false
    private var selected = Set<String>()

    private weak var applyButton: NSButton?

    override var paneTitle: String { L("maint.tab.debloat") }
    override var symbolName: String { "slider.horizontal.3" }

    // MARK: Estado

    private func table(for s: CatalogService) -> [String: Bool]? { s.domain == .user ? userTable : systemTable }

    private func state(_ s: CatalogService) -> ServiceState {
        guard let t = table(for: s) else { return .unknown }
        return planner.state(of: s.label, table: t)
    }

    private var knownServices: [CatalogService] { ServiceCatalog.all.filter { state($0) != .unknown } }

    private func canAct(on s: CatalogService) -> Bool {
        guard planner.disableCommand(s, level: level) != nil else { return false }
        return level != .system || acknowledged
    }

    // MARK: Interface

    override func build() {
        applyButton = nil
        addSection(L("maint.debloat.title"))
        addNote(L("maint.debloat.intro"))
        addNote(L("maint.debloat.timing"))

        let levelTitles = [L("maint.debloat.level.audit"), L("maint.debloat.level.user"), L("maint.debloat.level.system")]
        let order: [DebloatPlanner.Level] = [.auditOnly, .user, .system]
        let pop = popup(levelTitles, selected: order.firstIndex(of: level) ?? 0) { [weak self] i in
            guard let self else { return }
            self.level = order[min(max(i, 0), 2)]
            if self.level != .system { self.acknowledged = false }
            self.selected.removeAll()
            self.rebuildSoon()
        }
        addRow(L("maint.debloat.level"), pop)
        switch level {
        case .auditOnly: addNote(L("maint.debloat.level.auditNote"))
        case .user: addNote(L("maint.debloat.level.userNote"))
        case .system:
            addNote(L("maint.debloat.level.systemNote"), color: Theme.bad)
            stack.addArrangedSubview(checkbox(L("maint.debloat.ack"), isOn: acknowledged) { [weak self] on in
                self?.acknowledged = on
                self?.selected.removeAll()
                self?.rebuildSoon()
            })
        }

        addSection(L("maint.debloat.services"))
        if !loaded {
            addNote(L("maint.debloat.loading"))
        } else if knownServices.isEmpty {
            addNote(L("maint.debloat.none"))
        } else {
            for s in knownServices { addServiceRow(s) }
        }

        let apply = button(L("maint.debloat.apply")) { [weak self] in self?.confirmApply() }
        applyButton = apply
        let restore = button(L("maint.debloat.restore")) { [weak self] in self?.confirmRestore() }
        restore.isEnabled = SnapshotStore.load()?.toRestore.isEmpty == false && !busy
        let refresh = button(L("maint.debloat.refresh")) { [weak self] in self?.reload() }
        stack.addArrangedSubview(NSStackView.horizontal([apply, restore, refresh], spacing: 8))
        updateApply()
        addNote(L("maint.debloat.revertNote"))

        addSection(L("maint.debloat.terminal"))
        addNote(L("maint.debloat.terminalNote"))
        let text = terminalText()
        let code = NSTextField.label(text, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                     color: Theme.primaryText, lines: 0)
        code.isSelectable = true
        code.preferredMaxLayoutWidth = Self.contentSize.width - 70
        stack.addFullWidth(code)
        stack.addArrangedSubview(button(L("maint.debloat.copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        addNote(L("maint.debloat.reference"))
    }

    private func addServiceRow(_ s: CatalogService) {
        let title = L(s.titleKey)
        let st = state(s)
        let stateText = st == .disabled ? L("maint.debloat.state.disabled") : L("maint.debloat.state.enabled")
        let riskText = L("maint.debloat.risk.\(s.risk.rawValue)")
        let scopeText = s.domain == .system ? " · " + L("maint.debloat.scopeSystem") : ""
        let left: NSView
        if st == .enabled, canAct(on: s) {
            left = checkbox(title, isOn: selected.contains(s.label)) { [weak self] on in
                guard let self else { return }
                if on { self.selected.insert(s.label) } else { self.selected.remove(s.label) }
                self.updateApply()
            }
        } else {
            left = NSTextField.label(title)
        }
        left.toolTip = s.label
        let info = NSTextField.label("\(stateText) · \(riskText)\(scopeText)", font: Theme.body(11),
                                     color: s.risk == .low ? Theme.secondaryText : Theme.warn, alignment: .right)
        info.setContentHuggingPriority(.required, for: .horizontal)
        stack.addFullWidth(MaintUI.spread(left, [info]))
        if let key = s.warningKey { addNote("⚠︎ " + L(key), color: Theme.warn) }
    }

    private func updateApply() {
        applyButton?.isEnabled = !selected.isEmpty && !busy && level != .auditOnly
    }

    private func terminalText() -> String {
        let uid = planner.uid
        var lines = ["# " + L("maint.debloat.term.inspect"),
                     "launchctl print-disabled gui/\(uid)",
                     "launchctl print-disabled system", ""]
        let user = ServiceCatalog.all.filter { $0.domain == .user }
        let sys = ServiceCatalog.all.filter { $0.domain == .system }
        lines.append("# " + L("maint.debloat.term.user"))
        for s in user { lines.append("launchctl disable gui/\(uid)/\(s.label)") }
        if !sys.isEmpty {
            lines.append("")
            lines.append("# " + L("maint.debloat.term.system"))
            for s in sys { lines.append(planner.manualCommand(s, disable: true)) }
        }
        lines.append("")
        lines.append("# " + L("maint.debloat.term.undo"))
        for s in user { lines.append("launchctl enable gui/\(uid)/\(s.label)") }
        for s in sys { lines.append(planner.manualCommand(s, disable: false)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Leitura

    override func paneDidAppear() { reload() }

    private func reload() {
        let uid = planner.uid
        Self.queue.async { [weak self] in
            let u = SystemTool.printDisabled(domain: "gui/\(uid)")
            let s = SystemTool.printDisabled(domain: "system")
            DispatchQueue.main.async {
                guard let self else { return }
                self.userTable = u; self.systemTable = s
                self.loaded = true
                self.selected = self.selected.filter { l in
                    ServiceCatalog.service(l).map { self.state($0) == .enabled } ?? false
                }
                self.rebuildSoon()
            }
        }
    }

    // MARK: Aplicar

    private func selectedServices() -> [CatalogService] {
        ServiceCatalog.all.filter { selected.contains($0.label) && canAct(on: $0) && state($0) == .enabled }
    }

    private func confirmApply() {
        let sel = selectedServices()
        guard !sel.isEmpty, !busy else { return }
        let needsAdmin = sel.contains { $0.domain == .system }
        var text = L("maint.debloat.confirmText", sel.map { "• " + L($0.titleKey) }.joined(separator: "\n"))
        text += "\n\n" + L("maint.debloat.confirmTiming")
        var field: NSTextField?
        if needsAdmin {
            text += "\n\n" + L("maint.debloat.confirmAdmin", Self.confirmWord)
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            f.placeholderString = Self.confirmWord
            field = f
        }
        MaintUI.confirm(window: view.window, title: L("maint.debloat.confirmTitle"), text: text,
                        action: L("maint.debloat.apply"), accessory: field) { [weak self] ok in
            guard ok, let self else { return }
            if needsAdmin, field?.stringValue.trimmingCharacters(in: .whitespaces) != Self.confirmWord {
                self.showError(L("maint.debloat.confirmWordMismatch", Self.confirmWord))
                return
            }
            self.apply(sel)
        }
    }

    private func apply(_ sel: [CatalogService]) {
        busy = true
        rebuildSoon()
        let planner = self.planner
        let level = self.level
        let userT = userTable ?? [:], sysT = systemTable ?? [:]
        Self.queue.async { [weak self] in
            // 1) snapshot ANTES de mudar qualquer coisa
            let currentlyDisabled = ServiceCatalog.all.filter { s in
                (s.domain == .user ? userT : sysT)[s.label] == true
            }.map { $0.label }
            let old = SnapshotStore.load()
            let oldChanged = old?.changed ?? []
            let snap = DebloatSnapshot(
                date: Date(),
                previouslyDisabled: Array(Set((old?.previouslyDisabled ?? []) + currentlyDisabled.filter { !oldChanged.contains($0) })).sorted(),
                changed: Array(Set(oldChanged + sel.map { $0.label })).sorted())
            do { try SnapshotStore.save(snap) } catch {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.showError(L("maint.debloat.snapshotFailed", String(describing: error)))
                    self?.rebuildSoon()
                }
                return
            }
            // 2) executar
            var errors: [String] = []
            for s in sel where s.domain == .user {
                guard let argv = planner.disableCommand(s, level: level) else { continue }
                let r = SystemTool.run("/bin/launchctl", Array(argv.dropFirst()))
                if r.status != 0 { errors.append("\(s.label): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
            }
            let sysCmds = sel.filter { $0.domain == .system }.compactMap { planner.disableCommand($0, level: level) }
            if !sysCmds.isEmpty {
                let r = SystemTool.runAsAdmin(sysCmds)
                if r.status != 0 { errors.append(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            // 3) verificar e podar o snapshot do que não mudou
            let u = SystemTool.printDisabled(domain: "gui/\(planner.uid)")
            let s2 = SystemTool.printDisabled(domain: "system")
            var done: [String] = [], notDone: [String] = []
            for s in sel {
                let t = (s.domain == .user ? u : s2) ?? [:]
                if t[s.label] == true { done.append(s.label) } else { notDone.append(s.label) }
            }
            var pruned = snap
            pruned.changed.removeAll { notDone.contains($0) && !oldChanged.contains($0) }
            if pruned.changed.isEmpty { SnapshotStore.delete() } else { try? SnapshotStore.save(pruned) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.userTable = u; self.systemTable = s2
                self.selected.removeAll()
                var lines = [L("maint.debloat.reportApplied", done.count, sel.count)]
                if !errors.isEmpty { lines.append(L("maint.debloat.reportErrors")); lines += errors.prefix(4).map { "• " + $0 } }
                lines.append(""); lines.append(L("maint.debloat.reportNote"))
                MaintUI.inform(window: self.view.window, title: L("maint.debloat.reportTitle"), text: lines.joined(separator: "\n"))
                self.rebuildSoon()
            }
        }
    }

    // MARK: Restaurar

    private func confirmRestore() {
        guard let snap = SnapshotStore.load(), !busy else { return }
        let list = snap.toRestore.compactMap { ServiceCatalog.service($0) }
        guard !list.isEmpty else { return }
        var text = L("maint.debloat.restoreText", list.map { "• " + L($0.titleKey) }.joined(separator: "\n"))
        if list.contains(where: { $0.domain == .system }) { text += "\n\n" + L("maint.debloat.restoreAdmin") }
        MaintUI.confirm(window: view.window, title: L("maint.debloat.restoreTitle"), text: text,
                        action: L("maint.debloat.restore")) { [weak self] ok in
            if ok { self?.restore(snap, list) }
        }
    }

    private func restore(_ snap: DebloatSnapshot, _ list: [CatalogService]) {
        busy = true
        rebuildSoon()
        let planner = self.planner
        Self.queue.async { [weak self] in
            var errors: [String] = []
            for s in list where s.domain == .user {
                guard let argv = planner.enableCommand(s, level: .user) else { continue }
                let r = SystemTool.run("/bin/launchctl", Array(argv.dropFirst()))
                if r.status != 0 { errors.append("\(s.label): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
            }
            let sysCmds = list.filter { $0.domain == .system }.compactMap { planner.enableCommand($0, level: .system) }
            if !sysCmds.isEmpty {
                let r = SystemTool.runAsAdmin(sysCmds)
                if r.status != 0 { errors.append(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            let u = SystemTool.printDisabled(domain: "gui/\(planner.uid)")
            let s2 = SystemTool.printDisabled(domain: "system")
            var restored: [String] = []
            for s in list {
                let t = (s.domain == .user ? u : s2) ?? [:]
                if t[s.label] != true { restored.append(s.label) }
            }
            var rest = snap
            rest.changed.removeAll { restored.contains($0) }
            if rest.toRestore.isEmpty { SnapshotStore.delete() } else { try? SnapshotStore.save(rest) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.userTable = u; self.systemTable = s2
                var lines = [L("maint.debloat.reportRestored", restored.count, list.count)]
                if !errors.isEmpty { lines.append(L("maint.debloat.reportErrors")); lines += errors.prefix(4).map { "• " + $0 } }
                MaintUI.inform(window: self.view.window, title: L("maint.debloat.restoreTitle"), text: lines.joined(separator: "\n"))
                self.rebuildSoon()
            }
        }
    }
}
