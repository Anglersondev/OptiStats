import Cocoa
import OptiStatsCore

/// Otimizador de RAM e proteções. O otimizador nunca encerra apps sem confirmação e respeita a lista protegida.
final class OptimizerPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.optimizer") }
    override var symbolName: String { "memorychip" }

    private var protectedEditor: BundleListEditor?
    private var unprotectedEditor: BundleListEditor?

    override func build() {
        let p = env.preferences.current

        addSection(L("prefs.optimizer.general"))
        addNote(L("prefs.optimizer.note"))
        stack.addArrangedSubview(checkbox(L("prefs.optimizer.alerts"), isOn: p.memory.alertsEnabled) { [weak self] on in
            self?.change { $0.memory.alertsEnabled = on }
        })
        addNote(L("prefs.optimizer.alertsNote"))
        stack.addArrangedSubview(checkbox(L("prefs.optimizer.group"), isOn: p.memory.groupByApp) { [weak self] on in
            self?.change { $0.memory.groupByApp = on }
        })
        let counts = [0, 5, 8, 10, 15, 20]
        let shown = counts.firstIndex(of: p.memory.processesShown) ?? 2
        addRow(L("prefs.optimizer.processesShown"), popup(counts.map { String($0) }, selected: shown) { [weak self] i in
            guard i < counts.count else { return }
            self?.change { $0.memory.processesShown = counts[i] }
        })

        addSection(L("prefs.optimizer.protectedSection"))
        addNote(L("prefs.optimizer.protectedNote"))
        let pe = BundleListEditor(items: p.memory.userProtectedBundleIDs, placeholder: L("prefs.optimizer.bundlePlaceholder")) { [weak self] set in
            self?.change { $0.memory.userProtectedBundleIDs = set }
        }
        protectedEditor = pe
        stack.addFullWidth(pe.view)

        addSection(L("prefs.optimizer.unprotectedSection"))
        addNote(L("prefs.optimizer.unprotectedNote"))
        let ue = BundleListEditor(items: p.memory.userUnprotectedBundleIDs, placeholder: L("prefs.optimizer.bundlePlaceholder")) { [weak self] set in
            self?.change { $0.memory.userUnprotectedBundleIDs = set }
        }
        unprotectedEditor = ue
        stack.addFullWidth(ue.view)

        addSection(L("prefs.optimizer.builtinSection"))
        addNote(L("prefs.optimizer.builtinNote"))
    }
}
