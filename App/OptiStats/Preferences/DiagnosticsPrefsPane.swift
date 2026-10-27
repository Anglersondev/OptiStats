import Cocoa
import OptiStatsCore
import UniformTypeIdentifiers

/// Diagnóstico: relatório textual SEM dados pessoais (redigido), para copiar ou exportar. Nada é enviado.
final class DiagnosticsPrefsPane: PrefsPaneViewController {
    override var paneTitle: String { L("prefs.tab.diagnostics") }
    override var symbolName: String { "stethoscope" }

    private var textView: NSTextView?
    private var report = ""

    override func build() {
        addSection(L("prefs.diag.section"))
        addNote(L("prefs.diag.note"))

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 270).isActive = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = Theme.number(11)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.string = report
            textView = tv
        }
        stack.addFullWidth(scroll)

        let refresh = button(L("prefs.diag.refresh")) { [weak self] in self?.regenerate() }
        let copy = button(L("prefs.diag.copy")) { [weak self] in self?.copyReport() }
        let export = button(L("prefs.diag.export")) { [weak self] in self?.exportReport() }
        stack.addArrangedSubview(NSStackView.horizontal([refresh, copy, export], spacing: 8))
        addNote(L("prefs.diag.privacyNote"))
    }

    // O relatório é gerado sob demanda (ao abrir a aba ou ao pedir), nunca em segundo plano.
    override func paneDidAppear() { regenerate() }

    private func regenerate() {
        report = Redactor.redact(env.diagnosticsText(), hostName: ProcessInfo.processInfo.hostName)
        textView?.string = report
    }

    private func copyReport() {
        if report.isEmpty { regenerate() }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
    }

    private func exportReport() {
        if report.isEmpty { regenerate() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OptiStats-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let text = report
        let write: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.showError(L("prefs.diag.exportFailed", error.localizedDescription)) }
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: write) } else { write(panel.runModal()) }
    }
}
