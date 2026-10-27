import Foundation
import IOKit
import OptiStatsCore

/// GPU via `PerformanceStatistics` do IOAccelerator. Se a fonte não expõe utilização, publica `unsupported`
/// (nunca deriva utilização de temperatura ou potência).
final class GPUCollector: BaseCollector {
    private let name: String?
    private let cores: Int?

    init(store: MetricsStore, clock: MonotonicClock, name: String?, cores: Int?) {
        self.name = name; self.cores = cores
        super.init(id: .gpu, store: store, clock: clock)
    }

    override func collect() {
        var found = false
        var device: Double?, renderer: Double?, tiler: Double?
        IOReg.forEachService(matching: "IOAccelerator") { entry in
            // Só a chave necessária: copiar todas as propriedades do acelerador a cada leitura é caro.
            guard let stats = IOReg.property(of: entry, key: "PerformanceStatistics") as? [String: Any] else { return }
            guard let d = stats.double("Device Utilization %") else { return }
            // Com mais de um acelerador, mantém o mais carregado.
            if device == nil || d > (device ?? 0) {
                device = d
                renderer = stats.double("Renderer Utilization %")
                tiler = stats.double("Tiler Utilization %")
            }
            found = true
        }
        guard found, let d = device else {
            markUnsupported("platform.reason.noGPUStats"); return
        }
        func frac(_ v: Double?) -> Double? { v.map { min(1, max(0, $0 / 100)) } }
        store.publish(gpu: GPUSnapshot(timestamp: clock.now, name: name, coreCount: cores,
                                       utilization: frac(d), renderer: frac(renderer), tiler: frac(tiler)))
        markAvailable()
    }
}
