import Cocoa
import OptiStatsCore

/// Alvo de ação por closure (NSControl exige target/action Objective-C).
final class ActionTarget: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { if let c = sender as? NSControl { handler(c) } }
}

enum PrefsText {
    static func kindName(_ kind: WidgetKind) -> String { L("shell.kind.\(kind.rawValue)") }
    static func collectorName(_ id: CollectorID) -> String { L("prefs.collector.\(id.rawValue)") }
    static func profileName(_ p: SamplingProfile) -> String { L("prefs.profile.\(p.rawValue)") }
}

/// Base das abas: pilha vertical rolável + auxiliares para controles ligados às preferências.
/// Regra: nenhuma aba cria timers; abas que precisam de dados vivos declaram demanda só enquanto visíveis.
class PrefsPaneViewController: NSViewController {
    static let contentSize = NSSize(width: 980, height: 560)

    let env: AppEnvironment
    let stack = NSStackView.vertical([], spacing: 10)
    var onLanguageChanged: (() -> Void)?
    private var targets: [ActionTarget] = []

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        title = paneTitle
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    // MARK: Para subclasses

    var paneTitle: String { "" }
    var symbolName: String { "gearshape" }
    /// Monta o conteúdo em `stack`. Chamado de novo em `rebuild()`.
    func build() {}
    func paneDidAppear() {}
    func paneDidDisappear() {}

    // MARK: Ciclo de vida

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: Self.contentSize))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20)
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        view = scroll
        preferredContentSize = Self.contentSize
        build()
    }

    override func viewDidAppear() { super.viewDidAppear(); paneDidAppear() }
    override func viewDidDisappear() { super.viewDidDisappear(); paneDidDisappear() }

    /// Reconstrói depois do ciclo de eventos atual (nunca destrua o controle que está disparando a ação).
    func rebuildSoon() {
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        targets.removeAll()
        build()
    }

    // MARK: Preferências

    /// Aplica a mudança, grava e reaplica (idioma, aparência, demanda, barra).
    func change(_ mutate: @escaping (inout Preferences) -> Void) {
        env.preferences.update(mutate)
        env.applyPreferences()
    }

    // MARK: Construtores de controles

    private func wire(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let t = ActionTarget(handler)
        targets.append(t)
        control.target = t
        control.action = #selector(ActionTarget.fire(_:))
    }

    func addSection(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
            stack.addArrangedSubview(spacer)
        }
        stack.addFullWidth(SectionHeaderView(title))
    }

    @discardableResult
    func addNote(_ text: String, color: NSColor = Theme.secondaryText) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.body(11), color: color, lines: 0)
        f.preferredMaxLayoutWidth = Self.contentSize.width - 70
        stack.addFullWidth(f)
        return f
    }

    func checkbox(_ title: String, isOn: Bool, _ handler: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = isOn ? .on : .off
        b.translatesAutoresizingMaskIntoConstraints = false
        wire(b) { c in handler((c as? NSButton)?.state == .on) }
        return b
    }

    func popup(_ titles: [String], selected: Int, _ handler: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        if selected >= 0 && selected < titles.count { p.selectItem(at: selected) }
        p.translatesAutoresizingMaskIntoConstraints = false
        wire(p) { c in handler((c as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        return p
    }

    func button(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        wire(b) { _ in handler() }
        return b
    }

    func iconButton(symbol: String, fallback: String, label: String, _ handler: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: fallback, target: nil, action: nil)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            b.image = img
            b.title = ""
        }
        b.bezelStyle = .texturedRounded
        b.setAccessibilityLabel(label)
        b.toolTip = label
        b.translatesAutoresizingMaskIntoConstraints = false
        wire(b) { _ in handler() }
        return b
    }

    /// Linha "Rótulo:  [controle]" com rótulo alinhado à direita em coluna fixa.
    func formRow(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField.label(label, alignment: .right)
        l.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let row = NSStackView.horizontal([l, control], spacing: 10)
        row.alignment = .firstBaseline
        return row
    }

    func addRow(_ label: String, _ control: NSView) { stack.addArrangedSubview(formRow(label, control)) }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: L("prefs.ok"))
        if let w = view.window { alert.beginSheetModal(for: w, completionHandler: nil) } else { alert.runModal() }
    }

    deinit { targets.removeAll() }
}

/// Lista editável de bundle IDs (tabela de uma coluna + campo para adicionar + remover).
final class BundleListEditor: NSObject, NSTableViewDataSource {
    private var items: [String]
    private let table = NSTableView()
    private let field = NSTextField()
    private let onChange: (Set<String>) -> Void
    private var targets: [ActionTarget] = []
    let view: NSView

    init(items: Set<String>, placeholder: String, onChange: @escaping (Set<String>) -> Void) {
        self.items = items.sorted()
        self.onChange = onChange

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: L("prefs.add"), target: nil, action: nil)
        let remove = NSButton(title: L("prefs.remove"), target: nil, action: nil)
        let controls = NSStackView.horizontal([field, add, remove], spacing: 8)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let box = NSStackView.vertical([scroll, controls], spacing: 6)
        scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor).isActive = true
        scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor).isActive = true
        controls.leadingAnchor.constraint(equalTo: box.leadingAnchor).isActive = true
        controls.trailingAnchor.constraint(equalTo: box.trailingAnchor).isActive = true
        view = box
        super.init()

        table.dataSource = self
        let addT = ActionTarget { [weak self] _ in self?.addItem() }
        let remT = ActionTarget { [weak self] _ in self?.removeSelected() }
        targets = [addT, remT]
        add.target = addT; add.action = #selector(ActionTarget.fire(_:))
        remove.target = remT; remove.action = #selector(ActionTarget.fire(_:))
        field.target = addT; field.action = #selector(ActionTarget.fire(_:))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        row < items.count ? items[row] : nil
    }

    private func addItem() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bundle ID válido: sem espaços e com ao menos um ponto (ex.: com.exemplo.app).
        guard !text.isEmpty, !text.contains(" "), text.contains("."), !items.contains(text) else { NSSound.beep(); return }
        items.append(text); items.sort()
        field.stringValue = ""
        table.reloadData()
        onChange(Set(items))
    }

    private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        items.remove(at: row)
        table.reloadData()
        onChange(Set(items))
    }
}
