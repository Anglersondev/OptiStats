import XCTest
@testable import OptiStatsCore

final class SamplingPolicyTests: XCTestCase {
    let policy = SamplingPolicy()

    func testBalancedTableMatchesSpecStartingPoints() {
        let c = SamplingConfiguration(profile: .balanced)
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .bar, config: c), 3)
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .popover, config: c), 1)
        XCTAssertEqual(policy.interval(for: .memory, visibility: .bar, config: c), 5)
        XCTAssertEqual(policy.interval(for: .memory, visibility: .popover, config: c), 2)
        XCTAssertEqual(policy.interval(for: .temperatures, visibility: .bar, config: c), 20)
        XCTAssertEqual(policy.interval(for: .power, visibility: .popover, config: c), 3)
        XCTAssertEqual(policy.interval(for: .battery, visibility: .bar, config: c), 20)
    }

    func testOnDemandCollectorsDoNotRunInTheBar() {
        for p in [SamplingProfile.economy, .balanced, .realtime] {
            let c = SamplingConfiguration(profile: p)
            XCTAssertNil(policy.interval(for: .processes, visibility: .bar, config: c))
            XCTAssertNil(policy.interval(for: .sensorList, visibility: .bar, config: c))
            XCTAssertNotNil(policy.interval(for: .processes, visibility: .popover, config: c))
        }
    }

    func testHiddenNeverSamples() {
        for id in CollectorID.allCases { XCTAssertNil(policy.interval(for: id, visibility: .hidden, config: SamplingConfiguration())) }
    }

    func testProfilesAreMonotonicEconomyToRealtime() {
        for id in CollectorID.allCases {
            for v in [Visibility.bar, .popover] {
                let e = policy.interval(for: id, visibility: v, config: SamplingConfiguration(profile: .economy))
                let b = policy.interval(for: id, visibility: v, config: SamplingConfiguration(profile: .balanced))
                let r = policy.interval(for: id, visibility: v, config: SamplingConfiguration(profile: .realtime))
                if let e, let b, let r { XCTAssertGreaterThanOrEqual(e, b, "\(id)"); XCTAssertGreaterThanOrEqual(b, r, "\(id)") }
            }
        }
    }

    func testLowPowerAndThermalScaling() {
        var c = SamplingConfiguration(profile: .balanced)
        c.power = PowerContext(lowPowerMode: true)
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .bar, config: c), 4.5)            // essencial ×1.5
        XCTAssertEqual(policy.interval(for: .temperatures, visibility: .bar, config: c), 40)    // opcional ×2
        c.power = PowerContext(thermal: .critical)
        XCTAssertNil(policy.interval(for: .temperatures, visibility: .bar, config: c))          // opcional suspenso na barra
        XCTAssertEqual(policy.interval(for: .temperatures, visibility: .popover, config: c), 9) // com painel aberto ainda lê
        XCTAssertEqual(policy.interval(for: .memory, visibility: .bar, config: c), 10)          // essencial ×2
        c.power = PowerContext(lowPowerMode: true, thermal: .serious)
        XCTAssertLessThanOrEqual(policy.interval(for: .temperatures, visibility: .bar, config: c)!, 120)
    }

    func testCustomIntervalsAreCoercedToAllowedValues() {
        var c = SamplingConfiguration(profile: .custom)
        c.custom[.temperatures] = ModuleIntervals(background: .seconds(1), visible: .seconds(1))
        XCTAssertEqual(policy.interval(for: .temperatures, visibility: .popover, config: c), 2)  // 1 s não é permitido para sensores
        XCTAssertEqual(policy.interval(for: .temperatures, visibility: .bar, config: c), 2)
        c.custom[.cpu] = ModuleIntervals(background: .seconds(7), visible: .automatic)
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .bar, config: c), 10)              // 7 → próximo permitido
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .popover, config: c), 1)           // automático = tabela equilibrada
        // Fora do perfil .custom, as sobreposições são ignoradas.
        var b = SamplingConfiguration(profile: .balanced); b.custom = c.custom
        XCTAssertEqual(policy.interval(for: .cpu, visibility: .bar, config: b), 3)
    }

    func testAllowedIntervalOptionsRespectRiskAndCost() {
        XCTAssertTrue(AllowedIntervals.options(for: .cpu).contains(1))
        XCTAssertFalse(AllowedIntervals.options(for: .temperatures).contains(1))
        XCTAssertFalse(AllowedIntervals.options(for: .battery).contains(1))
        XCTAssertEqual(AllowedIntervals.coerce(999, for: .cpu), 60)
    }
}

final class SamplingCoordinatorTests: XCTestCase {
    func testNoDemandNoTimerNoReads() {
        let (coord, sched, _) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        XCTAssertNil(sched.pendingDeadline)
        XCTAssertEqual(cpu.collectCount, 0)
        XCTAssertNil(coord.effectiveInterval(for: .cpu))
    }

    func testBarDemandSamplesImmediatelyThenEveryThreeSeconds() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "widget.cpu", collector: .cpu, visibility: .bar)
        XCTAssertEqual(sched.pendingDeadline, clock.now)
        XCTAssertTrue(sched.fire(clock: clock)); XCTAssertEqual(cpu.collectCount, 1)
        XCTAssertEqual(sched.pendingDeadline!, clock.now + 3, accuracy: 0.001)
        sched.fire(clock: clock); XCTAssertEqual(cpu.collectCount, 2)
        sched.fire(clock: clock); XCTAssertEqual(cpu.collectCount, 3)
    }

    func testOpeningPopoverSpeedsUpAndClosingSlowsDownWithoutDuplicateTimers() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "widget.cpu", collector: .cpu, visibility: .bar)
        sched.fire(clock: clock)
        clock.advance(by: 1.2)
        coord.setDemand(consumer: "popover.cpu", collector: .cpu, visibility: .popover)
        XCTAssertEqual(coord.effectiveInterval(for: .cpu), 1)
        XCTAssertLessThanOrEqual(sched.pendingDeadline!, clock.now + 0.001)                    // leitura quase imediata (>1 s da última)
        sched.fire(clock: clock); XCTAssertEqual(cpu.collectCount, 2)
        coord.setDemand(consumer: "popover.cpu", collector: .cpu, visibility: nil)             // fechou o popover
        XCTAssertEqual(coord.effectiveInterval(for: .cpu), 3)
        XCTAssertEqual(sched.pendingDeadline!, clock.now + 3, accuracy: 0.05)
    }

    func testMultipleConsumersShareOneRead() {
        let (coord, sched, clock) = makeCoordinator()
        let mem = FakeCollector(.memory); coord.register(mem)
        coord.setDemand(consumer: "widget.ram", collector: .memory, visibility: .bar)
        coord.setDemand(consumer: "alerts", collector: .memory, visibility: .bar)
        coord.setDemand(consumer: "combined", collector: .memory, visibility: .bar)
        sched.fire(clock: clock)
        XCTAssertEqual(mem.collectCount, 1)
    }

    func testRemovingLastDemandSuspendsCollectorAndCancelsTimer() {
        let (coord, sched, clock) = makeCoordinator()
        let gpu = FakeCollector(.gpu); coord.register(gpu)
        coord.setDemand(consumer: "w", collector: .gpu, visibility: .bar)
        sched.fire(clock: clock)
        coord.setDemand(consumer: "w", collector: .gpu, visibility: nil)
        XCTAssertEqual(gpu.suspendCount, 1)
        XCTAssertNil(sched.pendingDeadline)
        XCTAssertNil(coord.effectiveInterval(for: .gpu))
    }

    func testNearbyDeadlinesAreCoalescedIntoOneWakeup() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu), mem = FakeCollector(.memory)
        coord.register(cpu); coord.register(mem)
        coord.setDemand(consumer: "a", collector: .cpu, visibility: .bar)       // 3 s
        clock.advance(by: 0.2)
        coord.setDemand(consumer: "b", collector: .memory, visibility: .bar)    // 5 s
        let before = coord.wakeupCount
        sched.fire(clock: clock)
        XCTAssertEqual(coord.wakeupCount, before + 1)
        XCTAssertEqual(cpu.collectCount + mem.collectCount, 2)                  // os dois leram no mesmo despertar (janela de coalescência)
    }

    func testNeverOverlapsAReadStillRunning() {
        let exec = ManualExecutor()
        let (coord, sched, clock) = makeCoordinator(executor: { _ in exec })
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "w", collector: .cpu, visibility: .popover)   // 1 s
        sched.fire(clock: clock)
        XCTAssertEqual(exec.queue.count, 1)
        clock.advance(by: 1.5)
        sched.fire(clock: clock)                                                // leitura anterior ainda não terminou
        XCTAssertEqual(exec.queue.count, 1)
        exec.runAll()
        XCTAssertEqual(cpu.collectCount, 1)
        XCTAssertTrue(coord.stats()[.cpu]!.runs == 1)
    }

    func testStalledCollectorIsFlagged() {
        let exec = ManualExecutor()
        let (coord, sched, clock) = makeCoordinator(executor: { _ in exec })
        coord.register(FakeCollector(.sensorList))
        coord.setDemand(consumer: "w", collector: .sensorList, visibility: .popover)
        sched.fire(clock: clock)
        XCTAssertFalse(coord.stats()[.sensorList]!.isStalled)
        clock.advance(by: 30)
        XCTAssertTrue(coord.stats()[.sensorList]!.isStalled)
    }

    func testManualRefreshIsRateLimited() {
        let (coord, _, clock) = makeCoordinator()
        let proc = FakeCollector(.processes); coord.register(proc)
        XCTAssertTrue(coord.refreshNow(.processes)); XCTAssertEqual(proc.collectCount, 1)
        XCTAssertFalse(coord.refreshNow(.processes)); XCTAssertEqual(proc.collectCount, 1)
        clock.advance(by: 1.1)
        XCTAssertTrue(coord.refreshNow(.processes)); XCTAssertEqual(proc.collectCount, 2)
        XCTAssertFalse(coord.refreshNow(.fans))                                // não registrado
    }

    func testProfileChangeAppliesImmediatelyWithSingleTimer() {
        let (coord, sched, clock) = makeCoordinator()
        let t = FakeCollector(.temperatures); coord.register(t)
        coord.setDemand(consumer: "w", collector: .temperatures, visibility: .bar)
        sched.fire(clock: clock)
        XCTAssertEqual(coord.effectiveInterval(for: .temperatures), 20)
        coord.setConfiguration(SamplingConfiguration(profile: .economy))
        XCTAssertEqual(coord.effectiveInterval(for: .temperatures), 30)
        XCTAssertEqual(sched.pendingDeadline!, clock.now + 30, accuracy: 0.05)
        coord.setConfiguration(SamplingConfiguration(profile: .realtime))
        XCTAssertEqual(coord.effectiveInterval(for: .temperatures), 10)
        XCTAssertEqual(sched.pendingDeadline!, clock.now + 10, accuracy: 0.05)
    }

    func testPauseCancelsEverythingAndResumeRestartsWithSettleDelay() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "w", collector: .cpu, visibility: .bar)
        sched.fire(clock: clock)
        coord.pause()
        XCTAssertNil(sched.pendingDeadline)
        XCTAssertEqual(cpu.suspendCount, 1)                                    // baseline descartada
        XCTAssertFalse(coord.refreshNow(.cpu))
        clock.advance(by: 3600)
        coord.resume(settleDelay: 2)
        XCTAssertEqual(sched.pendingDeadline!, clock.now + 2, accuracy: 0.001)
        sched.fire(clock: clock)
        XCTAssertEqual(cpu.collectCount, 2)
    }

    func testLowPowerModeStretchesIntervalsLive() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "w", collector: .cpu, visibility: .bar)
        sched.fire(clock: clock)
        var cfg = SamplingConfiguration(); cfg.power.lowPowerMode = true
        coord.setConfiguration(cfg)
        XCTAssertEqual(coord.effectiveInterval(for: .cpu), 4.5)
    }

    func testStatsReportReadsPerMinute() {
        let (coord, sched, clock) = makeCoordinator()
        let cpu = FakeCollector(.cpu); coord.register(cpu)
        coord.setDemand(consumer: "w", collector: .cpu, visibility: .bar)
        for _ in 0..<20 { sched.fire(clock: clock) }                           // 20 leituras a cada 3 s = 60 s
        let s = coord.stats()[.cpu]!
        XCTAssertEqual(s.runs, 20)
        XCTAssertGreaterThanOrEqual(s.readsLastMinute, 19)
        XCTAssertTrue(s.isActive)
    }
}
