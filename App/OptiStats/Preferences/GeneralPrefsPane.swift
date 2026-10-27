import Cocoa
import OptiStatsCore

/// Geral: idioma, aparência, iniciar no login, unidade de temperatura e modo de monitoramento.
final class GeneralPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.general") }
    override var symbolName: String { "gearshape" }

    override func build() {
        let p = env.preferences.current

        addSection(L("prefs.general.appearanceSection"))

        let langs = LanguageChoice.allCases
        let langTitles = langs.map { choice -> String in
            switch choice {
            case .system: return L("prefs.language.system")
            case .ptBR: return "Português (Brasil)"
            case .en: return "English"
            }
        }
        addRow(L("prefs.general.language"), popup(langTitles, selected: langs.firstIndex(of: p.language) ?? 0) { [weak self] i in
            guard let self, i < langs.count else { return }
            let choice = langs[i]
            self.change { $0.language = choice }
            self.onLanguageChanged?()
        })

        let looks = AppearanceChoice.allCases
        addRow(L("prefs.general.appearance"), popup(looks.map { L("prefs.appearance.\($0.rawValue)") },
                                                    selected: looks.firstIndex(of: p.appearance) ?? 0) { [weak self] i in
            guard i < looks.count else { return }
            self?.change { $0.appearance = looks[i] }
        })

        let units = TemperatureUnit.allCases
        addRow(L("prefs.general.temperatureUnit"), popup(units.map { L("prefs.unit.\($0.rawValue)") },
                                                         selected: units.firstIndex(of: p.temperatureUnit) ?? 0) { [weak self] i in
            guard i < units.count else { return }
            self?.change { $0.temperatureUnit = units[i] }
        })

        addSection(L("prefs.general.systemSection"))

        let login = checkbox(L("prefs.general.launchAtLogin"), isOn: env.platform.isLaunchAtLoginEnabled()) { [weak self] on in
            guard let self else { return }
            do {
                try self.env.platform.setLaunchAtLogin(on)
                self.change { $0.launchAtLogin = on }
            } catch {
                self.showError(L("prefs.general.launchFailed", error.localizedDescription))
                self.rebuildSoon()   // volta o checkbox ao estado real
            }
        }
        stack.addArrangedSubview(login)
        addNote(L("prefs.general.launchNote"))

        addSection(L("prefs.general.modeSection"))
        let modes = MonitoringMode.allCases
        addRow(L("prefs.general.mode"), popup(modes.map { L("prefs.mode.\($0.rawValue)") },
                                              selected: modes.firstIndex(of: p.monitoringMode) ?? 0) { [weak self] i in
            guard i < modes.count else { return }
            self?.change { $0.monitoringMode = modes[i] }
        })
        addNote(L("prefs.general.modeNote"))

        addSection(L("prefs.general.resetSection"))
        stack.addArrangedSubview(button(L("prefs.general.reset")) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = L("prefs.general.resetConfirm")
            alert.informativeText = L("prefs.general.resetInfo")
            alert.addButton(withTitle: L("prefs.general.resetAction"))
            alert.addButton(withTitle: L("prefs.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try? self.env.platform.setLaunchAtLogin(false)
            self.env.preferences.resetToDefaults()
            self.env.applyPreferences()
            self.onLanguageChanged?()   // reconstrói a janela com o idioma padrão
        })
    }
}
