import Cocoa
import OptiStatsCore

/// Indicadores da barra: visibilidade, ordem, estilo de rótulo, casas decimais e modo compacto.
final class MenuBarPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.menubar") }
    override var symbolName: String { "menubar.rectangle" }

    override func build() {
        let p = env.preferences.current
        let widgets = p.menuBar.widgets

        addSection(L("prefs.menubar.indicators"))
        addNote(L("prefs.menubar.note"))

        for (index, w) in widgets.enumerated() {
            let kind = w.kind
            var name = PrefsText.kindName(kind)
            if p.monitoringMode == .essential && !kind.isEssential { name += " " + L("prefs.menubar.needsFull") }

            let enabled = checkbox(name, isOn: w.enabled) { [weak self] on in
                self?.change { prefs in
                    if let i = prefs.menuBar.widgets.firstIndex(where: { $0.kind == kind }) { prefs.menuBar.widgets[i].enabled = on }
                    // Ligar um indicador não essencial promove para o modo Completo: só o que está visível é amostrado.
                    if on && !kind.isEssential && prefs.monitoringMode == .essential { prefs.monitoringMode = .full }
                }
                self?.rebuildSoon()
            }
            enabled.widthAnchor.constraint(equalToConstant: 250).isActive = true

            let labelStyles = LabelStyle.allCases
            let labelPopup = popup(labelStyles.map { L("prefs.label.\($0.rawValue)") },
                                   selected: labelStyles.firstIndex(of: w.label) ?? 0) { [weak self] i in
                guard i < labelStyles.count else { return }
                self?.change { prefs in
                    if let j = prefs.menuBar.widgets.firstIndex(where: { $0.kind == kind }) { prefs.menuBar.widgets[j].label = labelStyles[i] }
                }
            }
            // CPU/GPU: carga, temperatura ou os dois juntos (compacto: "24% 58°").
            var contentViews: [NSView] = []
            if kind == .cpu || kind == .gpu {
                let contents = WidgetContent.allCases
                contentViews.append(popup(contents.map { L("prefs.content.\($0.rawValue)") },
                                          selected: contents.firstIndex(of: w.content) ?? 0) { [weak self] i in
                    guard i < contents.count else { return }
                    self?.change { prefs in
                        if let j = prefs.menuBar.widgets.firstIndex(where: { $0.kind == kind }) { prefs.menuBar.widgets[j].content = contents[i] }
                        if contents[i] != .load && prefs.monitoringMode == .essential { prefs.monitoringMode = .full }
                    }
                })
            }
            let decimalsPopup = popup(["0", "1", "2"], selected: min(2, max(0, w.decimals))) { [weak self] i in
                self?.change { prefs in
                    if let j = prefs.menuBar.widgets.firstIndex(where: { $0.kind == kind }) { prefs.menuBar.widgets[j].decimals = i }
                }
            }
            let up = iconButton(symbol: "chevron.up", fallback: "↑", label: L("prefs.menubar.moveUp")) { [weak self] in
                self?.move(kind, by: -1)
            }
            let down = iconButton(symbol: "chevron.down", fallback: "↓", label: L("prefs.menubar.moveDown")) { [weak self] in
                self?.move(kind, by: 1)
            }
            up.isEnabled = index > 0
            down.isEnabled = index < widgets.count - 1

            var rowViews: [NSView] = [enabled, labelPopup]
            rowViews += contentViews
            rowViews += [NSTextField.label(L("prefs.menubar.decimals"), font: Theme.body(11), color: Theme.secondaryText), decimalsPopup, up, down]
            let row = NSStackView.horizontal(rowViews, spacing: 8)
            stack.addArrangedSubview(row)
        }

        addSection(L("prefs.menubar.compactSection"))
        stack.addArrangedSubview(checkbox(L("prefs.menubar.combined"), isOn: p.menuBar.combined) { [weak self] on in
            self?.change { $0.menuBar.combined = on }
            self?.rebuildSoon()
        })
        addNote(L("prefs.menubar.combinedNote"))
        if p.menuBar.combined {
            for kind in WidgetKind.allCases {
                let selected = p.menuBar.combinedKinds.contains(kind)
                stack.addArrangedSubview(checkbox(PrefsText.kindName(kind), isOn: selected) { [weak self] on in
                    self?.change { prefs in
                        var kinds = prefs.menuBar.combinedKinds
                        if on {
                            if !kinds.contains(kind) && kinds.count < 3 { kinds.append(kind) }
                        } else if kinds.count > 1 {
                            kinds.removeAll { $0 == kind }
                        }
                        prefs.menuBar.combinedKinds = kinds
                    }
                    self?.rebuildSoon()   // reflete o limite de 3 / mínimo de 1
                })
            }
        }

        addSection(L("prefs.menubar.detailsSection"))
        let sources: [TemperatureSource] = [.cpuAverage, .cpuHottest, .gpuAverage, .gpuHottest]
        var sourceTitles = sources.map { L("prefs.tempsource.\(Self.sourceKey($0))") }
        var selectedSource = sources.firstIndex(of: p.menuBar.temperatureSource) ?? 0
        if case .sensor(let id) = p.menuBar.temperatureSource {
            sourceTitles.append(L("prefs.tempsource.sensor", id))
            selectedSource = sourceTitles.count - 1
        }
        addRow(L("prefs.menubar.tempSource"), popup(sourceTitles, selected: selectedSource) { [weak self] i in
            guard i < sources.count else { return }   // a opção "sensor específico" é só informativa
            self?.change { $0.menuBar.temperatureSource = sources[i] }
        })

        let scopes = PowerScopeChoice.allCases
        addRow(L("prefs.menubar.powerScope"), popup(scopes.map { L("prefs.powerscope.\($0.rawValue)") },
                                                    selected: scopes.firstIndex(of: p.menuBar.powerScope) ?? 0) { [weak self] i in
            guard i < scopes.count else { return }
            self?.change { $0.menuBar.powerScope = scopes[i] }
        })

        stack.addArrangedSubview(checkbox(L("prefs.menubar.showBits"), isOn: p.network.showBits) { [weak self] on in
            self?.change { $0.network.showBits = on }
        })
    }

    private static func sourceKey(_ s: TemperatureSource) -> String {
        switch s {
        case .cpuAverage: return "cpuAverage"
        case .cpuHottest: return "cpuHottest"
        case .gpuAverage: return "gpuAverage"
        case .gpuHottest: return "gpuHottest"
        case .sensor: return "sensor"
        }
    }

    private func move(_ kind: WidgetKind, by delta: Int) {
        change { prefs in
            guard let i = prefs.menuBar.widgets.firstIndex(where: { $0.kind == kind }) else { return }
            let j = i + delta
            guard j >= 0, j < prefs.menuBar.widgets.count else { return }
            prefs.menuBar.widgets.swapAt(i, j)
        }
        rebuildSoon()
    }
}
