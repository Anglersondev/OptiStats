import XCTest
@testable import OptiStatsCore

final class DiagnosticsTests: XCTestCase {
    func testRedactorStripsPersonalData() {
        let raw = """
        /Users/anglerson/Library/Foo log
        mac aa:bb:cc:dd:ee:ff ip 192.168.0.12 uuid 1F1E1328-51E0-46BD-9C19-58B4EC33287A
        Serial Number: C02ABCDEFGH1
        SSID: CasaDoAngle
        usuario anglerson
        """
        let out = Redactor.redact(raw, userName: "anglerson", hostName: nil)
        for leak in ["anglerson", "aa:bb:cc:dd:ee:ff", "192.168.0.12", "1F1E1328", "C02ABCDEFGH1", "CasaDoAngle"] {
            XCTAssertFalse(out.contains(leak), "vazou: \(leak)")
        }
        XCTAssertTrue(out.contains("/Users/<usuario>"))
    }

    func testReportHasNoProcessNamesAndShowsFormulaReconciliation() {
        let snap = memorySnapshot(t: 1, used: 16 * GiB, pressure: .normal)
        let input = DiagnosticsInput(
            appVersion: "1.0.0", system: SystemProfile(chip: ChipFamily.parse(brand: "Apple M4 Pro"), modelIdentifier: "Mac16,8",
                marketingModel: nil, totalMemoryBytes: 24 * GiB, logicalCPUs: 14, physicalCPUs: 14, topology: nil,
                osVersion: "26.0", fanCount: 2, gpuName: nil, gpuCores: nil),
            memory: snap, states: [.cpu: .available, .temperatures: .unsupported(reason: "sem sensores")],
            stats: [.cpu: CollectorStats(runs: 10, totalRunSeconds: 0.05, lastRunAt: 1, lastDuration: 0.005, interval: 3, isActive: true, isStalled: false, readsLastMinute: 20)],
            configuration: SamplingConfiguration(), wakeups: 42, sensorCounts: [.temperature: 12], fanControl: .unavailable(reason: "somente leitura"),
            selfFootprintBytes: 40 * MiB, selfCPUPercent: 0.4)
        let text = DiagnosticsReport.render(input)
        XCTAssertTrue(text.contains("Apple M4 Pro"))
        XCTAssertTrue(text.contains("usada(AM)"))
        XCTAssertTrue(text.contains("usada(alt/Stats)"))
        XCTAssertTrue(text.contains("não suportada (sem sensores)"))
        XCTAssertTrue(text.contains("Controle de ventoinha: indisponível"))
        XCTAssertFalse(text.contains("Brave"))
    }
}

final class MetricsStoreTests: XCTestCase {
    func testPublishUpdatesLatestAndSeries() {
        let store = MetricsStore(clock: ManualClock())
        XCTAssertNil(store.memory)
        XCTAssertEqual(store.state(.cpu), .loading)
        store.publish(memory: memorySnapshot(t: 1, used: 12 * GiB))
        store.publish(memory: memorySnapshot(t: 2, used: 18 * GiB))
        XCTAssertEqual(store.memory?.timestamp, 2)
        XCTAssertEqual(store.series(.memoryUsed).count, 2)
        XCTAssertEqual(store.series(.memoryUsed).latest?.v ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(store.memoryHistory.count, 2)
    }

    func testSubscriptionsAreScopedAndCancelable() {
        let store = MetricsStore(clock: ManualClock())
        var memCalls = 0, cpuCalls = 0
        let t1 = store.subscribe(.memory) { memCalls += 1 }
        let t2 = store.subscribe(.cpu) { cpuCalls += 1 }
        store.publish(memory: memorySnapshot(t: 1))
        XCTAssertEqual(memCalls, 1); XCTAssertEqual(cpuCalls, 0)
        t1.cancel()
        store.publish(memory: memorySnapshot(t: 2))
        XCTAssertEqual(memCalls, 1)
        _ = t2
    }

    func testStateChangesNotifyOnlyWhenChanged() {
        let store = MetricsStore(clock: ManualClock())
        var calls = 0
        let tok = store.subscribe(.sensors) { calls += 1 }
        store.setState(.unsupported(reason: "x"), for: .temperatures)
        store.setState(.unsupported(reason: "x"), for: .temperatures)
        XCTAssertEqual(calls, 1)
        _ = tok
    }

    func testSensorAggregatesFeedTemperatureSeriesAndMissingStaysEmpty() {
        let store = MetricsStore(clock: ManualClock())
        let d = SensorDescriptor(key: "Tp01", name: "Tp01", kind: .temperature, role: .cpuPerformanceZone, source: .smc)
        store.updateSensors(timestamp: 5, owner: "temperatures", readings: [SensorValidator.reading(d, raw: 44, at: 5)])
        XCTAssertEqual(store.series(.tempCPU).latest?.v, 44)
        XCTAssertEqual(store.series(.tempGPU).count, 0)                            // sem GPU: série vazia, não zero
    }
}

final class PartialSensorUpdateTests: XCTestCase {
    func r(_ key: String, _ kind: SensorKind, _ role: SensorRole, _ v: Double?) -> SensorReading {
        SensorValidator.reading(SensorDescriptor(key: key, name: key, kind: kind, role: role, source: .smc), raw: v, at: 1)
    }

    func testCollectorsDoNotOverwriteEachOther() {
        let store = MetricsStore(clock: ManualClock())
        store.updateSensors(timestamp: 1, owner: "temperatures", readings: [r("Tp01", .temperature, .cpuPerformanceZone, 50), r("Tp02", .temperature, .cpuPerformanceZone, 60)])
        store.updateSensors(timestamp: 2, owner: "sensorList", readings: [r("PSTR", .power, .systemTotal, 12)])
        store.updateSensors(timestamp: 3, owner: "fans", fans: [FanReading(index: 0, rpm: 1500, minRPM: 1200, maxRPM: 6000, mode: .automatic, timestamp: 3)])
        let s = store.sensors!
        XCTAssertEqual(s.readings.count, 3)
        XCTAssertEqual(s.fans.count, 1)
        XCTAssertEqual(s.aggregates.first { $0.descriptor.key == "avg-cpu" }?.value, 55)
        XCTAssertEqual(store.series(.fan(0)).latest?.v, 1500)
        // nova leitura do dono "temperatures" substitui só as dele
        store.updateSensors(timestamp: 4, owner: "temperatures", readings: [r("Tp01", .temperature, .cpuPerformanceZone, 70)])
        XCTAssertEqual(store.sensors!.readings.count, 2)
        XCTAssertEqual(store.sensors!.readings.first { $0.descriptor.key == "PSTR" }?.value, 12)
        XCTAssertEqual(store.sensors!.fans.count, 1)
        // dono pode esvaziar suas leituras
        store.updateSensors(timestamp: 5, owner: "temperatures", readings: [])
        XCTAssertEqual(store.sensors!.readings.map(\.descriptor.key), ["PSTR"])
    }
}
