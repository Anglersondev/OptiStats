import Foundation

public enum CollectorID: String, CaseIterable, Codable, Hashable {
    case cpu, gpu, memory, processes, temperatures, fans, power, sensorList, disk, network, battery

    /// Essenciais (CPU/RAM) continuam, mais devagar, mesmo sob economia/térmica; os demais são opcionais.
    public var isEssential: Bool { self == .cpu || self == .memory }
}

public enum SamplingProfile: String, Codable, CaseIterable {
    case economy, balanced, realtime, custom
}

/// Quem está olhando: nada, a barra de menus, ou um popover aberto.
public enum Visibility: Int, Comparable, Codable {
    case hidden = 0, bar = 1, popover = 2
    public static func < (a: Visibility, b: Visibility) -> Bool { a.rawValue < b.rawValue }
}

public enum IntervalChoice: Codable, Equatable {
    case automatic
    case seconds(Int)
}

/// Intervalos por módulo: `background` = só barra; `visible` = com painel aberto.
public struct ModuleIntervals: Codable, Equatable {
    public var background: IntervalChoice
    public var visible: IntervalChoice
    public init(background: IntervalChoice = .automatic, visible: IntervalChoice = .automatic) {
        self.background = background; self.visible = visible
    }
}

public enum ThermalLevel: Int, Codable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct PowerContext: Equatable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel
    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal) {
        self.onBattery = onBattery; self.lowPowerMode = lowPowerMode; self.thermal = thermal
    }
}

public struct SamplingConfiguration: Equatable {
    public var profile: SamplingProfile
    public var custom: [CollectorID: ModuleIntervals]
    public var power: PowerContext
    public init(profile: SamplingProfile = .balanced, custom: [CollectorID: ModuleIntervals] = [:],
                power: PowerContext = PowerContext()) {
        self.profile = profile; self.custom = custom; self.power = power
    }
}

/// Opções de intervalo permitidas por fonte (risco/custo). Nem todas as opções valem para todas as fontes.
public enum AllowedIntervals {
    public static func options(for id: CollectorID) -> [Int] {
        switch id {
        case .cpu, .gpu, .memory, .disk, .network: return [1, 2, 3, 5, 10, 15, 20, 30, 60]
        case .processes, .temperatures, .fans, .power, .sensorList: return [2, 3, 5, 10, 15, 20, 30, 60]
        case .battery: return [5, 10, 15, 20, 30, 60]
        }
    }
    /// Ajusta ao valor permitido mais próximo (por cima, para nunca ficar MAIS agressivo que o limite).
    public static func coerce(_ seconds: Int, for id: CollectorID) -> Int {
        let opts = options(for: id)
        return opts.first(where: { $0 >= seconds }) ?? opts.last!
    }
}

/// Estatísticas de custo por coletor (alimenta o indicador "Eficiência do monitor").
public struct CollectorStats: Equatable {
    public var runs = 0
    public var totalRunSeconds: TimeInterval = 0
    public var lastRunAt: TimeInterval?
    public var lastDuration: TimeInterval = 0
    public var interval: TimeInterval?
    public var isActive = false
    public var isStalled = false
    public var readsLastMinute = 0
}

public protocol Collector: AnyObject {
    var id: CollectorID { get }
    /// Executa UMA leitura (no executor serial do coletor). Deve publicar o resultado no `MetricsStore`.
    func collect()
    /// Libera recursos caros e zera linhas de base (sem demanda, repouso ou bloqueio de tela).
    func suspend()
}

public extension Collector {
    func suspend() {}
}
