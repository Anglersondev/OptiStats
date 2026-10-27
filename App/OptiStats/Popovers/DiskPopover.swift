import Cocoa
import OptiStatsCore

/// Volume: nome, livre/total (base 1000, como o Finder) e barra de uso.
final class VolumeRowView: NSStackView {
    private let header = KeyValueRowView(title: "")
    private let bar = SegmentedBarView(height: 8)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
        addFullWidth(header)
        addFullWidth(bar)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    func configure(_ v: VolumeInfo) {
        header.title = v.name
        header.value = L("disk.volume.free", Fmt.bytes(v.availableBytes, style: .decimal), Fmt.bytes(v.totalBytes, style: .decimal))
        bar.segments = [.init(fraction: v.usedFraction, color: Theme.usageColor(v.usedFraction))]
        bar.setAccessibilityLabel("\(v.name): \(Fmt.percent(v.usedFraction))")
        toolTip = v.id
    }
}

/// Disco: volumes e taxas de leitura/escrita (a primeira amostra só define a linha de base: "—").
final class DiskPopover: StatPopover {
    private let readRow = KeyValueRowView(title: L("disk.read"), dotColor: Theme.accent)
    private let writeRow = KeyValueRowView(title: L("disk.write"), dotColor: Theme.warn)
    private let chart = LineChartView(height: 56)
    private let volumePool = ViewPool<VolumeRowView>(spacing: 10) { VolumeRowView() }
    private var chartSection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "disk", title: L("disk.title"), collectors: [.disk], kinds: [.disk])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.disk?.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("disk.section.activity"), [readRow, writeRow]))
        chartSection = makeSection(L("disk.section.history"), [chart])
        body.addFullWidth(chartSection)
        body.addFullWidth(makeSection(L("disk.section.volumes"), [volumePool.stack]))
        chart.fixedRange = nil
    }

    override func render() {
        guard let snap = env.store.disk else { showEmpty(L("disk.empty")); return }
        if snap.volumes.isEmpty && snap.readBytesPerSecond == nil && snap.writeBytesPerSecond == nil {
            showEmpty(L("disk.empty"))
            return
        }
        showEmpty(nil)
        readRow.value = Fmt.rate(snap.readBytesPerSecond)
        writeRow.value = Fmt.rate(snap.writeBytesPerSecond)

        let read = Fmt.values(env, .diskRead), write = Fmt.values(env, .diskWrite)
        chart.lines = [LineChartView.Line(values: read, color: Theme.accent),
                       LineChartView.Line(values: write, color: Theme.warn)]
        chartSection.isHidden = max(read.count, write.count) < 2

        // Internos primeiro, depois removíveis/externos; ordem estável por nome.
        let volumes = snap.volumes.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let rows = volumePool.show(volumes.count)
        for (row, v) in zip(rows, volumes) { row.configure(v) }
    }
}
