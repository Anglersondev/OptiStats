import XCTest
@testable import OptiStatsCore

final class CPUTests: XCTestCase {
    func ticks(_ u: UInt32, _ s: UInt32, _ i: UInt32, nice: UInt32 = 0) -> CPUTicks { CPUTicks(user: u, system: s, idle: i, nice: nice) }

    func testFirstSampleIsBaselineNotZero() {
        let c = CPULoadCalculator()
        XCTAssertNil(c.update(ticks: [ticks(10, 5, 100)], at: 0))
    }

    func testDeltaUsageAndSplit() {
        let c = CPULoadCalculator()
        _ = c.update(ticks: [ticks(0, 0, 0), ticks(0, 0, 0)], at: 0)
        let l = c.update(ticks: [ticks(30, 10, 60), ticks(0, 0, 100)], at: 3)!
        XCTAssertEqual(l.perCore[0], 0.40, accuracy: 1e-9)
        XCTAssertEqual(l.perCore[1], 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.total, 0.20, accuracy: 1e-9)
        XCTAssertEqual(l.user, 0.15, accuracy: 1e-9)
        XCTAssertEqual(l.system, 0.05, accuracy: 1e-9)
        XCTAssertEqual(l.idle, 0.80, accuracy: 1e-9)
        XCTAssertEqual(l.user + l.system + l.idle, 1.0, accuracy: 1e-9)
    }

    func testNiceCountsAsUser() {
        let c = CPULoadCalculator()
        _ = c.update(ticks: [ticks(0, 0, 0)], at: 0)
        let l = c.update(ticks: [ticks(0, 0, 50, nice: 50)], at: 1)!
        XCTAssertEqual(l.user, 0.5, accuracy: 1e-9)
        XCTAssertEqual(l.total, 0.5, accuracy: 1e-9)
    }

    func testCounterWraparoundIsHandled() {
        let c = CPULoadCalculator()
        _ = c.update(ticks: [ticks(UInt32.max - 9, 0, UInt32.max - 9)], at: 0)
        let l = c.update(ticks: [ticks(10, 0, 10)], at: 1)!     // +20 ticks cada, atravessando 2^32
        XCTAssertEqual(l.total, 0.5, accuracy: 1e-9)
    }

    func testLongGapDiscardsBaseline() {
        let c = CPULoadCalculator(maxGap: 60)
        _ = c.update(ticks: [ticks(0, 0, 0)], at: 0)
        XCTAssertNil(c.update(ticks: [ticks(500, 0, 500)], at: 3600))   // após repouso: não exibir média de uma hora
        XCTAssertNotNil(c.update(ticks: [ticks(510, 0, 510)], at: 3603))
    }

    func testCoreCountChangeResetsInsteadOfCrashing() {
        let c = CPULoadCalculator()
        _ = c.update(ticks: [ticks(0, 0, 0)], at: 0)
        XCTAssertNil(c.update(ticks: [ticks(1, 1, 1), ticks(1, 1, 1)], at: 1))
    }

    func testProcessCPUCanExceedOneCoreAndIgnoresRecycledPIDs() {
        let calc = ProcessCPUCalculator()
        let a = ProcessIdentity(pid: 10, startTime: 1), b = ProcessIdentity(pid: 11, startTime: 1)
        XCTAssertTrue(calc.update(cpuTimeNs: [a: 0, b: 0], at: 0).isEmpty)
        let new = ProcessIdentity(pid: 12, startTime: 5)
        let r = calc.update(cpuTimeNs: [a: 5_000_000_000, b: 1_000_000_000, new: 9], at: 2)
        XCTAssertEqual(r.map(\.identity), [a, b])                         // processo novo não tem delta
        XCTAssertEqual(r[0].coresBusy, 2.5, accuracy: 1e-9)               // 250% de um núcleo
        XCTAssertEqual(ProcessCPUCalculator.normalizedToMachine(coresBusy: 2.5, logicalCPUs: 14), 2.5 / 14, accuracy: 1e-9)
        // mesmo PID, outro start time => outra identidade, sem delta falso
        let reused = ProcessIdentity(pid: 10, startTime: 99)
        XCTAssertTrue(calc.update(cpuTimeNs: [reused: 7], at: 4).isEmpty)
    }

    func testMachTimebaseConversion() {
        let tb = MachTimebase(numer: 125, denom: 3)            // razão típica de Apple Silicon
        XCTAssertEqual(tb.nanoseconds(24_000_000), 1_000_000_000)
        XCTAssertEqual(MachTimebase(numer: 1, denom: 1).nanoseconds(123), 123)
        XCTAssertGreaterThan(tb.nanoseconds(UInt64.max / 1000), 0)   // sem overflow trap
    }
}

final class ChipTests: XCTestCase {
    func testParsesKnownAndFutureChips() {
        XCTAssertEqual(ChipFamily.parse(brand: "Apple M1")?.generation, 1)
        XCTAssertEqual(ChipFamily.parse(brand: "Apple M4 Pro")?.tier, .pro)
        XCTAssertEqual(ChipFamily.parse(brand: "Apple M2 Ultra")?.tier, .ultra)
        XCTAssertEqual(ChipFamily.parse(brand: "Apple M6 Max")?.generation, 6)
        let future = ChipFamily.parse(brand: "Apple M9")!
        XCTAssertEqual(future.generation, 9); XCTAssertFalse(future.isKnownGeneration)
        XCTAssertNil(ChipFamily.parse(brand: "Intel(R) Core(TM) i9-9980HK"))
        XCTAssertNil(ChipFamily.parse(brand: ""))
    }
}

final class TopologyTests: XCTestCase {
    func nodes(_ spec: [String]) -> [CPUNode] { spec.enumerated().map { CPUNode(logicalIndex: $0.offset, clusterType: $0.element) } }

    func testVerifiedTopologyForTenPlusFour() {
        // 14 núcleos: a ordem NÃO é presumida — P-cores intercalados de propósito.
        let spec = ["E", "E", "E", "E", "P", "P", "P", "P", "P", "P", "P", "P", "P", "P"]
        let t = CoreTopology.build(logicalCPUCount: 14, physicalCPUCount: 14, nodes: nodes(spec),
                                   perfLevels: [PerfLevel(index: 0, name: "Performance", logicalCPUs: 10),
                                                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 4)])
        XCTAssertEqual(t.confidence, .verified)
        XCTAssertTrue(t.hasTrustedClasses)
        let perCore = (0..<14).map { $0 < 4 ? 0.5 : 0.1 }
        let usage = t.usage(perCore: perCore)
        XCTAssertEqual(usage.map { $0.0.key }, ["E", "P"])
        XCTAssertEqual(usage[0].1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(usage[1].1, 0.1, accuracy: 1e-9)
    }

    func testMismatchedCountsAreUnverifiedAndHideLabels() {
        let spec = ["E", "E", "P", "P", "P", "P", "P", "P"]
        let t = CoreTopology.build(logicalCPUCount: 8, physicalCPUCount: 8, nodes: nodes(spec),
                                   perfLevels: [PerfLevel(index: 0, name: "Performance", logicalCPUs: 4),
                                                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 4)])
        guard case .unverified = t.confidence else { return XCTFail("deveria ser não verificada") }
        XCTAssertTrue(t.usage(perCore: Array(repeating: 0.3, count: 8)).isEmpty)
    }

    func testMissingClusterTypeOrNodesIsUnverified() {
        let levels = [PerfLevel(index: 0, name: "Performance", logicalCPUs: 8)]
        XCTAssertFalse(CoreTopology.build(logicalCPUCount: 8, physicalCPUCount: 8, nodes: [], perfLevels: levels).hasTrustedClasses)
        let partial = (0..<8).map { CPUNode(logicalIndex: $0, clusterType: $0 == 3 ? nil : "P") }
        XCTAssertFalse(CoreTopology.build(logicalCPUCount: 8, physicalCPUCount: 8, nodes: partial, perfLevels: levels).hasTrustedClasses)
        XCTAssertFalse(CoreTopology.build(logicalCPUCount: 8, physicalCPUCount: 8, nodes: nodes(Array(repeating: "P", count: 8)), perfLevels: []).hasTrustedClasses)
    }

    func testThreeClassTopologyForNewerChips() {
        let spec = Array(repeating: "E", count: 6) + Array(repeating: "M", count: 8) + Array(repeating: "P", count: 4)
        let t = CoreTopology.build(logicalCPUCount: 18, physicalCPUCount: 18, nodes: nodes(spec),
                                   perfLevels: [PerfLevel(index: 0, name: "Super", logicalCPUs: 4),
                                                PerfLevel(index: 1, name: "Performance", logicalCPUs: 8),
                                                PerfLevel(index: 2, name: "Efficiency", logicalCPUs: 6)])
        XCTAssertEqual(t.confidence, .verified)
        XCTAssertEqual(t.orderedClasses.map(\.key), ["E", "M", "P"])
    }
}
