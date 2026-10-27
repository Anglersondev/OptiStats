import Cocoa
import OptiStatsCore

/// Linha de sensor: favorito (estrela), nome, fonte/qualidade e valor.
final class SensorRowView: NSStackView {
    private let star = NSButton()
    private let nameLabel = NSTextField.label(font: Theme.body(12))
    private let tagLabel = NSTextField.label(font: Theme.body(9.5), color: Theme.tertiaryText)
    private let valueLabel = NSTextField.label(font: Theme.number(12, weight: .medium), alignment: .right)
    private(set) var sensorID = ""
    var onToggleFavorite: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        star.isBordered = false
        star.bezelStyle = .regularSquare
        star.imagePosition = .imageOnly
        star.translatesAutoresizingMaskIntoConstraints = false
        star.widthAnchor.constraint(equalToConstant: 16).isActive = true
        star.target = self
        star.action = #selector(starTapped)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [star, nameLabel, tagLabel, spacer, valueLabel] { addArrangedSubview(v) }
        setAccessibilityElement(true)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    @objc private func starTapped() { onToggleFavorite?(sensorID) }

    func configure(id: String, name: String, tag: String, value: String, tooltip: String, favorite: Bool) {
        sensorID = id
        nameLabel.setText(name)
        tagLabel.setText(tag)
        valueLabel.setText(value)
        toolTip = tooltip
        let symbol = favorite ? "star.fill" : "star"
        star.image = NSImage(systemSymbolName: symbol, accessibilityDescription: favorite ? L("sensors.unfavorite") : L("sensors.favorite"))
        star.contentTintColor = favorite ? Theme.warn : Theme.tertiaryText
        star.toolTip = favorite ? L("sensors.unfavorite") : L("sensors.favorite")
        setAccessibilityLabel("\(name), \(value)")
    }

    func update(value: String, tag: String, tooltip: String) {
        valueLabel.setText(value)
        tagLabel.setText(tag)
        if toolTip != tooltip { toolTip = tooltip }
        setAccessibilityLabel("\(nameLabel.stringValue), \(value)")
    }
}

/// Sensores por categoria, com favoritos. Mostra fonte e qualidade (observado / calculado / estimado).
/// As "temperaturas de núcleos" são zonas/termistores do inventário, não sensores de um núcleo físico.
final class SensorsPopover: StatPopover {
    private enum Category: Int, CaseIterable {
        case aggregate, cpu, gpu, soc, storage, battery, ambient, electrical, other
        var titleKey: String {
            switch self {
            case .aggregate: return "sensors.cat.aggregate"
            case .cpu: return "sensors.cat.cpu"
            case .gpu: return "sensors.cat.gpu"
            case .soc: return "sensors.cat.soc"
            case .storage: return "sensors.cat.storage"
            case .battery: return "sensors.cat.battery"
            case .ambient: return "sensors.cat.ambient"
            case .electrical: return "sensors.cat.electrical"
            case .other: return "sensors.cat.other"
            }
        }
    }

    private let listStack = NSStackView.vertical(spacing: 10)
    private let hiddenNote = Fmt.note(size: 10)
    private var rows: [SensorRowView] = []
    private var signature: [String] = []

    init(env: AppEnvironment) {
        super.init(env: env, moduleID: "sensors", title: L("sensors.title"), collectors: [.temperatures, .sensorList], kinds: [.sensors])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var lastDataTimestamp: TimeInterval? { env.store.sensors?.timestamp }

    override func buildBody() {
        body.addFullWidth(listStack)
        body.addFullWidth(Fmt.note(L("sensors.zoneNote"), lines: 4, size: 10))
        body.addFullWidth(hiddenNote)
    }

    private func category(of r: SensorReading) -> Category? {
        let d = r.descriptor
        if d.source == .derived { return .aggregate }
        switch d.kind {
        case .fan: return nil   // ventoinhas têm painel próprio
        case .voltage, .current, .power, .energy: return .electrical
        case .temperature:
            switch d.role {
            case .cpuEfficiencyZone, .cpuPerformanceZone, .cpuSuperZone: return .cpu
            case .gpuZone: return .gpu
            case .socZone, .memoryZone: return .soc
            case .storage: return .storage
            case .battery: return .battery
            case .ambient, .airflow, .wireless, .thunderbolt, .display: return .ambient
            case .dcIn, .rail, .systemTotal, .other: return .other
            }
        }
    }

    private func valueText(_ r: SensorReading, unit: TemperatureUnit) -> String {
        guard let v = r.value else { return Fmt.dash }
        switch r.descriptor.kind {
        case .temperature: return Fmt.temperature(v, unit: unit)
        case .voltage: return Fmt.number(v, decimals: 2, unit: "V")
        case .current: return Fmt.number(v, decimals: 2, unit: "A")
        case .power: return Fmt.number(v, decimals: 2, unit: "W")
        case .energy: return Fmt.number(v, decimals: 2, unit: "Wh")
        case .fan: return Fmt.number(v, decimals: 0, unit: "RPM")
        }
    }

    private func tagText(_ r: SensorReading) -> String {
        switch r.quality {
        case .observed: return Fmt.sourceName(r.descriptor.source)
        case .calculated: return L("quality.calculated")
        case .estimated: return L("quality.estimated")
        case .unavailable: return ""
        }
    }

    private func tooltip(_ r: SensorReading) -> String {
        var t = L("sensors.tooltip", r.descriptor.id, Fmt.qualityName(r.quality))
        if let n = r.note, !n.isEmpty { t += "\n" + n }
        return t
    }

    private func toggleFavorite(_ id: String) {
        env.preferences.update { p in
            if p.favoriteSensorIDs.contains(id) { p.favoriteSensorIDs.remove(id) } else { p.favoriteSensorIDs.insert(id) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.render()
            self?.updatePreferredSize()
        }
    }

    override func render() {
        guard let snap = env.store.sensors, !snap.readings.isEmpty || !snap.aggregates.isEmpty else {
            showEmpty(L("sensors.empty"))
            return
        }
        showEmpty(nil)
        let unit = env.preferences.current.temperatureUnit
        let favorites = env.preferences.current.favoriteSensorIDs

        // Agregados primeiro (rotulados como calculados), depois as leituras do inventário.
        var all: [SensorReading] = snap.aggregates
        let aggregateIDs = Set(all.map { $0.descriptor.id })
        all.append(contentsOf: snap.readings.filter { !aggregateIDs.contains($0.descriptor.id) })
        var byID: [String: SensorReading] = [:]
        for r in all where byID[r.descriptor.id] == nil { byID[r.descriptor.id] = r }

        var favoriteList: [SensorReading] = []
        var perCategory: [Category: [SensorReading]] = [:]
        var withoutReading = 0
        var seen = Set<String>()
        for r in all where seen.insert(r.descriptor.id).inserted {
            guard let cat = category(of: r) else { continue }
            if favorites.contains(r.descriptor.id) { favoriteList.append(r); continue }
            if r.value == nil { withoutReading += 1; continue }   // sem leitura válida: contado, não listado
            perCategory[cat, default: []].append(r)
        }
        favoriteList.sort { $0.descriptor.name < $1.descriptor.name }
        for key in perCategory.keys {
            perCategory[key]?.sort { $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending }
        }

        // Estrutura (quais linhas existem) só muda quando o conjunto muda; valores atualizam no lugar.
        var plan: [(title: String, items: [SensorReading], isFavorite: Bool)] = []
        if !favoriteList.isEmpty { plan.append((L("sensors.cat.favorites"), favoriteList, true)) }
        for cat in Category.allCases {
            if let items = perCategory[cat], !items.isEmpty { plan.append((L(cat.titleKey), items, false)) }
        }
        let newSignature = plan.flatMap { section in [section.title] + section.items.map { $0.descriptor.id } }
        if newSignature != signature {
            signature = newSignature
            rebuild(plan: plan, unit: unit)
        } else {
            for row in rows {
                guard let r = byID[row.sensorID] else { continue }
                row.update(value: valueText(r, unit: unit), tag: tagText(r), tooltip: tooltip(r))
            }
        }
        if withoutReading > 0 {
            hiddenNote.setText(L("sensors.withoutReading", withoutReading))
            hiddenNote.isHidden = false
        } else {
            hiddenNote.isHidden = true
        }
    }

    private func rebuild(plan: [(title: String, items: [SensorReading], isFavorite: Bool)], unit: TemperatureUnit) {
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rows = []
        for section in plan {
            var views: [NSView] = []
            for r in section.items {
                let row = SensorRowView()
                row.configure(id: r.descriptor.id, name: r.descriptor.name, tag: tagText(r), value: valueText(r, unit: unit),
                              tooltip: tooltip(r), favorite: section.isFavorite)
                row.onToggleFavorite = { [weak self] id in self?.toggleFavorite(id) }
                rows.append(row)
                views.append(row)
            }
            listStack.addFullWidth(makeSection(section.title, views))
        }
    }
}
