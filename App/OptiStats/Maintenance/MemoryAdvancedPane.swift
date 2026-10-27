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

/// Aba "RAM avançada": diagnóstico (pressão real x cache cheio), apps agrupados com histórico em memória,
/// purge opcional (admin), modo foco e agentes de inicialização. Tudo somente leitura, salvo ações confirmadas.
/// Demanda de processos/memória só enquanto a aba está visível; sem timers próprios.
final class MemoryAdvancedPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.launch", qos: .utility)
    private static let purgeQueue = DispatchQueue(label: "dev.optistats.maintenance.purge", qos: .utility)
    private static let maxApps = 15
    private static let maxChildren = 8

    var onOpenOptimizer: (() -> Void)?
    private var items: [LaunchItem]?
    private var procToken: SubscriptionToken?
    private var memToken: SubscriptionToken?
    private var hadProcesses = false

    // Contêineres dinâmicos (recriados em build()).
    private var diagnosisBox = NSStackView.vertical(spacing: 4)
    private var appsBox = NSStackView.vertical(spacing: 4)
    private var chartBox = NSStackView.vertical(spacing: 4)
    private var agentsBox = NSStackView.vertical(spacing: 6)
    private var purgeResult = NSTextField.label("", font: Theme.body(11), color: Theme.secondaryText, lines: 0)
    private var purgeButton: NSButton?
    private var dynTargets: [ActionTarget] = []      // linhas de apps (recriadas a cada amostra)
    private var agentTargets: [ActionTarget] = []    // linhas de agentes

    private var selectedGroupID: String?
    private var expanded = Set<String>()
    private var purgeEnabled = false      // desligado por padrão; não persiste
    private var purgeRunning = false

    override var paneTitle: String { L("maint.tab.ram") }
    override var symbolName: String { "memorychip" }

    override func build() {
        diagnosisBox = NSStackView.vertical(spacing: 4)
        appsBox = NSStackView.vertical(spacing: 4)
        chartBox = NSStackView.vertical(spacing: 4)
        agentsBox = NSStackView.vertical(spacing: 6)
        purgeResult = NSTextField.label("", font: Theme.body(11), color: Theme.secondaryText, lines: 0)
        purgeResult.preferredMaxLayoutWidth = Self.contentSize.width - 70

        addSection(L("maint.ram.title"))
        addNote(L("maint.ram.honest"))
        let optimizer = button(L("maint.ram.openOptimizer")) { [weak self] in self?.onOpenOptimizer?() }
        let loginSettings = button(L("maint.ram.openLoginItems")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        let refresh = button(L("maint.ram.refresh")) { [weak self] in self?.reload() }
        let allProcs = button(L("procs.open")) { [weak self] in self?.env.openProcessBrowser?() }
        stack.addArrangedSubview(NSStackView.horizontal([optimizer, loginSettings, refresh, allProcs], spacing: 8))

        addSection(L("ram.diag.section"))
        stack.addFullWidth(diagnosisBox)

        addSection(L("ram.apps.section"))
        addNote(L("ram.apps.note"))
        stack.addFullWidth(appsBox)
        stack.addFullWidth(chartBox)

        addSection(L("ram.purge.section"))
        addNote(L("ram.purge.note"))
        let purge = button(L("ram.purge.button")) { [weak self] in self?.purgeTapped() }
        purge.isEnabled = purgeEnabled && SystemTool.purgeAvailable && !purgeRunning
        purgeButton = purge
        let enable = checkbox(L("ram.purge.enable"), isOn: purgeEnabled) { [weak self] on in
            guard let self else { return }
            self.purgeEnabled = on
            self.purgeButton?.isEnabled = on && SystemTool.purgeAvailable && !self.purgeRunning
        }
        stack.addArrangedSubview(NSStackView.horizontal([enable, purge], spacing: 12))
        if !SystemTool.purgeAvailable { addNote(L("ram.purge.unavailable")) }
        stack.addFullWidth(purgeResult)

        addSection(L("ram.focus.section"))
        addNote(L("ram.focus.note"))
        stack.addFullWidth(MemoryOptimizerPanel(env: env))

        addSection(L("maint.ram.agents"))
        addNote(L("maint.ram.agentsNote"))
        stack.addFullWidth(agentsBox)

        refreshDiagnosis()
        refreshApps()
        rebuildAgents()
    }

    // MARK: Utilidades de interface dinâmica

    private func clear(_ box: NSStackView) {
        for v in box.arrangedSubviews { box.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    private func dynButton(_ title: String, font: NSFont? = nil, bordered: Bool = true, agent: Bool = false,
                           _ handler: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.isBordered = bordered
        if let font { b.font = font }
        let t = ActionTarget { _ in handler() }
        if agent { agentTargets.append(t) } else { dynTargets.append(t) }
        b.target = t
        b.action = #selector(ActionTarget.fire(_:))
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func note(_ text: String, color: NSColor = Theme.secondaryText, size: CGFloat = 11) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.body(size), color: color, lines: 0)
        f.preferredMaxLayoutWidth = Self.contentSize.width - 70
        return f
    }

    private func metricRow(_ label: String, _ value: String) -> NSView {
        let l = NSTextField.label(label, font: Theme.body(11), color: Theme.secondaryText)
        return MaintUI.spread(l, [MaintUI.sizeLabel(value)])
    }

    // MARK: Diagnóstico

    private func bandName(_ b: PressureBand) -> String {
        switch b {
        case .normal: return L("ram.band.normal")
        case .attention: return L("ram.band.attention")
        case .high: return L("ram.band.high")
        case .unknown: return L("ram.band.unknown")
        }
    }

    private func reasonText(_ r: MemoryDiagnosisReason) -> String {
        switch r {
        case .kernelPressure(let b): return L("ram.reason.pressure", bandName(b))
        case .activeSwapOut(let v): return L("ram.reason.swapOut", Fmt.number(v, decimals: 0, unit: ""))
        case .activeSwapIn(let v): return L("ram.reason.swapIn", Fmt.number(v, decimals: 0, unit: ""))
        case .swapInUse(let b): return L("ram.reason.swapUsed", Fmt.bytes(b))
        case .heavyCompression(let b): return L("ram.reason.compression", Fmt.bytes(b))
        case .lowAvailable(let b): return L("ram.reason.lowAvail", Fmt.bytes(b))
        case .fileCacheLarge(let b): return L("ram.reason.cache", Fmt.bytes(b))
        }
    }

    private func refreshDiagnosis() {
        clear(diagnosisBox)
        guard let snap = env.store.memory else {
            diagnosisBox.addFullWidth(note(L("maint.ram.loading")))
            return
        }
        let history = env.store.memoryHistory
        let rates = history.count >= 2 ? MemoryRates.between(history[max(0, history.count - 3)], snap) : nil
        let d = MemoryDiagnosis.evaluate(snap, rates: rates)

        let key: String, color: NSColor
        switch d.verdict {
        case .healthy: key = "healthy"; color = Theme.good
        case .cacheFull: key = "cacheFull"; color = Theme.good
        case .watch: key = "watch"; color = Theme.warn
        case .realPressure: key = "realPressure"; color = Theme.bad
        case .insufficientData: key = "unknown"; color = Theme.secondaryText
        }
        diagnosisBox.addFullWidth(NSTextField.label(L("ram.diag.\(key).title"), font: Theme.title(13), color: color))
        diagnosisBox.addFullWidth(note(L("ram.diag.\(key).body")))
        for r in d.reasons { diagnosisBox.addFullWidth(note("• " + reasonText(r), size: 10.5)) }

        diagnosisBox.addFullWidth(metricRow(L("ram.m.pressure"), bandName(PressureBand(snap.pressure))))
        diagnosisBox.addFullWidth(metricRow(L("ram.m.available"), Fmt.bytes(snap.availableBytes)))
        diagnosisBox.addFullWidth(metricRow(L("ram.m.cache"), Fmt.bytes(snap.cachedFilesBytes)))
        diagnosisBox.addFullWidth(metricRow(L("ram.m.compressed"), Fmt.bytes(snap.compressedBytes)))
        if let ratio = d.compressionRatio {
            diagnosisBox.addFullWidth(metricRow(L("ram.m.ratio"), Fmt.number(ratio, decimals: 1, unit: "×")))
        }
        diagnosisBox.addFullWidth(metricRow(L("ram.m.swapUsed"), Fmt.bytes(snap.swap?.usedBytes)))
        if let rates {
            diagnosisBox.addFullWidth(metricRow(L("ram.m.swapIn"), Fmt.number(rates.swapInsPerSecond, decimals: 1, unit: "/s")))
            diagnosisBox.addFullWidth(metricRow(L("ram.m.swapOut"), Fmt.number(rates.swapOutsPerSecond, decimals: 1, unit: "/s")))
            diagnosisBox.addFullWidth(metricRow(L("ram.m.compressions"), Fmt.number(rates.compressionsPerSecond, decimals: 1, unit: "/s")))
        }
    }

    // MARK: Apps agrupados

    private func roleName(_ r: ProcessGrouper.ChildRole) -> String { L("ram.role.\(r.rawValue)") }

    /// Depois do clique atual: nunca destruir o botão (e seu alvo) que está disparando a ação.
    private func refreshAppsSoon() { DispatchQueue.main.async { [weak self] in self?.refreshApps() } }

    private func refreshApps() {
        clear(appsBox)
        dynTargets.removeAll()
        guard let snap = env.store.processes, !snap.byMemory.isEmpty else {
            appsBox.addFullWidth(note(L("ram.apps.empty")))
            refreshChart(nil)
            return
        }
        let groups = Array(snap.byMemory.prefix(Self.maxApps))
        if selectedGroupID == nil || !snap.byMemory.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id
        }
        for g in groups {
            appsBox.addFullWidth(groupRow(g))
            if expanded.contains(g.id), g.processCount > 1 {
                let kids = ProcessGrouper.heaviestMembers(of: g, limit: Self.maxChildren)
                for k in kids { appsBox.addFullWidth(childRow(k)) }
                appsBox.addFullWidth(note(L("ram.apps.children", kids.count), color: Theme.tertiaryText, size: 10))
            }
        }
        refreshChart(snap.byMemory.first { $0.id == selectedGroupID })
    }

    private func groupRow(_ g: AppGroup) -> NSView {
        let isSelected = g.id == selectedGroupID
        let lead: NSView
        if g.processCount > 1 {
            let open = expanded.contains(g.id)
            let d = dynButton(open ? "▾" : "▸", bordered: false) { [weak self] in
                guard let self else { return }
                if open { self.expanded.remove(g.id) } else { self.expanded.insert(g.id) }
                self.refreshAppsSoon()
            }
            lead = d
        } else {
            lead = NSView(); lead.translatesAutoresizingMaskIntoConstraints = false
        }
        lead.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let name = dynButton(g.displayName, font: .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
                             bordered: false) { [weak self] in
            self?.selectedGroupID = g.id
            self?.refreshAppsSoon()
        }
        var detail = [g.processCount > 1 ? L("ram.apps.processes", g.processCount) : ""]
        if env.growth.suspicion(for: g.id) != nil { detail.append("⚠ " + L("ram.apps.suspect")) }
        let sub = NSTextField.label(detail.filter { !$0.isEmpty }.joined(separator: " · "), font: Theme.body(10.5),
                                    color: env.growth.suspicion(for: g.id) != nil ? Theme.warn : Theme.secondaryText)
        let left = NSStackView.horizontal([lead, name, sub], spacing: 6)
        return MaintUI.spread(left, [MaintUI.sizeLabel(Fmt.bytes(g.footprintBytes))])
    }

    private func childRow(_ p: ProcessSample) -> NSView {
        let indent = NSView(); indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NSTextField.label(p.name, font: Theme.body(11), color: Theme.primaryText)
        let sub = NSTextField.label("\(roleName(ProcessGrouper.childRole(of: p))) · PID \(p.identity.pid)",
                                    font: Theme.body(10), color: Theme.secondaryText)
        let left = NSStackView.horizontal([indent, name, sub], spacing: 6)
        return MaintUI.spread(left, [MaintUI.sizeLabel(Fmt.bytes(p.footprintBytes))])
    }

    private func refreshChart(_ group: AppGroup?) {
        clear(chartBox)
        guard let g = group else { chartBox.addFullWidth(note(L("ram.chart.hint"))); return }
        chartBox.addFullWidth(NSTextField.label(L("ram.chart.title", g.displayName), font: Theme.caption(11),
                                                color: Theme.primaryText))
        let history = env.growth.history(for: g.id)
        if history.count >= 2 {
            let chart = LineChartView(height: 90)
            chart.fixedRange = nil
            chart.lines = [LineChartView.Line(values: history.map { Double($0.bytes) / 1_048_576 }, color: Theme.accent)]
            chartBox.addFullWidth(chart)
        } else {
            chartBox.addFullWidth(note(L("ram.chart.collecting")))
        }
        if let s = env.growth.suspicion(for: g.id) {
            let conf = s.confidence == .medium ? L("ram.conf.medium") : L("ram.conf.low")
            let rate = Fmt.bytes(UInt64(max(0, s.bytesPerMinute)))
            chartBox.addFullWidth(note(L("ram.growth.line", rate, Fmt.duration(minutes: max(1, Int(s.observedSeconds / 60))), conf),
                                       color: Theme.warn))
        } else {
            chartBox.addFullWidth(note(L("ram.growth.none"), color: Theme.tertiaryText, size: 10.5))
        }
    }

    // MARK: purge (admin, opcional)

    private func purgeTapped() {
        guard purgeEnabled, !purgeRunning, SystemTool.purgeAvailable else { return }
        MaintUI.confirm(window: view.window, title: L("ram.purge.confirmTitle"), text: L("ram.purge.confirmText"),
                        action: L("ram.purge.confirmOk")) { [weak self] ok in
            if ok { self?.runPurge() }
        }
    }

    private func runPurge() {
        purgeRunning = true
        purgeButton?.isEnabled = false
        purgeResult.stringValue = L("ram.purge.running")
        let probe = env.platform.memoryProbe
        Self.purgeQueue.async { [weak self] in
            let before = probe.captureMemory()
            let result = SystemTool.runPurgeAsAdmin()
            var after: MemorySnapshot?
            if result.status == 0 {
                Thread.sleep(forTimeInterval: 3)   // única espera, disparada pela pessoa; deixa o sistema assentar
                after = probe.captureMemory()
            }
            DispatchQueue.main.async { self?.finishPurge(result, before, after) }
        }
    }

    private func finishPurge(_ r: SystemTool.Result, _ before: MemorySnapshot?, _ after: MemorySnapshot?) {
        purgeRunning = false
        purgeButton?.isEnabled = purgeEnabled && SystemTool.purgeAvailable
        guard r.status == 0 else {
            purgeResult.stringValue = r.err.contains("-128") ? L("ram.purge.cancelled") : L("ram.purge.failed", r.status)
            return
        }
        let report = PurgeReport(before: before, after: after)
        var lines: [String] = []
        if let b = before, let a = after, let dA = report.availableDelta, let dC = report.cachedDelta {
            lines.append(L("ram.purge.available", Fmt.bytes(b.availableBytes), Fmt.bytes(a.availableBytes), Fmt.signedBytes(dA)))
            lines.append(L("ram.purge.cache", Fmt.bytes(b.cachedFilesBytes), Fmt.bytes(a.cachedFilesBytes), Fmt.signedBytes(dC)))
        }
        lines.append(L("ram.purge.reportNote"))
        purgeResult.stringValue = lines.joined(separator: "\n")
    }

    // MARK: Agentes de inicialização

    private func rebuildAgents() {
        clear(agentsBox)
        agentTargets.removeAll()
        guard let items else { agentsBox.addFullWidth(note(L("maint.ram.loading"))); return }
        if items.isEmpty { agentsBox.addFullWidth(note(L("maint.ram.none"))) }
        let snap = env.store.processes
        for scope in [LaunchItem.Scope.user, .global] {
            let list = items.filter { $0.scope == scope }
            guard !list.isEmpty else { continue }
            agentsBox.addFullWidth(note(scope == .user ? L("maint.ram.scopeUser") : L("maint.ram.scopeGlobal"),
                                        color: Theme.primaryText))
            for item in list { agentsBox.addFullWidth(row(item, snap)) }
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
        let finder = dynButton(L("maint.showInFinder"), agent: true) { MaintUI.revealInFinder(item.plistPath) }
        finder.controlSize = .small
        return MaintUI.spread(left, [value, finder])
    }

    private func reload() {
        Self.queue.async { [weak self] in
            let found = LaunchItemScanner.scan()
            DispatchQueue.main.async {
                self?.items = found
                self?.rebuildAgents()
            }
        }
    }

    // MARK: Ciclo de vida (demanda só com a aba visível)

    override func paneDidAppear() {
        env.setDemand(consumer: "maintenance.ram", collectors: [.processes, .memory], visibility: .popover)
        hadProcesses = env.store.processes != nil
        procToken = env.store.subscribe(.processes) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshApps()
                if !self.hadProcesses { self.hadProcesses = true; self.rebuildAgents() }
            }
        }
        memToken = env.store.subscribe(.memory) { [weak self] in
            DispatchQueue.main.async { self?.refreshDiagnosis() }
        }
        refreshDiagnosis()
        refreshApps()
        reload()
    }

    override func paneDidDisappear() {
        procToken?.cancel(); procToken = nil
        memToken?.cancel(); memToken = nil
        env.setDemand(consumer: "maintenance.ram", collectors: [.processes, .memory], visibility: nil)
    }
}
