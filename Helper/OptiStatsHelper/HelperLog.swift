import Foundation
import OptiStatsCore

/// Log mínimo do helper: uma linha por evento, sem dados pessoais (nada de nomes, caminhos de usuário ou conteúdo).
/// Rotação simples: ao passar do limite, o arquivo atual vira ".1" (substituindo o anterior) e recomeça.
enum HelperLog {
    private static let maxBytes = 128 * 1024
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let path = FanHelperConstants.logPath
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path), let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "\(formatter.string(from: Date())) \(message.prefix(300))\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
