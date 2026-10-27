import Cocoa
import OptiStatsCore

/// Ventoinhas: SOMENTE LEITURA. Esta versão não escreve no SMC nem altera o controle das ventoinhas.
final class FansPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.fans") }
    override var symbolName: String { "wind" }

    private var token: SubscriptionToken?
    private var shownSignature = ""

    override func build() {
        let fans = env.store.sensors?.fans ?? []
        shownSignature = Self.signature(fans)

        addSection(L("prefs.fans.status"))
        let warning = addNote(L("prefs.fans.warning"), color: Theme.warn)
        warning.font = Theme.body(12)

        let capability: String
        switch env.platform.fanActuator.capability {
        case .unavailable(let reason): capability = L("prefs.fans.capability.unavailable", reason)
        case .experimentalUnvalidated: capability = L("prefs.fans.capability.experimental")
        case .validated: capability = L("prefs.fans.capability.validated")
        }
        let capLabel = NSTextField.label(capability, color: Theme.secondaryText, lines: 0)
        capLabel.preferredMaxLayoutWidth = 400
        addRow(L("prefs.fans.control"), capLabel)
        addNote(L("prefs.fans.smartBoost"))

        addSection(L("prefs.fans.readings"))
        if fans.isEmpty {
            let state = env.store.state(.fans)
            addNote(ModulePopoverViewController.message(for: state) ?? L("prefs.fans.none"), color: Theme.tertiaryText)
            return
        }
        for fan in fans {
            let name = fan.name ?? L("prefs.fans.fanN", fan.index + 1)
            var value = fan.rpm.map { ByteFormat.decimal($0, decimals: 0, locale: Localizer.shared.locale) + " RPM" } ?? "—"
            if let lo = fan.minRPM, let hi = fan.maxRPM {
                let f = { (v: Double) in ByteFormat.decimal(v, decimals: 0, locale: Localizer.shared.locale) }
                value += "  (\(f(lo))–\(f(hi)) RPM)"
            }
            stack.addArrangedSubview(KeyValueRowForPrefs.make(name, value))
        }
    }

    private static func signature(_ fans: [FanReading]) -> String {
        fans.map { "\($0.index):\(Int($0.rpm ?? -1))" }.joined(separator: "|")
    }

    override func paneDidAppear() {
        env.setDemand(consumer: "prefs.fans", collectors: [.fans], visibility: .popover)
        token?.cancel()
        token = env.store.subscribe(.sensors) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if Self.signature(self.env.store.sensors?.fans ?? []) != self.shownSignature { self.rebuildSoon() }
            }
        }
    }

    override func paneDidDisappear() { stopDemand() }

    private func stopDemand() {
        token?.cancel(); token = nil
        env.setDemand(consumer: "prefs.fans", collectors: [.fans], visibility: nil)
    }

    deinit { stopDemand() }
}

/// Linha simples "nome  valor" para as abas (sem depender dos componentes dos painéis).
enum KeyValueRowForPrefs {
    static func make(_ key: String, _ value: String) -> NSStackView {
        let k = NSTextField.label(key)
        k.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let v = NSTextField.label(value, font: Theme.number(), color: Theme.secondaryText)
        return NSStackView.horizontal([k, v], spacing: 10)
    }
}
