import XCTest
@testable import OptiStatsCore

final class MenuBarFormatterTests: XCTestCase {
    let en = Locale(identifier: "en_US")
    let pt = Locale(identifier: "pt_BR")

    func cfg(_ kind: WidgetKind, label: LabelStyle = .short, decimals: Int = 0) -> WidgetConfig { WidgetConfig(kind: kind, enabled: true, label: label, decimals: decimals) }

    func text(_ kind: WidgetKind, store: MetricsStore, prefs: Preferences = Preferences(), label: LabelStyle = .short, decimals: Int = 0, locale: Locale? = nil) -> MenuBarText {
        MenuBarFormatter.text(kind: kind, config: cfg(kind, label: label, decimals: decimals), store: store, prefs: prefs, locale: locale ?? en)
    }

    func testMissingDataIsDashNeverZero() {
        let store = MetricsStore(clock: ManualClock())
        for kind in WidgetKind.allCases {
            let t = text(kind, store: store)
            XCTAssertFalse(t.isAvailable, "\(kind)")
            XCTAssertTrue(t.value == "—", "\(kind): \(t.value)")
        }
    }

    func testRamPercentLikeScreenshotAndLocale() {
        let store = MetricsStore(clock: ManualClock())
        store.publish(memory: memorySnapshot(t: 1, used: UInt64(16.72 * Double(GiB))))
        XCTAssertEqual(text(.ram, store: store).display, "RAM 70%")
        XCTAssertEqual(text(.ram, store: store, label: .none).display, "70%")
        XCTAssertEqual(text(.ram, store: store, decimals: 1, locale: pt).value, "69,7%")
    }

    func testTemperatureSourceUnitAndDecimals() {
        let store = MetricsStore(clock: ManualClock())
        func z(_ k: String, _ role: SensorRole, _ v: Double) -> SensorReading {
            SensorValidator.reading(SensorDescriptor(key: k, name: k, kind: .temperature, role: role, source: .smc), raw: v, at: 1)
        }
        store.updateSensors(timestamp: 1, owner: "temperatures", readings: [z("a", .cpuPerformanceZone, 40), z("b", .cpuPerformanceZone, 50), z("c", .gpuZone, 36)])
        var prefs = Preferences()
        XCTAssertEqual(text(.temperature, store: store, prefs: prefs).display, "T 45°")
        prefs.menuBar.temperatureSource = .cpuHottest
        XCTAssertEqual(text(.temperature, store: store, prefs: prefs).value, "50°")
        prefs.menuBar.temperatureSource = .gpuAverage
        XCTAssertEqual(text(.temperature, store: store, prefs: prefs).value, "36°")
        prefs.temperatureUnit = .fahrenheit
        XCTAssertEqual(text(.temperature, store: store, prefs: prefs).value, "97°F")
        prefs.menuBar.temperatureSource = .sensor(id: "smc:b")
        XCTAssertEqual(text(.temperature, store: store, prefs: prefs).value, "122°F")
        prefs.menuBar.temperatureSource = .sensor(id: "smc:missing")
        XCTAssertFalse(text(.temperature, store: store, prefs: prefs).isAvailable)
    }

    func testFanZeroRPMIsARealReadingButNoFansIsDash() {
        let store = MetricsStore(clock: ManualClock())
        store.updateSensors(timestamp: 1, owner: "fans", fans: [FanReading(index: 0, rpm: 0, minRPM: 1200, maxRPM: 6000, mode: .automatic, timestamp: 1)])
        XCTAssertEqual(text(.fan, store: store).value, "0 RPM")
        let empty = MetricsStore(clock: ManualClock())
        empty.updateSensors(timestamp: 1, owner: "fans", fans: [])
        XCTAssertEqual(text(.fan, store: empty).value, "—")
    }

    func testPowerShowsScopeAndNeverMixesDomains() {
        let store = MetricsStore(clock: ManualClock())
        func p(_ scope: PowerScope, _ w: Double) -> PowerReading { PowerReading(id: scope.rawValue, name: scope.rawValue, scope: scope, watts: w, quality: .observed, source: .smc, timestamp: 1) }
        store.publish(power: PowerSnapshot(timestamp: 1, readings: [p(.systemTotal, 8.04), p(.battery, -6.2)], energy: nil, energyScope: nil, movingAverageWatts: nil))
        var prefs = Preferences()
        XCTAssertEqual(text(.power, store: store, prefs: prefs).display, "SYS 8.0 W")
        prefs.menuBar.powerScope = .battery
        XCTAssertEqual(text(.power, store: store, prefs: prefs).display, "BAT -6.2 W")
        prefs.menuBar.powerScope = .gpu                      // sem leitura desse escopo
        XCTAssertEqual(text(.power, store: store, prefs: prefs).value, "—")
    }

    func testCoreGroupsOnlyWhenClustersAreTrusted() {
        let store = MetricsStore(clock: ManualClock())
        let load = CPULoad(timestamp: 1, total: 0.1, user: 0.07, system: 0.03, idle: 0.9, perCore: [0.05, 0.13])
        store.publish(cpu: CPUSnapshot(load: load, loadAverage: nil, clusters: [], thermal: .nominal))
        XCTAssertEqual(text(.coreGroups, store: store).value, "—")
        let e = ClusterUsage(coreClass: CoreClass(key: "E", name: "Efficiency"), usage: 0.05, cpuCount: 4)
        let p = ClusterUsage(coreClass: CoreClass(key: "P", name: "Performance"), usage: 0.13, cpuCount: 10)
        store.publish(cpu: CPUSnapshot(load: load, loadAverage: nil, clusters: [e, p], thermal: .nominal))
        XCTAssertEqual(text(.coreGroups, store: store).value, "E 5% / P 13%")
        XCTAssertEqual(text(.cpu, store: store).display, "CPU 10%")
    }

    func testNetworkAndBatteryFormatting() {
        let store = MetricsStore(clock: ManualClock())
        store.publish(network: NetworkSnapshot(timestamp: 1, interfaces: [], rxBytesPerSecond: 1_500_000, txBytesPerSecond: 250_000))
        XCTAssertEqual(text(.network, store: store).value, "↓1.5 MB/s ↑250 KB/s")
        var prefs = Preferences(); prefs.network.showBits = true
        XCTAssertEqual(text(.network, store: store, prefs: prefs).value, "↓12.0 Mb/s ↑2.0 Mb/s")
        store.publish(battery: BatterySnapshot(timestamp: 1, isPresent: true, percent: 85, isCharging: true, onAC: true,
                                               minutesRemaining: nil, cycleCount: nil, healthPercent: nil, temperatureC: nil, voltageV: nil, amperageA: nil))
        XCTAssertEqual(text(.battery, store: store).value, "85% ⚡")
        store.publish(battery: BatterySnapshot(timestamp: 2, isPresent: false, percent: nil, isCharging: false, onAC: true,
                                               minutesRemaining: nil, cycleCount: nil, healthPercent: nil, temperatureC: nil, voltageV: nil, amperageA: nil))
        XCTAssertFalse(text(.battery, store: store).isAvailable)
    }

    func testBatteryPackPowerIsVoltsTimesAmps() {
        let b = BatterySnapshot(timestamp: 1, isPresent: true, percent: 50, isCharging: false, onAC: false, minutesRemaining: nil,
                                cycleCount: nil, healthPercent: nil, temperatureC: nil, voltageV: 12.0, amperageA: -0.5)
        XCTAssertEqual(b.batteryPowerW!, -6.0, accuracy: 1e-9)
        var none = b; none.amperageA = nil
        XCTAssertNil(none.batteryPowerW)
    }
}

final class WidgetContentTests: XCTestCase {
    func testOldWidgetConfigDecodesWithLoadContent() throws {
        let json = #"{"kind":"cpu","enabled":true,"label":"short","decimals":0}"#.data(using: .utf8)!
        let w = try JSONDecoder().decode(WidgetConfig.self, from: json)
        XCTAssertEqual(w.content, .load)
    }
    func testInlineTemperatureAddsCollector() {
        var p = Preferences()
        p.monitoringMode = .full
        if let i = p.menuBar.widgets.firstIndex(where: { $0.kind == .cpu }) { p.menuBar.widgets[i].content = .temperature }
        XCTAssertTrue(p.visibleKinds().contains(.temperature))
        p.monitoringMode = .essential
        XCTAssertFalse(p.visibleKinds().contains(.temperature))
    }
}
