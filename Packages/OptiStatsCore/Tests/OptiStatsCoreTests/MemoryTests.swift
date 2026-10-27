import XCTest
@testable import OptiStatsCore

final class MemoryTests: XCTestCase {
    /// Fixture SINTÉTICO coerente com a captura do Stats informada pelo usuário
    /// (70%, 16,72 GB usados = 11,3 apps + 2,77 wired + 2,65 comprimidos, total 24 GB). Não é medição.
    func vmFixture() -> VMStatistics {
        VMStatistics(pageSize: 16384, freeCount: 100_000, activeCount: 500_000, inactiveCount: 300_000,
                     speculativeCount: 10_000, wireCount: 181_534, compressorPageCount: 173_670,
                     purgeableCount: 20_000, externalPageCount: 250_000, internalPageCount: 760_557,
                     swapIns: 10, swapOuts: 20, pageIns: 100, pageOuts: 50, compressions: 1000, decompressions: 900)
    }

    func testActivityMonitorStyleFormulaMatchesScreenshotShape() {
        let s = MemoryFormula.snapshot(from: vmFixture(), totalBytes: 24 * GiB,
                                       swap: SwapUsage(totalBytes: 0, usedBytes: 0, freeBytes: 0),
                                       pressure: .normal, timestamp: 1)
        func gib(_ b: UInt64) -> Double { Double(b) / Double(GiB) }
        XCTAssertEqual(gib(s.appBytes), 11.3, accuracy: 0.01)
        XCTAssertEqual(gib(s.wiredBytes), 2.77, accuracy: 0.01)
        XCTAssertEqual(gib(s.compressedBytes), 2.65, accuracy: 0.01)
        XCTAssertEqual(s.usedBytes, s.appBytes + s.wiredBytes + s.compressedBytes)
        XCTAssertEqual(gib(s.usedBytes), 16.72, accuracy: 0.02)
        XCTAssertEqual(s.usedFraction, 0.70, accuracy: 0.005)
        XCTAssertEqual(s.availableBytes, s.totalBytes - s.usedBytes)
        XCTAssertEqual(gib(s.availableBytes), 7.28, accuracy: 0.02)
        XCTAssertEqual(ByteFormat.percent(s.usedFraction), "70%")
    }

    func testStrictFreeAndCachedAreSeparateFromAvailable() {
        let s = MemoryFormula.snapshot(from: vmFixture(), totalBytes: 24 * GiB, swap: nil, pressure: .normal, timestamp: 1)
        XCTAssertEqual(s.freeStrictBytes, (100_000 - 10_000) * 16384)         // free − speculative
        XCTAssertEqual(s.cachedFilesBytes, (250_000 + 20_000) * 16384)        // external + purgeable
        XCTAssertLessThan(s.freeStrictBytes, s.availableBytes)
    }

    func testAlternativeFormulaIsKeptForReconciliation() {
        let s = MemoryFormula.snapshot(from: vmFixture(), totalBytes: 24 * GiB, swap: nil, pressure: nil, timestamp: 1)
        let expected = (500_000 + 300_000 + 10_000 + 181_534 + 173_670 - 20_000 - 250_000) * UInt64(16384)
        XCTAssertEqual(s.alternativeUsedBytes, expected)
    }

    func testSaturatingSubtractionNeverUnderflows() {
        var vm = vmFixture()
        vm.purgeableCount = vm.internalPageCount + 5      // inconsistência momentânea
        vm.freeCount = 1; vm.speculativeCount = 50
        let s = MemoryFormula.snapshot(from: vm, totalBytes: 1 * GiB, swap: nil, pressure: nil, timestamp: 0)
        XCTAssertEqual(s.appBytes, 0)
        XCTAssertEqual(s.freeStrictBytes, 0)
        XCTAssertLessThanOrEqual(s.usedFraction, 1)
    }

    func testZeroTotalGivesZeroFractionNotNaN() {
        let s = MemoryFormula.snapshot(from: vmFixture(), totalBytes: 0, swap: nil, pressure: nil, timestamp: 0)
        XCTAssertEqual(s.usedFraction, 0)
    }

    func testPressureMapping() {
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(kernelValue: 4), .critical)
        XCTAssertNil(MemoryPressureLevel(kernelValue: 3))
        XCTAssertEqual(PressureBand(.warning), .attention)
        XCTAssertEqual(PressureBand(nil), .unknown)
        XCTAssertTrue(MemoryPressureLevel.critical > .warning)
    }

    func testRatesHandleCounterResetAndZeroDelta() {
        let a = memorySnapshot(t: 0, swapOuts: 100)
        var b = memorySnapshot(t: 10, swapOuts: 600)
        XCTAssertEqual(MemoryRates.between(a, b)?.swapOutsPerSecond, 50)
        b.counters.swapOuts = 10   // contador reiniciou
        XCTAssertEqual(MemoryRates.between(a, b)?.swapOutsPerSecond, 0)
        XCTAssertNil(MemoryRates.between(a, memorySnapshot(t: 0)))
    }
}

final class ByteFormatTests: XCTestCase {
    func testBinaryAndDecimalUnits() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ByteFormat.string(0, locale: en), "0 B")
        XCTAssertEqual(ByteFormat.string(1536, locale: en), "1.50 KB")
        XCTAssertEqual(ByteFormat.string(UInt64(16.72 * Double(GiB)), locale: en), "16.7 GB")
        XCTAssertEqual(ByteFormat.string(1_000_000_000, style: .decimal, locale: en), "1.00 GB")
    }
    func testPortugueseUsesDecimalComma() {
        let pt = Locale(identifier: "pt_BR")
        XCTAssertEqual(ByteFormat.string(UInt64(2.5 * Double(GiB)), locale: pt), "2,50 GB")
        XCTAssertEqual(ByteFormat.percent(0.704, decimals: 1, locale: pt), "70,4%")
    }
    func testInvalidRatesRenderDash() {
        XCTAssertEqual(ByteFormat.rate(.nan), "—")
        XCTAssertEqual(ByteFormat.rate(-1), "—")
        XCTAssertEqual(ByteFormat.percent(.infinity), "—")
    }
}

final class SeriesTests: XCTestCase {
    func testRingBufferOverwritesOldest() {
        var r = RingBuffer<Int>(capacity: 3)
        (1...5).forEach { r.append($0) }
        XCTAssertEqual(r.elements, [3, 4, 5])
        XCTAssertEqual(r.first, 3); XCTAssertEqual(r.last, 5)
        r.dropOldest(while: { $0 < 5 })
        XCTAssertEqual(r.elements, [5])
        r.removeAll(); XCTAssertTrue(r.isEmpty)
    }
    func testTimeSeriesRetentionAndNaNDiscard() {
        var s = TimeSeries(capacity: 100, retention: 10)
        for t in 0..<30 { s.append(t: TimeInterval(t), v: Double(t)) }
        s.append(t: 30, v: .nan)
        XCTAssertEqual(s.all.first?.t, 19)                    // janela de 10 s (inclusiva) até t=29
        XCTAssertEqual(s.latest?.v, 29)                       // NaN descartado, não virou zero
        XCTAssertEqual(s.average(since: 25), 27)
        XCTAssertEqual(s.maximum(since: 0), 29)
    }
    func testCapacityBoundsMemory() {
        var s = TimeSeries(capacity: 50, retention: 10_000)
        for t in 0..<1000 { s.append(t: TimeInterval(t), v: 1) }
        XCTAssertEqual(s.count, 50)
    }
    func testDownsamplingKeepsMeanAndLimit() {
        var s = TimeSeries(capacity: 1000, retention: 10_000)
        for t in 0..<400 { s.append(t: TimeInterval(t), v: t < 200 ? 0 : 100) }
        let d = s.downsampled(since: 0, maxPoints: 40)
        XCTAssertEqual(d.count, 40)
        XCTAssertEqual(d.first?.v, 0); XCTAssertEqual(d.last?.v, 100)
    }
}
