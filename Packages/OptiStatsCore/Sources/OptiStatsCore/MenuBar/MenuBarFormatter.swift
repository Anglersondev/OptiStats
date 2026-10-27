import Foundation

/// Rótulos curtos usados nos indicadores (a interface passa as versões localizadas).
public struct MenuBarLabels: Equatable {
    public var ram = "RAM", cpu = "CPU", gpu = "GPU", temperature = "T", fan = "FAN", power = "W"
    public var disk = "DISK", net = "NET", battery = "BAT"
    public var systemTotal = "SYS", batteryPower = "BAT", dcIn = "DC", cpuPower = "CPU", gpuPower = "GPU"
    public var efficiency = "E", performance = "P", superCores = "S"
    public init() {}
}

public struct MenuBarText: Equatable {
    /// Rótulo curto (nil quando o estilo é `.none`/ícone).
    public var label: String?
    public var value: String
    public var isAvailable: Bool
    /// Texto longo para tooltip e VoiceOver (explica o escopo da medida).
    public var detail: String
    /// Preenchido só quando o item mostra carga E temperatura: [carga, temperatura] (para o desenho empilhado).
    public var lines: [String]? = nil
    public var display: String { [label, value].compactMap { $0 }.joined(separator: " ") }
}

/// Converte o estado do `MetricsStore` no texto de cada indicador. Lógica pura: sem AppKit.
/// Regras: leitura ausente vira "—" (nunca zero); unidades e escopo sempre explícitos.
public enum MenuBarFormatter {
    public static let unavailable = "—"

    public static func text(kind: WidgetKind, config: WidgetConfig, store: MetricsStore, prefs: Preferences,
                            labels: MenuBarLabels = MenuBarLabels(), locale: Locale = .current) -> MenuBarText {
        func lab(_ s: String) -> String? { config.label == .short ? s : nil }
        func make(_ short: String, _ value: String?, _ detail: String) -> MenuBarText {
            MenuBarText(label: lab(short), value: value ?? unavailable, isAvailable: value != nil, detail: detail)
        }
        let d = config.decimals

        switch kind {
        case .ram:
            let v = store.memory.map { ByteFormat.percent($0.usedFraction, decimals: d, locale: locale) }
            return make(labels.ram, v, "RAM")
        case .cpu:
            let v = store.cpu.map { ByteFormat.percent($0.load.total, decimals: d, locale: locale) }
            return withTemperature(make(labels.cpu, v, "CPU"), config: config, source: .cpuAverage, store: store, prefs: prefs, locale: locale)
        case .gpu:
            let v = store.gpu?.utilization.map { ByteFormat.percent($0, decimals: d, locale: locale) }
            return withTemperature(make(labels.gpu, v, "GPU"), config: config, source: .gpuAverage, store: store, prefs: prefs, locale: locale)
        case .temperature:
            let (value, name) = temperature(prefs.menuBar.temperatureSource, store: store)
            let text = value.map { formatTemperature($0, unit: prefs.temperatureUnit, decimals: d, locale: locale) }
            return make(labels.temperature, text, name)
        case .fan:
            let rpms = (store.sensors?.fans ?? []).compactMap(\.rpm)
            let v = rpms.max().map { ByteFormat.decimal($0, decimals: 0, locale: locale) + " RPM" }
            return make(labels.fan, v, "Fan")
        case .power:
            let (watts, scope) = power(prefs.menuBar.powerScope, store: store, labels: labels)
            let v = watts.map { ByteFormat.decimal($0, decimals: max(d, 1), locale: locale) + " W" }
            return MenuBarText(label: config.label == .short ? scope : nil, value: v ?? unavailable, isAvailable: v != nil, detail: scope)
        case .coreGroups:
            let clusters = store.cpu?.clusters ?? []
            guard !clusters.isEmpty else {
                return MenuBarText(label: nil, value: unavailable, isAvailable: false, detail: "Core groups")
            }
            let parts = clusters.map { c -> String in
                let k: String
                switch c.coreClass.key { case "E": k = labels.efficiency; case "S": k = labels.superCores; default: k = labels.performance }
                return "\(k) \(ByteFormat.percent(c.usage, decimals: d, locale: locale))"
            }
            return MenuBarText(label: nil, value: parts.joined(separator: " / "), isAvailable: true, detail: "Core groups")
        case .disk:
            guard let disk = store.disk, let r = disk.readBytesPerSecond, let w = disk.writeBytesPerSecond else {
                return make(labels.disk, nil, "Disk")
            }
            return make(labels.disk, "R \(ByteFormat.rate(r, locale: locale)) W \(ByteFormat.rate(w, locale: locale))", "Disk")
        case .network:
            guard let n = store.network, let rx = n.rxBytesPerSecond, let tx = n.txBytesPerSecond else {
                return make(labels.net, nil, "Network")
            }
            let rate: (Double) -> String = { prefs.network.showBits ? ByteFormat.bitRate($0, locale: locale) : ByteFormat.rate($0, locale: locale) }
            return make(labels.net, "↓\(rate(rx)) ↑\(rate(tx))", "Network")
        case .battery:
            guard let b = store.battery, b.isPresent, let p = b.percent else { return make(labels.battery, nil, "Battery") }
            let value = ByteFormat.percent(p / 100, decimals: 0, locale: locale) + (b.isCharging ? " ⚡" : "")
            return make(labels.battery, value, "Battery")
        }
    }

    /// Aplica `config.content` ao texto de carga já calculado: só carga, só temperatura, ou "carga temperatura".
    static func withTemperature(_ load: MenuBarText, config: WidgetConfig, source: TemperatureSource, store: MetricsStore,
                                prefs: Preferences, locale: Locale) -> MenuBarText {
        guard config.content != .load else { return load }
        let (value, name) = temperature(source, store: store)
        let temp = value.map { formatTemperature($0, unit: prefs.temperatureUnit, decimals: config.decimals, locale: locale) }
        var out = load
        if config.content == .temperature {
            out.value = temp ?? unavailable; out.isAvailable = temp != nil
        } else {
            out.value = [load.isAvailable ? load.value : nil, temp].compactMap { $0 }.joined(separator: " ")
            if out.value.isEmpty { out.value = unavailable }
            out.isAvailable = load.isAvailable || temp != nil
            out.lines = [load.isAvailable ? load.value : unavailable, temp ?? unavailable]
        }
        out.detail = load.detail + " · " + name
        return out
    }

    public static func formatTemperature(_ celsius: Double, unit: TemperatureUnit, decimals: Int, locale: Locale = .current) -> String {
        switch unit {
        case .celsius: return ByteFormat.decimal(celsius, decimals: decimals, locale: locale) + "°"
        case .fahrenheit: return ByteFormat.decimal(celsius * 9 / 5 + 32, decimals: decimals, locale: locale) + "°F"
        }
    }

    static func temperature(_ source: TemperatureSource, store: MetricsStore) -> (Double?, String) {
        guard let s = store.sensors else { return (nil, "Temperature") }
        func aggregate(_ key: String, _ name: String) -> (Double?, String) {
            (s.aggregates.first { $0.descriptor.key == key }?.value, name)
        }
        switch source {
        case .cpuAverage: return aggregate("avg-cpu", "Average CPU (thermal zones)")
        case .cpuHottest: return aggregate("max-cpu", "Hottest CPU zone")
        case .gpuAverage: return aggregate("avg-gpu", "Average GPU (thermal zones)")
        case .gpuHottest: return aggregate("max-gpu", "Hottest GPU zone")
        case .sensor(let id):
            let r = s.readings.first { $0.descriptor.id == id }
            return (r?.value, r?.descriptor.name ?? id)
        }
    }

    static func power(_ scope: PowerScopeChoice, store: MetricsStore, labels: MenuBarLabels) -> (Double?, String) {
        let target: PowerScope
        let label: String
        switch scope {
        case .systemTotal: target = .systemTotal; label = labels.systemTotal
        case .battery: target = .battery; label = labels.batteryPower
        case .dcIn: target = .dcIn; label = labels.dcIn
        case .cpu: target = .cpu; label = labels.cpuPower
        case .gpu: target = .gpu; label = labels.gpuPower
        }
        guard let reading = store.power?.readings.first(where: { $0.scope == target }) else { return (nil, label) }
        return (reading.watts, label)
    }
}

public extension ByteFormat {
    /// Taxa em bits/s (decimal): "12,3 Mb/s".
    static func bitRate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let bits = bytesPerSecond * 8
        let units = ["b/s", "Kb/s", "Mb/s", "Gb/s"]
        var v = bits; var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return decimal(v, decimals: i == 0 ? 0 : (v >= 100 ? 0 : 1), locale: locale) + " " + units[i]
    }
}
