import Cocoa
import OptiStatsCore

/// Linha de uma ventoinha: nome, RPM, barra de faixa (só se mín./máx. forem conhecidos) e modo.
final class FanRowView: NSStackView {
    private let header = KeyValueRowView(title: "")
    private let bar = SegmentedBarView(height: 6)
    private let detail = NSTextField.label(font: Theme.body(10), color: Theme.secondaryText)
    private let mode = NSSegmentedControl(labels: [L("fan.mode.automatic"), L("fan.mode.manual")], trackingMode: .selectOne, target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sliderValue = NSTextField.label(font: Theme.number(10), color: Theme.secondaryText)
    private lazy var controls: NSStackView = {
        let s = NSStackView.vertical([mode, NSStackView.horizontal([slider, sliderValue], spacing: 8)], spacing: 4)
        s.alignment = .leading
        return s
    }()
    private var fanIndex = 0
    /// (ventoinha, rpm?) — rpm nil = voltar ao automático.
    var onControl: ((Int, Double?) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
        addFullWidth(header)
        addFullWidth(bar)
        addFullWidth(detail)
        mode.target = self; mode.action = #selector(modeChanged)
        slider.target = self; slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        addFullWidth(controls)
        controls.isHidden = true
    }

    @objc private func modeChanged() {
        if mode.selectedSegment == 0 { onControl?(fanIndex, nil) } else { onControl?(fanIndex, slider.doubleValue.rounded()) }
    }

    @objc private func sliderMoved() {
        sliderValue.stringValue = "\(Int(slider.doubleValue.rounded())) RPM"
        // Envia ao soltar (ou por teclado), nunca a cada pixel arrastado; só se estiver em Manual.
        let type = NSApp.currentEvent?.type
        if mode.selectedSegment == 1, type != .leftMouseDragged, type != .leftMouseDown { onControl?(fanIndex, slider.doubleValue.rounded()) }
    }

    /// Controle Automático/Manual (só quando o controle está liberado e validado neste Mac).
    func configureControl(fan: FanReading, available: Bool, manualRPM: Double?) {
        fanIndex = fan.index
        guard available, let lo = fan.minRPM, let hi = fan.maxRPM, hi > lo else { controls.isHidden = true; return }
        controls.isHidden = false
        slider.minValue = lo.rounded(.up); slider.maxValue = hi.rounded(.down)
        let tracking = NSApp.currentEvent?.type == .leftMouseDragged
        mode.selectedSegment = manualRPM == nil ? 0 : 1
        slider.isEnabled = manualRPM != nil
        if !tracking {
            slider.doubleValue = manualRPM ?? min(max(fan.rpm ?? lo, lo), hi)
            sliderValue.stringValue = manualRPM.map { "\(Int($0)) RPM" } ?? "—"
        }
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
            let settings = env.fanControl.settings
            var validated = false
            if case .validated = env.platform.fanActuator.capability { validated = true }
            let available = validated && (settings?.manualAllowed ?? false) && !(settings?.smartBoostEnabled ?? false)
                && !(settings?.isUnsupportedForThisMac ?? true) && !env.fanControl.busy
            row.configureControl(fan: fan, available: available, manualRPM: env.fanControl.manualTargets[fan.index])
            row.onControl = { [weak self] index, rpm in
                guard let self else { return }
                if let rpm { self.env.fanControl.setManual(fan: index, rpm: rpm) { [weak self] _ in self?.render() } }
                else { self.env.fanControl.restoreAutomatic { [weak self] _ in self?.render() } }
            }
            let values = Fmt.values(env, .fan(fan.index))
            if values.count >= 2 {
                lines.append(LineChartView.Line(values: values, color: Self.palette[lines.count % Self.palette.count], filled: false))
            }
        }
        chart.lines = lines
        chartSection.isHidden = lines.isEmpty
    }
}
