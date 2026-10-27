import Cocoa
import OptiStatsCore

/// Amostragem: perfis (tomada/bateria), intervalos personalizados e histórico.
final class SamplingPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.sampling") }
    override var symbolName: String { "speedometer" }

    override func build() {
        let p = env.preferences.current
        let profiles = SamplingProfile.allCases
        let names = profiles.map { PrefsText.profileName($0) }

        addSection(L("prefs.sampling.profiles"))
        addRow(L("prefs.sampling.onAC"), popup(names, selected: profiles.firstIndex(of: p.profileOnAC) ?? 0) { [weak self] i in
            guard i < profiles.count else { return }
            self?.change { $0.profileOnAC = profiles[i] }
            self?.rebuildSoon()
        })
        addRow(L("prefs.sampling.onBattery"), popup(names, selected: profiles.firstIndex(of: p.profileOnBattery) ?? 0) { [weak self] i in
            guard i < profiles.count else { return }
            self?.change { $0.profileOnBattery = profiles[i] }
            self?.rebuildSoon()
        })
        addNote(L("prefs.sampling.profileNote"))
        stack.addArrangedSubview(button(L("prefs.sampling.restore")) { [weak self] in
            guard let self else { return }
            self.env.preferences.restoreBalancedProfile()
            self.env.applyPreferences()
            self.rebuildSoon()
        })

        if p.profileOnAC == .custom || p.profileOnBattery == .custom {
            addSection(L("prefs.sampling.custom"))
            addNote(L("prefs.sampling.customNote"))
            let header = NSStackView.horizontal([
                columnLabel("", width: 170), columnLabel(L("prefs.sampling.background"), width: 150),
                columnLabel(L("prefs.sampling.visible"), width: 150)], spacing: 8)
            stack.addArrangedSubview(header)
            for id in CollectorID.allCases {
                let intervals = p.customIntervals[id] ?? ModuleIntervals()
                let bg = intervalPopup(id: id, current: intervals.background) { [weak self] choice in
                    self?.change { prefs in
                        var mi = prefs.customIntervals[id] ?? ModuleIntervals()
                        mi.background = choice
                        prefs.customIntervals[id] = mi
                    }
                }
                let vis = intervalPopup(id: id, current: intervals.visible) { [weak self] choice in
                    self?.change { prefs in
                        var mi = prefs.customIntervals[id] ?? ModuleIntervals()
                        mi.visible = choice
                        prefs.customIntervals[id] = mi
                    }
                }
                let name = NSTextField.label(PrefsText.collectorName(id))
                name.widthAnchor.constraint(equalToConstant: 170).isActive = true
                bg.widthAnchor.constraint(equalToConstant: 150).isActive = true
                vis.widthAnchor.constraint(equalToConstant: 150).isActive = true
                stack.addArrangedSubview(NSStackView.horizontal([name, bg, vis], spacing: 8))
            }
        }

        addSection(L("prefs.sampling.historySection"))
        stack.addArrangedSubview(checkbox(L("prefs.sampling.persist"), isOn: p.persistHistory) { [weak self] on in
            self?.change { $0.persistHistory = on }
        })
        let mins = [5, 10, 15]
        addRow(L("prefs.sampling.historyMinutes"), popup(mins.map { L("prefs.sampling.minutesFormat", $0) },
                                                         selected: mins.firstIndex(of: p.historyMinutes) ?? 1) { [weak self] i in
            guard i < mins.count else { return }
            self?.change { $0.historyMinutes = mins[i] }
        })
        addNote(L("prefs.sampling.historyNote"))
    }

    private func columnLabel(_ text: String, width: CGFloat) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.caption(), color: Theme.secondaryText)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    private func intervalPopup(id: CollectorID, current: IntervalChoice, _ apply: @escaping (IntervalChoice) -> Void) -> NSPopUpButton {
        let options = AllowedIntervals.options(for: id)
        var titles = [L("prefs.sampling.automatic")]
        titles += options.map { L("prefs.sampling.secondsFormat", $0) }
        var selected = 0
        if case .seconds(let s) = current { selected = (options.firstIndex(of: AllowedIntervals.coerce(s, for: id)) ?? -1) + 1 }
        return popup(titles, selected: selected) { i in
            apply(i == 0 ? .automatic : .seconds(options[i - 1]))
        }
    }
}
