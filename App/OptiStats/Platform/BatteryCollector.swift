import Foundation
import IOKit
import IOKit.ps
import OptiStatsCore

/// Bateria: IOPowerSources (porcentagem/tempo/estado) + AppleSmartBattery (ciclos, saúde, temperatura, tensão, corrente).
/// V × A é a potência do pacote de bateria, não o consumo do sistema.
final class BatteryCollector: BaseCollector {
    init(store: MetricsStore, clock: MonotonicClock) { super.init(id: .battery, store: store, clock: clock) }

    override func collect() {
        let now = clock.now
        let ps = Self.powerSourceDescription()
        var smc: [String: Any]?
        IOReg.forEachService(matching: "AppleSmartBattery") { entry in
            if smc == nil { smc = IOReg.properties(of: entry) }
        }

        let present = (smc?.bool("BatteryInstalled") ?? (ps != nil)) && (ps != nil || smc != nil)
        guard present else {
            store.publish(battery: BatterySnapshot(timestamp: now, isPresent: false, percent: nil, isCharging: false,
                                                   onAC: true, minutesRemaining: nil, cycleCount: nil, healthPercent: nil,
                                                   temperatureC: nil, voltageV: nil, amperageA: nil))
            markUnsupported("platform.reason.noBattery")
            return
        }

        var percent: Double?
        if let cur = (ps?["Current Capacity"] as? NSNumber)?.doubleValue,
           let max = (ps?["Max Capacity"] as? NSNumber)?.doubleValue, max > 0 {
            percent = Swift.min(100, Swift.max(0, cur / max * 100))
        }
        let state = ps?["Power Source State"] as? String
        let onAC = state.map { $0 == "AC Power" } ?? (smc?.bool("ExternalConnected") ?? false)
        let charging = (ps?["Is Charging"] as? Bool) ?? smc?.bool("IsCharging") ?? false

        var minutes: Int?
        let key = charging ? "Time to Full Charge" : "Time to Empty"
        if let m = (ps?[key] as? NSNumber)?.intValue, m >= 0, m < 24 * 60 * 7 { minutes = m }

        var health: Double?
        if let raw = smc?.double("AppleRawMaxCapacity") ?? smc?.double("NominalChargeCapacity"),
           let design = smc?.double("DesignCapacity"), design > 0, raw > 0 {
            health = Swift.min(100, raw / design * 100)
        }
        // "Temperature" do AppleSmartBattery vem em centésimos de °C.
        let temperature = smc?.double("Temperature").map { $0 / 100 }.flatMap { SensorValidator.validate($0, kind: .temperature) }
        let voltage = smc?.double("Voltage").map { $0 / 1000 }.flatMap { SensorValidator.validate($0, kind: .voltage) }
        let amperage = smc?.signedInt("Amperage").map { Double($0) / 1000 }.flatMap { SensorValidator.validate($0, kind: .current) }

        store.publish(battery: BatterySnapshot(
            timestamp: now, isPresent: true, percent: percent, isCharging: charging, onAC: onAC,
            minutesRemaining: minutes, cycleCount: (smc?["CycleCount"] as? NSNumber)?.intValue,
            healthPercent: health, temperatureC: temperature, voltageV: voltage, amperageA: amperage))
        markAvailable()
    }

    /// Descrição da fonte "InternalBattery" do IOPowerSources.
    static func powerSourceDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
               (desc["Type"] as? String) == "InternalBattery" { return desc }
        }
        return nil
    }
}
