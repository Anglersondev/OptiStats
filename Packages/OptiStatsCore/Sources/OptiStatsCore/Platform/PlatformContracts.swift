import Foundation

/// Eventos do sistema que alteram a política de amostragem. Entregues em fila arbitrária.
public enum SystemEvent: Equatable {
    case willSleep
    case didWake
    case screenLocked
    case screenUnlocked
    case thermalChanged(ThermalLevel)
    case lowPowerModeChanged(Bool)
    case powerSourceChanged(onBattery: Bool)
    case memoryPressure(MemoryPressureLevel)
}

public protocol SystemEventSource: AnyObject {
    /// Definir antes de `start()`. Chamado em fila arbitrária.
    var handler: ((SystemEvent) -> Void)? { get set }
    func start()
    func stop()
    /// Estado atual (para inicializar a política antes de qualquer evento).
    func currentPowerContext() -> PowerContext
}

public struct SelfUsage: Equatable {
    public var footprintBytes: UInt64?
    public var residentBytes: UInt64?
    /// Média desde a última chamada (0...100+ de um núcleo); nil na primeira chamada.
    public var cpuPercentSinceLastCall: Double?
    public var threadCount: Int?
    public init(footprintBytes: UInt64? = nil, residentBytes: UInt64? = nil, cpuPercentSinceLastCall: Double? = nil, threadCount: Int? = nil) {
        self.footprintBytes = footprintBytes; self.residentBytes = residentBytes
        self.cpuPercentSinceLastCall = cpuPercentSinceLastCall; self.threadCount = threadCount
    }
}

public protocol SelfUsageMeasuring: AnyObject {
    func measure() -> SelfUsage
}

public protocol FrontmostAppProviding: AnyObject {
    var frontmostBundleIdentifier: String? { get }
}

/// Fronteira com tudo que é específico do macOS. Implementada pela camada `Platform` do app.
public protocol PlatformServices: AnyObject {
    func readSystemProfile() -> SystemProfile
    /// Um coletor por `CollectorID` suportado. Coletores sem suporte devem publicar `SourceState.unsupported`.
    func makeCollectors(store: MetricsStore, clock: MonotonicClock, system: SystemProfile) -> [Collector]
    var events: SystemEventSource { get }
    var apps: AppController & FrontmostAppProviding { get }
    var selfMeter: SelfUsageMeasuring { get }
    var memoryProbe: MemoryProbe { get }
    var fanActuator: FanActuator { get }
    /// Inicia no login (SMAppService.mainApp). Lança erro com mensagem apresentável.
    func setLaunchAtLogin(_ enabled: Bool) throws
    func isLaunchAtLoginEnabled() -> Bool
}
