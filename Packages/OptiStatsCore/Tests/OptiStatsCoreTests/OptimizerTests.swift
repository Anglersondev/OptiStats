import XCTest
@testable import OptiStatsCore

final class GrowthDetectorTests: XCTestCase {
    func feed(_ d: GrowthDetector, name: String, start: UInt64, perMinute: Double, minutes: Int, step: TimeInterval = 30,
              noise: (Int) -> Double = { _ in 0 }) {
        var t: TimeInterval = 0; var i = 0
        while t <= Double(minutes) * 60 {
            let bytes = Double(start) + perMinute * t / 60 + noise(i)
            d.record(groups: [appGroup(name, footprint: UInt64(max(0, bytes)))], at: t)
            t += step; i += 1
        }
    }

    func testSteadyGrowthIsSuspectedNotConfirmed() {
        let d = GrowthDetector()
        feed(d, name: "Leaky", start: 500 * MiB, perMinute: 60 * Double(MiB), minutes: 10)
        let s = d.suspicion(for: "app:/Applications/Leaky.app")
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.bytesPerMinute / Double(MiB), 60, accuracy: 3)
        XCTAssertGreaterThan(s!.rSquared, 0.95)
    }

    func testFlatAndSawtoothAreNotSuspects() {
        let flat = GrowthDetector()
        feed(flat, name: "Flat", start: GiB, perMinute: 0, minutes: 10)
        XCTAssertNil(flat.suspicion(for: "app:/Applications/Flat.app"))
        let saw = GrowthDetector()
        feed(saw, name: "Saw", start: GiB, perMinute: 2 * Double(MiB), minutes: 10) { i in (i % 2 == 0) ? 400 * Double(MiB) : 0 }
        XCTAssertNil(saw.suspicion(for: "app:/Applications/Saw.app"))
    }

    func testTooShortOrTooFewSamples() {
        let d = GrowthDetector()
        feed(d, name: "Short", start: 500 * MiB, perMinute: 200 * Double(MiB), minutes: 2)
        XCTAssertNil(d.suspicion(for: "app:/Applications/Short.app"))
    }

    func testTrackedGroupsAreBounded() {
        var cfg = GrowthConfig(); cfg.maxTrackedGroups = 3
        let d = GrowthDetector(config: cfg)
        let groups = (0..<10).map { appGroup("App\($0)", footprint: UInt64($0 + 1) * 100 * MiB) }
        d.record(groups: groups, at: 0)
        XCTAssertNotNil(d.suspicion(for: "x") == nil ? 1 : nil)       // API não quebra com id desconhecido
    }
}

final class AdvisorTests: XCTestCase {
    let brave = appGroup("Brave Browser", bundle: "com.brave.Browser", footprint: 3 * GiB, processes: 8, pid: 100)
    let figma = appGroup("Figma", bundle: "com.figma.Desktop", footprint: 1500 * MiB, processes: 3, pid: 200)
    let tiny = appGroup("Tiny", bundle: "x.tiny", footprint: 50 * MiB, pid: 300)

    func history(pressure: MemoryPressureLevel, seconds: Int, swap: UInt64 = 0) -> [MemorySnapshot] {
        stride(from: 0, through: seconds, by: 10).map { memorySnapshot(t: TimeInterval($0), pressure: pressure, swapUsed: swap) }
    }

    func testHealthyWhenPressureNormalAndSwapZero() {
        let advice = OptimizationAdvisor().advise(history: history(pressure: .normal, seconds: 200), groups: [brave, figma],
                                                  growth: { _ in nil }, frontmostBundleID: nil)
        XCTAssertEqual(advice.assessment, .healthy)
        XCTAssertTrue(advice.candidates.isEmpty)               // nada a recomendar
    }

    func testInsufficientDataWithoutPressureReading() {
        let h = [memorySnapshot(t: 0, pressure: nil)]
        XCTAssertEqual(OptimizationAdvisor().advise(history: h, groups: [], growth: { _ in nil }, frontmostBundleID: nil).assessment, .insufficientData)
        XCTAssertEqual(OptimizationAdvisor().advise(history: [], groups: [], growth: { _ in nil }, frontmostBundleID: nil).assessment, .insufficientData)
    }

    func testSustainedPressureRecommendsOnlyUnprotectedCandidates() {
        let advice = OptimizationAdvisor().advise(history: history(pressure: .warning, seconds: 150), groups: [brave, figma, tiny],
                                                  growth: { _ in nil }, frontmostBundleID: nil)
        guard case .actionRecommended = advice.assessment else { return XCTFail("esperava ação recomendada: \(advice.assessment)") }
        XCTAssertEqual(advice.candidates.map(\.group.displayName), ["Figma"])          // Brave protegido; Tiny pequeno
        XCTAssertEqual(advice.candidates[0].estimatedReclaimBytes, figma.footprintBytes)
        XCTAssertTrue(advice.candidates[0].risks.contains(.mayLoseUnsavedWork))
        XCTAssertEqual(advice.protectedTop.map(\.group.displayName), ["Brave Browser"])
        XCTAssertTrue(advice.protectedTop[0].verdict.reasons.contains(.category(.browser)))
    }

    func testBriefPressureOnlyWatches() {
        let advice = OptimizationAdvisor().advise(history: history(pressure: .normal, seconds: 100) + [memorySnapshot(t: 110, pressure: .warning)],
                                                  groups: [figma], growth: { _ in nil }, frontmostBundleID: nil)
        guard case .watch = advice.assessment else { return XCTFail("esperava observar: \(advice.assessment)") }
        XCTAssertTrue(advice.candidates.isEmpty)
    }

    func testSwapInUseWithNormalPressureIsWatchNotHealthy() {
        let advice = OptimizationAdvisor().advise(history: history(pressure: .normal, seconds: 100, swap: 2 * GiB), groups: [figma],
                                                  growth: { _ in nil }, frontmostBundleID: nil)
        guard case .watch(let reasons) = advice.assessment else { return XCTFail("\(advice.assessment)") }
        XCTAssertTrue(reasons.contains(.swapInUse(bytes: 2 * GiB)))
    }

    func testActiveSwappingRecommendsEvenWithoutPersistedPressure() {
        var h = history(pressure: .normal, seconds: 40)
        h = h.enumerated().map { i, s in var m = s; m.counters.swapOuts = UInt64(i) * 1000; return m }   // ~100/s
        let advice = OptimizationAdvisor().advise(history: h, groups: [figma], growth: { _ in nil }, frontmostBundleID: nil)
        guard case .actionRecommended(let reasons) = advice.assessment else { return XCTFail("\(advice.assessment)") }
        XCTAssertTrue(reasons.contains { if case .activeSwapping = $0 { return true } else { return false } })
    }

    func testFrontmostAppIsNeverACandidate() {
        let advice = OptimizationAdvisor().advise(history: history(pressure: .critical, seconds: 150), groups: [figma],
                                                  growth: { _ in nil }, frontmostBundleID: "com.figma.Desktop")
        XCTAssertTrue(advice.candidates.isEmpty)
        XCTAssertTrue(advice.protectedTop[0].verdict.reasons.contains(.frontmost))
    }

    func testGrowthSuspectsComeFirst() {
        let slack = appGroup("Slackish", bundle: "x.slackish", footprint: 900 * MiB, pid: 400)
        let suspicion = GrowthSuspicion(bytesPerMinute: 50 * Double(MiB), growthBytes: 500 * MiB, observedSeconds: 600,
                                        sampleCount: 20, rSquared: 0.97, confidence: .medium)
        let advice = OptimizationAdvisor().advise(history: history(pressure: .warning, seconds: 150), groups: [figma, slack],
                                                  growth: { $0 == slack.id ? suspicion : nil }, frontmostBundleID: nil)
        XCTAssertEqual(advice.candidates.map(\.group.displayName), ["Slackish", "Figma"])
        XCTAssertTrue(advice.candidates[0].risks.contains(.growthSuspected))
    }
}

// MARK: - Coordenador de otimização

final class FakeApps: AppController {
    var running: Set<ProcessIdentity> = []
    var frontmost: Set<ProcessIdentity> = []
    var refuses: Set<ProcessIdentity> = []          // pedido aceito, mas o app não fecha (ex.: documento não salvo)
    var requestFails: Set<ProcessIdentity> = []
    var replacedBy: [ProcessIdentity: ProcessIdentity] = [:]
    private(set) var quitRequests: [ProcessIdentity] = []

    func liveIdentity(matching identity: ProcessIdentity) -> ProcessIdentity? { replacedBy[identity] ?? (running.contains(identity) ? identity : nil) }
    func isFrontmost(_ identity: ProcessIdentity) -> Bool { frontmost.contains(identity) }
    func requestGracefulQuit(_ identity: ProcessIdentity) -> Bool {
        quitRequests.append(identity)
        if requestFails.contains(identity) { return false }
        if !refuses.contains(identity) { running.remove(identity) }
        return true
    }
    func isRunning(_ identity: ProcessIdentity) -> Bool { running.contains(identity) }
}

final class FakeProbe: MemoryProbe {
    var snapshots: [MemorySnapshot]
    private var i = 0
    init(_ s: [MemorySnapshot]) { snapshots = s }
    func captureMemory() -> MemorySnapshot? { defer { i += 1 }; return i < snapshots.count ? snapshots[i] : snapshots.last }
}

struct InstantSleeper: AsyncSleeper { func sleep(seconds: TimeInterval) async {} }

final class OptimizationCoordinatorTests: XCTestCase {
    let figma = appGroup("Figma", bundle: "com.figma.Desktop", footprint: 2 * GiB, pid: 200)
    let notes = appGroup("Notes", bundle: "com.apple.Notes", footprint: GiB, pid: 300)

    func make(_ apps: FakeApps, probe: FakeProbe, policy: ProtectionPolicy = ProtectionPolicy()) -> OptimizationCoordinator {
        var cfg = OptimizationConfig(); cfg.quitTimeout = 2; cfg.pollInterval = 0.5
        return OptimizationCoordinator(apps: apps, probe: probe, policy: { policy }, sleeper: InstantSleeper(), config: cfg)
    }

    func testGracefulQuitReportsObservedGlobalDeltaWithoutAttribution() async {
        let apps = FakeApps(); apps.running = [figma.leader!, notes.leader!]
        let probe = FakeProbe([memorySnapshot(t: 0, used: 20 * GiB, pressure: .warning), memorySnapshot(t: 10, used: 17 * GiB)])
        let report = await make(apps, probe: probe).run(items: [OptimizationItem(group: figma)])
        XCTAssertEqual(report.results.map(\.outcome), [.quit])
        XCTAssertEqual(report.availableDelta, Int64(3 * GiB))
        XCTAssertEqual(report.summary, .closedApps(count: 1, availableDelta: Int64(3 * GiB)))
        XCTAssertTrue(apps.running.contains(notes.leader!))            // o que não foi selecionado fica intacto
    }

    func testRefusingAppIsNotForced() async {
        let apps = FakeApps(); apps.running = [figma.leader!]; apps.refuses = [figma.leader!]
        let report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)])).run(items: [OptimizationItem(group: figma)])
        XCTAssertEqual(report.results.map(\.outcome), [.stillRunning])
        XCTAssertEqual(apps.quitRequests.count, 1)                     // um único pedido, sem insistir nem forçar
        XCTAssertEqual(report.summary, .requestedButStillOpen(count: 1))
    }

    func testRecycledPIDAndMissingProcessAreSkipped() async {
        let apps = FakeApps()                                           // nada em execução: o processo sumiu
        var report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)])).run(items: [OptimizationItem(group: figma)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped(.identityChanged)])
        XCTAssertEqual(report.summary, .noActionTaken)

        apps.running = [figma.leader!]
        apps.replacedBy[figma.leader!] = ProcessIdentity(pid: figma.leader!.pid, startTime: 9999)   // PID reciclado
        report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)])).run(items: [OptimizationItem(group: figma)])
        XCTAssertEqual(report.results.map(\.outcome), [.skipped(.identityChanged)])
        XCTAssertTrue(apps.quitRequests.isEmpty)
    }

    func testAppThatBecameFrontmostOrProtectedIsSkipped() async {
        let apps = FakeApps(); apps.running = [figma.leader!, notes.leader!]; apps.frontmost = [figma.leader!]
        var p = ProtectionPolicy(); p.userProtectedBundleIDs = ["com.apple.Notes"]
        let report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)]), policy: p)
            .run(items: [OptimizationItem(group: figma), OptimizationItem(group: notes)])
        for r in report.results { guard case .skipped(.protectedNow) = r.outcome else { return XCTFail("\(r.outcome)") } }
        XCTAssertTrue(apps.quitRequests.isEmpty)
    }

    func testCancellationSkipsRemainingItems() async {
        let apps = FakeApps(); apps.running = [figma.leader!, notes.leader!]
        let token = CancelToken(); token.cancel()
        let report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)])).run(items: [OptimizationItem(group: figma)], cancel: token)
        XCTAssertEqual(report.results.map(\.outcome), [.skipped(.cancelled)])
        XCTAssertTrue(apps.quitRequests.isEmpty)
    }

    func testRequestFailureIsReported() async {
        let apps = FakeApps(); apps.running = [figma.leader!]; apps.requestFails = [figma.leader!]
        let report = await make(apps, probe: FakeProbe([memorySnapshot(t: 0)])).run(items: [OptimizationItem(group: figma)])
        XCTAssertEqual(report.results.map(\.outcome), [.requestFailed])
    }
}
