import Foundation
import OptiStatsCore

/// Temperaturas: zonas do catálogo SMC (somente as chaves que existem neste Mac e dão valor plausível) + sensores HID.
/// Para não enviesar médias, sensores HID de CPU/GPU só entram quando o SMC não deu nenhuma zona do mesmo grupo.
final class TemperatureCollector: BaseCollector {
    private let smc: SMCReader
    private let specs: [SMCSensorSpec]
    private let hid = HIDTemperatureSensors()

    init(store: MetricsStore, clock: MonotonicClock, smc: SMCReader, chip: ChipFamily?) {
        self.smc = smc
        self.specs = SMCCatalog.specs(for: chip).filter { $0.kind == .temperature }
        super.init(id: .temperatures, store: store, clock: clock)
    }

    override func collect() {
        let t = clock.now
        guard smc.isAvailable || hid.isAvailable else {
            markFailed(L("platform.reason.smcOpenFailed", smc.lastError ?? "—")); return
        }
        var readings: [SensorReading] = []
        for spec in specs {
            guard let raw = smc.read(spec.key) else { continue }   // chave ausente neste Mac
            let r = SensorValidator.reading(spec.descriptor(), raw: raw, at: t)
            if r.value != nil { readings.append(r) }
        }
        let smcHasCPU = !SensorAggregator.cpuZones(readings).isEmpty
        let smcHasGPU = !SensorAggregator.gpuZones(readings).isEmpty

        var seenKeys: [String: Int] = [:]
        for item in hid.readTemperatures() {
            guard let info = SMCCatalog.hidRole(forProductName: item.product) else { continue }
            let isCPU = [SensorRole.cpuEfficiencyZone, .cpuPerformanceZone, .cpuSuperZone].contains(info.role)
            if (isCPU && smcHasCPU) || (info.role == .gpuZone && smcHasGPU) { continue }
            let n = seenKeys[item.product, default: 0]; seenKeys[item.product] = n + 1
            let key = n == 0 ? item.product : "\(item.product)#\(n)"
            let d = SensorDescriptor(key: key, name: n == 0 ? info.label : "\(info.label) (\(n + 1))",
                                     kind: .temperature, role: info.role, source: .hid)
            let r = SensorValidator.reading(d, raw: item.celsius, at: t)
            if r.value != nil { readings.append(r) }
        }

        guard !readings.isEmpty else {
            markUnsupported("platform.reason.noTemperatures")
            store.updateSensors(timestamp: t, owner: "temperatures", readings: [])
            return
        }
        store.updateSensors(timestamp: t, owner: "temperatures", readings: readings)
        markAvailable()
    }

    override func suspend() { hid.release(); smc.close() }
}

/// Ventoinhas: leitura (FNum, F{i}Ac/Mn/Mx, F{i}Md). Nenhuma escrita.
final class FanCollector: BaseCollector {
    private let smc: SMCReader

    init(store: MetricsStore, clock: MonotonicClock, smc: SMCReader) {
        self.smc = smc
        super.init(id: .fans, store: store, clock: clock)
    }

    override func collect() {
        let t = clock.now
        guard smc.isAvailable else { markFailed(L("platform.reason.smcOpenFailed", smc.lastError ?? "—")); return }
        guard let n = smc.read("FNum"), n >= 1, n <= 8 else {
            markUnsupported("platform.reason.noFans")
            store.updateSensors(timestamp: t, owner: "fans", fans: [])
            return
        }
        var fans: [FanReading] = []
        for i in 0..<Int(n) {
            let rpm = SensorValidator.validate(smc.read("F\(i)Ac"), kind: .fan)
            let lo = SensorValidator.validate(smc.read("F\(i)Mn"), kind: .fan)
            let hi = SensorValidator.validate(smc.read("F\(i)Mx"), kind: .fan)
            var mode = FanMode.unknown
            // "F{i}Md" (maioria) ou "F{i}md" (Apple Silicon recente); 0 e 3 são automáticos, 1 é manual (como no Stats).
            if let m = smc.read("F\(i)Md") ?? smc.read("F\(i)md") { mode = (m == 0 || m == 3) ? .automatic : .manual }
            fans.append(FanReading(index: i, name: nil, rpm: rpm, minRPM: lo, maxRPM: hi, mode: mode, timestamp: t))
        }
        store.updateSensors(timestamp: t, owner: "fans", fans: fans)
        markAvailable()
    }

    override func suspend() { smc.close() }
}

/// Lista elétrica (tensão, corrente, potência) do catálogo SMC. Domínios de potência se sobrepõem: nunca somar.
final class SensorListCollector: BaseCollector {
    private let smc: SMCReader
    private let specs: [SMCSensorSpec]

    init(store: MetricsStore, clock: MonotonicClock, smc: SMCReader, chip: ChipFamily?) {
        self.smc = smc
        self.specs = SMCCatalog.specs(for: chip).filter { $0.kind != .temperature }
        super.init(id: .sensorList, store: store, clock: clock)
    }

    override func collect() {
        let t = clock.now
        guard smc.isAvailable else { markFailed(L("platform.reason.smcOpenFailed", smc.lastError ?? "—")); return }
        var readings: [SensorReading] = []
        for spec in specs {
            guard let raw = smc.read(spec.key) else { continue }
            let r = SensorValidator.reading(spec.descriptor(), raw: raw, at: t)
            if r.value != nil { readings.append(r) }
        }
        store.updateSensors(timestamp: t, owner: "electrical", readings: readings)
        if readings.isEmpty { markUnsupported("platform.reason.noElectrical") } else { markAvailable() }
    }

    override func suspend() { smc.close() }
}
