import Foundation
import OptiStatsCore

// OptiStatsHelper: daemon root (launchd) que controla ventoinhas por pedido do app OptiStats.
// Fala só por socket Unix local, só com o usuário de console, e devolve o automático ao menor sinal de problema.
// Depende somente de Foundation, IOKit e OptiStatsCore.

if CommandLine.arguments.dropFirst().first == "--version" {
    print("OptiStatsHelper build \(FanHelperConstants.helperBuild) protocol \(FanHelperConstants.protocolVersion)")
    exit(0)
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("OptiStatsHelper precisa rodar como root (launchd).\n".utf8))
    exit(1)
}

installTerminationHandlers()
HelperLog.write("iniciando (build \(FanHelperConstants.helperBuild), protocolo \(FanHelperConstants.protocolVersion))")

let driver = SMCFanDriver(shouldAbort: { terminateRequested != 0 })
// Ao iniciar: restaurar automático (cobre queda anterior do helper com ventoinhas em manual).
if driver.restoreAutomatic() == false { HelperLog.write("restauração inicial não confirmada; será repetida") }

let server = HelperServer(driver: driver)
exit(server.run() ? 0 : 1)
