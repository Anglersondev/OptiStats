import Cocoa
import OptiStatsCore

/// Linha de uma ventoinha: nome, RPM, barra de faixa (só se mín./máx. forem conhecidos) e modo.
final class FanRowView: NSStackView {
    private let header = KeyValueRowView(title: "")
    private let bar = SegmentedBarView(height: 6)
    private let detail = NSTextField.label(font: Theme.body(10), color: Theme.secondaryText)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
        addFullWidth(header)
        addFullWidth(bar)
        addFullWidth(detail)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    func configure(name: String, rpmText: String, fraction: Double?, detailText: String) {
        header.title = name
        header.value = rpmText
        bar.isHidden = fraction == nil
        if let f = fraction { bar.segments = [.init(fraction: f, color: Theme.usageColor(f))] }
        detail.setText(detailText)
    }
}

/// Ventoinhas: SOMENTE leitura. Smart Boost permanece indisponível, com a explicação do motivo.
final class FansPopover: StatPopover {
    private let fanPool = ViewPool<FanRowView>(spacing: 10) { FanRowView() }
    private let chart = LineChartView(height: 56)
    private let boostCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let boostNote = Fmt.note(lines: 6)
    private var chartSection: NSStackView!
    private static let palette: [NSColor] = [NSColor.controlAccentColor, NSColor.systemTeal, NSColor.systemPurple, NSColor.systemOrange]

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "fans", title: L("fans.title"), collectors: [.fans], kinds: [.sensors])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.sensors?.fans.map(\.timestamp).max() }

    override func buildBody() {
        body.addFullWidth(makeSection(L("fans.section.fans"), [fanPool.stack]))
        chartSection = makeSection(L("fans.section.history"), [chart])
        body.addFullWidth(chartSection)
        boostCheckbox.title = L("fans.smartBoost")
        boostCheckbox.isEnabled = false
        boostCheckbox.state = .off
        boostCheckbox.translatesAutoresizingMaskIntoConstraints = false
        body.addFullWidth(makeSection(L("fans.section.control"), [boostCheckbox, boostNote]))
        chart.fixedRange = nil
    }

    private func modeText(_ m: FanMode) -> String {
        switch m {
        case .automatic: return L("fans.mode.automatic")
        case .manual: return L("fans.mode.manual")
        case .unknown: return L("fans.mode.unknown")
        }
    }

    private func boostExplanation() -> String {
        switch env.platform.fanActuator.capability {
        case .unavailable(let reason):
            return L("fans.boost.unavailable", reason) + "\n" + L("fans.boost.readOnly")
        case .experimentalUnvalidated:
            return L("fans.boost.unvalidated") + "\n" + L("fans.boost.readOnly")
        case .validated:
            return L("fans.boost.notEnabled") + "\n" + L("fans.boost.readOnly")
        }
    }

    override func render() {
        boostNote.setText(boostExplanation())
        let fans = env.store.sensors?.fans ?? []
        if fans.isEmpty {
            if env.system.fanCount == 0 {
                showEmpty(L("fans.none") + "\n\n" + boostExplanation())
            } else if env.store.sensors == nil {
                showEmpty(L("fans.empty"))
            } else {
                showEmpty(L("fans.noneReadable") + "\n\n" + boostExplanation())
            }
            return
        }
        showEmpty(nil)
        let rows = fanPool.show(fans.count)
        var lines: [LineChartView.Line] = []
        for (row, fan) in zip(rows, fans) {
            let name = fan.name ?? L("fans.fanN", fan.index + 1)
            let range: String
            if let lo = fan.minRPM, let hi = fan.maxRPM {
                range = L("fans.range", Fmt.number(lo, decimals: 0, unit: ""), Fmt.number(hi, decimals: 0, unit: "RPM"))
            } else {
                range = L("fans.rangeUnknown")
            }
            let percent = fan.percentOfRange.map { " · " + Fmt.percent($0) } ?? ""
            row.configure(name: name, rpmText: Fmt.number(fan.rpm, decimals: 0, unit: "RPM") + percent,
                          fraction: fan.percentOfRange, detailText: range + " · " + modeText(fan.mode))
            let values = Fmt.values(env, .fan(fan.index))
            if values.count >= 2 {
                lines.append(LineChartView.Line(values: values, color: Self.palette[lines.count % Self.palette.count], filled: false))
            }
        }
        chart.lines = lines
        chartSection.isHidden = lines.isEmpty
    }
}
