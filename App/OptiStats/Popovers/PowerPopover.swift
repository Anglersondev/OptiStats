import Cocoa
import OptiStatsCore

/// Energia: potências por escopo (sistema, DC, bateria, CPU, GPU…) com qualidade, e energia integrada com cobertura.
final class PowerPopover: StatPopover {
    private let readingPool = ViewPool<KeyValueRowView>(spacing: 4) { KeyValueRowView(title: "") }
    private let averageRow = KeyValueRowView(title: L("power.average"))
    private let energyRow = KeyValueRowView(title: L("power.energy"))
    private let coverageRow = KeyValueRowView(title: L("power.coverage"))
    private let chart = LineChartView(height: 56)
    private var chartSection: NSStackView!
    private var energySection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "power", title: L("power.title"), collectors: [.power], kinds: [.power])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.power?.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("power.section.readings"), [readingPool.stack, Fmt.note(L("power.scopeNote"), lines: 4, size: 10)]))
        chartSection = makeSection(L("power.section.history"), [chart])
        body.addFullWidth(chartSection)
        energySection = makeSection(L("power.section.energy"), [averageRow, energyRow, coverageRow, Fmt.note(L("power.energyNote"), lines: 4, size: 10)])
        body.addFullWidth(energySection)
        chart.fixedRange = nil
    }

    override func render() {
        guard let snap = env.store.power, snap.readings.contains(where: { $0.watts != nil }) else {
            showEmpty(L("power.empty"))
            return
        }
        showEmpty(nil)
        let rows = readingPool.show(snap.readings.count)
        for (row, r) in zip(rows, snap.readings) {
            row.title = r.name + Fmt.qualitySuffix(r.quality)
            row.value = Fmt.watts(r.watts)
            row.toolTip = L("power.tooltip", Fmt.powerScopeName(r.scope), Fmt.qualityName(r.quality), Fmt.sourceName(r.source))
        }

        let series = Fmt.values(env, .powerSystem)
        chart.lines = [LineChartView.Line(values: series, color: Theme.accent)]
        chartSection.isHidden = series.count < 2

        if let energy = snap.energy {
            let scope = snap.energyScope.map { Fmt.powerScopeName($0) } ?? ""
            energyRow.title = scope.isEmpty ? L("power.energy") : L("power.energyScoped", scope)
            energyRow.value = Fmt.number(energy.wattHours, decimals: 3, unit: "Wh")
            coverageRow.value = Fmt.percent(energy.coverage)
            averageRow.value = Fmt.watts(snap.movingAverageWatts)
            energySection.isHidden = false
        } else {
            energySection.isHidden = true
        }
    }
}
