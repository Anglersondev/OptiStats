import Foundation

/// Identidade forte: PID + horário de início, para não agir sobre um PID reciclado.
public struct ProcessIdentity: Hashable, Codable {
    public var pid: Int32
    /// Segundos desde 1970 (de `pbi_start_tvsec` + microssegundos).
    public var startTime: TimeInterval
    public init(pid: Int32, startTime: TimeInterval) { self.pid = pid; self.startTime = startTime }
}

public struct ProcessSample: Equatable {
    public var identity: ProcessIdentity
    public var name: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var uid: UInt32
    /// `ri_phys_footprint` (proc_pid_rusage). nil quando o sistema negar leitura.
    public var footprintBytes: UInt64?
    public var residentBytes: UInt64?
    public var cpuTimeNs: UInt64?
    /// PID responsável (API privada, opcional). Usado só como pista de agrupamento.
    public var responsiblePID: Int32?

    public init(identity: ProcessIdentity, name: String, executablePath: String? = nil,
                bundleIdentifier: String? = nil, uid: UInt32 = 501, footprintBytes: UInt64? = nil,
                residentBytes: UInt64? = nil, cpuTimeNs: UInt64? = nil, responsiblePID: Int32? = nil) {
        self.identity = identity; self.name = name; self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier; self.uid = uid; self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes; self.cpuTimeNs = cpuTimeNs; self.responsiblePID = responsiblePID
    }
}

/// Aplicativo (com todos os seus processos auxiliares) para exibição e análise.
public struct AppGroup: Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var bundlePath: String?
    public var bundleIdentifier: String?
    /// Processo principal (o do `.app` mais externo), usado para pedir encerramento normal.
    public var leader: ProcessIdentity?
    public var members: [ProcessSample]
    public var footprintBytes: UInt64 { members.reduce(0) { $0 + ($1.footprintBytes ?? 0) } }
    public var processCount: Int { members.count }
    public var isSystemOwned: Bool
}

public enum ProcessGrouper {
    /// Caminho do `.app` MAIS EXTERNO em um caminho de executável.
    /// "/Applications/Brave Browser.app/Contents/Frameworks/…/Brave Browser Helper.app/Contents/MacOS/x"
    /// → "/Applications/Brave Browser.app"
    public static func outermostAppBundlePath(from executablePath: String?) -> String? {
        guard let p = executablePath, let range = p.range(of: ".app/") ?? (p.hasSuffix(".app") ? p.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(p[p.startIndex..<range.upperBound]).trimmingSuffix("/")
    }

    public static func appName(fromBundlePath path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    public static func isSystemPath(_ path: String?) -> Bool {
        guard let p = path else { return false }
        // Apps do usuário que vêm com o macOS (Safari, Mail, Notas…) ficam em /System/Applications:
        // não são "de sistema" para fins de proteção rígida.
        if p.hasPrefix("/System/Applications/") { return false }
        return p.hasPrefix("/System/") || p.hasPrefix("/usr/") || p.hasPrefix("/sbin/") || p.hasPrefix("/bin/")
            || p.hasPrefix("/Library/Apple/") || p.hasPrefix("/private/var/db/")
    }

    public static func group(_ samples: [ProcessSample]) -> [AppGroup] {
        var order: [String] = []
        var buckets: [String: [ProcessSample]] = [:]
        var meta: [String: (name: String, bundlePath: String?, system: Bool)] = [:]
        for s in samples {
            let bundle = outermostAppBundlePath(from: s.executablePath)
            let key: String
            let name: String
            if let b = bundle {
                key = "app:" + b; name = appName(fromBundlePath: b)
            } else {
                key = "proc:" + s.name; name = s.name
            }
            if buckets[key] == nil {
                order.append(key)
                meta[key] = (name, bundle, isSystemPath(s.executablePath) || s.uid == 0)
            }
            buckets[key, default: []].append(s)
        }
        return order.map { key in
            let members = buckets[key]!
            let m = meta[key]!
            // O líder é o processo cujo executável está diretamente em <app>/Contents/MacOS/.
            let leader = members.first(where: { s in
                guard let b = m.bundlePath, let p = s.executablePath else { return false }
                return p.hasPrefix(b + "/Contents/MacOS/")
            })?.identity
            let bundleID = members.compactMap(\.bundleIdentifier).first
            return AppGroup(id: key, displayName: m.name, bundlePath: m.bundlePath, bundleIdentifier: bundleID,
                            leader: leader, members: members, isSystemOwned: m.system)
        }.sorted { $0.footprintBytes > $1.footprintBytes }
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }
}
