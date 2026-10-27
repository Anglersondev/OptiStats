import Foundation
import Darwin
import OptiStatsCore

/// Leitura de processos via libproc (proc_listpids / proc_pidinfo / proc_pid_rusage). Somente leitura.
enum ProcReader {
    static let pathBufferSize = 4 * 1024   // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN

    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func startTime(_ info: proc_bsdinfo) -> TimeInterval {
        TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }

    static func startTime(pid: pid_t) -> TimeInterval? { bsdInfo(pid).map(startTime) }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: pathBufferSize)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// nil quando o sistema nega a leitura (processos de outros usuários/root sem privilégio).
    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? ru : nil
    }
}

final class ProcessCollector: BaseCollector {
    private struct StaticInfo {
        var name: String
        var path: String?
        var bundleID: String?
        var uid: UInt32
        var groupName: String
    }

    private var cache: [ProcessIdentity: StaticInfo] = [:]
    private var bundleIDs: [String: String?] = [:]
    private var cpuCalc = ProcessCPUCalculator()
    private let timebase = Sys.machTimebase
    private let maxGroups = 60
    private let maxCPUEntries = 20

    init(store: MetricsStore, clock: MonotonicClock) { super.init(id: .processes, store: store, clock: clock) }

    override func collect() {
        let now = clock.now
        let pids = ProcReader.allPIDs()
        guard !pids.isEmpty else { markFailed(L("platform.reason.processesFailed")); return }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        var cpuNs: [ProcessIdentity: UInt64] = [:]
        var seen: Set<ProcessIdentity> = []
        var denied = 0

        for pid in pids {
            guard let bsd = ProcReader.bsdInfo(pid) else { continue }
            let identity = ProcessIdentity(pid: pid, startTime: ProcReader.startTime(bsd))
            seen.insert(identity)
            let info = cache[identity] ?? makeStaticInfo(pid: pid, bsd: bsd)
            cache[identity] = info

            guard let ru = ProcReader.rusage(pid) else { denied += 1; continue }
            let ns = timebase.nanoseconds(ru.ri_user_time &+ ru.ri_system_time)
            cpuNs[identity] = ns
            samples.append(ProcessSample(identity: identity, name: info.name, executablePath: info.path,
                                         bundleIdentifier: info.bundleID, uid: info.uid,
                                         footprintBytes: ru.ri_phys_footprint, residentBytes: ru.ri_resident_size,
                                         cpuTimeNs: ns, responsiblePID: nil))
        }
        cache = cache.filter { seen.contains($0.key) }

        let groups = Array(ProcessGrouper.group(samples).prefix(maxGroups))
        let cpuEntries: [ProcessCPUEntry] = cpuCalc.update(cpuTimeNs: cpuNs, at: now)
            .prefix(maxCPUEntries)
            .compactMap { r in
                guard r.coresBusy > 0.001, let info = cache[r.identity] else { return nil }
                return ProcessCPUEntry(identity: r.identity, name: info.name, groupName: info.groupName, coresBusy: r.coresBusy)
            }
        store.publish(processes: ProcessListSnapshot(timestamp: now, byMemory: groups, byCPU: cpuEntries,
                                                     permissionLimited: denied > 0))
        markAvailable()
    }

    override func suspend() {
        cpuCalc = ProcessCPUCalculator()
        cache.removeAll(keepingCapacity: false)
        bundleIDs.removeAll()
    }

    private func makeStaticInfo(pid: pid_t, bsd: proc_bsdinfo) -> StaticInfo {
        let path = ProcReader.path(pid)
        let name = ProcReader.name(pid)
            ?? path.map { ($0 as NSString).lastPathComponent }
            ?? "pid \(pid)"
        var bundleID: String?
        var group = name
        if let bundle = ProcessGrouper.outermostAppBundlePath(from: path) {
            group = ProcessGrouper.appName(fromBundlePath: bundle)
            if let cached = bundleIDs[bundle] {
                bundleID = cached
            } else {
                bundleID = Bundle(path: bundle)?.bundleIdentifier
                bundleIDs[bundle] = bundleID
            }
        }
        return StaticInfo(name: name, path: path, bundleID: bundleID, uid: bsd.pbi_uid, groupName: group)
    }
}
