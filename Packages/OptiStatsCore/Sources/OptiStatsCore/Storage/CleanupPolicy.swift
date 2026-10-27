import Foundation

/// Categorias de limpeza. Só `deletable` pode ser removido (sempre para a Lixeira); `reportOnly` apenas informa.
public enum CleanupCategory: String, Codable, CaseIterable {
    case appCaches, userLogs, trash, xcodeDerivedData, packageCaches   // removíveis
    case largeDownloads, deviceBackups                                 // somente relatório
    /// Arquivo individual escolhido pela pessoa (grande/antigo/duplicado). Nunca vem de varredura automática:
    /// só vale por arquivo, com confirmação explícita, e `canDelete` aplica regras próprias e mais estritas.
    case userSelected

    public var isDeletable: Bool {
        switch self {
        case .appCaches, .userLogs, .trash, .xcodeDerivedData, .packageCaches, .userSelected: return true
        case .largeDownloads, .deviceBackups: return false
        }
    }
}

/// Um item candidato. `path` é absoluto e padronizado.
public struct CleanupItem: Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let category: CleanupCategory
    public let bytes: UInt64
    public init(path: String, category: CleanupCategory, bytes: UInt64) {
        self.path = path; self.category = category; self.bytes = bytes
    }
}

/// Abstração mínima do sistema de arquivos (permite testar sem disco).
public protocol FileSystemProviding {
    func children(of path: String) -> [String]          // caminhos completos; vazio se não existe
    func allocatedBytes(at path: String) -> UInt64       // recursivo
    func isSymbolicLink(_ path: String) -> Bool
    /// Verdadeiro se `path` for diretório (inclui pacotes). Usado pela categoria `userSelected`, que só aceita arquivos.
    func isDirectory(_ path: String) -> Bool
}

public extension FileSystemProviding {
    /// Padrão conservador: sem informação, trata como diretório (portanto não removível por `userSelected`).
    func isDirectory(_ path: String) -> Bool { true }
}

/// Regras de segurança da limpeza. É a ÚNICA fonte de verdade sobre o que pode ser apagado.
public struct CleanupPolicy {
    public let home: String
    /// Prefixos de cache de apps que nunca são tocados (dados que o usuário sentiria falta).
    public var protectedNames: Set<String> = ["com.apple.Safari", "CloudKit", "com.apple.bird", "FamilyCircle", "com.apple.akd", "com.apple.AddressBook"]

    public init(home: String) { self.home = Self.normalize(home) }

    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Raízes (dentro de `home`) que cada categoria removível pode esvaziar. Os filhos diretos são os itens.
    public func roots(for category: CleanupCategory) -> [String] {
        switch category {
        case .appCaches: return [home + "/Library/Caches"]
        case .userLogs: return [home + "/Library/Logs"]
        case .trash: return [home + "/.Trash"]
        case .xcodeDerivedData: return [home + "/Library/Developer/Xcode/DerivedData"]
        case .packageCaches: return [home + "/.npm/_cacache", home + "/.cache"]
        case .largeDownloads: return [home + "/Downloads"]
        case .deviceBackups: return [home + "/Library/Application Support/MobileSync/Backup"]
        case .userSelected: return []   // sem raízes: vale só por arquivo (ver `canTrashUserFile`)
        }
    }

    /// Extensões de pacotes que nunca podem ter conteúdo interno removido arquivo a arquivo.
    static let protectedPackageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "pkg", "photoslibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "imovielibrary", "logicx", "band", "sparsebundle", "xcodeproj", "xcworkspace", "playground"
    ]

    /// Regras da categoria `userSelected` (arquivo escolhido pela pessoa). Estritas e independentes de maiúsculas
    /// (APFS/HFS+ costumam ignorar caixa). Requer `path` já normalizado, dentro do home, que:
    /// - seja arquivo (nunca diretório/pacote) e não seja link simbólico (checado por quem chama);
    /// - esteja fora de `~/Library`, exceto em `~/Library/Caches/` e `~/Library/Logs/`;
    /// - nunca em `~/Library/Mobile Documents` (iCloud Drive), `/Applications` ou dentro de pacotes (.app etc.);
    /// - não esteja na Lixeira (nada a ganhar) nem seja o próprio home.
    public func canTrashUserFile(_ path: String, fs: FileSystemProviding) -> Bool {
        let lp = path.lowercased(), lh = home.lowercased()
        guard lp.hasPrefix(lh + "/"), lp.count > lh.count + 1 else { return false }
        guard !lp.hasPrefix("/applications/"), !lp.contains("/library/mobile documents") else { return false }
        let rel = String(lp.dropFirst(lh.count + 1))
        if rel.hasPrefix(".trash/") { return false }
        if rel == "library" || rel.hasPrefix("library/") {
            guard rel.hasPrefix("library/caches/") || rel.hasPrefix("library/logs/") else { return false }
            if rel.hasPrefix("library/mobile documents") { return false }
        }
        // Qualquer componente que seja um pacote protegido bloqueia (inclusive o próprio nome do arquivo).
        for comp in rel.split(separator: "/") {
            if let dot = comp.lastIndex(of: "."), dot != comp.startIndex {
                let ext = String(comp[comp.index(after: dot)...])
                if Self.protectedPackageExtensions.contains(ext) { return false }
            }
        }
        return !fs.isDirectory(path)
    }

    /// Verdadeiro só se `path` for um FILHO de uma raiz removível, dentro do home, sem `..`, sem link simbólico.
    public func canDelete(_ path: String, category: CleanupCategory, fs: FileSystemProviding) -> Bool {
        guard category.isDeletable, !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        let p = Self.normalize(path)
        guard p == path, p.hasPrefix(home + "/"), !fs.isSymbolicLink(p) else { return false }
        let name = (p as NSString).lastPathComponent
        if protectedNames.contains(name) { return false }
        if category == .userSelected { return canTrashUserFile(p, fs: fs) }
        for root in roots(for: category) where p.hasPrefix(root + "/") {
            return p.count > root.count + 1
        }
        return false
    }
}

/// Varre as raízes e devolve itens ordenados do maior para o menor.
public struct CleanupScanner {
    public let policy: CleanupPolicy
    public let fs: FileSystemProviding
    public init(policy: CleanupPolicy, fs: FileSystemProviding) { self.policy = policy; self.fs = fs }

    public func scan(categories: [CleanupCategory] = CleanupCategory.allCases, minBytes: UInt64 = 1) -> [CleanupItem] {
        var items: [CleanupItem] = []
        for cat in categories {
            for root in policy.roots(for: cat) {
                for child in fs.children(of: root) {
                    let p = CleanupPolicy.normalize(child)
                    if cat.isDeletable && !policy.canDelete(p, category: cat, fs: fs) { continue }
                    let b = fs.allocatedBytes(at: p)
                    if b >= minBytes { items.append(CleanupItem(path: p, category: cat, bytes: b)) }
                }
            }
        }
        return items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    public static func total(_ items: [CleanupItem], category: CleanupCategory? = nil) -> UInt64 {
        items.filter { category == nil || $0.category == category }.reduce(0) { $0 + $1.bytes }
    }
}

/// Resultado de uma execução (para o relatório; sem promessa de espaço: o macOS pode demorar a refletir).
public struct CleanupReport: Equatable {
    public var moved: [CleanupItem] = []
    public var skipped: [(item: CleanupItem, reason: String)] = []
    public var failed: [(item: CleanupItem, error: String)] = []
    public init() {}
    public var movedBytes: UInt64 { moved.reduce(0) { $0 + $1.bytes } }
    public static func == (l: CleanupReport, r: CleanupReport) -> Bool { l.moved == r.moved && l.skipped.count == r.skipped.count && l.failed.count == r.failed.count }
}

/// Executa a limpeza movendo para a Lixeira através de `trash` (injetado). Revalida cada item antes.
public struct CleanupExecutor {
    public let policy: CleanupPolicy
    public let fs: FileSystemProviding
    public let trash: (String) throws -> Void
    /// Usado só para itens que já estão na Lixeira (esvaziar). Irreversível: a UI avisa e exige confirmação.
    public let removePermanently: (String) throws -> Void
    public init(policy: CleanupPolicy, fs: FileSystemProviding, trash: @escaping (String) throws -> Void,
                removePermanently: @escaping (String) throws -> Void = { _ in throw CocoaError(.fileWriteNoPermission) }) {
        self.policy = policy; self.fs = fs; self.trash = trash; self.removePermanently = removePermanently
    }

    public func run(_ items: [CleanupItem]) -> CleanupReport {
        var r = CleanupReport()
        for item in items {
            guard policy.canDelete(item.path, category: item.category, fs: fs) else {
                r.skipped.append((item, "blocked-by-policy")); continue
            }
            do { try (item.category == .trash ? removePermanently : trash)(item.path); r.moved.append(item) }
            catch { r.failed.append((item, String(describing: error))) }
        }
        return r
    }
}
