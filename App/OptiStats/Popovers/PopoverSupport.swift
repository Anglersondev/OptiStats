import Cocoa
import OptiStatsCore

// Utilidades compartilhadas pelos popovers (formatação, pools de views, base com estado vazio, fábrica).

/// Formatação com o idioma escolhido no app (nunca usa zero fictício: indisponível vira "—").
enum Fmt {
    static let dash = "—"
    static var locale: Locale { Localizer.shared.locale }

    static func percent(_ fraction: Double?, decimals: Int = 0) -> String {
        guard let f = fraction, f.isFinite else { return dash }
        return ByteFormat.percent(f, decimals: decimals, locale: locale)
    }

    /// `value` já na escala de exibição (ex.: 85 para "85 %").
    static func number(_ value: Double?, decimals: Int, unit: String) -> String {
        guard let v = value, v.isFinite else { return dash }
        let n = ByteFormat.decimal(v, decimals: decimals, locale: locale)
        return unit.isEmpty ? n : n + " " + unit
    }

    static func bytes(_ b: UInt64?, style: ByteStyle = .binary) -> String {
        guard let b = b else { return dash }
        return ByteFormat.string(b, style: style, locale: locale)
    }

    /// Variação com sinal ("+1,2 GB" / "−300 MB").
    static func signedBytes(_ delta: Int64) -> String {
        let sign = delta < 0 ? "−" : "+"
        return sign + ByteFormat.string(delta.magnitude, style: .binary, locale: locale)
    }

    /// Taxa em bytes/s (base 1000) ou, com `bits`, em bits/s.
    static func rate(_ bytesPerSecond: Double?, bits: Bool = false) -> String {
        guard let v = bytesPerSecond, v.isFinite, v >= 0 else { return dash }
        if !bits { return ByteFormat.rate(v, style: .decimal, locale: locale) }
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var x = v * 8
        var i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1000; i += 1 }
        let decimals = i == 0 ? 0 : (x >= 100 ? 0 : (x >= 10 ? 1 : 2))
        return ByteFormat.decimal(x, decimals: decimals, locale: locale) + " " + units[i]
    }

    static func temperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        guard let c = celsius, c.isFinite else { return dash }
        switch unit {
        case .celsius: return ByteFormat.decimal(c, decimals: 1, locale: locale) + " °C"
        case .fahrenheit: return ByteFormat.decimal(c * 9 / 5 + 32, decimals: 1, locale: locale) + " °F"
        }
    }

    static func watts(_ w: Double?) -> String { number(w, decimals: 2, unit: "W") }

    static func duration(minutes: Int) -> String {
        guard minutes >= 0 else { return dash }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? String(format: "%ld h %02ld min", h, m) : String(format: "%ld min", m)
    }

    /// Série recente reduzida para desenho (valores já na escala armazenada).
    static func values(_ env: AppEnvironment, _ id: SeriesID, seconds: TimeInterval = 300, maxPoints: Int = 120) -> [Double] {
        env.store.series(id).downsampled(since: env.clock.now - seconds, maxPoints: maxPoints).map(\.v)
    }

    /// Nota explicativa de várias linhas (largura fixada para a quebra de linha funcionar).
    static func note(_ text: String = "", lines: Int = 4, size: CGFloat = 10.5) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.body(size), color: Theme.secondaryText, lines: lines)
        f.preferredMaxLayoutWidth = Theme.popoverWidth - 2 * Theme.padding
        return f
    }

    private static var iconCache: [String: NSImage] = [:]
    /// Ícone do .app (cache pequeno; somente main thread).
    static func appIcon(path: String?) -> NSImage? {
        guard let path = path else { return nil }
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 18, height: 18)
        if iconCache.count > 64 { iconCache.removeAll() }
        iconCache[path] = image
        return image
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    static func thermalText(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return L("thermal.nominal")
        case .fair: return L("thermal.fair")
        case .serious: return L("thermal.serious")
        case .critical: return L("thermal.critical")
        }
    }

    static func powerScopeName(_ scope: PowerScope) -> String {
        switch scope {
        case .systemTotal: return L("power.scope.systemTotal")
        case .dcIn: return L("power.scope.dcIn")
        case .battery: return L("power.scope.battery")
        case .cpu: return L("power.scope.cpu")
        case .gpu: return L("power.scope.gpu")
        case .ane: return L("power.scope.ane")
        case .dram: return L("power.scope.dram")
        case .pci: return L("power.scope.pci")
        case .display: return L("power.scope.display")
        case .other: return L("power.scope.other")
        }
    }

    /// Sufixo curto para leituras que não são medições diretas.
    static func qualitySuffix(_ q: MetricQuality) -> String {
        switch q {
        case .observed, .unavailable: return ""
        case .calculated: return " (" + L("quality.calculated") + ")"
        case .estimated: return " (" + L("quality.estimated") + ")"
        }
    }

    static func qualityName(_ q: MetricQuality) -> String {
        switch q {
        case .observed: return L("quality.observed")
        case .calculated: return L("quality.calculated")
        case .estimated: return L("quality.estimated")
        case .unavailable: return L("quality.unavailable")
        }
    }

    static func sourceName(_ s: SensorSource) -> String {
        switch s {
        case .smc: return "SMC"
        case .hid: return "HID"
        case .ioReport: return "IOReport"
        case .powerSources: return "Power Sources"
        case .ioRegistry: return "IORegistry"
        case .derived: return L("source.derived")
        }
    }
}

extension NSTextField {
    /// Atribui o texto somente se mudou (evita invalidar layout à toa).
    func setText(_ text: String) { if stringValue != text { stringValue = text } }
}

/// Seção com cabeçalho em caixa-alta e linhas em largura total.
func makeSection(_ title: String, _ views: [NSView]) -> NSStackView {
    let s = NSStackView.vertical(spacing: Theme.rowSpacing)
    s.addFullWidth(SectionHeaderView(title))
    for v in views { s.addFullWidth(v) }
    return s
}

/// Gauge à esquerda e linhas à direita.
func makeGaugeLayout(_ gauge: NSView, _ rows: [NSView]) -> NSStackView {
    let right = NSStackView.vertical(rows, spacing: 4)
    for r in rows {
        r.leadingAnchor.constraint(equalTo: right.leadingAnchor).isActive = true
        r.trailingAnchor.constraint(equalTo: right.trailingAnchor).isActive = true
    }
    right.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let h = NSStackView.horizontal([gauge, right], spacing: 14)
    h.distribution = .fill
    return h
}

/// Conjunto reutilizável de views numa pilha: cria sob demanda e esconde as sobras (sem recriar a cada render).
final class ViewPool<T: NSView> {
    let stack: NSStackView
    private let make: () -> T
    private(set) var views: [T] = []

    init(spacing: CGFloat = Theme.rowSpacing, make: @escaping () -> T) {
        self.stack = NSStackView.vertical(spacing: spacing)
        self.make = make
    }

    /// Garante `count` views visíveis e devolve exatamente essas.
    @discardableResult
    func show(_ count: Int) -> [T] {
        while views.count < count {
            let v = make()
            views.append(v)
            stack.addFullWidth(v)
        }
        for (i, v) in views.enumerated() { v.isHidden = i >= count }
        return Array(views.prefix(count))
    }
}

/// Uma barra vertical por CPU lógica (ordem do sistema; sem rótulos E/P).
final class CoreBarsView: NSView {
    var values: [Double] = [] {
        didSet {
            guard values != oldValue else { return }
            needsDisplay = true
            let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            setAccessibilityLabel(String(format: "%ld CPUs, %@", values.count, Fmt.percent(avg)))
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }

    override func draw(_ dirtyRect: NSRect) {
        let n = values.count
        guard n > 0 else { return }
        let gap: CGFloat = 2
        let width = max(2, (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, raw) in values.enumerated() {
            let v = raw.isFinite ? min(max(raw, 0), 1) : 0
            let x = CGFloat(i) * (width + gap)
            let track = NSRect(x: x, y: 0, width: width, height: bounds.height)
            Theme.track.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let fill = NSRect(x: x, y: 0, width: width, height: max(1, bounds.height * CGFloat(v)))
            Theme.usageColor(v).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// Base dos popovers de dados: corpo (`body`) e mensagem de estado vazio mutuamente exclusivos.
class StatPopover: ModulePopoverViewController {
    let body = NSStackView.vertical(spacing: Theme.sectionSpacing)
    private let emptyLabel = Fmt.note("", lines: 6, size: 12)

    final override func buildContent() {
        emptyLabel.isHidden = true
        content.addFullWidth(emptyLabel)
        content.addFullWidth(body)
        buildBody()
    }

    /// Cria a hierarquia estática dentro de `body`.
    func buildBody() {}

    /// `text != nil` mostra a mensagem no lugar do corpo; `nil` mostra o corpo.
    func showEmpty(_ text: String?) {
        if let t = text {
            emptyLabel.setText(t)
            emptyLabel.isHidden = false
            body.isHidden = true
        } else {
            emptyLabel.isHidden = true
            body.isHidden = false
        }
    }
}

/// Fábrica usada pela camada Shell: um popover por tipo de widget.
enum PopoverFactory {
    static func make(kind: WidgetKind, env: AppEnvironment) -> ModulePopoverViewController {
        switch kind {
        case .ram: return MemoryPopover(env: env)
        case .cpu, .coreGroups: return CPUPopover(env: env)
        case .gpu: return GPUPopover(env: env)
        case .temperature: return SensorsPopover(env: env)
        case .fan: return FansPopover(env: env)
        case .power: return PowerPopover(env: env)
        case .disk: return DiskPopover(env: env)
        case .network: return NetworkPopover(env: env)
        case .battery: return BatteryPopover(env: env)
        }
    }
}
