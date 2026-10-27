import XCTest
@testable import OptiStatsCore

final class MetricsStoreTests: XCTestCase {
    func testPublishingPreservesRetainedSnapshotsAndBoundsHistory() {
        let store = MetricsStore(clock: ManualClock(), seriesCapacity: 4, seriesRetention: 100)
        func publish(_ t: Int) {
            store.publish(network: NetworkSnapshot(timestamp: Double(t), interfaces: [],
                                                   rxBytesPerSecond: Double(t), txBytesPerSecond: Double(t * 2)))
        }
        publish(0); publish(1)
        let retained = store.series(.netRx)
        for t in 2..<30 { publish(t) }
        XCTAssertEqual(retained.all.map(\.v), [0, 1])
        XCTAssertEqual(store.series(.netRx).all.map(\.v), [26, 27, 28, 29])
        XCTAssertEqual(store.series(.netTx).all.map(\.v), [52, 54, 56, 58])
        store.clearSeries()
        XCTAssertEqual(store.series(.netRx).count, 0)
        XCTAssertEqual(retained.all.map(\.v), [0, 1])
    }
}
