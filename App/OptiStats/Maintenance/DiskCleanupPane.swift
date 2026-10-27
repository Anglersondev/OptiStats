import Cocoa
import OptiStatsCore

/// Aba "Disco e cache": varre as categorias da política do Core, mostra tamanhos e move SÓ o que a pessoa marcar
/// para a Lixeira (itens que já estão na Lixeira são apagados de vez, com aviso de irreversível).
/// Nada vem pré-marcado. Varredura e execução rodam em fila de background; nada de timers.
final class DiskCleanupPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.disk", qos: .utility)
    private static let maxRowsPerCategory = 40

    private var items: [CleanupItem]?
    private var scanning = false
    private var working = false
    private var cancelToken: CancelToken?
    private var selected = Set<String>()
    private var space = VolumeSpace.read()

    private weak var moveButton: NSButton?
    private weak var summaryLabel: NSTextField?

    override var paneTitle: String { L("maint.tab.disk") }
    override var symbolName: String { "internaldrive" }

    override func build() {
        moveButton = nil; summaryLabel = nil

        addSection(L("maint.disk.volume"))
        let free = KeyValueRowView(title: L("maint.disk.free"), value: Fmt.bytes(space.available))
        let total = KeyValueRowView(title: L("maint.disk.total"), value: Fmt.bytes(space.total))
        stack.addFullWidth(free)
        stack.addFullWidth(total)

        addSection(L("maint.disk.title"))
        addNote(L("maint.disk.intro"))
        if scanning {
            addNote(L("maint.disk.scanning"))
            stack.addArrangedSubview(button(L("maint.disk.cancelScan")) { [weak self] in self?.cancelScan() })
        } else {
            let b = button(items == nil ? L("maint.disk.scan") : L("maint.disk.rescan")) { [weak self] in self?.startScan() }
            b.isEnabled = !working
            stack.addArrangedSubview(b)
        }

        guard let items else { return }
        if items.isEmpty && !scanning { addNote(L("maint.disk.nothing")) }
        for cat in CleanupCategory.allCases {
            let list = items.filter { $0.category == cat }
            guard !list.isEmpty else { continue }
            addSection("\(L("maint.cat.\(cat.rawValue)"))  ·  \(Fmt.bytes(CleanupScanner.total(list)))")
            addNote(L("maint.catdesc.\(cat.rawValue)"))
            if cat == .trash { addNote(L("maint.disk.trashWarning"), color: Theme.bad) }
            for item in list.prefix(Self.maxRowsPerCategory) { stack.addFullWidth(row(for: item)) }
            if list.count > Self.maxRowsPerCategory {
                addNote(L("maint.disk.more", list.count - Self.maxRowsPerCategory))
            }
        }

        addSection(L("maint.disk.actionSection"))
        let summary = NSTextField.label("", font: Theme.body(), color: Theme.secondaryText)
        summaryLabel = summary
        let move = button(L("maint.disk.move")) { [weak self] in self?.confirmAndMove() }
        moveButton = move
        stack.addFullWidth(MaintUI.spread(summary, [move]))
        updateSummary()
    }

    private func row(for item: CleanupItem) -> NSView {
        let name = (item.path as NSString).lastPathComponent
        let size = MaintUI.sizeLabel(Fmt.bytes(item.bytes))
        if item.category.isDeletable {
            let box = checkbox(name, isOn: selected.contains(item.path)) { [weak self] on in
                guard let self else { return }
                if on { self.selected.insert(item.path) } else { self.selected.remove(item.path) }
                self.updateSummary()
            }
            box.toolTip = item.path
            return MaintUI.spread(box, [size])
        }
        let label = NSTextField.label(name, font: Theme.body(), color: Theme.primaryText)
        label.toolTip = item.path
        let finder = button(L("maint.showInFinder")) { MaintUI.revealInFinder(item.path) }
        finder.controlSize = .small
        return MaintUI.spread(label, [size, finder])
    }

    private func selectedItems() -> [CleanupItem] {
        (items ?? []).filter { selected.contains($0.path) && $0.category.isDeletable }
    }

    private func updateSummary() {
        let sel = selectedItems()
        summaryLabel?.stringValue = sel.isEmpty
            ? L("maint.disk.noneSelected")
            : L("maint.disk.selected", sel.count, Fmt.bytes(CleanupScanner.total(sel)))
        moveButton?.isEnabled = !sel.isEmpty && !working && !scanning
    }

    // MARK: Varredura

    private func startScan() {
        guard !scanning, !working else { return }
        let token = CancelToken()
        cancelToken = token
        scanning = true
        selected.removeAll()
        rebuildSoon()
        let home = NSHomeDirectory()
        Self.queue.async { [weak self] in
            let fs = DiskFileSystem(cancelToken: token)
            let scanner = CleanupScanner(policy: CleanupPolicy(home: home), fs: fs)
            var found: [CleanupItem] = []
            for cat in CleanupCategory.allCases {
                if token.isCancelled { break }
                let minBytes: UInt64 = cat == .largeDownloads ? 100 << 20 : 1
                found += scanner.scan(categories: [cat], minBytes: minBytes)
            }
            let space = VolumeSpace.read()
            DispatchQueue.main.async {
                guard let self, self.cancelToken === token else { return }
                self.scanning = false
                self.cancelToken = nil
                self.space = space
                if !token.isCancelled { self.items = found }
                self.rebuildSoon()
            }
        }
    }

    private func cancelScan() {
        cancelToken?.cancel()
        cancelToken = nil
        scanning = false
        rebuildSoon()
    }

    override func paneDidDisappear() { cancelToken?.cancel() }

    // MARK: Execução

    private func confirmAndMove() {
        let sel = selectedItems()
        guard !sel.isEmpty, !working, !scanning else { return }
        let hasTrash = sel.contains { $0.category == .trash }
        var text = L("maint.disk.confirmText", sel.count, Fmt.bytes(CleanupScanner.total(sel)))
        if hasTrash { text += "\n\n" + L("maint.disk.confirmTrash") }
        MaintUI.confirm(window: view.window, title: L("maint.disk.confirmTitle"), text: text,
                        action: L("maint.disk.move")) { [weak self] ok in
            if ok { self?.execute(sel) }
        }
    }

    private func execute(_ sel: [CleanupItem]) {
        working = true
        rebuildSoon()
        let home = NSHomeDirectory()
        Self.queue.async { [weak self] in
            let fm = FileManager()
            let executor = CleanupExecutor(
                policy: CleanupPolicy(home: home), fs: DiskFileSystem(),
                trash: { try fm.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) },
                removePermanently: { try fm.removeItem(atPath: $0) })
            let report = executor.run(sel)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                self.show(report)
                self.items = nil
                self.selected.removeAll()
                self.space = VolumeSpace.read()
                self.rebuildSoon()
            }
        }
    }

    private func show(_ r: CleanupReport) {
        var lines = [L("maint.disk.reportMoved", r.moved.count, Fmt.bytes(r.movedBytes))]
        if !r.skipped.isEmpty { lines.append(L("maint.disk.reportSkipped", r.skipped.count)) }
        if !r.failed.isEmpty {
            lines.append(L("maint.disk.reportFailed", r.failed.count))
            for f in r.failed.prefix(3) { lines.append("• \((f.item.path as NSString).lastPathComponent): \(f.error)") }
        }
        lines.append("")
        lines.append(L("maint.disk.reportNote"))
        MaintUI.inform(window: view.window, title: L("maint.disk.reportTitle"), text: lines.joined(separator: "\n"))
    }
}
