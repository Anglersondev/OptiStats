import Foundation

// Análise avançada de armazenamento (somente leitura). Tudo aqui é puro e testável sem disco:
// o sistema de arquivos entra por `FileTreeProviding`, o hash por closure e o relógio por parâmetro.
// NADA neste arquivo apaga algo. Remoção de arquivos do usuário só existe via `CleanupCategory.userSelected`
// (um arquivo por vez, com confirmação explícita na UI, validado por `CleanupPolicy.canTrashUserFile`).

// MARK: - Tipos de arquivo

public enum FileKind: String, CaseIterable, Codable {
    case video, image, audio, document, archive, code, app, other

    private static let table: [String: FileKind] = {
        var t: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: [String]) { for e in exts { t[e] = kind } }
        add(.video, ["mp4", "m4v", "mov", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts", "vob", "prproj"])
        add(.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef",
                     "arw", "dng", "psd", "ai", "svg", "ico", "icns"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf", "mid", "midi", "aup"])
        add(.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md",
                        "csv", "odt", "ods", "odp", "epub", "mobi", "tex", "pub"])
        add(.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "dmg", "iso", "img",
                       "cdr", "toast", "pkg", "sparseimage", "cab", "jar"])
        add(.code, ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "go", "rs", "py", "rb", "php",
                    "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm", "json", "xml", "yml", "yaml", "toml", "sh",
                    "zsh", "pl", "lua", "sql", "gradle", "o", "a", "dylib", "class", "pyc", "map", "swiftmodule",
                    "swiftdoc", "xcodeproj", "pbxproj", "plist", "strings", "ipynb", "wasm"])
        add(.app, ["app", "ipa", "apk", "exe", "msi"])
        return t
    }()

    /// `ext` sem ponto, qualquer caixa.
    public static func kind(forExtension ext: String) -> FileKind { table[ext.lowercased()] ?? .other }
}

// MARK: - Árvore de arquivos (abstração)

/// Uma entrada de diretório. Para arquivos `allocatedBytes` é o tamanho alocado; para diretórios é 0
/// (o analisador desce neles). Links simbólicos devem ser marcados e NUNCA são seguidos.
public struct FileEntry: Equatable {
    public let path: String
    public let allocatedBytes: UInt64
    public let modified: Date?
    public let accessed: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// Identificador do arquivo no volume (inode), quando conhecido. Evita contar hardlinks como duplicados.
    public let fileID: UInt64?

    public init(path: String, allocatedBytes: UInt64 = 0, modified: Date? = nil, accessed: Date? = nil,
                isDirectory: Bool = false, isSymlink: Bool = false, fileID: UInt64? = nil) {
        self.path = path; self.allocatedBytes = allocatedBytes; self.modified = modified; self.accessed = accessed
        self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.fileID = fileID
    }

    public var name: String { StoragePath.lastComponent(path) }
    /// Extensão minúscula sem ponto ("" se não houver; ".bashrc" não tem extensão).
    public var fileExtension: String { StoragePath.fileExtension(path) }
}

public struct DirectoryListing: Equatable {
    public var entries: [FileEntry]
    /// Verdadeiro se o sistema negou a leitura do diretório (contado como "sem permissão").
    public var permissionDenied: Bool
    public init(entries: [FileEntry] = [], permissionDenied: Bool = false) {
        self.entries = entries; self.permissionDenied = permissionDenied
    }
}

public protocol FileTreeProviding {
    /// Lista os filhos diretos de `path` (não recursivo). Vazio se não existe.
    func listing(of path: String) -> DirectoryListing
}

public enum StoragePath {
    public static func lastComponent(_ path: String) -> String {
        if let i = path.lastIndex(of: "/") { return String(path[path.index(after: i)...]) }
        return path
    }
    public static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/"), i != path.startIndex else { return "/" }
        return String(path[..<i])
    }
    public static func fileExtension(_ path: String) -> String {
        let name = lastComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

// MARK: - Resultados

public struct FolderUsage: Equatable {
    public let path: String
    public let name: String
    public let bytes: UInt64
    public let fileCount: Int
    public let isDirectory: Bool
    /// Fração do total varrido (0...1).
    public let fraction: Double
    /// Subpastas de nível 2 (vazio nas entradas de nível 2).
    public let children: [FolderUsage]
}

public struct TypeUsage: Equatable {
    public let kind: FileKind
    public let bytes: UInt64
    public let fileCount: Int
    public let fraction: Double
}

/// Arquivo candidato a relatório (grande/antigo). `lastUsed` = o mais recente entre modificação e acesso.
public struct FileRecord: Equatable {
    public let path: String
    public let bytes: UInt64
    public let modified: Date?
    public let accessed: Date?
    public let kind: FileKind
    public var name: String { StoragePath.lastComponent(path) }
    public var lastUsed: Date? {
        switch (modified, accessed) {
        case let (m?, a?): return max(m, a)
        case let (m?, nil): return m
        case let (nil, a?): return a
        default: return nil
        }
    }
}

public enum AppDataKind: String, CaseIterable, Codable { case caches, applicationSupport, containers, logs }

public struct AppUsage: Equatable {
    public let key: String            // id canônico (minúsculo)
    public let displayName: String
    public let caches: UInt64
    public let applicationSupport: UInt64
    public let containers: UInt64
    public let logs: UInt64
    public var total: UInt64 { caches + applicationSupport + containers + logs }
}

public enum DeveloperKind: String, CaseIterable, Codable {
    case xcodeDerivedData, npmCache, dotCache, simulators, docker

    /// Categoria removível da política, quando houver. nil = SOMENTE RELATÓRIO.
    public var cleanupCategory: CleanupCategory? {
        switch self {
        case .xcodeDerivedData: return .xcodeDerivedData
        case .npmCache, .dotCache: return .packageCaches
        case .simulators, .docker: return nil
        }
    }
}

public struct DeveloperUsage: Equatable {
    public let kind: DeveloperKind
    public let path: String
    public let bytes: UInt64
    public var isReportOnly: Bool { kind.cleanupCategory == nil }
}

/// Arquivos com o mesmo tamanho: candidatos a duplicados (ainda sem hash).
public struct DuplicateSizeGroup: Equatable {
    public let size: UInt64
    public let paths: [String]          // ordenados; hardlinks do mesmo arquivo já colapsados
}

public struct StorageAnalysis: Equatable {
    public var totalBytes: UInt64 = 0
    public var fileCount: Int = 0
    /// Diretórios que o sistema negou ler (a UI mostra "N itens sem permissão").
    public var deniedCount: Int = 0
    public var wasCancelled = false
    public var folders: [FolderUsage] = []
    public var types: [TypeUsage] = []
    public var records: [FileRecord] = []           // maiores arquivos de usuário, bytes desc
    public var duplicateCandidates: [DuplicateSizeGroup] = []
    public var apps: [AppUsage] = []
    public var developer: [DeveloperUsage] = []

    public init() {}

    public func largestFiles(limit: Int) -> [FileRecord] { Array(records.prefix(max(0, limit))) }

    /// Arquivos sem modificação NEM acesso há mais de `days` dias e com ao menos `minBytes`. Sem data = não entra.
    public func oldFiles(olderThanDays days: Int, minBytes: UInt64, now: Date) -> [FileRecord] {
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86_400)
        return records.filter { r in
            guard r.bytes >= minBytes, let last = r.lastUsed else { return false }
            return last < cutoff
        }
    }
}

// MARK: - Opções e analisador

public struct StorageScanOptions {
    public var recordLimit = 3000
    public var recordMinBytes: UInt64 = 1 << 20
    public var duplicateMinBytes: UInt64 = 1 << 20
    public var excludedPrefixes: [String] = ["/System", "/Volumes"]
    /// nome de pasta minúsculo (ex.: "slack") -> id canônico minúsculo (ex.: "com.tinyspeck.slackmacgap").
    public var appAliases: [String: String] = [:]
    /// id canônico minúsculo -> nome de exibição.
    public var appDisplayNames: [String: String] = [:]
    public init() {}
}

public struct ScanProgress: Equatable {
    public var files: Int
    public var bytes: UInt64
    public var currentPath: String
}

public struct StorageAnalyzer {
    public let policy: CleanupPolicy
    public let tree: FileTreeProviding
    public let options: StorageScanOptions

    public init(policy: CleanupPolicy, tree: FileTreeProviding, options: StorageScanOptions = StorageScanOptions()) {
        self.policy = policy; self.tree = tree; self.options = options
    }

    private struct AppKey: Hashable { let key: String; let kind: AppDataKind }

    private struct Ctx {
        var l1Path: String?
        var l2Path: String?
        var app: AppKey?
        var dev: DeveloperKind?
        var inBundle = false
        var userSpace = false
    }

    private struct Frame { let path: String; let depth: Int; let ctx: Ctx }

    private struct Acc: Equatable {
        var bytes: UInt64 = 0
        var files = 0
    }

    private var developerRoots: [(DeveloperKind, String)] {
        let home = policy.home
        var out: [(DeveloperKind, String)] = []
        for r in policy.roots(for: .xcodeDerivedData) { out.append((.xcodeDerivedData, r)) }
        for r in policy.roots(for: .packageCaches) {
            out.append((r.hasSuffix("/.cache") ? .dotCache : .npmCache, r))
        }
        out.append((.simulators, home + "/Library/Developer/CoreSimulator"))
        out.append((.docker, home + "/Library/Containers/com.docker.docker"))
        return out
    }

    /// Varre o home. `isCancelled` é consultado a cada diretório; `progress` a cada ~512 arquivos.
    public func analyze(isCancelled: () -> Bool = { false },
                        progress: (ScanProgress) -> Void = { _ in }) -> StorageAnalysis {
        let home = policy.home
        let libraryApps: [String: AppDataKind] = [
            home + "/Library/Caches": .caches, home + "/Library/Application Support": .applicationSupport,
            home + "/Library/Containers": .containers, home + "/Library/Logs": .logs
        ]
        var devByPath: [String: DeveloperKind] = [:]
        for (k, p) in developerRoots { devByPath[p] = k }

        var result = StorageAnalysis()
        var l1: [String: Acc] = [:], l1IsDir: [String: Bool] = [:]
        var l2: [String: Acc] = [:]
        var typeAcc: [FileKind: Acc] = [:]
        var appBytes: [AppKey: UInt64] = [:], appNames: [String: Set<String>] = [:]
        var devBytes: [DeveloperKind: UInt64] = [:]
        var records: [FileRecord] = []
        var sizeMap: [UInt64: [(path: String, id: UInt64?)]] = [:]
        var sinceProgress = 0

        var stack: [Frame] = [Frame(path: home, depth: 0, ctx: Ctx())]
        while let frame = stack.popLast() {
            if isCancelled() { result.wasCancelled = true; break }
            let listing = tree.listing(of: frame.path)
            if listing.permissionDenied { result.deniedCount += 1 }
            for e in listing.entries.sorted(by: { $0.path < $1.path }) {
                if e.isSymlink { continue }                       // nunca segue (nem conta) links
                if options.excludedPrefixes.contains(where: { e.path == $0 || e.path.hasPrefix($0 + "/") }) { continue }
                let name = e.name

                if e.isDirectory {
                    var c = frame.ctx
                    if frame.depth == 0 {
                        c.l1Path = e.path
                        c.userSpace = !name.hasPrefix(".") && name != "Library"
                        if l1[e.path] == nil { l1[e.path] = Acc() }
                        l1IsDir[e.path] = true
                    } else if frame.depth == 1 {
                        c.l2Path = e.path
                        if l2[e.path] == nil { l2[e.path] = Acc() }
                    }
                    if let kind = libraryApps[frame.path] {
                        let lower = name.lowercased()
                        let key = options.appAliases[lower] ?? lower
                        c.app = AppKey(key: key, kind: kind)
                        appNames[key, default: []].insert(name)
                    }
                    if let d = devByPath[e.path] { c.dev = d }
                    if e.fileExtension == "app" { c.inBundle = true }
                    stack.append(Frame(path: e.path, depth: frame.depth + 1, ctx: c))
                    continue
                }

                // Arquivo regular.
                let bytes = e.allocatedBytes
                result.fileCount += 1
                result.totalBytes += bytes
                sinceProgress += 1
                if sinceProgress >= 512 {
                    sinceProgress = 0
                    progress(ScanProgress(files: result.fileCount, bytes: result.totalBytes, currentPath: frame.path))
                }

                var ctx = frame.ctx
                if frame.depth == 0 {                              // arquivo solto no home
                    l1[e.path, default: Acc()].bytes += bytes
                    l1[e.path, default: Acc()].files += 1
                    l1IsDir[e.path] = false
                    ctx.userSpace = !name.hasPrefix(".")
                } else if let p1 = ctx.l1Path {
                    l1[p1, default: Acc()].bytes += bytes
                    l1[p1, default: Acc()].files += 1
                    if let p2 = ctx.l2Path {
                        l2[p2, default: Acc()].bytes += bytes
                        l2[p2, default: Acc()].files += 1
                    }
                }
                let kind: FileKind = ctx.inBundle ? .app : FileKind.kind(forExtension: e.fileExtension)
                typeAcc[kind, default: Acc()].bytes += bytes
                typeAcc[kind, default: Acc()].files += 1
                if let a = ctx.app { appBytes[a, default: 0] += bytes }
                if let d = ctx.dev { devBytes[d, default: 0] += bytes }

                if ctx.userSpace && !ctx.inBundle {
                    if bytes >= options.recordMinBytes {
                        records.append(FileRecord(path: e.path, bytes: bytes, modified: e.modified, accessed: e.accessed, kind: kind))
                        if records.count > options.recordLimit * 2 { records = Self.trimmed(records, to: options.recordLimit) }
                    }
                    if bytes >= options.duplicateMinBytes && bytes > 0 {
                        sizeMap[bytes, default: []].append((e.path, e.fileID))
                    }
                }
            }
        }

        // Pastas
        let total = Double(max(result.totalBytes, 1))
        func usage(_ path: String, _ acc: Acc, isDir: Bool, children: [FolderUsage]) -> FolderUsage {
            FolderUsage(path: path, name: StoragePath.lastComponent(path), bytes: acc.bytes, fileCount: acc.files,
                        isDirectory: isDir, fraction: Double(acc.bytes) / total, children: children)
        }
        var childrenByParent: [String: [FolderUsage]] = [:]
        for (p, acc) in l2 { childrenByParent[StoragePath.parent(p), default: []].append(usage(p, acc, isDir: true, children: [])) }
        result.folders = l1.map { (p, acc) in
            usage(p, acc, isDir: l1IsDir[p] ?? true, children: (childrenByParent[p] ?? []).sorted(by: Self.folderOrder))
        }.sorted(by: Self.folderOrder)

        // Tipos
        result.types = typeAcc.filter { $0.value.bytes > 0 || $0.value.files > 0 }.map {
            TypeUsage(kind: $0.key, bytes: $0.value.bytes, fileCount: $0.value.files, fraction: Double($0.value.bytes) / total)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind.rawValue < $1.kind.rawValue }

        result.records = Self.trimmed(records, to: options.recordLimit)

        // Duplicados (estágio 1: por tamanho; hardlinks colapsados pelo fileID)
        var groups: [DuplicateSizeGroup] = []
        for (size, list) in sizeMap where list.count > 1 {
            var seen = Set<UInt64>(), paths: [String] = []
            for item in list.sorted(by: { $0.path < $1.path }) {
                if let id = item.id { if !seen.insert(id).inserted { continue } }
                paths.append(item.path)
            }
            if paths.count > 1 { groups.append(DuplicateSizeGroup(size: size, paths: paths)) }
        }
        result.duplicateCandidates = groups.sorted {
            let a = $0.size * UInt64($0.paths.count - 1), b = $1.size * UInt64($1.paths.count - 1)
            return a != b ? a > b : $0.paths[0] < $1.paths[0]
        }

        // Apps
        var perApp: [String: [AppDataKind: UInt64]] = [:]
        for (k, b) in appBytes { perApp[k.key, default: [:]][k.kind, default: 0] += b }
        result.apps = perApp.compactMap { key, kinds in
            let u = AppUsage(key: key,
                             displayName: options.appDisplayNames[key] ?? (appNames[key]?.sorted().first ?? key),
                             caches: kinds[.caches] ?? 0, applicationSupport: kinds[.applicationSupport] ?? 0,
                             containers: kinds[.containers] ?? 0, logs: kinds[.logs] ?? 0)
            return u.total > 0 ? u : nil
        }.sorted { $0.total != $1.total ? $0.total > $1.total : $0.key < $1.key }

        // Desenvolvedor
        result.developer = developerRoots.compactMap { kind, path in
            guard let b = devBytes[kind], b > 0 else { return nil }
            return DeveloperUsage(kind: kind, path: path, bytes: b)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }

        return result
    }

    private static func trimmed(_ r: [FileRecord], to n: Int) -> [FileRecord] {
        let sorted = r.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return Array(sorted.prefix(max(0, n)))
    }

    private static func folderOrder(_ a: FolderUsage, _ b: FolderUsage) -> Bool {
        a.bytes != b.bytes ? a.bytes > b.bytes : a.path < b.path
    }
}

// MARK: - Duplicados (estágio 2)

public struct DuplicateGroup: Equatable {
    public let size: UInt64
    public let hash: String
    public let paths: [String]          // ordenados, 2 ou mais

    public init(size: UInt64, hash: String, paths: [String]) { self.size = size; self.hash = hash; self.paths = paths.sorted() }

    /// Grupo sem `path` (já movido para a Lixeira). nil se sobrar menos de 2 cópias (deixa de ser duplicado).
    public func removing(_ path: String) -> DuplicateGroup? {
        let rest = paths.filter { $0 != path }
        return rest.count >= 2 ? DuplicateGroup(size: size, hash: hash, paths: rest) : nil
    }

    /// Cópia sugerida para MANTER (a primeira em ordem alfabética). Nunca se sugere apagar todas.
    public var keep: String { paths[0] }
    public var extraCopies: [String] { Array(paths.dropFirst()) }
    /// Bytes recuperáveis = total − 1 cópia.
    public var reclaimableBytes: UInt64 { size * UInt64(paths.count - 1) }

    /// Uma seleção para a Lixeira só é válida se for um subconjunto ESTRITO e não vazio do grupo.
    public func isValidTrashSelection(_ selection: Set<String>) -> Bool {
        !selection.isEmpty && selection.isSubset(of: Set(paths)) && selection.count < paths.count
    }
}

public enum DuplicateFinder {
    /// `hash` é injetado (ex.: head+tail do arquivo); nil = ilegível, o arquivo sai do grupo.
    /// Resultado = CANDIDATOS: o hash parcial não prova igualdade byte a byte (a UI deve dizer isso).
    public static func find(sizeGroups: [DuplicateSizeGroup], hash: (String) -> String?,
                            isCancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        var out: [DuplicateGroup] = []
        for g in sizeGroups {
            if isCancelled() { break }
            var byHash: [String: [String]] = [:]
            for p in g.paths {
                if let h = hash(p) { byHash[h, default: []].append(p) }
            }
            for (h, paths) in byHash where paths.count > 1 {
                out.append(DuplicateGroup(size: g.size, hash: h, paths: paths.sorted()))
            }
        }
        return out.sorted {
            $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes : $0.paths[0] < $1.paths[0]
        }
    }

    public static func totalReclaimable(_ groups: [DuplicateGroup]) -> UInt64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

// MARK: - Snapshots locais do Time Machine (saída de `tmutil listlocalsnapshots /`)

public struct LocalSnapshot: Equatable {
    public let name: String       // com.apple.TimeMachine.2024-05-01-120000.local
    public let stamp: String      // 2024-05-01-120000
}

public enum LocalSnapshotParser {
    public static func parse(_ output: String) -> [LocalSnapshot] {
        var out: [LocalSnapshot] = []
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let prefix = "com.apple.TimeMachine."
            guard line.hasPrefix(prefix) else { continue }
            var stamp = String(line.dropFirst(prefix.count))
            if stamp.hasSuffix(".local") { stamp = String(stamp.dropLast(".local".count)) }
            out.append(LocalSnapshot(name: line, stamp: stamp))
        }
        return out.sorted { $0.stamp < $1.stamp }
    }
}

// MARK: - Relatório CSV

public enum StorageReport {
    /// RFC 4180: aspas se houver vírgula, aspas, quebra de linha; aspas duplicadas. Também neutraliza
    /// "injeção de fórmula" em planilhas prefixando ' em células que começam com = + - @.
    public static func csvField(_ s: String) -> String {
        var v = s
        if let f = v.first, "=+-@".contains(f) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    /// Cabeçalho fixo e neutro em idioma: section,path,bytes,detail.
    public static func csv(analysis a: StorageAnalysis, duplicates: [DuplicateGroup], oldFiles: [FileRecord]) -> String {
        var rows: [[String]] = [["section", "path", "bytes", "detail"]]
        for f in a.folders {
            rows.append(["folder", f.path, String(f.bytes), String(f.fileCount)])
            for c in f.children { rows.append(["subfolder", c.path, String(c.bytes), String(c.fileCount)]) }
        }
        for t in a.types { rows.append(["type", t.kind.rawValue, String(t.bytes), String(t.fileCount)]) }
        for r in a.records.prefix(200) { rows.append(["largest", r.path, String(r.bytes), r.kind.rawValue]) }
        for r in oldFiles.prefix(200) { rows.append(["old", r.path, String(r.bytes), r.kind.rawValue]) }
        for g in duplicates {
            for (i, p) in g.paths.enumerated() {
                rows.append(["duplicate", p, String(g.size), i == 0 ? "keep" : "extra"])
            }
        }
        for u in a.apps.prefix(200) { rows.append(["app", u.displayName, String(u.total), u.key]) }
        for d in a.developer { rows.append(["developer", d.path, String(d.bytes), d.kind.rawValue + (d.isReportOnly ? ":report-only" : "")]) }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
