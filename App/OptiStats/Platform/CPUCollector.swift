import Foundation
import Darwin
import OptiStatsCore

/// CPU por `host_processor_info` (contadores por núcleo). A primeira leitura é só linha de base (não publica).
final class CPUCollector: BaseCollector {
    private let calculator = CPULoadCalculator()
    private let topology: CoreTopology?

    init(store: MetricsStore, clock: MonotonicClock, topology: CoreTopology?) {
        self.topology = topology
        super.init(id: .cpu, store: store, clock: clock)
    }

    override func collect() {
        guard let ticks = Self.readTicks() else { markFailed(L("platform.reason.cpuFailed")); return }
        let now = clock.now
        guard let load = calculator.update(ticks: ticks, at: now) else { return }   // linha de base

        var clusters: [ClusterUsage] = []
        if let topo = topology, topo.hasTrustedClasses {
            for (cls, usage) in topo.usage(perCore: load.perCore) {
                clusters.append(ClusterUsage(coreClass: cls, usage: usage, cpuCount: topo.classes[cls]?.count ?? 0))
            }
        }
        var avg = [Double](repeating: 0, count: 3)
        let loadAvg: LoadAverage? = getloadavg(&avg, 3) == 3 ? LoadAverage(one: avg[0], five: avg[1], fifteen: avg[2]) : nil
        store.publish(cpu: CPUSnapshot(load: load, loadAverage: loadAvg, clusters: clusters,
                                       thermal: thermalLevel(ProcessInfo.processInfo.thermalState)))
        markAvailable()
    }

    override func suspend() { calculator.reset() }

    static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard r == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        var out: [CPUTicks] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[stride * i + Int(state)]) }
            out.append(CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return out
    }
}
