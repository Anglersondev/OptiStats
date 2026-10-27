// swift-tools-version:5.9
// OptiStatsCore: lógica pura (somente Foundation/Dispatch) usada pelo app macOS.
// Compila e testa em macOS e em Linux, para que fórmulas, políticas de amostragem
// e regras de segurança sejam verificáveis sem hardware Apple.
import PackageDescription

let package = Package(
    name: "OptiStatsCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OptiStatsCore", targets: ["OptiStatsCore"])
    ],
    targets: [
        .target(name: "OptiStatsCore"),
        .testTarget(name: "OptiStatsCoreTests", dependencies: ["OptiStatsCore"])
    ]
)
