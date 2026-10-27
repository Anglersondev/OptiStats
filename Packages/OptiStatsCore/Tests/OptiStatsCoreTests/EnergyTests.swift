import XCTest
@testable import OptiStatsCore

final class EnergyTests: XCTestCase {
    func testConstantPowerIntegratesToWattHours() {
        let e = EnergyIntegrator(maxGap: 5)
        for t in 0...3600 { e.add(watts: 10, at: TimeInterval(t)) }
        XCTAssertEqual(e.accumulator.wattHours, 10.0, accuracy: 1e-6)         // 10 W × 1 h
        XCTAssertEqual(e.accumulator.coverage, 1.0, accuracy: 1e-9)
    }

    func testGapsAreNotInterpolated() {
        let e = EnergyIntegrator(maxGap: 5)
        e.add(watts: 10, at: 0); e.add(watts: 10, at: 3)
        e.add(watts: 10, at: 603)                                              // 10 min sem leitura (ex.: repouso)
        e.add(watts: 10, at: 606)
        XCTAssertEqual(e.accumulator.wattHours, 10.0 * 6 / 3600, accuracy: 1e-9)
        XCTAssertEqual(e.accumulator.gapCount, 1)
        XCTAssertLessThan(e.accumulator.coverage, 0.05)
    }

    func testInvalidSamplesBreakContinuity() {
        let e = EnergyIntegrator(maxGap: 5)
        e.add(watts: 10, at: 0)
        e.add(watts: nil, at: 1)
        e.add(watts: .nan, at: 2)
        e.add(watts: -3, at: 3)
        e.add(watts: 10, at: 4)                                                // nova linha de base; nada integrado
        XCTAssertEqual(e.accumulator.wattHours, 0, accuracy: 1e-12)
        e.add(watts: 10, at: 5)
        XCTAssertEqual(e.accumulator.wattHours, 10.0 / 3600, accuracy: 1e-9)
    }

    func testTrapezoidAndDiscontinuity() {
        let e = EnergyIntegrator(maxGap: 5)
        e.add(watts: 0, at: 0); e.add(watts: 20, at: 2)
        XCTAssertEqual(e.accumulator.wattHours, 10.0 * 2 / 3600, accuracy: 1e-9)
        e.markDiscontinuity()
        e.add(watts: 100, at: 3)
        XCTAssertEqual(e.accumulator.wattHours, 10.0 * 2 / 3600, accuracy: 1e-9)   // 3 s após a descontinuidade não integra
    }

    func testMovingAverageWindow() {
        var m = MovingAverage(window: 10)
        for t in 0..<30 { m.add(Double(t), at: TimeInterval(t)) }
        XCTAssertEqual(m.value!, 24.0, accuracy: 1e-9)                          // t ∈ [19, 29]
        m.add(.nan, at: 31); XCTAssertNotNil(m.value)
    }

    func testCounterRateBaselineResetAndGap() {
        let c = CounterRate(maxGap: 30)
        XCTAssertNil(c.update(1000, at: 0))                                    // linha de base, não 0
        XCTAssertEqual(c.update(3000, at: 2)!, 1000, accuracy: 1e-9)
        XCTAssertNil(c.update(10, at: 4))                                      // contador voltou: descarta
        XCTAssertEqual(c.update(110, at: 6)!, 50, accuracy: 1e-9)
        XCTAssertNil(c.update(5000, at: 600))                                  // após lacuna longa
    }
}
