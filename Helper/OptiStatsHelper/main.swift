import Foundation
import OptiStatsCore

// OptiStatsHelper: daemon root (launchd) que controla ventoinhas por pedido do app OptiStats.
// Fala só por socket Unix local, só com o usuário de console, e devolve o automático ao menor sinal de problema.
// Depende somente de Foundation, IOKit e OptiStatsCore.

if CommandLine.arguments.dropFirst().first == "--version" {
    print("OptiStatsHelper build \(FanHelperConstants.helperBuild)")
    exit(0)
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("OptiStatsHelper precisa rodar como root (launchd).\n".utf8))
    exit(1)
}

let terminationFD = installTerminationHandlers()
HelperLog.write("iniciando build \(FanHelperConstants.helperBuild)")

let driver = SMCFanDriver(shouldAbort: {
    terminateRequested != 0 || ProcessInfo.processInfo.thermalState == .critical
})
let server = HelperServer(driver: driver, terminationFD: terminationFD)
exit(server.run() ? 0 : 1)
