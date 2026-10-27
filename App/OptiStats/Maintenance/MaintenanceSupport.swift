import Cocoa
import OptiStatsCore

/// Execução de ferramentas do sistema (sem shell, sem sudo). Chamar SEMPRE fora da main.
enum SystemTool {
    struct Result { let status: Int32; let out: String; let err: String }

    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: String(describing: error)) }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(data: out, encoding: .utf8) ?? "",
                      err: String(data: err, encoding: .utf8) ?? "")
    }

    /// `launchctl print-disabled <domain>` (leitura; sem privilégio). nil se falhar.
    static func printDisabled(domain: String) -> [String: Bool]? {
        let r = run("/bin/launchctl", ["print-disabled", domain])
        guard r.status == 0 else { return nil }
        return DisabledTable.parse(r.out)
    }

    /// Executa argv com privilégios de administrador pelo prompt padrão do macOS (osascript, sem helper,
    /// sem guardar senha). Só aceita argumentos "simples" (vêm do catálogo); qualquer outro caractere recusa.
    static func runAsAdmin(_ commands: [[String]]) -> Result {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        var parts: [String] = []
        for argv in commands {
            guard argv.first == "launchctl", argv.count >= 2 else { return Result(status: -2, out: "", err: "invalid-command") }
            var a = argv
            a[0] = "/bin/launchctl"
            for arg in a where arg.isEmpty || arg.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return Result(status: -2, out: "", err: "invalid-argument")
            }
            parts.append(a.joined(separator: " "))
        }
        guard !parts.isEmpty else { return Result(status: 0, out: "", err: "") }
        let shell = parts.joined(separator: " ; ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script])
    }
}

/// Raiz de dados do app (única pasta onde este módulo escreve, além da Lixeira).
enum MaintenancePaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("OptiStats", isDirectory: true)
    }
    static var snapshotURL: URL { supportDir.appendingPathComponent("debloat-snapshot.json") }
}

enum SnapshotStore {
    static func load() -> DebloatSnapshot? {
        guard let data = try? Data(contentsOf: MaintenancePaths.snapshotURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(DebloatSnapshot.self, from: data)
    }
    static func save(_ s: DebloatSnapshot) throws {
        try FileManager.default.createDirectory(at: MaintenancePaths.supportDir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: MaintenancePaths.snapshotURL, options: .atomic)
    }
    static func delete() { try? FileManager.default.removeItem(at: MaintenancePaths.snapshotURL) }
}

/// Utilidades de interface compartilhadas pelas abas.
enum MaintUI {
    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Linha "[conteúdo à esquerda] ..... [direita]".
    static func spread(_ left: NSView, _ right: [NSView]) -> NSStackView {
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return NSStackView.horizontal([left, spacer] + right, spacing: 8)
    }

    static func sizeLabel(_ text: String) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.number(12, weight: .medium), alignment: .right)
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }

    /// Alerta de confirmação destrutiva: primeiro botão = ação; segundo = cancelar. true se confirmou a ação.
    static func confirm(window: NSWindow?, title: String, text: String, action: String, accessory: NSView? = nil,
                        _ done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        let b = a.addButton(withTitle: action)
        b.hasDestructiveAction = true
        a.addButton(withTitle: L("prefs.cancel"))
        a.accessoryView = accessory
        if let w = window {
            a.beginSheetModal(for: w) { done($0 == .alertFirstButtonReturn) }
        } else {
            done(a.runModal() == .alertFirstButtonReturn)
        }
    }

    static func inform(window: NSWindow?, title: String, text: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: L("prefs.ok"))
        if let w = window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }
}
