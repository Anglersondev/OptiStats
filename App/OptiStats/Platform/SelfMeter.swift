import Foundation
import Darwin
import OptiStatsCore

/// Autoconsumo do próprio app (pegada de memória, RSS, CPU média desde a última chamada, threads).
final class MacSelfMeter: SelfUsageMeasuring {
    private let lock = NSLock()
    private var lastCPU: Double?          // segundos de CPU acumulados (user + system)
    private var lastWall: TimeInterval?

    func measure() -> SelfUsage {
        var usage = SelfUsage()

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            usage.footprintBytes = UInt64(info.phys_footprint)
            usage.residentBytes = UInt64(info.resident_size)
        }

        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
            usage.threadCount = Int(threadCount)
            for i in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride))
        }

        var ru = rusage()
        if getrusage(RUSAGE_SELF, &ru) == 0 {
            let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
            let wall = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            lock.lock()
            if let c = lastCPU, let w = lastWall, wall > w, cpu >= c {
                usage.cpuPercentSinceLastCall = (cpu - c) / (wall - w) * 100
            }
            lastCPU = cpu; lastWall = wall
            lock.unlock()
        }
        return usage
    }
}
