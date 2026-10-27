import Foundation
import OptiStatsCore

/// Potência: chaves de potência do SMC (sistema/DC/bateria…) + domínios do IOReport (CPU/GPU/ANE/DRAM).
/// Os domínios se sobrepõem, então NUNCA são somados. A energia (Wh) integra só a potência total do sistema (PSTR).
final class PowerCollector: BaseCollector {
    private let smc: SMCReader
    private let specs: [SMCSensorSpec]
    private let ioReport = IOReportEnergy()
    private let integrator = EnergyIntegrator(maxGap: 30)
    private var average = MovingAverage(window: 60)

    init(store: MetricsStore, clock: MonotonicClock, smc: SMCReader, chip: ChipFamily?) {
        self.smc = smc
        self.specs = SMCCatalog.specs(for: chip).filter { $0.kind == .power }
        super.init(id: .power, store: store, clock: clock)
    }

    private func scope(for role: SensorRole) -> PowerScope {
        switch role {
        case .systemTotal: return .systemTotal
        case .dcIn: return .dcIn
        case .battery: return .battery
        case .memoryZone: return .dram
        case .thunderbolt: return .pci
        case .display: return .display
        default: return .other
        }
    }

    override func collect() {
        let t = clock.now
        var readings: [PowerReading] = []
        var systemWatts: Double?

        for spec in specs {
            guard let raw = smc.read(spec.key) else { continue }
            guard let w = SensorValidator.validate(raw, kind: .power) else { continue }
            let d = spec.descriptor()
            let s = scope(for: spec.role)
            if s == .systemTotal { systemWatts = w }
            readings.append(PowerReading(id: d.id, name: spec.name, scope: s, watts: w, quality: .observed,
                                         source: .smc, timestamp: t))
        }

        if let io = ioReport.read(at: t) {
            func add(_ key: String, _ name: String, _ scope: PowerScope, _ w: Double?) {
                guard let w, w.isFinite, w >= 0, w < 400 else { return }
                readings.append(PowerReading(id: "ioReport:\(key)", name: name, scope: scope, watts: w,
                                             quality: .calculated, source: .ioReport, timestamp: t))
            }
            add("cpu", "CPU", .cpu, io.cpu)
            add("gpu", "GPU", .gpu, io.gpu)
            add("ane", "Neural Engine", .ane, io.ane)
            add("dram", "DRAM", .dram, io.dram)
        }

        if let w = systemWatts {
            integrator.add(watts: w, at: t)
            average.add(w, at: t)
        } else {
            integrator.markDiscontinuity()
        }

        guard !readings.isEmpty else {
            // O IOReport precisa de duas amostras; no primeiro ciclo ainda não há nada a mostrar.
            if specs.isEmpty && !ioReport.isAvailable { markUnsupported("platform.reason.noPower") }
            return
        }
        store.publish(power: PowerSnapshot(
            timestamp: t, readings: readings,
            energy: systemWatts != nil ? integrator.accumulator : nil,
            energyScope: systemWatts != nil ? .systemTotal : nil,
            movingAverageWatts: average.value))
        markAvailable()
    }

    override func suspend() {
        ioReport.reset()
        integrator.markDiscontinuity()
        smc.close()
    }
}
