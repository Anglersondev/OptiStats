import XCTest
@testable import OptiStatsCore

final class FanTests: XCTestCase {
    func fan(_ i: Int = 0, rpm: Double?, mode: FanMode = .automatic, min: Double? = 1200, max: Double? = 6000, t: TimeInterval) -> FanReading {
        FanReading(index: i, rpm: rpm, minRPM: min, maxRPM: max, mode: mode, timestamp: t)
    }
    func obs(_ t: TimeInterval, _ fans: [FanReading], healthy: Bool = true, thermal: ThermalLevel = .nominal) -> FanObservation {
        FanObservation(timestamp: t, fans: fans, actuatorHealthy: healthy, thermal: thermal)
    }

    func testPercentOfRangeOnlyWithKnownLimits() {
        XCTAssertEqual(fan(rpm: 3000, t: 0).percentOfRange!, 0.5, accuracy: 1e-9)
        XCTAssertNil(fan(rpm: 3000, min: nil, max: nil, t: 0).percentOfRange)
        XCTAssertNil(fan(rpm: nil, t: 0).percentOfRange)
        XCTAssertNil(fan(rpm: 3000, min: 6000, max: 6000, t: 0).percentOfRange)
    }

    func testUnavailableActuatorOnlyAcceptsRestore() {
        let a = UnavailableFanActuator(reason: "teste")
        XCTAssertEqual(a.apply(.setTarget(rpm: 5000)), .unsupported)
        XCTAssertEqual(a.apply(.heartbeat(ttl: 10)), .unsupported)
        XCTAssertEqual(a.apply(.restoreAutomatic(reason: "x")), .ok)
    }

    // MARK: Smart Boost

    func engagedController() -> (SmartBoostController, TimeInterval) {
        let c = SmartBoostController(); c.enable()
        var t: TimeInterval = 0
        var cmds: [FanCommand] = []
        for _ in 0..<3 { t += 2; cmds = c.step(obs(t, [fan(rpm: 2500, t: t)])) }
        XCTAssertEqual(cmds.first, .setTarget(rpm: 6000))
        return (c, t)
    }

    func testDisabledByDefaultAndNeverCommands() {
        let c = SmartBoostController()
        XCTAssertEqual(c.state, .disabled)
        XCTAssertTrue(c.step(obs(1, [fan(rpm: 6000, t: 1)])).isEmpty)
        XCTAssertEqual(c.state, .disabled)
    }

    func testEngagesOnlyAfterSustainedAppleFanActivity() {
        let c = SmartBoostController(); c.enable()
        XCTAssertTrue(c.step(obs(2, [fan(rpm: 2500, t: 2)])).isEmpty)
        XCTAssertTrue(c.step(obs(4, [fan(rpm: 500, t: 4)])).isEmpty)              // caiu: zera a contagem
        XCTAssertTrue(c.step(obs(6, [fan(rpm: 2500, t: 6)])).isEmpty)
        XCTAssertTrue(c.step(obs(8, [fan(rpm: 2500, t: 8)])).isEmpty)
        let cmds = c.step(obs(10, [fan(rpm: 2500, t: 10)]))
        XCTAssertEqual(cmds.first, .setTarget(rpm: 6000))
        XCTAssertEqual(cmds.last, .heartbeat(ttl: SmartBoostConfig().heartbeatTTL))
    }

    func testTargetNeverBelowAppleFloorAndNeverAboveReportedMax() {
        var cfg = SmartBoostConfig(); cfg.boostFraction = 0.5
        let c = SmartBoostController(config: cfg); c.enable()
        var cmds: [FanCommand] = []
        for i in 1...3 { cmds = c.step(obs(TimeInterval(i * 2), [fan(rpm: 4800, t: TimeInterval(i * 2))])) }
        XCTAssertEqual(cmds.first, .setTarget(rpm: 4800))                          // metade do máx. seria 3000 < piso da Apple
        var cfg2 = SmartBoostConfig(); cfg2.boostFraction = 2.0
        let c2 = SmartBoostController(config: cfg2); c2.enable()
        for i in 1...3 { cmds = c2.step(obs(TimeInterval(i * 2), [fan(rpm: 2500, t: TimeInterval(i * 2))])) }
        XCTAssertEqual(cmds.first, .setTarget(rpm: 6000))                          // limitado ao máximo reportado
    }

    func testDoesNotEngageWithoutLimitsOrWithForeignController() {
        let c = SmartBoostController(); c.enable()
        _ = c.step(obs(2, [fan(rpm: 3000, min: nil, max: nil, t: 2)]))
        XCTAssertEqual(c.state, .faulted(.missingLimits))
        c.acknowledgeFault(); XCTAssertEqual(c.state, .monitoring)
        XCTAssertTrue(c.step(obs(4, [fan(rpm: 3000, mode: .manual, t: 4)])).isEmpty)   // outro app já controla: não escrever
        XCTAssertEqual(c.state, .faulted(.conflictingController))
    }

    func testNoFansFaults() {
        let c = SmartBoostController(); c.enable()
        // Falha sempre devolve o controle ao macOS (restaurar "automático" é inofensivo e o atuador ignora sem ventoinhas).
        XCTAssertEqual(c.step(obs(2, [])), [.restoreAutomatic(reason: "sem ventoinhas detectadas")])
        XCTAssertEqual(c.state, .faulted(.noFans))
    }

    func testHeartbeatWhileBoosting() {
        let (c, t) = engagedController()
        XCTAssertEqual(c.step(obs(t + 2, [fan(rpm: 5800, mode: .manual, t: t + 2)])), [.heartbeat(ttl: 15)])
    }

    func testRestoresOnUnhealthyActuatorStaleDataSleepAndDisable() {
        var (c, t) = engagedController()
        XCTAssertEqual(c.step(obs(t + 2, [fan(rpm: 5800, mode: .manual, t: t + 2)], healthy: false)), [.restoreAutomatic(reason: "atuador indisponível")])
        XCTAssertEqual(c.state, .faulted(.actuatorUnhealthy))

        (c, t) = engagedController()
        XCTAssertEqual(c.step(obs(t + 60, [fan(rpm: 5800, mode: .manual, t: t + 60)])), [.restoreAutomatic(reason: "leituras antigas")])
        XCTAssertEqual(c.state, .faulted(.staleObservation))

        (c, _) = engagedController()
        XCTAssertEqual(c.systemWillSleep(), [.restoreAutomatic(reason: "repouso do sistema")])
        XCTAssertEqual(c.state, .monitoring)

        (c, _) = engagedController()
        XCTAssertEqual(c.disable(reason: "usuário"), [.restoreAutomatic(reason: "usuário")])
        XCTAssertEqual(c.state, .disabled)
        XCTAssertTrue(SmartBoostController().disable().isEmpty)                      // desligar sem boost não escreve nada
    }

    func testUnresponsiveFanFaultsAfterTwoFailures() {
        let (c, t0) = engagedController()
        var t = t0
        var last: [FanCommand] = []
        for _ in 0..<4 {
            t += 5
            last = c.step(obs(t, [fan(rpm: 2500, mode: .manual, t: t)]))             // RPM não subiu
            if case .faulted = c.state { break }
        }
        XCTAssertEqual(c.state, .faulted(.rpmDidNotRespond))
        XCTAssertEqual(last, [.restoreAutomatic(reason: "RPM não respondeu ao comando")])
    }

    func testModeRevertedExternallyIsConflict() {
        let (c, t) = engagedController()
        let cmds = c.step(obs(t + 10, [fan(rpm: 5800, mode: .automatic, t: t + 10)]))
        XCTAssertEqual(c.state, .faulted(.conflictingController))
        XCTAssertEqual(cmds, [.restoreAutomatic(reason: "modo alterado externamente")])
    }

    func testMaxDurationRestoresAndEntersCooldown() {
        var cfg = SmartBoostConfig(); cfg.maxBoostDuration = 60; cfg.probeEvery = 1000
        let c = SmartBoostController(config: cfg); c.enable()
        var t: TimeInterval = 0
        for _ in 0..<3 { t += 2; _ = c.step(obs(t, [fan(rpm: 2500, t: t)])) }
        let start = t
        var cmds: [FanCommand] = []
        while t < start + 70 && cmds.first != .restoreAutomatic(reason: "duração máxima do boost") {
            t += 5; cmds = c.step(obs(t, [fan(rpm: 6000, mode: .manual, t: t)]))
        }
        XCTAssertEqual(cmds, [.restoreAutomatic(reason: "duração máxima do boost")])
        guard case .cooldown = c.state else { return XCTFail("\(c.state)") }
        // Durante o cooldown não volta a escrever, mesmo com ventoinha alta.
        t += 10
        XCTAssertTrue(c.step(obs(t, [fan(rpm: 3000, t: t)])).isEmpty)
    }

    func testCriticalThermalEndsBoost() {
        let (c, t) = engagedController()
        XCTAssertEqual(c.step(obs(t + 2, [fan(rpm: 6000, mode: .manual, t: t + 2)], thermal: .critical)),
                       [.restoreAutomatic(reason: "estado térmico crítico")])
    }

    func testProbeReturnsToAppleThenReleasesWhenMacOSWouldSlowDown() {
        var cfg = SmartBoostConfig(); cfg.probeEvery = 30; cfg.probeDuration = 10; cfg.minChangeInterval = 5
        let c = SmartBoostController(config: cfg); c.enable()
        var t: TimeInterval = 0
        for _ in 0..<3 { t += 2; _ = c.step(obs(t, [fan(rpm: 2500, t: t)])) }
        var probeCmd: [FanCommand] = []
        while probeCmd.isEmpty || probeCmd.first == .heartbeat(ttl: 15) {
            t += 5; probeCmd = c.step(obs(t, [fan(rpm: 6000, mode: .manual, t: t)]))
            XCTAssertLessThan(t, 200)
        }
        XCTAssertEqual(probeCmd, [.restoreAutomatic(reason: "sondagem do comportamento do macOS")])
        guard case .probing(let since) = c.state else { return XCTFail("\(c.state)") }
        // durante a janela de espera nada é comandado
        XCTAssertTrue(c.step(obs(since + 4, [fan(rpm: 4000, t: since + 4)])).isEmpty)
        // macOS baixou a rotação sozinho por 3 amostras → sai do boost
        var r: [FanCommand] = []
        for i in 0..<4 { let tt = since + 11 + Double(i) * 3; r = c.step(obs(tt, [fan(rpm: 700, t: tt)])) }
        XCTAssertTrue(r.isEmpty)
        guard case .cooldown = c.state else { return XCTFail("\(c.state)") }
    }

    func testProbeResumesBoostWhenMacOSStillWantsFans() {
        var cfg = SmartBoostConfig(); cfg.probeEvery = 30; cfg.probeDuration = 10; cfg.minChangeInterval = 5
        let c = SmartBoostController(config: cfg); c.enable()
        var t: TimeInterval = 0
        for _ in 0..<3 { t += 2; _ = c.step(obs(t, [fan(rpm: 2500, t: t)])) }
        var cmds: [FanCommand] = []
        while !(cmds.first == .restoreAutomatic(reason: "sondagem do comportamento do macOS")) {
            t += 5; cmds = c.step(obs(t, [fan(rpm: 6000, mode: .manual, t: t)]))
            XCTAssertLessThan(t, 200)
        }
        t += 11
        cmds = c.step(obs(t, [fan(rpm: 2600, t: t)]))                               // Apple ainda mantém ventoinha ligada
        XCTAssertEqual(cmds.first, .setTarget(rpm: 6000))
        guard case .boosting = c.state else { return XCTFail("\(c.state)") }
    }

    func testFaultedStateRequiresExplicitAcknowledgement() {
        let c = SmartBoostController(); c.enable()
        _ = c.step(obs(1, []))
        XCTAssertEqual(c.state, .faulted(.noFans))
        XCTAssertTrue(c.step(obs(3, [fan(rpm: 3000, t: 3)])).isEmpty)       // preso até o usuário reconhecer
        XCTAssertEqual(c.state, .faulted(.noFans))
    }
}
