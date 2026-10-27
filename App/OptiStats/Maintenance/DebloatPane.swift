import Cocoa
import OptiStatsCore

/// Aba "Debloat". Catálogo: mac-os-debloat de Oleksandr Krupko (MIT), embutido no app e atualizável manualmente.
/// Mostra o que existe neste Mac, agrupado por seção, com checkbox por item, presets e um botão "Aplicar (N)".
/// Usuário: `launchctl disable gui/<uid>/<label>`. Sistema: um único prompt de administrador. Antes de mudar
/// qualquer coisa grava um `DebloatSnapshot`; "Restaurar" reativa só o que o app mudou. Nada roda em segundo plano:
/// leitura do catálogo/launchctl só ao abrir a aba, em fila `.utility`.
final class DebloatPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.debloat", qos: .utility)

    private struct Target { let item: UpstreamItem; let domain: ServiceDomain }

    private let planner = DebloatPlanner(uid: UInt32(getuid()))

    // Dados (sempre acessados na main)
    private var catalog: UpstreamCatalog?
    private var source: DebloatCatalogSource = .embedded
    private var presence: [String: ServiceDomain] = [:]
    private var entries: [String: DebloatEntry] = [:]
    private var userTable: [String: Bool]?
    private var systemTable: [String: Bool]?
    private var loaded = false
    private var busy = false
    private var updating = false

    // Estado da interface
    private var selected = Set<String>()
    private var expanded = Set<String>()
    private var search = ""
    private var showAll = false
    private enum StateFilter: Int { case all, pending, done }
    private var stateFilter: StateFilter = .all
    private var allowSystem = false
    private var notice: String?
    private var lastShown = 0

    private weak var applyButton: NSButton?
    private weak var countLabel: NSTextField?
    private weak var listStack: NSStackView?
    private var buildTargets: [ActionTarget] = []
    private var listTargets: [ActionTarget] = []

    override var paneTitle: String { L("debloat.tab") }
    override var symbolName: String { "slider.horizontal.3" }

    private var level: DebloatPlanner.Level { allowSystem ? .system : .user }
    private var osMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    // MARK: Regras de seleção

    private func isSelectable(_ e: DebloatEntry) -> Bool {
        guard let d = e.domain, e.state == .enabled, let cat = catalog else { return false }
        if let sec = cat.sections.first(where: { $0.title == e.item.sectionTitle }), let min = sec.minMacOS, osMajor < min { return false }
        return planner.disableCommand(e.item, domain: d, in: cat, level: level) != nil
    }

    private func selectedTargets() -> [Target] {
        guard let cat = catalog else { return [] }
        return cat.items.compactMap { item in
            guard selected.contains(item.label), let e = entries[item.label], isSelectable(e), let d = e.domain else { return nil }
            return Target(item: item, domain: d)
        }
    }

    private func pruneSelection() {
        selected = selected.filter { l in entries[l].map { isSelectable($0) } ?? false }
    }

    // MARK: Interface

    private func ownTarget(_ handler: @escaping (NSControl) -> Void) -> ActionTarget {
        let t = ActionTarget(handler)
        buildTargets.append(t)
        return t
    }

    override func build() {
        buildTargets.removeAll()
        applyButton = nil; countLabel = nil; listStack = nil

        addSection(L("debloat.title"))
        addNote(L("debloat.intro"))
        addNote(L("debloat.timing"))
        addNote(L("debloat.credit"))
        if let n = notice { addNote(n, color: Theme.warn) }

        // Catálogo
        addSection(L("debloat.update.section"))
        if let cat = catalog {
            switch source {
            case .embedded: addNote(L("debloat.update.sourceEmbedded"))
            case .updated(let d): addNote(L("debloat.update.sourceUpdated", Self.dateText(d)))
            }
            addNote(L("debloat.update.count", cat.items.count, cat.sections.count))
        } else if loaded {
            addNote(L("debloat.catalogMissing"), color: Theme.bad)
        }
        let update = button(updating ? L("debloat.update.checking") : L("debloat.update.button")) { [weak self] in self?.updateFromGitHub() }
        update.isEnabled = !updating && !busy
        var isUpdated = false
        if case .updated = source { isUpdated = true }
        let reset = button(L("debloat.update.reset")) { [weak self] in self?.resetCatalog() }
        reset.isEnabled = isUpdated && !updating && !busy
        stack.addArrangedSubview(NSStackView.horizontal([update, reset], spacing: 8))
        addNote(L("debloat.update.network"))

        // Serviços
        addSection(L("debloat.title"))
        guard loaded else { addNote(L("debloat.loading")); return }
        guard catalog != nil else { return }

        let field = NSSearchField()
        field.placeholderString = L("debloat.search")
        field.stringValue = search
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let fieldTarget = ownTarget { [weak self] c in
            self?.search = (c as? NSTextField)?.stringValue ?? ""
            self?.refreshList()
        }
        field.target = fieldTarget; field.action = #selector(ActionTarget.fire(_:))
        stack.addArrangedSubview(field)

        stack.addArrangedSubview(checkbox(L("debloat.showAll"), isOn: showAll) { [weak self] on in
            self?.showAll = on
            self?.refreshList()
        })
        let presentEntries = entries.values.filter { $0.domain != nil }
        let doneCount = presentEntries.filter { $0.state == .disabled }.count
        let pendingCount = presentEntries.filter { $0.state == .enabled }.count
        addNote(L("debloat.summary", doneCount, pendingCount, presentEntries.count), color: doneCount > 0 ? Theme.good : Theme.secondaryText)
        let filterLabels = [L("debloat.filter.all"), L("debloat.filter.pending", pendingCount), L("debloat.filter.done", doneCount)]
        let filterPopup = popup(filterLabels, selected: stateFilter.rawValue) { [weak self] i in
            self?.stateFilter = StateFilter(rawValue: i) ?? .all
            self?.refreshList()
        }
        stack.addArrangedSubview(NSStackView.horizontal([NSTextField.label(L("debloat.filter.label"), font: Theme.body(11), color: Theme.secondaryText), filterPopup], spacing: 8))
        stack.addArrangedSubview(checkbox(L("debloat.allowSystem"), isOn: allowSystem) { [weak self] on in
            guard let self else { return }
            self.allowSystem = on
            self.pruneSelection()
            self.refreshList()
        })
        addNote(L("debloat.allowSystemNote"))

        let tel = button(L("debloat.presetTelemetry")) { [weak self] in self?.selectPreset(.telemetry) }
        let bal = button(L("debloat.presetBalanced")) { [weak self] in self?.selectPreset(.balanced) }
        let all = button(L("debloat.presetAll")) { [weak self] in self?.confirmPresetAll() }
        let clear = button(L("debloat.clear")) { [weak self] in self?.selected.removeAll(); self?.refreshList() }
        stack.addArrangedSubview(NSStackView.horizontal([tel, bal, all, clear], spacing: 8))

        let apply = button(L("debloat.apply", 0)) { [weak self] in self?.confirmApply() }
        apply.bezelColor = Theme.accent
        applyButton = apply
        let restore = button(L("debloat.restore")) { [weak self] in self?.confirmRestore() }
        restore.isEnabled = SnapshotStore.load()?.toRestore.isEmpty == false && !busy
        let reload = button(L("debloat.reload")) { [weak self] in self?.reload() }
        reload.isEnabled = !busy
        let count = NSTextField.label("", font: Theme.number(11), color: Theme.secondaryText)
        countLabel = count
        stack.addFullWidth(MaintUI.spread(NSStackView.horizontal([apply, restore, reload], spacing: 8), [count]))
        addNote(L("debloat.revertNote"))

        let list = NSStackView.vertical([], spacing: 4)
        listStack = list
        stack.addFullWidth(list)
        refreshList()
    }

    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: Lista

    private func matches(_ e: DebloatEntry, _ q: String) -> Bool {
        if q.isEmpty { return true }
        return e.item.label.lowercased().contains(q) || e.item.comment.lowercased().contains(q)
            || e.item.sectionTitle.lowercased().contains(q)
    }

    private func refreshList() {
        guard let list = listStack, let cat = catalog else { return }
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        listTargets.removeAll()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var shown = 0
        for sec in cat.sections {
            let rows = sec.items.compactMap { entries[$0.label] }.filter { (showAll || $0.domain != nil) && matches($0, q) && passesStateFilter($0) }
            if rows.isEmpty { continue }
            shown += rows.count
            let open = !q.isEmpty || expanded.contains(sec.title)
            addSectionHeader(list, sec, rows: rows, open: open)
            if open {
                if let hint = DebloatSections.hint(for: sec.title) {
                    let h = NSTextField.label(hint, font: Theme.body(11), color: Theme.secondaryText, lines: 0)
                    h.preferredMaxLayoutWidth = Self.contentSize.width - 90
                    list.addFullWidth(indent(h, 18))
                }
                if let min = sec.minMacOS, osMajor < min {
                    list.addFullWidth(indent(NSTextField.label(L("debloat.minMacOS", min), font: Theme.body(11), color: Theme.warn), 18))
                }
                for e in rows { addItemRow(list, e) }
            }
        }
        if shown == 0 { list.addFullWidth(NSTextField.label(L(q.isEmpty ? "debloat.empty" : "debloat.noMatch"), font: Theme.body(11), color: Theme.secondaryText, lines: 0)) }
        updateApply(shown: shown)
    }

    private func passesStateFilter(_ e: DebloatEntry) -> Bool {
        switch stateFilter {
        case .all: return true
        case .pending: return e.state == .enabled
        case .done: return e.state == .disabled
        }
    }

    /// Contagens só dos itens presentes neste Mac.
    private func stateCounts(_ rows: [DebloatEntry]) -> (done: Int, pending: Int) {
        let present = rows.filter { $0.domain != nil }
        return (present.filter { $0.state == .disabled }.count, present.filter { $0.state == .enabled }.count)
    }

    private func indent(_ v: NSView, _ left: CGFloat) -> NSStackView {
        let s = NSStackView.vertical([v], spacing: 0)
        s.edgeInsets = NSEdgeInsets(top: 0, left: left, bottom: 0, right: 0)
        return s
    }

    private func addSectionHeader(_ list: NSStackView, _ sec: UpstreamSection, rows: [DebloatEntry], open: Bool) {
        let nSel = rows.filter { selected.contains($0.item.label) }.count
        var title = (open ? "▾ " : "▸ ") + (sec.title.isEmpty ? "—" : sec.title) + "  (\(rows.count))"
        let c = stateCounts(rows)
        if c.done > 0 { title += "  ·  " + L("debloat.header.done", c.done) }
        if c.pending > 0 { title += "  ·  " + L("debloat.header.pending", c.pending) }
        if nSel > 0 { title += "  ·  " + L("debloat.selected", nSel) }
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.alignment = .left
        b.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        b.translatesAutoresizingMaskIntoConstraints = false
        let t = ActionTarget { [weak self] _ in
            guard let self else { return }
            if self.expanded.contains(sec.title) { self.expanded.remove(sec.title) } else { self.expanded.insert(sec.title) }
            self.refreshList()
        }
        listTargets.append(t)
        b.target = t; b.action = #selector(ActionTarget.fire(_:))
        list.addArrangedSubview(b)
    }

    private func addItemRow(_ list: NSStackView, _ e: DebloatEntry) {
        let item = e.item
        let box = NSButton(checkboxWithTitle: item.label, target: nil, action: nil)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.state = (selected.contains(item.label) || e.state == .disabled) ? .on : .off
        box.isEnabled = isSelectable(e)
        let t = ActionTarget { [weak self] c in
            guard let self else { return }
            if (c as? NSButton)?.state == .on { self.selected.insert(item.label) } else { self.selected.remove(item.label) }
            self.updateApply(shown: nil)
        }
        listTargets.append(t)
        box.target = t; box.action = #selector(ActionTarget.fire(_:))

        let stateText: String
        switch e.state {
        case .enabled: stateText = L("debloat.state.active")
        case .disabled: stateText = "✓ " + L("debloat.state.disabled")
        case .unknown: stateText = e.domain == nil ? L("debloat.state.absent") : "?"
        }
        var infoText = stateText + " · " + L("debloat.risk.\(item.risk.rawValue)")
        if e.domain == .system { infoText += " · " + L("debloat.scopeSystem") }
        let info = NSTextField.label(infoText, font: Theme.body(11),
                                     color: item.risk == .low ? Theme.secondaryText : Theme.warn, alignment: .right)
        info.setContentHuggingPriority(.required, for: .horizontal)

        var details: [NSView] = []
        func detail(_ text: String, _ color: NSColor = Theme.secondaryText) {
            let l = NSTextField.label(text, font: Theme.body(11), color: color, lines: 0)
            l.preferredMaxLayoutWidth = Self.contentSize.width - 90
            details.append(l)
        }
        if !item.comment.isEmpty { detail(L("debloat.authorSays") + " " + item.comment) }
        for w in item.warnings { detail("⚠︎ " + L("debloat.warn.\(w.rawValue)"), Theme.warn) }
        if item.sipOff { detail(L("debloat.sipOff"), Theme.tertiaryText) }
        if e.domain == .system, e.state == .enabled, !allowSystem { detail(L("debloat.needsSystem"), Theme.tertiaryText) }

        let row = NSStackView.vertical([MaintUI.spread(box, [info])], spacing: 1)
        row.alignment = .leading
        let det = NSStackView.vertical(details, spacing: 1)
        det.edgeInsets = NSEdgeInsets(top: 0, left: 36, bottom: 4, right: 0)
        list.addFullWidth(row)
        row.arrangedSubviews[0].leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        row.arrangedSubviews[0].trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        if !details.isEmpty { list.addFullWidth(det) }
    }

    private func updateApply(shown: Int?) {
        if let shown { lastShown = shown }
        let n = selectedTargets().count
        applyButton?.title = L("debloat.apply", n)
        applyButton?.isEnabled = n > 0 && !busy
        countLabel?.stringValue = L("debloat.selectedOf", n, lastShown)
    }

    // MARK: Presets

    private func selectPreset(_ preset: DebloatPreset) {
        guard let cat = catalog else { return }
        var skipped = 0, already = 0, absent = 0, toApply = 0
        let items = cat.presetItems(preset)
        for item in items {
            guard let e = entries[item.label], e.domain != nil else { absent += 1; continue }
            if e.state == .disabled { already += 1; continue }
            guard e.state == .enabled else { continue }
            if isSelectable(e) { selected.insert(item.label); toApply += 1 } else if e.domain == .system && !allowSystem { skipped += 1 }
        }
        var text = L("debloat.presetSummary", items.count, already, toApply, absent)
        if skipped > 0 { text += " " + L("debloat.presetSkipped", skipped) }
        notice = text
        rebuildSoon()
    }

    private func confirmPresetAll() {
        MaintUI.confirm(window: view.window, title: L("debloat.presetAllTitle"), text: L("debloat.presetAllText"),
                        action: L("debloat.presetAllAction")) { [weak self] ok in
            if ok { self?.selectPreset(.all) }
        }
    }

    // MARK: Leitura (só ao abrir a aba)

    override func paneDidAppear() { reload() }

    private func reload() {
        guard !busy else { return }
        let uid = planner.uid
        Self.queue.async { [weak self] in
            let loadedCatalog = DebloatCatalogStore.load()
            let presence = DebloatScanner.presence()
            let u = SystemTool.printDisabled(domain: "gui/\(uid)")
            let s = SystemTool.printDisabled(domain: "system")
            DispatchQueue.main.async {
                guard let self else { return }
                self.catalog = loadedCatalog?.catalog
                self.source = loadedCatalog?.source ?? .embedded
                self.presence = presence
                self.userTable = u; self.systemTable = s
                self.loaded = true
                self.recomputeEntries()
                self.rebuildSoon()
            }
        }
    }

    private func recomputeEntries() {
        if let cat = catalog {
            entries = DebloatScanner.entries(catalog: cat, presence: presence, user: userTable, system: systemTable)
        } else {
            entries = [:]
        }
        pruneSelection()
    }

    // MARK: Atualizar do GitHub (manual)

    private func updateFromGitHub() {
        guard !updating, !busy else { return }
        updating = true
        notice = nil
        rebuildSoon()
        DebloatDownload.start { [weak self] result in
            DispatchQueue.main.async { self?.handleDownload(result) }
        }
    }

    private func handleDownload(_ result: Result<Data, DebloatDownload.Failure>) {
        updating = false
        func fail(_ reason: String) {
            rebuildSoon()
            showError(L("debloat.update.failed", reason))
        }
        switch result {
        case .failure(let f):
            switch f {
            case .http: fail(L("debloat.update.err.http"))
            case .tooBig: fail(L("debloat.update.err.tooBig"))
            case .redirect: fail(L("debloat.update.err.redirect"))
            case .invalid: fail(L("debloat.update.err.invalid"))
            case .network(let m): fail(m)
            }
        case .success(let data):
            guard let script = String(data: data, encoding: .utf8),
                  let block = UpstreamCatalog.extractEmbeddedLabels(fromScript: script) else {
                fail(L("debloat.update.err.invalid")); return
            }
            let new = UpstreamCatalog.parse(block)
            let diff = catalog.map { UpstreamCatalog.diff(old: $0, new: new) } ?? CatalogDiff(added: new.items.map { $0.label }, removed: [])
            let text = diff.isEmpty ? L("debloat.update.diffNone") : L("debloat.update.diffText", diff.added.count, diff.removed.count)
            rebuildSoon()
            MaintUI.confirm(window: view.window, title: L("debloat.update.diffTitle"), text: text,
                            action: L("debloat.update.save")) { [weak self] ok in
                guard ok, let self else { return }
                do {
                    try DebloatCatalogStore.save(block: block)
                    self.notice = L("debloat.update.saved", diff.added.count, diff.removed.count)
                    self.reload()
                } catch {
                    self.showError(L("debloat.update.failed", L("debloat.update.err.saveFailed")))
                }
            }
        }
    }

    private func resetCatalog() {
        guard !busy, !updating else { return }
        DebloatCatalogStore.reset()
        notice = L("debloat.update.resetDone")
        reload()
    }

    // MARK: Aplicar

    private func confirmApply() {
        let targets = selectedTargets()
        guard !targets.isEmpty, !busy else { return }
        let nUser = targets.filter { $0.domain == .user }.count
        let nSys = targets.count - nUser
        let low = targets.filter { $0.item.risk == .low }.count
        let med = targets.filter { $0.item.risk == .medium }.count
        let high = targets.filter { $0.item.risk == .high }.count
        var text = L("debloat.confirmCounts", nUser, nSys) + "\n" + L("debloat.confirmRisks", low, med, high)
        var warned: [String] = []
        var seen = Set<DebloatWarning>()
        for t in targets { for w in t.item.warnings where !seen.contains(w) { seen.insert(w); warned.append("• " + L("debloat.warn.\(w.rawValue)")) } }
        if !warned.isEmpty { text += "\n\n" + L("debloat.confirmWarnings") + "\n" + warned.joined(separator: "\n") }
        let risky = targets.filter { $0.item.risk != .low }.prefix(8).map { "• " + $0.item.label }
        if !risky.isEmpty {
            text += "\n\n" + risky.joined(separator: "\n")
            if targets.filter({ $0.item.risk != .low }).count > risky.count {
                text += "\n" + L("debloat.confirmMore", targets.filter { $0.item.risk != .low }.count - risky.count)
            }
        }
        if nSys > 0 { text += "\n\n" + L("debloat.confirmAdmin") }
        text += "\n\n" + L("debloat.confirmRestoreHint") + "\n" + L("debloat.timing")
        MaintUI.confirm(window: view.window, title: L("debloat.confirmTitle", targets.count), text: text,
                        action: L("debloat.apply", targets.count)) { [weak self] ok in
            if ok { self?.apply(targets) }
        }
    }

    private func apply(_ targets: [Target]) {
        guard let cat = catalog else { return }
        busy = true
        rebuildSoon()
        let planner = self.planner, level = self.level
        let currentlyDisabled = entries.values.filter { $0.state == .disabled }.map { $0.item.label }
        Self.queue.async { [weak self] in
            // 1) snapshot ANTES de mudar qualquer coisa
            let old = SnapshotStore.load()
            let oldChanged = old?.changed ?? []
            let snap = DebloatSnapshot(
                date: Date(),
                previouslyDisabled: Array(Set((old?.previouslyDisabled ?? []) + currentlyDisabled.filter { !oldChanged.contains($0) })).sorted(),
                changed: Array(Set(oldChanged + targets.map { $0.item.label })).sorted())
            do { try SnapshotStore.save(snap) } catch {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.showError(L("debloat.snapshotFailed", String(describing: error)))
                    self?.rebuildSoon()
                }
                return
            }
            // 2) usuário: um comando por item
            var reasons: [String: String] = [:]
            for t in targets where t.domain == .user {
                guard let argv = planner.disableCommand(t.item, domain: .user, in: cat, level: level) else { continue }
                let r = SystemTool.run("/bin/launchctl", Array(argv.dropFirst()))
                if r.status != 0 { reasons[t.item.label] = r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            // 3) sistema: lote ÚNICO (um prompt de senha)
            let sysCmds = targets.filter { $0.domain == .system }
                .compactMap { planner.disableCommand($0.item, domain: .system, in: cat, level: level) }
            var sysError = ""
            if !sysCmds.isEmpty {
                let r = SystemTool.runAsAdmin(sysCmds)
                if r.status != 0 { sysError = r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            // 4) reler o estado e montar o relatório item a item
            let u = SystemTool.printDisabled(domain: "gui/\(planner.uid)")
            let s2 = SystemTool.printDisabled(domain: "system")
            var okLines: [String] = [], failLines: [String] = [], okCount = 0
            var notDone: [String] = []
            for t in targets {
                let table = (t.domain == .user ? u : s2) ?? [:]
                if table[t.item.label] == true {
                    okCount += 1
                    okLines.append("[\(L("debloat.reportOk"))] \(t.item.label)")
                } else {
                    notDone.append(t.item.label)
                    var why = reasons[t.item.label] ?? ""
                    if why.isEmpty { why = t.domain == .system ? (sysError.isEmpty ? L("debloat.reportNotApplied") : sysError) : "?" }
                    failLines.append("[\(L("debloat.reportFailed"))] \(t.item.label): \(why.components(separatedBy: "\n").first ?? why)")
                }
            }
            // 5) poda do snapshot: o que não mudou não deve ser "restaurado"
            var pruned = snap
            pruned.changed.removeAll { notDone.contains($0) && !oldChanged.contains($0) }
            if pruned.changed.isEmpty { SnapshotStore.delete() } else { try? SnapshotStore.save(pruned) }
            let lines = failLines + okLines   // falhas primeiro
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.userTable = u; self.systemTable = s2
                self.selected.removeAll()
                self.recomputeEntries()
                self.rebuildSoon()
                DebloatReport.show(window: self.view.window, title: L("debloat.reportTitle"),
                                   summary: L("debloat.reportSummary", okCount, targets.count) + "\n" + L("debloat.reportNote"),
                                   details: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: Restaurar

    private func confirmRestore() {
        guard let snap = SnapshotStore.load(), !busy else { return }
        let labels = snap.toRestore
        guard !labels.isEmpty else { return }
        let hasSystem = labels.contains { presence[$0] == .system }
        var text = L("debloat.restoreText") + "\n" + labels.prefix(20).map { "• " + $0 }.joined(separator: "\n")
        if labels.count > 20 { text += "\n" + L("debloat.confirmMore", labels.count - 20) }
        if hasSystem { text += "\n\n" + L("debloat.restoreAdmin") }
        MaintUI.confirm(window: view.window, title: L("debloat.restoreTitle"), text: text,
                        action: L("debloat.restore")) { [weak self] ok in
            if ok { self?.restore(snap) }
        }
    }

    private func restore(_ snap: DebloatSnapshot) {
        busy = true
        rebuildSoon()
        let planner = self.planner
        let presence = self.presence
        // Catálogo de consulta: o carregado + o embutido, para restaurar itens que uma atualização tenha removido.
        let lookup = UpstreamCatalog(sections: (catalog?.sections ?? []) + (DebloatCatalogStore.embedded()?.sections ?? []))
        Self.queue.async { [weak self] in
            var targets: [Target] = [], unknown = 0
            for label in snap.toRestore {
                if let item = lookup.item(label), let d = presence[label] { targets.append(Target(item: item, domain: d)) } else { unknown += 1 }
            }
            var errors: [String: String] = [:]
            for t in targets where t.domain == .user {
                guard let argv = planner.enableCommand(t.item, domain: .user, in: lookup, level: .system) else { continue }
                let r = SystemTool.run("/bin/launchctl", Array(argv.dropFirst()))
                if r.status != 0 { errors[t.item.label] = r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let sysCmds = targets.filter { $0.domain == .system }
                .compactMap { planner.enableCommand($0.item, domain: .system, in: lookup, level: .system) }
            if !sysCmds.isEmpty {
                let r = SystemTool.runAsAdmin(sysCmds)
                if r.status != 0 { for t in targets where t.domain == .system { errors[t.item.label] = r.err.trimmingCharacters(in: .whitespacesAndNewlines) } }
            }
            let u = SystemTool.printDisabled(domain: "gui/\(planner.uid)")
            let s2 = SystemTool.printDisabled(domain: "system")
            var restored: [String] = [], lines: [String] = []
            for t in targets {
                let table = (t.domain == .user ? u : s2) ?? [:]
                if table[t.item.label] != true {
                    restored.append(t.item.label)
                    lines.append("[\(L("debloat.reportOk"))] \(t.item.label)")
                } else {
                    let why = errors[t.item.label].flatMap { $0.isEmpty ? nil : $0 } ?? L("debloat.reportNotApplied")
                    lines.append("[\(L("debloat.reportFailed"))] \(t.item.label): \(why.components(separatedBy: "\n").first ?? why)")
                }
            }
            var rest = snap
            rest.changed.removeAll { restored.contains($0) }
            if rest.toRestore.isEmpty { SnapshotStore.delete() } else { try? SnapshotStore.save(rest) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.userTable = u; self.systemTable = s2
                self.recomputeEntries()
                self.rebuildSoon()
                var summary = L("debloat.restoreReport", restored.count, targets.count)
                if unknown > 0 { summary += "\n" + L("debloat.restoreUnknown", unknown) }
                DebloatReport.show(window: self.view.window, title: L("debloat.restoreTitle"), summary: summary,
                                   details: lines.joined(separator: "\n"))
            }
        }
    }
}
