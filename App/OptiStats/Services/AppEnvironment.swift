import Cocoa
import OptiStatsCore

/// Raiz de composição: liga plataforma, coletores, coordenador de amostragem, armazenamento de métricas e preferências.
/// Há UMA instância por processo. Toda a interface lê de `store` e declara demanda por `setDemand`.
final class AppEnvironment {
    static var current: AppEnvironment!

    let platform: PlatformServices
    let clock: MonotonicClock
    let store: MetricsStore
    let preferences: PreferencesStore
    let system: SystemProfile
    let coordinator: SamplingCoordinator
    let growth = GrowthDetector()
    /// Controle (opcional) de ventoinhas pelo helper. Criado sob demanda; nada roda até o usuário habilitar.
    private(set) lazy var fanControl = FanControlManager(env: self)

    private(set) var powerContext: PowerContext
    private var tokens: [SubscriptionToken] = []
    private var started = false

    /// A camada de interface assina para reconstruir itens da barra quando as preferências mudam.
    var onPreferencesApplied: (() -> Void)?

    init(platform: PlatformServices) {
        self.platform = platform
        let clock = SystemMonotonicClock()
        self.clock = clock
        let prefs = PreferencesStore(storage: UserDefaultsStorage())
        self.preferences = prefs
        let minutes = prefs.current.persistHistory ? prefs.current.historyMinutes : 10
        let retention = TimeInterval(minutes * 60)
        self.store = MetricsStore(clock: clock, seriesCapacity: max(300, Int(retention)), seriesRetention: retention)
        self.system = platform.readSystemProfile()
        self.coordinator = SamplingCoordinator(
            clock: clock,
            scheduler: DispatchWakeScheduler(clock: clock),
            executorFactory: { id in QueueExecutor(label: "app.optistats.collector.\(id.rawValue)", qos: .utility) })
        self.powerContext = platform.events.currentPowerContext()
        Localizer.shared.configure(language: prefs.current.language)
    }

    convenience init() { self.init(platform: MacPlatform()) }

    // MARK: Ciclo de vida

    func start() {
        guard !started else { return }
        started = true
        store.publish(system: system)
        for collector in platform.makeCollectors(store: store, clock: clock, system: system) {
            coordinator.register(collector)
        }
        platform.events.handler = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        platform.events.start()
        tokens.append(store.subscribe(.processes) { [weak self] in
            guard let self, let snap = self.store.processes else { return }
            self.growth.record(groups: snap.byMemory, at: snap.timestamp)
        })
        applyPreferences()
        fanControl.start()
    }

    func stop() {
        platform.events.stop()
        coordinator.pause()
        // Devolve as ventoinhas ao macOS (e derruba a conexão: o helper também restaura ao ver a desconexão).
        fanControl.shutdown()
    }

    // MARK: Preferências → política de amostragem

    var samplingConfiguration: SamplingConfiguration {
        let p = preferences.current
        return SamplingConfiguration(profile: p.effectiveProfile(onBattery: powerContext.onBattery),
                                     custom: p.customIntervals, power: powerContext)
    }

    /// Reaplica preferências: idioma, aparência, perfil e demandas da barra. Seguro chamar a qualquer momento.
    func applyPreferences() {
        let p = preferences.current
        Localizer.shared.configure(language: p.language)
        switch p.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
        coordinator.setConfiguration(samplingConfiguration)

        let visible = Set(p.visibleKinds())
        for kind in WidgetKind.allCases {
            for collector in kind.collectors {
                coordinator.setDemand(consumer: "widget.\(kind.rawValue)", collector: collector,
                                      visibility: visible.contains(kind) ? .bar : nil)
            }
        }
        onPreferencesApplied?()
    }

    private func handle(_ event: SystemEvent) {
        switch event {
        case .willSleep, .screenLocked:
            if case .willSleep = event { fanControl.systemWillSleep() }
            coordinator.pause()
        case .didWake, .screenUnlocked:
            powerContext = platform.events.currentPowerContext()
            coordinator.setConfiguration(samplingConfiguration)
            coordinator.resume()
        case .thermalChanged(let level):
            powerContext.thermal = level
            fanControl.thermalChanged(level)
            coordinator.setConfiguration(samplingConfiguration)
        case .lowPowerModeChanged(let on):
            powerContext.lowPowerMode = on
            coordinator.setConfiguration(samplingConfiguration)
        case .powerSourceChanged(let onBattery):
            powerContext.onBattery = onBattery
            coordinator.setConfiguration(samplingConfiguration)
        case .memoryPressure:
            coordinator.refreshNow(.memory)
        }
    }

    // MARK: Demanda e atualização

    func setDemand(consumer: String, collectors: [CollectorID], visibility: Visibility?) {
        for c in collectors { coordinator.setDemand(consumer: consumer, collector: c, visibility: visibility) }
    }

    @discardableResult
    func refreshNow(_ collectors: [CollectorID]) -> Bool {
        var any = false
        for c in collectors { any = coordinator.refreshNow(c) || any }
        return any
    }

    // MARK: Otimizador de RAM

    var protectionPolicy: ProtectionPolicy {
        let m = preferences.current.memory
        return ProtectionPolicy(userProtectedBundleIDs: m.userProtectedBundleIDs,
                                userUnprotectedBundleIDs: m.userUnprotectedBundleIDs,
                                ownBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.optistats.OptiStats")
    }

    func currentAdvice() -> Advice {
        OptimizationAdvisor(config: AdvisorConfig(), policy: protectionPolicy).advise(
            history: store.memoryHistory,
            groups: store.processes?.byMemory ?? [],
            growth: { [growth] id in growth.suspicion(for: id) },
            frontmostBundleID: platform.apps.frontmostBundleIdentifier)
    }

    func makeOptimizer() -> OptimizationCoordinator {
        OptimizationCoordinator(apps: platform.apps, probe: platform.memoryProbe, policy: { [unowned self] in self.protectionPolicy })
    }

    // MARK: Diagnóstico

    func diagnosticsText() -> String {
        var counts: [SensorKind: Int] = [:]
        for r in store.sensors?.readings ?? [] where r.value != nil { counts[r.descriptor.kind, default: 0] += 1 }
        let usage = platform.selfMeter.measure()
        let input = DiagnosticsInput(
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
            system: system, memory: store.memory, states: store.states, stats: coordinator.stats(),
            configuration: samplingConfiguration, wakeups: coordinator.wakeupCount, sensorCounts: counts,
            fanControl: platform.fanActuator.capability, selfFootprintBytes: usage.footprintBytes,
            selfCPUPercent: usage.cpuPercentSinceLastCall)
        return DiagnosticsReport.render(input, locale: Localizer.shared.locale)
    }
}
