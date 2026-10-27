import Cocoa
import OptiStatsCore

extension SystemTool {
    static let purgePath = "/usr/sbin/purge"
    static var purgeAvailable: Bool { FileManager.default.isExecutableFile(atPath: purgePath) }

    /// API separada e estreita: executa EXATAMENTE `/usr/sbin/purge` (sem argumentos, sem entrada externa) com
    /// privilégios de administrador pelo prompt padrão do macOS. Não afrouxa a validação de `runAsAdmin` (launchctl).
    /// Chamar fora da main (bloqueia até a pessoa responder ao prompt).
    static func runPurgeAsAdmin() -> Result {
        guard purgeAvailable else { return Result(status: -3, out: "", err: "purge-unavailable") }
        return run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"])
    }
}
