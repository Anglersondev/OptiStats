import Cocoa
import OptiStatsCore

/// CPU: total, usuário/sistema/ocioso, carga média, grupos de núcleos (somente com topologia verificada),
/// uso por CPU lógica, gráfico e principais processos.
final class CPUPopover: StatPopover {
    private let ring = RingGaugeView(size: 92)
    private let userRow = KeyValueRowView(title: L("cpu.user"), dotColor: Theme.accent)
    private let systemRow = KeyValueRowView(title: L("cpu.system"), dotColor: Theme.warn)
    private let idleRow = KeyValueRowView(title: L("cpu.idle"))
    private let loadRow = KeyValueRowView(title: L("cpu.loadAverage"))
    private let thermalRow = KeyValueRowView(title: L("cpu.thermal"))
    private let chart = LineChartView(height: 56)
    private let clusterPool = ViewPool<KeyValueRowView> { KeyValueRowView(title: "") }
    private let topologyNote = Fmt.note()
    private let coreBars = CoreBarsView()
    private let processPool = ViewPool<ProcessRowView> { ProcessRowView() }
    private let processNote = Fmt.note()
    private var chartSection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "cpu", title: L("cpu.title"), collectors: [.cpu, .processes], kinds: [.cpu, .processes])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.cpu?.load.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("cpu.section.usage"), [makeGaugeLayout(ring, [userRow, systemRow, idleRow, loadRow, thermalRow])]))
        let loadNote = Fmt.note(L("cpu.loadAverageNote"), lines: 2, size: 10)
        body.addFullWidth(loadNote)
        chartSection = makeSection(L("cpu.section.history"), [chart])
        body.addFullWidth(chartSection)
        body.addFullWidth(makeSection(L("cpu.section.groups"), [clusterPool.stack, topologyNote]))
        body.addFullWidth(makeSection(L("cpu.section.perCore"), [coreBars, Fmt.note(L("cpu.perCoreNote"), lines: 3, size: 10)]))
        body.addFullWidth(makeSection(L("cpu.section.top"), [processPool.stack, processNote]))
        chart.fixedRange = 0...100
        chart.lines = []
        chart.toolTip = L("cpu.chartTip")
    }

    private func className(_ c: CoreClass) -> String {
        switch c.key {
        case "E": return L("cpu.class.efficiency")
        case "P", "M": return L("cpu.class.performance")
        case "S": return L("cpu.class.super")
        default: return c.name
        }
    }

    override func render() {
        guard let snap = env.store.cpu else { showEmpty(L("cpu.empty")); return }
        showEmpty(nil)
        let load = snap.load

        ring.fraction = load.total
        ring.color = Theme.usageColor(load.total)
        ring.centerText = Fmt.percent(load.total)
        ring.subtitle = L("cpu.total")
        ring.setAccessibilityLabel("\(L("cpu.total")): \(Fmt.percent(load.total))")

        userRow.value = Fmt.percent(load.user, decimals: 1)
        systemRow.value = Fmt.percent(load.system, decimals: 1)
        idleRow.value = Fmt.percent(load.idle, decimals: 1)
        if let la = snap.loadAverage {
            loadRow.value = [la.one, la.five, la.fifteen].map { ByteFormat.decimal($0, decimals: 2, locale: Fmt.locale) }.joined(separator: " · ")
        } else {
            loadRow.value = Fmt.dash
        }
        thermalRow.value = Fmt.thermalText(snap.thermal)
        thermalRow.valueColor = snap.thermal == .nominal ? Theme.primaryText : (snap.thermal == .fair ? Theme.warn : Theme.bad)

        let series = Fmt.values(env, .cpuTotal)
        chart.lines = [LineChartView.Line(values: series, color: Theme.accent)]
        chartSection.isHidden = series.count < 2

        // Grupos E/P: somente quando a topologia foi verificada (clusters vazio = não verificada).
        let rows = clusterPool.show(snap.clusters.count)
        for (row, c) in zip(rows, snap.clusters) {
            row.title = className(c.coreClass)
            row.value = L("cpu.clusterValue", Fmt.percent(c.usage), c.cpuCount)
            row.dotColor = Theme.usageColor(c.usage)
        }
        if snap.clusters.isEmpty {
            topologyNote.setText(L("cpu.topologyUnverified"))
            if let topo = env.system.topology, case .unverified(let reason) = topo.confidence { topologyNote.toolTip = reason }
            topologyNote.isHidden = false
        } else {
            topologyNote.isHidden = true
        }

        coreBars.values = load.perCore

        if let procs = env.store.processes {
            let top = Array(procs.byCPU.prefix(5))
            let prows = processPool.show(top.count)
            for (row, e) in zip(prows, top) {
                let detail = e.groupName == e.name || e.groupName.isEmpty ? nil : e.groupName
                row.configure(icon: nil, name: e.name, detail: detail,
                              value: Fmt.number(e.coresBusy * 100, decimals: 0, unit: "%"))
            }
            if top.isEmpty {
                processNote.setText(L("cpu.processes.waiting"))
                processNote.isHidden = false
            } else if procs.permissionLimited {
                processNote.setText(L("pop.permissionLimited"))
                processNote.isHidden = false
            } else {
                processNote.setText(L("cpu.processes.unit"))
                processNote.isHidden = false
            }
        } else {
            processPool.show(0)
            processNote.setText(L("cpu.processes.waiting"))
            processNote.isHidden = false
        }
    }
}
