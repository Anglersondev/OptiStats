import Foundation

public enum LanguageChoice: String, Codable, CaseIterable { case system, ptBR, en }
public enum AppearanceChoice: String, Codable, CaseIterable { case system, light, dark }
public enum MonitoringMode: String, Codable, CaseIterable {
    /// Somente RAM/CPU/pressão: custo mínimo.
    case essential
    /// Sensores, energia, disco, rede e histórico sob demanda.
    case full
}
public enum TemperatureUnit: String, Codable, CaseIterable { case celsius, fahrenheit }

public enum WidgetKind: String, Codable, CaseIterable {
    case ram, cpu, gpu, temperature, fan, power, coreGroups, disk, network, battery

    /// Coletores necessários para o widget estar correto (nada além disso roda por causa dele).
    public var collectors: [CollectorID] {
        switch self {
        case .ram: return [.memory]
        case .cpu, .coreGroups: return [.cpu]
        case .gpu: return [.gpu]
        case .temperature: return [.temperatures]
        case .fan: return [.fans]
        case .power: return [.power]
        case .disk: return [.disk]
        case .network: return [.network]
        case .battery: return [.battery]
        }
    }

    /// Módulos caros/opcionais não funcionam em `MonitoringMode.essential`.
    public var isEssential: Bool { self == .ram || self == .cpu }
}

public enum LabelStyle: String, Codable, CaseIterable { case none, short, icon }

public enum TemperatureSource: Codable, Equatable {
    case cpuAverage, cpuHottest, gpuAverage, gpuHottest
    case sensor(id: String)
}

public enum PowerScopeChoice: String, Codable, CaseIterable { case systemTotal, battery, dcIn, cpu, gpu }

public struct WidgetConfig: Codable, Equatable {
    public var kind: WidgetKind
    public var enabled: Bool
    public var label: LabelStyle
    public var decimals: Int
    public init(kind: WidgetKind, enabled: Bool, label: LabelStyle = .short, decimals: Int = 0) {
        self.kind = kind; self.enabled = enabled; self.label = label; self.decimals = decimals
    }
}

public struct MenuBarConfig: Codable, Equatable {
    /// A ordem do array é a ordem de criação dos itens (o macOS decide a posição final na barra).
    public var widgets: [WidgetConfig]
    /// Modo compacto: vários números em um único item da barra.
    public var combined: Bool
    public var combinedKinds: [WidgetKind]
    public var temperatureSource: TemperatureSource
    public var powerScope: PowerScopeChoice

    public static let `default` = MenuBarConfig(
        widgets: WidgetKind.allCases.map { WidgetConfig(kind: $0, enabled: $0 == .ram || $0 == .cpu) },
        combined: false, combinedKinds: [.cpu, .ram], temperatureSource: .cpuAverage, powerScope: .systemTotal)
}

public struct MemoryPreferences: Codable, Equatable {
    public var userProtectedBundleIDs: Set<String> = []
    public var userUnprotectedBundleIDs: Set<String> = []
    /// Alertas (notificação) em pressão alta. NUNCA encerram apps.
    public var alertsEnabled = false
    public var processesShown = 8
    public var groupByApp = true
}

public struct NetworkPreferences: Codable, Equatable {
    public var interfaceFilter: String? = nil   // nil = automático
    public var showBits = false
}

public struct Preferences: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Preferences.currentSchemaVersion
    public var language: LanguageChoice = .system
    public var appearance: AppearanceChoice = .system
    public var launchAtLogin = false
    public var monitoringMode: MonitoringMode = .essential
    public var profileOnAC: SamplingProfile = .balanced
    public var profileOnBattery: SamplingProfile = .economy
    public var customIntervals: [CollectorID: ModuleIntervals] = [:]
    public var menuBar: MenuBarConfig = .default
    public var memory = MemoryPreferences()
    public var network = NetworkPreferences()
    public var temperatureUnit: TemperatureUnit = .celsius
    /// Histórico longo persistido: opt-in, desativado por padrão.
    public var persistHistory = false
    public var historyMinutes = 10
    public var smartBoostRequested = false     // só vale se o hardware for validado; hoje sempre ignorado
    public var firstRunCompleted = false
    /// IDs estáveis de sensores fixados no topo do painel de sensores.
    public var favoriteSensorIDs: Set<String> = []

    public init() {}

    // Decodificação tolerante: campos ausentes (versões antigas/novas) assumem o padrão.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, language, appearance, launchAtLogin, monitoringMode, profileOnAC, profileOnBattery
        case customIntervals, menuBar, memory, network, temperatureUnit, persistHistory, historyMinutes
        case smartBoostRequested, firstRunCompleted, favoriteSensorIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        schemaVersion = get(.schemaVersion, Preferences.currentSchemaVersion)
        language = get(.language, .system)
        appearance = get(.appearance, .system)
        launchAtLogin = get(.launchAtLogin, false)
        monitoringMode = get(.monitoringMode, .essential)
        profileOnAC = get(.profileOnAC, .balanced)
        profileOnBattery = get(.profileOnBattery, .economy)
        customIntervals = get(.customIntervals, [:])
        menuBar = get(.menuBar, .default)
        memory = get(.memory, MemoryPreferences())
        network = get(.network, NetworkPreferences())
        temperatureUnit = get(.temperatureUnit, .celsius)
        persistHistory = get(.persistHistory, false)
        historyMinutes = get(.historyMinutes, 10)
        smartBoostRequested = get(.smartBoostRequested, false)
        firstRunCompleted = get(.firstRunCompleted, false)
        favoriteSensorIDs = get(.favoriteSensorIDs, [])
    }

    /// Corrige valores inválidos. Idempotente.
    public func normalized() -> Preferences {
        var p = self
        p.schemaVersion = Preferences.currentSchemaVersion
        // Cada WidgetKind exatamente uma vez, na ordem existente; faltantes entram desativados no fim.
        var seen = Set<WidgetKind>()
        var widgets: [WidgetConfig] = []
        for var w in p.menuBar.widgets where !seen.contains(w.kind) {
            seen.insert(w.kind)
            w.decimals = min(2, max(0, w.decimals))
            widgets.append(w)
        }
        for k in WidgetKind.allCases where !seen.contains(k) { widgets.append(WidgetConfig(kind: k, enabled: false)) }
        p.menuBar.widgets = widgets
        p.menuBar.combinedKinds = Array(p.menuBar.combinedKinds.reduce(into: [WidgetKind]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
        if p.menuBar.combinedKinds.isEmpty { p.menuBar.combinedKinds = [.cpu, .ram] }
        // Intervalos personalizados só com valores permitidos.
        var custom: [CollectorID: ModuleIntervals] = [:]
        for (id, mi) in p.customIntervals {
            func fix(_ c: IntervalChoice) -> IntervalChoice {
                if case .seconds(let s) = c { return .seconds(AllowedIntervals.coerce(s, for: id)) }
                return c
            }
            custom[id] = ModuleIntervals(background: fix(mi.background), visible: fix(mi.visible))
        }
        p.customIntervals = custom
        p.memory.processesShown = min(20, max(0, p.memory.processesShown))
        p.historyMinutes = [5, 10, 15].contains(p.historyMinutes) ? p.historyMinutes : 10
        // Smart Boost permanece desligado até existir atuador validado.
        p.smartBoostRequested = false
        return p
    }

    public func effectiveProfile(onBattery: Bool) -> SamplingProfile { onBattery ? profileOnBattery : profileOnAC }

    /// Quais widgets realmente rodam, respeitando o modo "somente essenciais".
    public func activeWidgets() -> [WidgetConfig] {
        menuBar.widgets.filter { $0.enabled && (monitoringMode == .full || $0.kind.isEssential) }
    }

    /// Tipos exibidos na barra agora (modo compacto usa `combinedKinds`). Determina quais coletores recebem demanda.
    public func visibleKinds() -> [WidgetKind] {
        let allowed: (WidgetKind) -> Bool = { self.monitoringMode == .full || $0.isEssential }
        if menuBar.combined { return menuBar.combinedKinds.filter(allowed) }
        return activeWidgets().map(\.kind)
    }
}

// MARK: - Armazenamento

public protocol KeyValueStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class InMemoryStorage: KeyValueStorage {
    private var dict: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { dict[key] }
    public func set(_ data: Data?, forKey key: String) { dict[key] = data }
}

public final class UserDefaultsStorage: KeyValueStorage {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

public final class PreferencesStore {
    public static let storageKey = "app.optistats.preferences.v1"
    private let storage: KeyValueStorage
    private let lock = NSLock()
    private var _current: Preferences
    public private(set) var lastLoadWasRecovery = false

    public init(storage: KeyValueStorage) {
        self.storage = storage
        if let data = storage.data(forKey: Self.storageKey) {
            if let p = try? JSONDecoder().decode(Preferences.self, from: data) {
                _current = p.normalized()
            } else {
                // Dados corrompidos: volta ao padrão seguro em vez de travar.
                _current = Preferences().normalized(); lastLoadWasRecovery = true
            }
        } else {
            _current = Preferences().normalized()
        }
    }

    public var current: Preferences { lock.lock(); defer { lock.unlock() }; return _current }

    /// Aplica a mudança sobre uma cópia normalizada e só então grava; falha de codificação faz rollback.
    @discardableResult
    public func update(_ mutate: (inout Preferences) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var copy = _current
        mutate(&copy)
        let normalized = copy.normalized()
        guard let data = try? JSONEncoder().encode(normalized) else { return false }
        storage.set(data, forKey: Self.storageKey)
        _current = normalized
        return true
    }

    public func resetToDefaults() {
        lock.lock(); defer { lock.unlock() }
        _current = Preferences().normalized()
        storage.set(nil, forKey: Self.storageKey)
    }

    /// "Restaurar padrão equilibrado": só perfis e intervalos, preservando o resto.
    public func restoreBalancedProfile() {
        update { $0.profileOnAC = .balanced; $0.profileOnBattery = .balanced; $0.customIntervals = [:] }
    }
}
