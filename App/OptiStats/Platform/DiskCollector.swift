import Foundation
import IOKit
import OptiStatsCore

/// Disco: capacidade por volume (FileManager) + taxa de leitura/escrita pelos contadores cumulativos do IOBlockStorageDriver.
final class DiskCollector: BaseCollector {
    private let readRate = CounterRate()
    private let writeRate = CounterRate()

    init(store: MetricsStore, clock: MonotonicClock) { super.init(id: .disk, store: store, clock: clock) }

    override func collect() {
        let now = clock.now
        let volumes = Self.volumes()
        let (rd, wr) = Self.ioCounters()
        let readBps = rd.flatMap { readRate.update($0, at: now) }
        let writeBps = wr.flatMap { writeRate.update($0, at: now) }
        if volumes.isEmpty && rd == nil { markUnsupported("platform.reason.noDisk"); return }
        store.publish(disk: DiskSnapshot(timestamp: now, volumes: volumes,
                                         readBytesPerSecond: readBps, writeBytesPerSecond: writeBps))
        markAvailable()
    }

    override func suspend() { readRate.reset(); writeRate.reset() }

    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsRemovableKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for url in urls {
            let path = url.path
            // Só o volume de dados raiz e volumes montados pelo usuário (evita os volumes técnicos do APFS).
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal ?? true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            out.append(VolumeInfo(id: path, name: v.volumeName ?? url.lastPathComponent,
                                  totalBytes: UInt64(total), availableBytes: UInt64(max(0, available)),
                                  isInternal: v.volumeIsInternal ?? false, isRemovable: v.volumeIsRemovable ?? false))
        }
        return out
    }

    /// Soma dos bytes lidos/escritos de todos os drivers de armazenamento em bloco. nil se nenhum expõe estatísticas.
    static func ioCounters() -> (read: UInt64?, write: UInt64?) {
        var read: UInt64 = 0, write: UInt64 = 0, any = false
        IOReg.forEachService(matching: "IOBlockStorageDriver") { entry in
            guard let props = IOReg.properties(of: entry),
                  let stats = props["Statistics"] as? [String: Any] else { return }
            if let r = stats["Bytes (Read)"] as? NSNumber, let w = stats["Bytes (Write)"] as? NSNumber {
                read &+= r.uint64Value; write &+= w.uint64Value; any = true
            }
        }
        return any ? (read, write) : (nil, nil)
    }
}
