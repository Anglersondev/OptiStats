import XCTest
@testable import OptiStatsCore

final class PreferencesTests: XCTestCase {
    func testDefaultsAreLightAndSafe() {
        let p = Preferences().normalized()
        XCTAssertEqual(p.monitoringMode, .essential)
        XCTAssertEqual(p.activeWidgets().map(\.kind), [.ram, .cpu])
        XCTAssertFalse(p.persistHistory)
        XCTAssertFalse(p.smartBoostRequested)
        XCTAssertFalse(p.memory.alertsEnabled)
        XCTAssertEqual(p.profileOnAC, .balanced)
        XCTAssertEqual(p.effectiveProfile(onBattery: true), .economy)
        XCTAssertEqual(p.menuBar.widgets.first { $0.kind == .disk }?.enabled, false)
        XCTAssertEqual(p.menuBar.widgets.first { $0.kind == .network }?.enabled, false)
    }

    func testEssentialModeDisablesExpensiveWidgetsEvenIfEnabled() {
        var p = Preferences()
        for i in p.menuBar.widgets.indices { p.menuBar.widgets[i].enabled = true }
        XCTAssertEqual(Set(p.normalized().activeWidgets().map(\.kind)), [.ram, .cpu])
        p.monitoringMode = .full
        XCTAssertEqual(p.normalized().activeWidgets().count, WidgetKind.allCases.count)
    }

    func testNormalizationRepairsInvalidValues() {
        var p = Preferences()
        p.menuBar.widgets = [WidgetConfig(kind: .cpu, enabled: true, decimals: 9), WidgetConfig(kind: .cpu, enabled: false)]
        p.menuBar.combinedKinds = [.cpu, .cpu, .ram, .gpu, .disk]
        p.customIntervals[.temperatures] = ModuleIntervals(background: .seconds(1), visible: .seconds(3))
        p.historyMinutes = 77; p.smartBoostRequested = true; p.memory.processesShown = 500
        let n = p.normalized()
        XCTAssertEqual(n.menuBar.widgets.count, WidgetKind.allCases.count)
        XCTAssertEqual(n.menuBar.widgets.first?.decimals, 2)
        XCTAssertEqual(n.menuBar.combinedKinds, [.cpu, .ram, .gpu])
        XCTAssertEqual(n.customIntervals[.temperatures], ModuleIntervals(background: .seconds(2), visible: .seconds(3)))
        XCTAssertEqual(n.historyMinutes, 10)
        XCTAssertFalse(n.smartBoostRequested)
        XCTAssertEqual(n.memory.processesShown, 20)
        XCTAssertEqual(n.normalized(), n)                                          // idempotente
    }

    func testRoundTripThroughStorage() {
        let storage = InMemoryStorage()
        let store = PreferencesStore(storage: storage)
        XCTAssertTrue(store.update { $0.language = .ptBR; $0.monitoringMode = .full; $0.memory.userProtectedBundleIDs = ["a.b"] })
        let reloaded = PreferencesStore(storage: storage).current
        XCTAssertEqual(reloaded.language, .ptBR)
        XCTAssertEqual(reloaded.monitoringMode, .full)
        XCTAssertEqual(reloaded.memory.userProtectedBundleIDs, ["a.b"])
    }

    func testToleratesMissingUnknownAndCorruptData() {
        let partial = InMemoryStorage()
        partial.set(#"{"language":"en","futureField":123,"monitoringMode":"bogus"}"#.data(using: .utf8), forKey: PreferencesStore.storageKey)
        let s = PreferencesStore(storage: partial)
        XCTAssertEqual(s.current.language, .en)
        XCTAssertEqual(s.current.monitoringMode, .essential)                      // valor inválido → padrão
        XCTAssertFalse(s.lastLoadWasRecovery)

        let corrupt = InMemoryStorage()
        corrupt.set(Data([0xFF, 0x00, 0x13]), forKey: PreferencesStore.storageKey)
        let c = PreferencesStore(storage: corrupt)
        XCTAssertTrue(c.lastLoadWasRecovery)
        XCTAssertEqual(c.current, Preferences().normalized())
    }

    func testResetAndRestoreBalanced() {
        let store = PreferencesStore(storage: InMemoryStorage())
        store.update { $0.profileOnAC = .realtime; $0.customIntervals[.cpu] = ModuleIntervals(background: .seconds(10)); $0.language = .en }
        store.restoreBalancedProfile()
        XCTAssertEqual(store.current.profileOnAC, .balanced)
        XCTAssertTrue(store.current.customIntervals.isEmpty)
        XCTAssertEqual(store.current.language, .en)                                // o resto é preservado
        store.resetToDefaults()
        XCTAssertEqual(store.current.language, .system)
    }

    func testWidgetCollectorsAreMinimal() {
        XCTAssertEqual(WidgetKind.ram.collectors, [.memory])
        XCTAssertEqual(WidgetKind.cpu.collectors, [.cpu])
        XCTAssertEqual(WidgetKind.temperature.collectors, [.temperatures])
        XCTAssertFalse(WidgetKind.temperature.isEssential)
    }
}

final class VisibleKindsTests: XCTestCase {
    func testCombinedModeUsesCombinedKindsAndRespectsEssentialMode() {
        var p = Preferences()
        p.menuBar.combined = true
        p.menuBar.combinedKinds = [.cpu, .ram, .temperature]
        XCTAssertEqual(p.normalized().visibleKinds(), [.cpu, .ram])
        p.monitoringMode = .full
        XCTAssertEqual(p.normalized().visibleKinds(), [.cpu, .ram, .temperature])
        p.menuBar.combined = false
        XCTAssertEqual(p.normalized().visibleKinds(), [.ram, .cpu])
    }
}
