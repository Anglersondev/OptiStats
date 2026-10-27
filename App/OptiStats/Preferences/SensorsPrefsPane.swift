import Cocoa
import OptiStatsCore

/// Sensores favoritos: fixados no topo do painel de sensores. A lista vem dos sensores realmente detectados.
final class SensorsPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.sensors") }
    override var symbolName: String { "thermometer" }

    private var token: SubscriptionToken?
    private var shownSignature = ""

    override func build() {
        let p = env.preferences.current
        let readings = (env.store.sensors?.readings ?? []).sorted {
            if $0.descriptor.kind != $1.descriptor.kind { return $0.descriptor.kind.rawValue < $1.descriptor.kind.rawValue }
            return $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        }
        shownSignature = Self.signature(readings)

        addSection(L("prefs.sensors.favorites"))
        addNote(L("prefs.sensors.note"))

        if readings.isEmpty {
            let state = env.store.state(.sensorList)
            let text = ModulePopoverViewController.message(for: state) ?? L("prefs.sensors.none")
            addNote(text, color: Theme.tertiaryText)
            return
        }

        var currentKind: SensorKind?
        for r in readings {
            if r.descriptor.kind != currentKind {
                currentKind = r.descriptor.kind
                addSection(L("prefs.sensors.kind.\(r.descriptor.kind.rawValue)"))
            }
            let id = r.descriptor.id
            let title = "\(r.descriptor.name)  (\(r.descriptor.key))"
            stack.addArrangedSubview(checkbox(title, isOn: p.favoriteSensorIDs.contains(id)) { [weak self] on in
                self?.change { (prefs: inout Preferences) -> Void in
                    if on { _ = prefs.favoriteSensorIDs.insert(id) } else { _ = prefs.favoriteSensorIDs.remove(id) }
                }
            })
        }
    }

    private static func signature(_ readings: [SensorReading]) -> String {
        readings.map { $0.descriptor.id }.joined(separator: "|")
    }

    override func paneDidAppear() {
        // Demanda só enquanto a aba está visível; sai ao trocar de aba ou fechar a janela.
        env.setDemand(consumer: "prefs.sensors", collectors: [.temperatures, .sensorList], visibility: .popover)
        token?.cancel()
        token = env.store.subscribe(.sensors) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let sig = Self.signature(self.currentSortedReadings())
                if sig != self.shownSignature { self.rebuildSoon() }
            }
        }
        // Dados que chegaram antes da assinatura.
        if Self.signature(currentSortedReadings()) != shownSignature { rebuildSoon() }
    }

    override func paneDidDisappear() { stopDemand() }

    private func currentSortedReadings() -> [SensorReading] {
        (env.store.sensors?.readings ?? []).sorted {
            if $0.descriptor.kind != $1.descriptor.kind { return $0.descriptor.kind.rawValue < $1.descriptor.kind.rawValue }
            return $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending
        }
    }

    private func stopDemand() {
        token?.cancel(); token = nil
        env.setDemand(consumer: "prefs.sensors", collectors: [.temperatures, .sensorList], visibility: nil)
    }

    deinit { stopDemand() }
}
