import Foundation
import Darwin
import OptiStatsCore

/// Leitor de memória (host_statistics64 + vm.swapusage + nível de pressão do kernel), usado pelo coletor e pelo `MemoryProbe`.
enum MemoryReader {
    static func capture(timestamp: TimeInterval, totalBytes: UInt64) -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let vm = VMStatistics(
            pageSize: UInt64(getpagesize()),
            freeCount: UInt64(stats.free_count), activeCount: UInt64(stats.active_count),
            inactiveCount: UInt64(stats.inactive_count), speculativeCount: UInt64(stats.speculative_count),
            wireCount: UInt64(stats.wire_count), compressorPageCount: UInt64(stats.compressor_page_count),
            purgeableCount: UInt64(stats.purgeable_count), externalPageCount: UInt64(stats.external_page_count),
            internalPageCount: UInt64(stats.internal_page_count),
            swapIns: stats.swapins, swapOuts: stats.swapouts, pageIns: stats.pageins, pageOuts: stats.pageouts,
            compressions: stats.compressions, decompressions: stats.decompressions)
        return MemoryFormula.snapshot(from: vm, totalBytes: totalBytes, swap: swapUsage(),
                                      pressure: pressureLevel(), timestamp: timestamp)
    }

    static func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used, freeBytes: usage.xsu_avail)
    }

    static func pressureLevel() -> MemoryPressureLevel? {
        guard let v = Sys.int("kern.memorystatus_vm_pressure_level") else { return nil }
        return MemoryPressureLevel(kernelValue: v)
    }
}

final class MemoryCollector: BaseCollector {
    private let totalBytes: UInt64

    init(store: MetricsStore, clock: MonotonicClock, totalBytes: UInt64) {
        self.totalBytes = totalBytes
        super.init(id: .memory, store: store, clock: clock)
    }

    override func collect() {
        guard let snap = MemoryReader.capture(timestamp: clock.now, totalBytes: totalBytes) else {
            markFailed(L("platform.reason.memoryFailed")); return
        }
        store.publish(memory: snap)
        markAvailable()
    }
}

/// Foto de memória sob demanda para o otimizador (antes/depois de encerrar apps).
final class MacMemoryProbe: MemoryProbe {
    private let clock: MonotonicClock
    private let totalBytes: UInt64
    init(clock: MonotonicClock, totalBytes: UInt64) { self.clock = clock; self.totalBytes = totalBytes }
    func captureMemory() -> MemorySnapshot? { MemoryReader.capture(timestamp: clock.now, totalBytes: totalBytes) }
}
