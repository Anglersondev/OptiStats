import Foundation
import OptiStatsCore

enum HelperInstallState: Equatable {
    case notInstalled
    /// Arquivos presentes, mas o socket não existe (daemon parado ou ainda subindo).
    case installed
    case running
}

/// Instalação/remoção do helper SEM Developer ID: um único prompt de senha de administrador (osascript),
/// com scripts de texto CONSTANTE e caminhos fixos. A única entrada variável é o caminho do binário embutido
/// no app, passado como argumento ($1) já citado por `quoted form of` do AppleScript (nunca interpolado no script).
enum HelperInstaller {
    private static let helperPath = FanHelperConstants.helperPath
    private static let plistPath = FanHelperConstants.daemonPlistPath
    private static let socketPath = FanHelperConstants.socketPath
    private static let label = FanHelperConstants.label

    static func state() -> HelperInstallState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperPath), fm.fileExists(atPath: plistPath) else { return .notInstalled }
        return fm.fileExists(atPath: socketPath) ? .running : .installed
    }

    /// Binário embutido: OptiStats.app/Contents/Resources/OptiStatsHelper.
    static var bundledHelperURL: URL? { Bundle.main.url(forResource: "OptiStatsHelper", withExtension: nil) }

    // Script constante (sh). $1 = caminho do binário embutido.
    private static let installScript = """
    set -e
    SRC="$1"
    [ -f "$SRC" ] || exit 64
    /bin/mkdir -p /Library/PrivilegedHelperTools
    /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
    /usr/bin/install -o root -g wheel -m 755 "$SRC" \(helperPath)
    /bin/cat > \(plistPath) <<'PLIST_END'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(helperPath)</string>
        </array>
        <key>UserName</key>
        <string>root</string>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
    </plist>
    PLIST_END
    /usr/sbin/chown root:wheel \(plistPath)
    /bin/chmod 644 \(plistPath)
    /bin/launchctl bootstrap system \(plistPath)
    """

    private static let uninstallScript = """
    /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
    /bin/rm -f \(plistPath) \(helperPath) \(socketPath)
    """

    // AppleScript não tem "if" como expressão: o comando é montado em passos.
    private static let wrapper = [
        "on run argv",
        "set cmd to \"/bin/sh -c \" & quoted form of (item 1 of argv) & \" sh\"",
        "if (count of argv) > 1 then set cmd to cmd & \" \" & quoted form of (item 2 of argv)",
        "do shell script cmd with administrator privileges",
        "end run"
    ]

    private static func runAdmin(script: String, arguments: [String]) -> SystemTool.Result {
        var args: [String] = []
        for line in wrapper { args += ["-e", line] }
        args.append(script)
        args += arguments
        return SystemTool.run("/usr/bin/osascript", args)
    }

    /// Chamar fora da main (bloqueia no prompt de senha). nil = sucesso; senão, texto do erro (já curto).
    static func install() -> HelperError? {
        guard let src = bundledHelperURL else { return .missingBinary }
        let r = runAdmin(script: installScript, arguments: [src.path])
        if r.status == 0 { return nil }
        return classify(r)
    }

    static func uninstall() -> HelperError? {
        let r = runAdmin(script: uninstallScript, arguments: [])
        return r.status == 0 ? nil : classify(r)
    }

    private static func classify(_ r: SystemTool.Result) -> HelperError {
        // "User canceled." (-128) quando a pessoa cancela o prompt de senha.
        if r.err.contains("-128") || r.err.localizedCaseInsensitiveContains("canceled") || r.err.localizedCaseInsensitiveContains("cancelled") {
            return .cancelled
        }
        return .failed(String(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }

    enum HelperError: Equatable {
        case missingBinary, cancelled, failed(String)
    }
}
