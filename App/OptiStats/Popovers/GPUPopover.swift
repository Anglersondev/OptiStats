import Cocoa
import OptiStatsCore

/// GPU: utilização somente quando a fonte a expõe (nunca derivada de temperatura/potência).
final class GPUPopover: StatPopover {
    private let ring = RingGaugeView(size: 92)
    private let nameRow = KeyValueRowView(title: L("gpu.name"))
    private let coresRow = KeyValueRowView(title: L("gpu.cores"))
    private let rendererRow = KeyValueRowView(title: L("gpu.renderer"), dotColor: Theme.accent)
    private let tilerRow = KeyValueRowView(title: L("gpu.tiler"), dotColor: Theme.warn)
    private let chart = LineChartView(height: 56)
    private let noUtilNote = Fmt.note(L("gpu.noUtilization"))
    private var chartSection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "gpu", title: L("gpu.title"), collectors: [.gpu], kinds: [.gpu])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.gpu?.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("gpu.section.usage"), [makeGaugeLayout(ring, [nameRow, coresRow, rendererRow, tilerRow]), noUtilNote]))
        chartSection = makeSection(L("gpu.section.history"), [chart])
        body.addFullWidth(chartSection)
        chart.fixedRange = 0...100
    }

    override func render() {
        guard let snap = env.store.gpu else { showEmpty(L("gpu.empty")); return }
        showEmpty(nil)
        let util = snap.utilization
        ring.fraction = util ?? 0
        ring.color = util.map { Theme.usageColor($0) } ?? Theme.track
        ring.centerText = Fmt.percent(util)
        ring.subtitle = L("gpu.utilization")
        ring.setAccessibilityLabel("\(L("gpu.utilization")): \(Fmt.percent(util))")

        nameRow.value = snap.name ?? env.system.gpuName ?? Fmt.dash
        let cores = snap.coreCount ?? env.system.gpuCores
        coresRow.value = cores.map { String($0) } ?? Fmt.dash
        rendererRow.isHidden = snap.renderer == nil
        rendererRow.value = Fmt.percent(snap.renderer)
        tilerRow.isHidden = snap.tiler == nil
        tilerRow.value = Fmt.percent(snap.tiler)
        noUtilNote.isHidden = util != nil

        let series = Fmt.values(env, .gpuUtilization)
        chart.lines = [LineChartView.Line(values: series, color: Theme.accent)]
        chartSection.isHidden = series.count < 2
    }
}
