import Cocoa
import OptiStatsCore

/// Memória: uso, pressão, swap, composição, fórmulas, atividade, principais apps agrupados e gerenciador (otimizador seguro).
final class MemoryPopover: StatPopover {
    private let ring = RingGaugeView(size: 92)
    private let usedRow = KeyValueRowView(title: L("mem.used"))
    private let availableRow = KeyValueRowView(title: L("mem.available"))
    private let totalRow = KeyValueRowView(title: L("mem.total"))
    private let swapRow = KeyValueRowView(title: L("mem.swap"))
    private let pressureGauge = PressureGaugeView()
    private let compositionBar = SegmentedBarView(height: 10)
    private let appRow = KeyValueRowView(title: L("mem.app"), dotColor: NSColor.systemBlue)
    private let wiredRow = KeyValueRowView(title: L("mem.wired"), dotColor: NSColor.systemOrange)
    private let compressedRow = KeyValueRowView(title: L("mem.compressed"), dotColor: NSColor.systemPurple)
    private let cachedRow = KeyValueRowView(title: L("mem.cached"), dotColor: NSColor.systemTeal)
    private let freeRow = KeyValueRowView(title: L("mem.free"))
    private let altRow = KeyValueRowView(title: L("mem.altFormula"))
    private let swapInRow = KeyValueRowView(title: L("mem.swapIn"))
    private let swapOutRow = KeyValueRowView(title: L("mem.swapOut"))
    private let compressRow = KeyValueRowView(title: L("mem.compressions"))
    private let chart = LineChartView(height: 56)
    private let appPool = ViewPool<ProcessRowView> { ProcessRowView() }
    private let appNote = Fmt.note()
    private let allProcessesButton = NSButton(title: L("procs.open"), target: nil, action: nil)
    private lazy var optimizer = MemoryOptimizerPanel(env: env)
    private var chartSection: NSStackView!
    private var activitySection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "memory", title: L("ram.title"), collectors: [.memory, .processes], kinds: [.memory, .processes])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.memory?.timestamp }

    override func buildBody() {
        pressureGauge.labels = (L("mem.pressure.normal"), L("mem.pressure.attention"), L("mem.pressure.high"))
        body.addFullWidth(makeSection(L("mem.section.usage"), [makeGaugeLayout(ring, [usedRow, availableRow, totalRow, swapRow])]))
        body.addFullWidth(makeSection(L("mem.section.pressure"), [pressureGauge]))
        body.addFullWidth(makeSection(L("mem.section.composition"), [
            compositionBar, appRow, wiredRow, compressedRow, cachedRow, freeRow,
            Fmt.note(L("mem.formulaNote"), lines: 5, size: 10), altRow]))
        activitySection = makeSection(L("mem.section.activity"), [swapInRow, swapOutRow, compressRow])
        body.addFullWidth(activitySection)
        chartSection = makeSection(L("mem.section.history"), [chart])
        body.addFullWidth(chartSection)
        allProcessesButton.bezelStyle = .rounded
        allProcessesButton.controlSize = .small
        allProcessesButton.target = self
        allProcessesButton.action = #selector(openAllProcesses)
        body.addFullWidth(makeSection(L("mem.section.top"), [appPool.stack, appNote, allProcessesButton]))
        body.addFullWidth(makeSection(L("opt.section"), [optimizer]))
        chart.fixedRange = 0...100
        altRow.toolTip = L("mem.altFormulaTip")
        optimizer.onLayoutChange = { [weak self] in self?.updatePreferredSize() }
    }

    @objc private func openAllProcesses() { env.openProcessBrowser?() }

    override func render() {
        guard let m = env.store.memory else { showEmpty(L("mem.empty")); return }
        showEmpty(nil)
        let band = PressureBand(m.pressure)

        ring.fraction = m.usedFraction
        ring.color = band == .unknown ? Theme.usageColor(m.usedFraction) : Theme.pressureColor(band)
        ring.centerText = Fmt.percent(m.usedFraction)
        ring.subtitle = L("mem.used")
        ring.setAccessibilityLabel("\(L("mem.used")): \(Fmt.percent(m.usedFraction))")

        usedRow.value = Fmt.bytes(m.usedBytes)
        availableRow.value = Fmt.bytes(m.availableBytes)
        totalRow.value = Fmt.bytes(m.totalBytes)
        if let s = m.swap {
            swapRow.value = s.totalBytes > 0 ? L("mem.swapValue", Fmt.bytes(s.usedBytes), Fmt.bytes(s.totalBytes)) : Fmt.bytes(s.usedBytes)
        } else {
            swapRow.value = Fmt.dash
        }

        pressureGauge.band = band
        pressureGauge.setAccessibilityLabel(L("mem.section.pressure"))

        let total = Double(max(1, m.totalBytes))
        compositionBar.segments = [
            .init(fraction: Double(m.appBytes) / total, color: NSColor.systemBlue),
            .init(fraction: Double(m.wiredBytes) / total, color: NSColor.systemOrange),
            .init(fraction: Double(m.compressedBytes) / total, color: NSColor.systemPurple),
            .init(fraction: Double(m.cachedFilesBytes) / total, color: NSColor.systemTeal)
        ]
        appRow.value = Fmt.bytes(m.appBytes)
        wiredRow.value = Fmt.bytes(m.wiredBytes)
        compressedRow.value = Fmt.bytes(m.compressedBytes)
        cachedRow.value = Fmt.bytes(m.cachedFilesBytes)
        freeRow.value = Fmt.bytes(m.freeStrictBytes)
        altRow.value = Fmt.bytes(m.alternativeUsedBytes)

        // Taxas entre fotos recentes (contadores cumulativos → por segundo).
        let history = env.store.memoryHistory
        if history.count >= 2, let rates = MemoryRates.between(history[max(0, history.count - 3)], history[history.count - 1]) {
            swapInRow.value = Fmt.number(rates.swapInsPerSecond, decimals: 1, unit: L("mem.perSecond"))
            swapOutRow.value = Fmt.number(rates.swapOutsPerSecond, decimals: 1, unit: L("mem.perSecond"))
            compressRow.value = Fmt.number(rates.compressionsPerSecond, decimals: 1, unit: L("mem.perSecond"))
            activitySection.isHidden = false
        } else {
            activitySection.isHidden = true
        }

        let series = Fmt.values(env, .memoryUsed)
        chart.lines = [LineChartView.Line(values: series, color: Theme.accent)]
        chartSection.isHidden = series.count < 2

        renderTopApps()
    }

    private func renderTopApps() {
        guard let procs = env.store.processes else {
            appPool.show(0)
            appNote.setText(L("mem.top.waiting"))
            appNote.isHidden = false
            return
        }
        let prefs = env.preferences.current.memory
        let limit = min(15, max(3, prefs.processesShown))
        if prefs.groupByApp {
            let groups = Array(procs.byMemory.prefix(limit))
            let rows = appPool.show(groups.count)
            for (row, g) in zip(rows, groups) {
                let detail = g.processCount > 1 ? L("mem.top.processes", g.processCount) : nil
                row.configure(icon: Fmt.appIcon(path: g.bundlePath), name: g.displayName, detail: detail, value: Fmt.bytes(g.footprintBytes))
            }
            appNote.setText(groups.isEmpty ? L("mem.top.waiting") : L("mem.top.note"))
        } else {
            var flat: [ProcessSample] = []
            for g in procs.byMemory { flat.append(contentsOf: g.members) }
            flat.sort { ($0.footprintBytes ?? 0) > ($1.footprintBytes ?? 0) }
            let top = Array(flat.prefix(limit))
            let rows = appPool.show(top.count)
            for (row, p) in zip(rows, top) {
                row.configure(icon: nil, name: p.name, detail: nil, value: Fmt.bytes(p.footprintBytes))
            }
            appNote.setText(top.isEmpty ? L("mem.top.waiting") : L("mem.top.note"))
        }
        appNote.isHidden = false
        if procs.permissionLimited { appNote.setText(L("pop.permissionLimited")) }
    }
}
