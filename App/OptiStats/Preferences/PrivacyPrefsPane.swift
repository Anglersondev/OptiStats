import Cocoa
import OptiStatsCore

/// Privacidade: o que o aplicativo faz e não faz com os dados.
final class PrivacyPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.privacy") }
    override var symbolName: String { "hand.raised" }

    override func build() {
        addSection(L("prefs.privacy.section"))
        for key in ["prefs.privacy.noTelemetry", "prefs.privacy.local", "prefs.privacy.noWrite", "prefs.privacy.noKill",
                    "prefs.privacy.redaction", "prefs.privacy.history"] {
            let l = NSTextField.label("•  " + L(key), font: Theme.body(12), lines: 0)
            l.preferredMaxLayoutWidth = Self.contentSize.width - 70
            stack.addFullWidth(l)
        }
        addSection(L("prefs.privacy.permissionsSection"))
        addNote(L("prefs.privacy.permissions"))
    }
}
