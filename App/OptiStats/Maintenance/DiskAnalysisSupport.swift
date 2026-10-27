import Cocoa
import CryptoKit
import OptiStatsCore

/// `FileTreeProviding` real sobre FileManager/URLResourceKeys. Roda SEMPRE fora da main.
/// Não segue links simbólicos, não entra em volumes que não sejam locais e relata diretório sem permissão.
/// O analisador do Core ainda ignora /System e /Volumes.
final class DiskTreeProvider: FileTreeProviding {
    private let fm = FileManager()
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey
    ]
    /// Só pedimos o inode (para não tratar hardlinks como duplicados) a arquivos grandes o bastante.
    private let inodeMinBytes: UInt64

    init(inodeMinBytes: UInt64 = 1 << 20) { self.inodeMinBytes = inodeMinBytes }

    func listing(of path: String) -> DirectoryListing {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            let e = error as NSError
            // 260 = arquivo inexistente (some durante a varredura): não é falta de permissão.
            let missing = e.domain == NSCocoaErrorDomain && e.code == CocoaError.fileReadNoSuchFile.rawValue
            return DirectoryListing(entries: [], permissionDenied: !missing)
        }
        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(Self.keys)) else { continue }
            let full = (path as NSString).appendingPathComponent(u.lastPathComponent)
            if v.isSymbolicLink == true {
                entries.append(FileEntry(path: full, isSymlink: true))
                continue
            }
            if v.isDirectory == true {
                if v.volumeIsLocal == false { continue }      // volume de rede montado dentro da árvore
                entries.append(FileEntry(path: full, isDirectory: true))
                continue
            }
            let bytes = UInt64(max(0, v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0))
            entries.append(FileEntry(path: full, allocatedBytes: bytes, modified: v.contentModificationDate,
                                     accessed: v.contentAccessDate, fileID: bytes >= inodeMinBytes ? Self.inode(full) : nil))
        }
        return DirectoryListing(entries: entries, permissionDenied: false)
    }

    private static func inode(_ path: String) -> UInt64? {
        var st = stat()
        return lstat(path, &st) == 0 ? UInt64(st.st_ino) : nil
    }
}

/// Uso do volume principal: usado / purgável / livre (via URLResourceKey, sem executar nada).
struct VolumeBreakdown {
    let total: UInt64
    let used: UInt64
    let purgeable: UInt64
    let free: UInt64

    static func read(path: String = NSHomeDirectory()) -> VolumeBreakdown? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let raw = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? Int64(raw)))
        let t = UInt64(total)
        let free = min(raw, t)
        let purgeable = important > free ? min(important - free, t - free) : 0
        return VolumeBreakdown(total: t, used: t - free - purgeable, purgeable: purgeable, free: free)
    }
}

/// Hash parcial (início + fim, 64 KiB cada) para o 2º estágio de duplicados. Dá CANDIDATOS, não prova de igualdade.
enum PartialHasher {
    static func hash(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        var sha = SHA256()
        do {
            let size = try h.seekToEnd()
            try h.seek(toOffset: 0)
            if let head = try h.read(upToCount: chunk) { sha.update(data: head) }
            if size > UInt64(chunk * 2) {
                try h.seek(toOffset: size - UInt64(chunk))
                if let tail = try h.read(upToCount: chunk) { sha.update(data: tail) }
            }
        } catch { return nil }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Nomes de apps instalados (para juntar `Caches/<bundle id>` com `Application Support/<Nome>`).
enum InstalledAppCatalog {
    static func options(base: StorageScanOptions) -> StorageScanOptions {
        var o = base
        let fm = FileManager()
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(n)
                guard let info = Bundle(url: url)?.infoDictionary, let id = (info["CFBundleIdentifier"] as? String)?.lowercased() else { continue }
                let fileName = String(n.dropLast(4))
                let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
                o.appDisplayNames[id] = display
                for alias in [fileName, display, info["CFBundleName"] as? String].compactMap({ $0 }) {
                    o.appAliases[alias.lowercased()] = id
                }
            }
        }
        return o
    }
}

/// Snapshots locais do Time Machine: `tmutil listlocalsnapshots /` (somente leitura, sem privilégio).
enum TimeMachineInfo {
    static func localSnapshots() -> [LocalSnapshot] {
        let r = SystemTool.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard r.status == 0 else { return [] }
        return LocalSnapshotParser.parse(r.out)
    }
}

/// Relatório em texto, localizado (o CSV, de formato fixo, vem do Core).
enum DiskReportText {
    static func make(_ a: StorageAnalysis, duplicates: [DuplicateGroup], oldFiles: [FileRecord], volume: VolumeBreakdown?) -> String {
        var out: [String] = []
        let df = DateFormatter(); df.locale = Fmt.locale; df.dateStyle = .medium; df.timeStyle = .short
        out.append(L("maint.disk2.report.title") + " — " + df.string(from: Date()))
        if let v = volume {
            out.append("\(L("maint.disk2.volUsed")): \(Fmt.bytes(v.used))  ·  \(L("maint.disk2.volPurgeable")): \(Fmt.bytes(v.purgeable))  ·  \(L("maint.disk2.volFree")): \(Fmt.bytes(v.free))  ·  \(L("maint.disk.total")): \(Fmt.bytes(v.total))")
        }
        out.append(L("maint.disk2.report.scanned", a.fileCount, Fmt.bytes(a.totalBytes)))
        if a.deniedCount > 0 { out.append(L("maint.disk2.denied", a.deniedCount)) }
        out.append("")
        out.append("== " + L("maint.disk2.sec.folders"))
        for f in a.folders.prefix(40) {
            out.append("\(Fmt.bytes(f.bytes))\t\(Fmt.percent(f.fraction, decimals: 1))\t\(f.path)")
            for c in f.children.prefix(10) { out.append("    \(Fmt.bytes(c.bytes))\t\(c.path)") }
        }
        out.append("")
        out.append("== " + L("maint.disk2.sec.types"))
        for t in a.types { out.append("\(Fmt.bytes(t.bytes))\t\(Fmt.percent(t.fraction, decimals: 1))\t\(L("maint.disk2.kind.\(t.kind.rawValue)"))\t(\(t.fileCount))") }
        out.append("")
        out.append("== " + L("maint.disk2.sec.largest"))
        for r in a.largestFiles(limit: 50) { out.append("\(Fmt.bytes(r.bytes))\t\(r.path)") }
        out.append("")
        out.append("== " + L("maint.disk2.sec.old"))
        for r in oldFiles.prefix(50) { out.append("\(Fmt.bytes(r.bytes))\t\(r.path)") }
        out.append("")
        out.append("== " + L("maint.disk2.sec.duplicates") + "  (" + L("maint.disk2.dup.reclaim", Fmt.bytes(DuplicateFinder.totalReclaimable(duplicates))) + ")")
        for g in duplicates.prefix(30) {
            out.append("\(Fmt.bytes(g.size)) × \(g.paths.count)")
            for p in g.paths { out.append("    \(p)") }
        }
        out.append("")
        out.append("== " + L("maint.disk2.sec.apps"))
        for u in a.apps.prefix(50) { out.append("\(Fmt.bytes(u.total))\t\(u.displayName)") }
        out.append("")
        out.append("== " + L("maint.disk2.dev.title"))
        for d in a.developer {
            out.append("\(Fmt.bytes(d.bytes))\t\(L("maint.disk2.dev.\(d.kind.rawValue)"))\t\(d.isReportOnly ? L("maint.disk2.dev.reportOnly") : "")\t\(d.path)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
