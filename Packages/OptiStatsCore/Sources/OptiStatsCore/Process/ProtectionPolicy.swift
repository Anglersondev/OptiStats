import Foundation

public enum ProtectedCategory: String, Codable, CaseIterable {
    case browser, editorOrIDE, music, streaming, meeting, downloads, terminal, passwordManager, backup
}

public enum ProtectionReason: Equatable {
    case systemOrAppleComponent
    case rootOwned
    case thisApp
    case frontmost
    case category(ProtectedCategory)
    case userProtected
    case noIdentity           // sem bundle/identidade confiável
    case essentialProcess     // WindowServer, Finder, Dock, loginwindow…
}

public struct ProtectionVerdict: Equatable {
    public var reasons: [ProtectionReason]
    /// Nunca pode ser encerrado por este app (nem com confirmação).
    public var isHardBlocked: Bool
    /// Fora das recomendações por padrão; o usuário pode remover da lista protegida.
    public var isSoftProtected: Bool
    public var isProtected: Bool { isHardBlocked || isSoftProtected }
}

public struct AppRuntimeContext: Equatable {
    public var isFrontmost: Bool
    public init(isFrontmost: Bool = false) { self.isFrontmost = isFrontmost }
}

/// Regras de proteção. Padrão conservador: navegadores, IDEs, música, reuniões, downloads e o app
/// em primeiro plano nunca entram em recomendações.
public struct ProtectionPolicy: Codable, Equatable {
    /// Bundle IDs que o usuário escolheu proteger.
    public var userProtectedBundleIDs: Set<String>
    /// Bundle IDs padrão que o usuário liberou explicitamente (lista editável).
    public var userUnprotectedBundleIDs: Set<String>
    public var ownBundleIdentifier: String

    public init(userProtectedBundleIDs: Set<String> = [], userUnprotectedBundleIDs: Set<String> = [],
                ownBundleIdentifier: String = "app.optistats.OptiStats") {
        self.userProtectedBundleIDs = userProtectedBundleIDs
        self.userUnprotectedBundleIDs = userUnprotectedBundleIDs
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    static let essentialNames: Set<String> = [
        "WindowServer", "Finder", "Dock", "loginwindow", "SystemUIServer", "launchd", "kernel_task",
        "ControlCenter", "NotificationCenter", "coreaudiod", "Spotlight", "mds", "mds_stores"
    ]

    /// Prefixos de bundle ID → categoria (verificação por prefixo).
    static let categoryPrefixes: [(prefix: String, category: ProtectedCategory)] = [
        ("com.apple.Safari", .browser), ("com.brave.Browser", .browser), ("com.google.Chrome", .browser),
        ("org.mozilla.firefox", .browser), ("company.thebrowser.Browser", .browser),
        ("com.microsoft.edgemac", .browser), ("com.operasoftware.Opera", .browser), ("com.vivaldi.Vivaldi", .browser),
        ("com.apple.dt.Xcode", .editorOrIDE), ("com.microsoft.VSCode", .editorOrIDE), ("com.jetbrains.", .editorOrIDE),
        ("com.sublimetext.", .editorOrIDE), ("com.todesktop.", .editorOrIDE), ("dev.zed.", .editorOrIDE),
        ("com.apple.Music", .music), ("com.spotify.client", .music), ("com.apple.podcasts", .music),
        ("com.apple.TV", .streaming), ("com.netflix.", .streaming), ("tv.plex.", .streaming),
        ("us.zoom.xos", .meeting), ("com.microsoft.teams", .meeting), ("com.apple.FaceTime", .meeting),
        ("com.hnc.Discord", .meeting), ("com.tinyspeck.slackmacgap", .meeting), ("com.google.meet", .meeting),
        ("org.m0k.transmission", .downloads), ("com.folx.", .downloads), ("com.charliemonroe.Downie", .downloads),
        ("com.apple.Terminal", .terminal), ("com.googlecode.iterm2", .terminal), ("dev.warp.Warp", .terminal),
        ("com.1password.", .passwordManager), ("com.agilebits.", .passwordManager), ("com.bitwarden.", .passwordManager),
        ("com.apple.TimeMachine", .backup), ("com.crashplan.", .backup), ("com.backblaze.", .backup)
    ]

    /// Nomes (sem bundle ID) que identificam apps de uso contínuo do usuário.
    static let categoryNames: [(name: String, category: ProtectedCategory)] = [
        ("Codex", .editorOrIDE), ("Claude", .editorOrIDE), ("Cursor", .editorOrIDE)
    ]

    public func category(for group: AppGroup) -> ProtectedCategory? {
        if let id = group.bundleIdentifier {
            for entry in Self.categoryPrefixes where id.hasPrefix(entry.prefix) { return entry.category }
        }
        for entry in Self.categoryNames where group.displayName == entry.name { return entry.category }
        // Navegadores sem bundle ID no grupo: reconhecer pelo nome do .app.
        let browserNames = ["Brave Browser", "Google Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Opera", "Vivaldi"]
        if browserNames.contains(group.displayName) { return .browser }
        return nil
    }

    public func verdict(for group: AppGroup, context: AppRuntimeContext) -> ProtectionVerdict {
        var reasons: [ProtectionReason] = []
        var hard = false
        var soft = false

        if group.isSystemOwned {
            reasons.append(.systemOrAppleComponent); hard = true
        }
        if group.members.contains(where: { $0.uid == 0 }) {
            reasons.append(.rootOwned); hard = true
        }
        if group.members.contains(where: { Self.essentialNames.contains($0.name) }) || Self.essentialNames.contains(group.displayName) {
            reasons.append(.essentialProcess); hard = true
        }
        if group.bundleIdentifier == ownBundleIdentifier {
            reasons.append(.thisApp); hard = true
        }
        if group.leader == nil && group.bundlePath == nil {
            // Processo avulso sem identidade de aplicativo: não oferecemos encerramento.
            reasons.append(.noIdentity); hard = true
        }
        if context.isFrontmost {
            reasons.append(.frontmost); soft = true
        }
        let id = group.bundleIdentifier ?? ""
        if userProtectedBundleIDs.contains(id) {
            reasons.append(.userProtected); soft = true
        }
        if let cat = category(for: group), !userUnprotectedBundleIDs.contains(id) {
            reasons.append(.category(cat)); soft = true
        }
        return ProtectionVerdict(reasons: reasons, isHardBlocked: hard, isSoftProtected: soft)
    }
}
