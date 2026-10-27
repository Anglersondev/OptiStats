import Foundation
import IOKit
import OptiStatsCore

/// Identificação do Mac: chip, memória, topologia de núcleos (sysctl hw.perflevelN + cluster-type do IORegistry).
enum SystemProfileReader {
    static func read(smc: SMCReader) -> SystemProfile {
        let brand = Sys.string("machdep.cpu.brand_string") ?? ""
        let logical = Sys.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let physical = Sys.int("hw.physicalcpu") ?? logical
        let gpu = gpuInfo()

        var topology: CoreTopology?
        if ChipFamily.parse(brand: brand) != nil {
            topology = CoreTopology.build(logicalCPUCount: logical, physicalCPUCount: physical,
                                          nodes: cpuNodes(), perfLevels: perfLevels())
        }

        var fanCount: Int?
        if smc.hasKey("FNum"), let n = smc.read("FNum"), n >= 0, n < 16 { fanCount = Int(n) }

        return SystemProfile(
            chip: ChipFamily.parse(brand: brand),
            modelIdentifier: Sys.string("hw.model"),
            marketingModel: marketingModel(),
            totalMemoryBytes: Sys.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
            logicalCPUs: logical, physicalCPUs: physical, topology: topology,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            fanCount: fanCount, gpuName: gpu.name, gpuCores: gpu.cores)
    }

    static func perfLevels() -> [PerfLevel] {
        guard let n = Sys.int("hw.nperflevels"), n > 0, n < 16 else { return [] }
        var levels: [PerfLevel] = []
        for i in 0..<n {
            guard let count = Sys.int("hw.perflevel\(i).logicalcpu") else { continue }
            levels.append(PerfLevel(index: i, name: Sys.string("hw.perflevel\(i).name") ?? "perflevel\(i)", logicalCPUs: count))
        }
        return levels
    }

    /// Nós `cpuN` de `IODeviceTree:/cpus` com `cluster-type`. Se algo faltar, a topologia fica "unverified" no Core.
    static func cpuNodes() -> [CPUNode] {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, "IODeviceTree", &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var nodes: [CPUNode] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(child, &nameBuf)
            let name = String(decoding: nameBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("cpu"), let byName = Int(name.dropFirst(3)) {
                var index = byName
                if let d = IOReg.property(of: child, key: "logical-cpu-id") as? Data, d.count >= 4 {
                    index = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                }
                let cluster = IOReg.string(from: IOReg.property(of: child, key: "cluster-type"))
                nodes.append(CPUNode(logicalIndex: index, clusterType: cluster))
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return nodes.sorted { $0.logicalIndex < $1.logicalIndex }
    }

    static func marketingModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IOReg.string(from: IOReg.property(of: service, key: "product-name"))
            ?? IOReg.string(from: IOReg.property(of: service, key: "model"))
    }

    static func gpuInfo() -> (name: String?, cores: Int?) {
        var name: String?, cores: Int?
        IOReg.forEachService(matching: "IOAccelerator") { entry in
            guard name == nil, let p = IOReg.properties(of: entry) else { return }
            name = IOReg.string(from: p["model"])
            cores = (p["gpu-core-count"] as? NSNumber)?.intValue
        }
        return (name, cores)
    }
}
