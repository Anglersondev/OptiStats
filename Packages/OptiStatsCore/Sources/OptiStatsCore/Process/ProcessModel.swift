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
        mergeOrphanHelpers(order: &order, buckets: &buckets, meta: &meta)
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

extension ProcessGrouper {
    /// Une processos auxiliares SEM `.app` no caminho (ex.: WebContent do Safari, XPC de apps) ao app de que dependem:
    /// 1) pelo PID responsável (`responsiblePID`) quando ele aponta para um membro de um grupo de app;
    /// 2) pelo bundle id prefixado ("com.google.Chrome.helper" → "com.google.Chrome").
    /// Só afeta grupos "proc:" (sem bundle); nunca funde dois apps distintos.
    fileprivate static func mergeOrphanHelpers(order: inout [String], buckets: inout [String: [ProcessSample]],
                                               meta: inout [String: (name: String, bundlePath: String?, system: Bool)]) {
        var appKeyByPID: [Int32: String] = [:]
        var appKeyByBundleID: [String: String] = [:]
        for key in order where key.hasPrefix("app:") {
            for m in buckets[key] ?? [] {
                appKeyByPID[m.identity.pid] = key
                if let b = m.bundleIdentifier, appKeyByBundleID[b] == nil { appKeyByBundleID[b] = key }
            }
        }
        guard !appKeyByPID.isEmpty else { return }
        // Prefixos mais longos primeiro, para não casar "com.google" antes de "com.google.Chrome".
        let bundleIDs = appKeyByBundleID.keys.sorted { $0.count > $1.count }
        var removed = Set<String>()
        for key in order where key.hasPrefix("proc:") {
            guard let samples = buckets[key] else { continue }
            var remaining: [ProcessSample] = []
            for s in samples {
                var target: String?
                if let r = s.responsiblePID, r != s.identity.pid, let k = appKeyByPID[r] { target = k }
                if target == nil, let id = s.bundleIdentifier,
                   let owner = bundleIDs.first(where: { id.hasPrefix($0 + ".") && $0.split(separator: ".").count >= 3 }) {
                    target = appKeyByBundleID[owner]
                }
                if let t = target { buckets[t, default: []].append(s) } else { remaining.append(s) }
            }
            if remaining.isEmpty { removed.insert(key); buckets[key] = nil; meta[key] = nil } else { buckets[key] = remaining }
        }
        order.removeAll { removed.contains($0) }
    }

    /// Papel do processo dentro de um app com muitos processos (só para exibição).
    public enum ChildRole: String, Equatable { case renderer, gpu, network, plugin, helper, main }

    public static func childRole(of sample: ProcessSample) -> ChildRole {
        let n = sample.name.lowercased()
        if n.contains("renderer") || n.contains("webcontent") || n.contains("web content") { return .renderer }
        if n.contains("(gpu)") || n.hasSuffix(" gpu") || n.contains("gpu helper") || n.contains("gpu process") { return .gpu }
        if n.contains("network") { return .network }
        if n.contains("plugin") || n.contains("extension") { return .plugin }
        if n.contains("helper") { return .helper }
        return .main
    }

    /// Processos do grupo mais pesados primeiro (somente exibição; nada aqui encerra processos).
    public static func heaviestMembers(of group: AppGroup, limit: Int) -> [ProcessSample] {
        guard limit > 0 else { return [] }
        let sorted = group.members.sorted {
            let a = $0.footprintBytes ?? 0, b = $1.footprintBytes ?? 0
            return a != b ? a > b : $0.identity.pid < $1.identity.pid
        }
        return Array(sorted.prefix(limit))
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }
}
