import Foundation
import OptiStatsCore

/// Implementação real de `FileSystemProviding` sobre FileManager.
/// Feita para rodar SEMPRE fora da main: a varredura recursiva pode demorar. Cancelável via `CancelToken`.
/// Não segue links simbólicos (um link conta 0 bytes) e ignora o que o sistema negar ler.
final class DiskFileSystem: FileSystemProviding {
    private let fm = FileManager()
    private let token: CancelToken?

    init(cancelToken: CancelToken? = nil) { self.token = cancelToken }

    private var cancelled: Bool { token?.isCancelled ?? false }

    func children(of path: String) -> [String] {
        guard !cancelled, let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.map { (path as NSString).appendingPathComponent($0) }
    }

    func isSymbolicLink(_ path: String) -> Bool {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        return v?.isSymbolicLink ?? false
    }

    func allocatedBytes(at path: String) -> UInt64 {
        if cancelled { return 0 }
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if top.isSymbolicLink == true { return 0 }
        if top.isDirectory != true { return Self.size(of: top) }

        // Enumerator não segue links simbólicos de diretório; entradas que são link são ignoradas abaixo.
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        var n = 0
        for case let child as URL in en {
            n += 1
            if n & 0xFF == 0, cancelled { return total }
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            total += Self.size(of: v)
        }
        return total
    }

    private static func size(of v: URLResourceValues) -> UInt64 {
        if let t = v.totalFileAllocatedSize { return UInt64(max(0, t)) }
        if let a = v.fileAllocatedSize { return UInt64(max(0, a)) }
        return 0
    }
}

/// Espaço do volume principal (do usuário). Valores nil quando o sistema não informar.
struct VolumeSpace {
    let available: UInt64?
    let total: UInt64?

    static func read(path: String = NSHomeDirectory()) -> VolumeSpace {
        let url = URL(fileURLWithPath: path)
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let avail = v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let total = v?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        return VolumeSpace(available: avail, total: total)
    }
}
