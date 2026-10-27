import Cocoa
import OptiStatsCore

/// Rede: taxa total (somente interfaces físicas ativas), gráfico e interfaces. Respeita o filtro e "bits" das preferências.
final class NetworkPopover: StatPopover {
    private let downRow = KeyValueRowView(title: L("net.download"), dotColor: Theme.accent)
    private let upRow = KeyValueRowView(title: L("net.upload"), dotColor: Theme.warn)
    private let chart = LineChartView(height: 56)
    private let ifacePool = ViewPool<ProcessRowView> { ProcessRowView() }
    private let ifaceNote = Fmt.note()
    private var chartSection: NSStackView!

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "network", title: L("net.title"), collectors: [.network], kinds: [.network])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.network?.timestamp }

    override func buildBody() {
        body.addFullWidth(makeSection(L("net.section.total"), [downRow, upRow, Fmt.note(L("net.totalNote"), lines: 3, size: 10)]))
        chartSection = makeSection(L("net.section.history"), [chart])
        body.addFullWidth(chartSection)
        body.addFullWidth(makeSection(L("net.section.interfaces"), [ifacePool.stack, ifaceNote]))
        chart.fixedRange = nil
    }

    private func kindName(_ k: NetworkKind) -> String {
        switch k {
        case .wifi: return L("net.kind.wifi")
        case .ethernet: return L("net.kind.ethernet")
        case .cellular: return L("net.kind.cellular")
        case .vpn: return L("net.kind.vpn")
        case .bridge: return L("net.kind.bridge")
        case .other: return L("net.kind.other")
        }
    }

    private func kindIcon(_ k: NetworkKind) -> NSImage? {
        switch k {
        case .wifi: return Fmt.symbol("wifi")
        case .cellular: return Fmt.symbol("antenna.radiowaves.left.and.right")
        case .vpn: return Fmt.symbol("lock.shield")
        case .ethernet, .bridge, .other: return Fmt.symbol("network")
        }
    }

    override func render() {
        guard let snap = env.store.network else { showEmpty(L("net.empty")); return }
        showEmpty(nil)
        let prefs = env.preferences.current.network
        let bits = prefs.showBits

        downRow.value = Fmt.rate(snap.rxBytesPerSecond, bits: bits)
        upRow.value = Fmt.rate(snap.txBytesPerSecond, bits: bits)

        let rx = Fmt.values(env, .netRx), tx = Fmt.values(env, .netTx)
        chart.lines = [LineChartView.Line(values: rx, color: Theme.accent),
                       LineChartView.Line(values: tx, color: Theme.warn)]
        chartSection.isHidden = max(rx.count, tx.count) < 2

        var interfaces: [NetworkInterfaceRate]
        if let filter = prefs.interfaceFilter {
            interfaces = snap.interfaces.filter { $0.id == filter }
        } else {
            interfaces = snap.interfaces.filter { $0.isUp }
        }
        interfaces.sort {
            let a = ($0.rxBytesPerSecond ?? 0) + ($0.txBytesPerSecond ?? 0)
            let b = ($1.rxBytesPerSecond ?? 0) + ($1.txBytesPerSecond ?? 0)
            return a != b ? a > b : $0.id < $1.id
        }
        let rows = ifacePool.show(interfaces.count)
        for (row, i) in zip(rows, interfaces) {
            let value = "↓ " + Fmt.rate(i.rxBytesPerSecond, bits: bits) + "  ↑ " + Fmt.rate(i.txBytesPerSecond, bits: bits)
            let detail = L("net.session", kindName(i.kind), Fmt.bytes(i.totalRxBytes, style: .decimal), Fmt.bytes(i.totalTxBytes, style: .decimal))
            row.configure(icon: kindIcon(i.kind), name: i.id, detail: detail, value: value)
        }
        if interfaces.isEmpty {
            ifaceNote.setText(prefs.interfaceFilter == nil ? L("net.noInterfaces") : L("net.filterNoMatch"))
            ifaceNote.isHidden = false
        } else {
            ifaceNote.isHidden = true
        }
    }
}
