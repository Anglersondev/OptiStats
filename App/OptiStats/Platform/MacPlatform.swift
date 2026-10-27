import Foundation
import ServiceManagement
import OptiStatsCore

/// Implementação macOS de `PlatformServices`: junta os coletores reais e os serviços do sistema.
/// Nada aqui roda por conta própria: os coletores só executam quando o `SamplingCoordinator` os chama.
final class MacPlatform: PlatformServices {
    private let smc = SMCReader()
    private let appController = MacAppController()
    private let systemEvents = MacSystemEvents()
    private let meter = MacSelfMeter()
    /// Atuador de ventoinhas: fala com o helper privilegiado (se o usuário o instalou). Sem helper → `.unavailable`.
    private lazy var actuator: FanActuator = HelperFanActuator(settings: FanControlSettings(modelKey: { [unowned self] in
        // Flag de validação por modelo de hardware E versão principal do macOS (uma atualização maior exige novo teste).
        let model = self.readSystemProfile().modelIdentifier ?? "unknown"
        return "\(model)|macOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }))
    private var cachedProfile: SystemProfile?

    // Memória total usada pelo `memoryProbe` (definida quando o perfil é lido).
    private lazy var probe: MacMemoryProbe = {
        MacMemoryProbe(clock: SystemMonotonicClock(), totalBytes: readSystemProfile().totalMemoryBytes)
    }()

    var events: SystemEventSource { systemEvents }
    var apps: AppController & FrontmostAppProviding { appController }
    var selfMeter: SelfUsageMeasuring { meter }
    var memoryProbe: MemoryProbe { probe }
    var fanActuator: FanActuator { actuator }

    func readSystemProfile() -> SystemProfile {
        if let p = cachedProfile { return p }
        let p = SystemProfileReader.read(smc: smc)
        smc.close()
        cachedProfile = p
        return p
    }

    func makeCollectors(store: MetricsStore, clock: MonotonicClock, system: SystemProfile) -> [Collector] {
        [
            CPUCollector(store: store, clock: clock, topology: system.topology),
            GPUCollector(store: store, clock: clock, name: system.gpuName, cores: system.gpuCores),
            MemoryCollector(store: store, clock: clock, totalBytes: system.totalMemoryBytes),
            ProcessCollector(store: store, clock: clock),
            TemperatureCollector(store: store, clock: clock, smc: smc, chip: system.chip),
            FanCollector(store: store, clock: clock, smc: smc),
            PowerCollector(store: store, clock: clock, smc: smc, chip: system.chip),
            SensorListCollector(store: store, clock: clock, smc: smc, chip: system.chip),
            DiskCollector(store: store, clock: clock),
            NetworkCollector(store: store, clock: clock),
            BatteryCollector(store: store, clock: clock)
        ]
    }

    // MARK: Iniciar no login (SMAppService)

    func setLaunchAtLogin(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw PlatformError.launchAtLogin(error.localizedDescription)
        }
    }

    func isLaunchAtLoginEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
}

enum PlatformError: LocalizedError {
    case launchAtLogin(String)
    var errorDescription: String? {
        switch self {
        case .launchAtLogin(let detail): return L("platform.error.launchAtLogin", detail)
        }
    }
}
