import Foundation
import OptiStatsCore

@main
struct TelemetrySmoke {
    static func main() {
        let clock = SystemMonotonicClock()
        let store = MetricsStore(clock: clock)
        let smc = SMCReader()
        let chip = ChipFamily.parse(brand: Sys.string("machdep.cpu.brand_string") ?? "")
        let temperature = TemperatureCollector(store: store, clock: clock, smc: smc, chip: chip)
        let fan = FanCollector(store: store, clock: clock, smc: smc)
        let electrical = SensorListCollector(store: store, clock: clock, smc: smc, chip: chip)
        let power = PowerCollector(store: store, clock: clock, smc: smc, chip: chip)

        temperature.collect()
        fan.collect()
        electrical.collect()
        power.collect()
        Thread.sleep(forTimeInterval: 0.3)
        power.collect()
        temperature.suspend()
        fan.suspend()
        electrical.suspend()
        power.suspend()

        // Exercise reconnection after the final collector releases the shared connection.
        temperature.collect()
        fan.collect()
        let snapshot = store.sensors
        temperature.suspend()
        fan.suspend()

        let temperatures = snapshot?.readings.filter { $0.descriptor.kind == .temperature } ?? []
        let cpuTemperatures = snapshot?.aggregates.filter {
            $0.descriptor.key == "avg-cpu" || $0.descriptor.key == "max-cpu"
        } ?? []
        let fans = snapshot?.fans ?? []
        let powerSources = store.power?.readings ?? []
        print("Read-only telemetry on \(Sys.string("hw.model") ?? "unknown")")
        print("Temperature sensors: \(temperatures.count), CPU aggregates: \(cpuTemperatures.compactMap(\.value)) °C")
        for fan in fans {
            print("Fan \(fan.index): \(fan.rpm ?? -1) RPM, range \(fan.minRPM ?? -1)–\(fan.maxRPM ?? -1) RPM")
        }
        print("Power sources: \(powerSources.count), IOReport: \(powerSources.filter { $0.source == .ioReport }.count)")

        let requireHardware = CommandLine.arguments.contains("--require-telemetry")
        if requireHardware && (cpuTemperatures.compactMap(\.value).isEmpty || powerSources.isEmpty) {
            fputs("Expected CPU temperature and power telemetry on this hardware.\n", stderr)
            exit(1)
        }
        let validFans = fans.allSatisfy {
            guard let rpm = $0.rpm, let min = $0.minRPM, let max = $0.maxRPM else { return false }
            return rpm >= 0 && max > min && min >= 0
        }
        if requireHardware && !validFans {
            fputs("The fan-capable hardware did not return plausible RPM and firmware limits.\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.contains("--expect-fans") && fans.isEmpty {
            fputs("Expected at least one physical fan.\n", stderr)
            exit(1)
        }
    }
}
