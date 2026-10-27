import Cocoa
import OptiStatsCore

/// Janela "Sobre": versão, privacidade e avisos de licença.
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: (() -> Void)?

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        onClose?()
    }

    private func makeWindow() -> NSWindow {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField.label("OptiStats", font: Theme.title(22), alignment: .center)
        let ver = NSTextField.label(L("about.version", version, build), font: Theme.body(11), color: Theme.secondaryText, alignment: .center)
        let tagline = NSTextField.label(L("about.tagline"), font: Theme.body(12), color: Theme.secondaryText, alignment: .center, lines: 0)
        tagline.preferredMaxLayoutWidth = 420
        let privacy = NSTextField.label(L("about.privacy"), font: Theme.body(11), color: Theme.secondaryText, alignment: .center, lines: 0)
        privacy.preferredMaxLayoutWidth = 420

        func link(_ text: String, _ url: String) -> NSTextField {
            let f = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: [
                .link: URL(string: url) as Any, .font: Theme.body(12), .foregroundColor: NSColor.linkColor]))
            f.allowsEditingTextAttributes = true
            f.isSelectable = true
            return f
        }
        let author = NSStackView.horizontal([NSTextField.label(L("about.by"), font: Theme.body(11), color: Theme.secondaryText),
                                             link("GitHub: Anglersondev", "https://github.com/Anglersondev"),
                                             link("anglerson.com.br", "https://anglerson.com.br")], spacing: 10)
        // Frase de apoio (segue o idioma do sistema/Ajustes) com o link de doação.
        let supportText = NSMutableAttributedString(string: L("about.support") + " ",
                                                    attributes: [.font: Theme.body(11), .foregroundColor: NSColor.secondaryLabelColor])
        supportText.append(NSAttributedString(string: "pixgg.com/Anglerson", attributes: [
            .link: URL(string: "https://pixgg.com/Anglerson") as Any, .font: Theme.body(11), .foregroundColor: NSColor.linkColor]))
        let support = NSTextField(labelWithAttributedString: supportText)
        support.allowsEditingTextAttributes = true
        support.isSelectable = true
        support.alignment = .center
        support.lineBreakMode = .byWordWrapping
        support.maximumNumberOfLines = 0
        support.preferredMaxLayoutWidth = 420
        let header = NSStackView.vertical([icon, name, ver, tagline, privacy, author, support], spacing: 6)
        header.alignment = .centerX

        let licenseTitle = SectionHeaderView(L("about.licenses"))

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = Theme.number(10)
            tv.textColor = Theme.primaryText
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.string = Self.licenseNotice
        }

        let column = NSStackView.vertical([header, licenseTitle, scroll], spacing: 12)
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        header.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        header.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
        scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(equalToConstant: 460)
        ])

        let vc = NSViewController()
        vc.view = root
        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .closable]
        w.title = L("about.title")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    /// Avisos de terceiros em texto fixo (notas legais não são traduzidas).
    static let licenseNotice = """
    OptiStats
    Copyright (c) OptiStats contributors.

    Third-party notices

    This project adapts ideas and, where indicated in the source, portions of the
    open-source project "Stats" (https://github.com/exelban/stats), licensed under
    the MIT License:

    MIT License

    Copyright (c) 2019 Serhiy Mytrovtsiy

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
