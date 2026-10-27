import Cocoa
import OptiStatsCore

/// Aba Ventoinhas: leituras + controle opcional pelo helper privilegiado (instalado pelo usuário, com senha de administrador).
/// Tudo que escreve começa DESLIGADO. Nenhum timer aqui: dados vivos vêm da assinatura do store e só enquanto a aba está visível.
final class FansPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.fans") }
    override var symbolName: String { "wind" }

    private struct FanRow {
        let index: Int
        let readings: NSTextField
    }

    private var token: SubscriptionToken?
    private var shownSignature = ""
    private var controlTargets: [ActionTarget] = []
    private var rows: [FanRow] = []
    private var helperInfo = HelperInfo(state: HelperInstaller.state())
    private var statusLabel: NSTextField?
    private var lastTestText: String?

    private var manager: FanControlManager { env.fanControl }

    /// Helper instalado de uma versão anterior do app: precisa ser atualizado (reinstalar) antes de testar.
    private var helperOutdated: Bool { helperInfo.state == .running && HelperInstaller.installedMatchesBundled() == false }
    private var helperRunning: Bool { helperInfo.state == .running && helperInfo.supported != false }

    override func build() {
        controlTargets.removeAll()
        rows.removeAll()
        let fans = env.store.sensors?.fans ?? []
        shownSignature = Self.signature(fans)

        // 1) Estado e avisos honestos
        addSection(L("prefs.fans.status"))
        let warning = addNote(L("fan.warning.main"), color: Theme.warn)
        warning.font = Theme.body(12)
        addNote(L("fan.warning.untested"), color: Theme.warn)
        addRow(L("prefs.fans.control"), capabilityLabel())
        stack.addArrangedSubview(NSStackView.horizontal([button(L("fan.restore.button")) { [weak self] in self?.restoreAll() }], spacing: 8))
        if let message = manager.lastMessage { addNote(message, color: Theme.warn) }

        // 2) Helper
        addSection(L("fan.helper.section"))
        let status = NSTextField.label(helperStatusText(), color: Theme.secondaryText, lines: 0)
        status.preferredMaxLayoutWidth = 400
        statusLabel = status
        addRow(L("fan.helper.status"), status)
        if helperOutdated { addNote(L("fan.helper.outdatedBanner"), color: Theme.warn) }
        let installTitle = helperInfo.state == .notInstalled ? L("fan.helper.install") : (helperOutdated ? L("fan.helper.update") : L("fan.helper.reinstall"))
        let install = button(installTitle) { [weak self] in self?.confirmInstall() }
        let uninstall = button(L("fan.helper.uninstall")) { [weak self] in self?.confirmUninstall() }
        install.isEnabled = !manager.busy
        uninstall.isEnabled = !manager.busy && helperInfo.state != .notInstalled
        stack.addArrangedSubview(NSStackView.horizontal([install, uninstall], spacing: 8))
        addNote(L("fan.helper.note"))

        guard let settings = manager.settings else { addNote(L("fan.err.notInstalled"), color: Theme.tertiaryText); return }

        if settings.isUnsupportedForThisMac {
            addSection(L("fan.manual.section"))
            addNote(L("fan.unsupported.note"), color: Theme.secondaryText)
            stack.addArrangedSubview(NSStackView.horizontal([button(L("fan.unsupported.retry")) { [weak self] in
                self?.manager.settings?.markUnsupported(false)
                self?.rebuildSoon()
            }], spacing: 8))
            addReadingsSection(fans: fans, settings: settings)
            return
        }

        // 3) Permissão
        addSection(L("fan.manual.section"))
        stack.addArrangedSubview(checkbox(L("fan.allow.title"), isOn: settings.manualAllowed) { [weak self] on in
            self?.setManualAllowed(on)
        })
        addNote(L("fan.allow.note"))

        // 4) Teste de controle
        addSection(L("fan.test.section"))
        let test = button(L("fan.test.button")) { [weak self] in self?.confirmTest() }
        test.isEnabled = settings.manualAllowed && helperRunning && !helperOutdated && !manager.busy && !manager.isEngaged
        stack.addArrangedSubview(NSStackView.horizontal([test], spacing: 8))
        addNote(L("fan.test.note"))
        if let text = lastTestText { addNote(text, color: Theme.secondaryText) }

        // 5) Smart Boost
        addSection(L("fan.boost.section"))
        var validated = false
        if case .validated = manager.capability { validated = true }
        let boost = checkbox(L("fan.boost.title"), isOn: settings.smartBoostEnabled) { [weak self] on in self?.setSmartBoost(on) }
        boost.isEnabled = settings.manualAllowed && validated && helperRunning && !manager.busy
        stack.addArrangedSubview(boost)
        addNote(validated ? L("fan.boost.note") : L("fan.boost.needsValidation"))
        if settings.smartBoostEnabled { addNote(smartBoostStateText(), color: Theme.secondaryText) }

        // 6) Ventoinhas
        addReadingsSection(fans: fans, settings: settings)
    }

    /// Leituras atuais (RPM, mín–máx). Sempre visíveis; o controle por ventoinha só existe se permitido e validado.
    private func addReadingsSection(fans: [FanReading], settings: FanControlSettings) {
        addSection(L("prefs.fans.readings"))
        if fans.isEmpty {
            let state = env.store.state(.fans)
            addNote(ModulePopoverViewController.message(for: state) ?? L("prefs.fans.none"), color: Theme.tertiaryText)
            return
        }
        var validated = false
        if case .validated = manager.capability { validated = true }
        let canControl = validated && !settings.isUnsupportedForThisMac && settings.manualAllowed
            && helperRunning && !helperOutdated && !settings.smartBoostEnabled && !manager.busy
        for fan in fans { addFanRow(fan, canControl: canControl) }
        addNote(L("fan.row.note"))
        updateReadings()
    }

    // MARK: Construção

    private func capabilityLabel() -> NSTextField {
        let text: String
        switch manager.capability {
        case .unavailable(let reason): text = L("prefs.fans.capability.unavailable", reason)
        case .experimentalUnvalidated: text = L("fan.cap.experimental")
        case .validated: text = L("fan.cap.validated")
        }
        let label = NSTextField.label(text, color: Theme.secondaryText, lines: 0)
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func helperStatusText() -> String {
        switch helperInfo.state {
        case .notInstalled: return L("fan.helper.state.notInstalled")
        case .installed: return L("fan.helper.state.installed")
        case .running:
            if let err = helperInfo.error { return L("fan.helper.state.noAnswer", err) }
            var text = L("fan.helper.state.running")
            if helperInfo.supported == false { text += "\n" + L("fan.cap.unsupportedHardware") }
            if helperOutdated { text += "\n" + L("fan.helper.outdated") }
            return text
        }
    }

    private func smartBoostStateText() -> String {
        switch manager.smartBoostState {
        case .disabled: return L("fan.boost.state.disabled")
        case .monitoring: return L("fan.boost.state.monitoring")
        case .boosting: return L("fan.boost.state.boosting")
        case .probing: return L("fan.boost.state.probing")
        case .cooldown: return L("fan.boost.state.cooldown")
        case .faulted: return L("fan.boost.state.faulted")
        }
    }

    private func addFanRow(_ fan: FanReading, canControl: Bool) {
        let name = fan.name ?? L("prefs.fans.fanN", fan.index + 1)
        let readings = NSTextField.label("", font: Theme.number(), color: Theme.secondaryText)
        rows.append(FanRow(index: fan.index, readings: readings))
        let nameLabel = NSTextField.label(name)
        nameLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(NSStackView.horizontal([nameLabel, readings], spacing: 10))

        let limitsKnown = FanRPMPolicy.clampForUI(0, min: fan.minRPM, max: fan.maxRPM) != nil
        let enabled = canControl && limitsKnown
        let engagedRPM = manager.manualTargets[fan.index]

        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        if let lo = fan.minRPM, let hi = fan.maxRPM, limitsKnown {
            slider.minValue = lo.rounded(.up)
            slider.maxValue = hi.rounded(.down)
            let initial = engagedRPM ?? FanRPMPolicy.clampForUI(fan.rpm ?? lo, min: lo, max: hi) ?? lo
            slider.doubleValue = initial
        }
        slider.isContinuous = true
        slider.isEnabled = enabled && engagedRPM != nil
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = NSTextField.label(engagedRPM.map { "\(Int($0)) RPM" } ?? "—", font: Theme.number(), color: Theme.secondaryText)
        value.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let index = fan.index
        let sliderTarget = ActionTarget { [weak self, weak slider, weak value] _ in
            guard let self, let slider, let value else { return }
            let rpm = FanRPMPolicy.clampForUI(slider.doubleValue, min: slider.minValue, max: slider.maxValue) ?? slider.minValue
            value.stringValue = "\(Int(rpm)) RPM"
            // Envia ao soltar o controle (ou por teclado), nunca a cada pixel arrastado.
            let type = NSApp.currentEvent?.type
            if type != .leftMouseDragged && type != .leftMouseDown { self.applyManual(fan: index, rpm: rpm) }
        }
        controlTargets.append(sliderTarget)
        slider.target = sliderTarget
        slider.action = #selector(ActionTarget.fire(_:))

        let popupControl = popup([L("fan.mode.automatic"), L("fan.mode.manual")], selected: engagedRPM == nil ? 0 : 1) { [weak self, weak slider] choice in
            guard let self else { return }
            if choice == 0 { self.restoreAll(); return }
            guard let slider else { return }
            let rpm = FanRPMPolicy.clampForUI(slider.doubleValue, min: slider.minValue, max: slider.maxValue) ?? slider.minValue
            self.applyManual(fan: index, rpm: rpm)
        }
        popupControl.isEnabled = enabled
        popupControl.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let fullSpeed = button(L("fan.fullSpeed")) { [weak self] in
            guard let hi = fan.maxRPM else { return }
            self?.applyManual(fan: index, rpm: hi.rounded(.down))
        }
        fullSpeed.isEnabled = enabled
        fullSpeed.toolTip = L("fan.fullSpeed.tooltip")

        let controls = NSStackView.horizontal([popupControl, slider, value, fullSpeed], spacing: 10)
        let indent = NSView(); indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(NSStackView.horizontal([indent, controls], spacing: 0))
    }

    // MARK: Ações

    private func refreshHelperStatus() {
        manager.helperInfo { [weak self] info in
            guard let self else { return }
            let changed = info != self.helperInfo
            self.helperInfo = info
            if changed { self.rebuildSoon() } else { self.statusLabel?.stringValue = self.helperStatusText() }
        }
    }

    private func restoreAll() {
        manager.restoreAutomatic { [weak self] error in
            if let error { self?.showError(error) }
            self?.rebuildSoon()
        }
    }

    private func setManualAllowed(_ on: Bool) {
        guard let settings = manager.settings else { return }
        if !on {
            settings.manualAllowed = false
            restoreAll()
            return
        }
        MaintUI.confirm(window: view.window, title: L("fan.allow.confirmTitle"), text: L("fan.allow.confirmText"),
                        action: L("fan.allow.confirmAction")) { [weak self] ok in
            if ok { settings.manualAllowed = true }
            self?.rebuildSoon()
        }
    }

    private func setSmartBoost(_ on: Bool) {
        if let refusal = manager.setSmartBoost(on) { showError(refusal) }
        rebuildSoon()
    }

    private func applyManual(fan: Int, rpm: Double) {
        manager.setManual(fan: fan, rpm: rpm) { [weak self] error in
            if let error { self?.showError(error) }
            self?.rebuildSoon()
        }
    }

    private func confirmInstall() {
        MaintUI.confirm(window: view.window, title: L("fan.install.confirmTitle"), text: L("fan.install.confirmText"),
                        action: L("fan.install.confirmAction")) { [weak self] ok in
            guard ok, let self else { return }
            self.manager.installHelper { [weak self] error in
                if let error { self?.showError(error) }
                self?.refreshHelperStatus()
            }
        }
    }

    private func confirmUninstall() {
        MaintUI.confirm(window: view.window, title: L("fan.uninstall.confirmTitle"), text: L("fan.uninstall.confirmText"),
                        action: L("fan.uninstall.confirmAction")) { [weak self] ok in
            guard ok, let self else { return }
            self.manager.uninstallHelper { [weak self] error in
                if let error { self?.showError(error) }
                self?.helperInfo = HelperInfo(state: HelperInstaller.state())
                self?.refreshHelperStatus()
                self?.rebuildSoon()
            }
        }
    }

    /// Outros apps que controlam ventoinhas (e seguram o modo manual) invalidam o teste.
    private static let otherFanApps: [(bundleID: String, name: String)] = [
        ("eu.exelban.Stats", "Stats"), ("com.crystalidea.macsfancontrol", "Macs Fan Control"),
        ("com.tunabellysoftware.tgpro", "TG Pro"), ("com.crystalidea.MacsFanControl", "Macs Fan Control")
    ]

    private func otherFanControllersRunning() -> [String] {
        var names: [String] = []
        for (id, name) in Self.otherFanApps where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private func confirmTest() {
        let others = otherFanControllersRunning()
        if !others.isEmpty {
            MaintUI.inform(window: view.window, title: L("fan.test.otherApp.title"), text: L("fan.test.otherApp.text", others.joined(separator: ", ")))
            return
        }
        MaintUI.confirm(window: view.window, title: L("fan.test.confirmTitle"), text: L("fan.test.confirmText"),
                        action: L("fan.test.confirmAction")) { [weak self] ok in
            guard ok, let self else { return }
            self.lastTestText = L("fan.test.running")
            self.rebuildSoon()
            self.manager.runControlTest { [weak self] report in
                self?.lastTestText = report.message
                MaintUI.inform(window: self?.view.window, title: report.passed ? L("fan.test.passed") : L("fan.test.failed"), text: report.message)
                self?.rebuildSoon()
            }
        }
    }

    // MARK: Leituras vivas (sem reconstruir, para não interromper o slider)

    private static func signature(_ fans: [FanReading]) -> String {
        fans.map { "\($0.index):\(Int($0.minRPM ?? -1))-\(Int($0.maxRPM ?? -1))" }.joined(separator: "|")
    }

    private func updateReadings() {
        let fans = env.store.sensors?.fans ?? []
        let f = { (v: Double) in ByteFormat.decimal(v, decimals: 0, locale: Localizer.shared.locale) }
        for row in rows {
            guard let fan = fans.first(where: { $0.index == row.index }) else { continue }
            var text = fan.rpm.map { f($0) + " RPM" } ?? "—"
            if let lo = fan.minRPM, let hi = fan.maxRPM { text += "  (\(f(lo))–\(f(hi)) RPM)" }
            switch fan.mode {
            case .automatic: text += "  ·  " + L("fans.mode.automatic")
            case .manual: text += "  ·  " + L("fans.mode.manual")
            case .unknown: break
            }
            row.readings.stringValue = text
        }
    }

    override func paneDidAppear() {
        env.setDemand(consumer: "prefs.fans", collectors: [.fans], visibility: .popover)
        manager.onChange = { [weak self] in self?.rebuildSoon() }
        token?.cancel()
        token = env.store.subscribe(.sensors) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if Self.signature(self.env.store.sensors?.fans ?? []) != self.shownSignature { self.rebuildSoon() }
                else { self.updateReadings() }
            }
        }
        refreshHelperStatus()
    }

    override func paneDidDisappear() { stopDemand() }

    private func stopDemand() {
        token?.cancel(); token = nil
        manager.onChange = nil
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
