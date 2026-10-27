import Cocoa
import UniformTypeIdentifiers
import OptiStatsCore

/// Aba "Disco e cache", em sub-seções: Visão geral, Pastas, Maiores arquivos, Tipos, Antigos, Duplicados, Apps e
/// Caches e limpeza (o fluxo original). A análise (somente leitura) varre o home em fila de background, é cancelável,
/// não segue links, ignora o que não tem permissão (e conta) e NUNCA apaga nada sozinha: arquivos do usuário
/// (grandes/antigos/duplicados) só vão para a Lixeira um a um, com confirmação explícita, e a política do Core
/// (`CleanupCategory.userSelected`) revalida cada caminho. Sem timers próprios.
final class DiskCleanupPane: PrefsPaneViewController {
    private static let queue = DispatchQueue(label: "dev.optistats.maintenance.disk", qos: .utility)
    private static let maxRowsPerCategory = 40
    private static let maxRows = 100

    private enum Section: String, CaseIterable {
        case overview, folders, largest, types, old, duplicates, apps, cleanup
    }

    private var section: Section = .overview
    private var sectionTarget: ActionTarget?

    // Análise
    private var analysis: StorageAnalysis?
    private var analyzing = false
    private var analysisToken: CancelToken?
    private var duplicates: [DuplicateGroup]?
    private var hashing = false
    private var hashToken: CancelToken?
    private var volume = VolumeBreakdown.read()
    private var snapshots: [LocalSnapshot]?
    private var snapshotsLoading = false
    private var expanded = Set<String>()
    private var oldDays = 365
    private var oldMinMB = 10
    private weak var progressLabel: NSTextField?

    // Limpeza de caches (fluxo original)
    private var items: [CleanupItem]?
    private var scanning = false
    private var working = false
    private var cancelToken: CancelToken?
    private var selected = Set<String>()
    private var space = VolumeSpace.read()
    private weak var moveButton: NSButton?
    private weak var summaryLabel: NSTextField?

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Fmt.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    override var paneTitle: String { L("maint.tab.disk") }
    override var symbolName: String { "internaldrive" }

    override func build() {
        moveButton = nil; summaryLabel = nil; progressLabel = nil
        stack.addFullWidth(sectionPicker())
        switch section {
        case .overview: buildOverview()
        case .folders: buildFolders()
        case .largest: buildLargest()
        case .types: buildTypes()
        case .old: buildOld()
        case .duplicates: buildDuplicates()
        case .apps: buildApps()
        case .cleanup: buildCleanup()
        }
    }

    override func paneDidAppear() {
        loadSnapshotsIfNeeded()
    }

    override func paneDidDisappear() {
        cancelToken?.cancel()
        let busy = analyzing || hashing
        analysisToken?.cancel(); analysisToken = nil; analyzing = false
        hashToken?.cancel(); hashToken = nil; hashing = false
        if busy { rebuildSoon() }
    }

    // MARK: Navegação

    private func sectionPicker() -> NSView {
        let labels = Section.allCases.map { L("maint.disk2.sec.\($0.rawValue)") }
        let target = ActionTarget { [weak self] c in
            guard let self, let seg = c as? NSSegmentedControl else { return }
            let i = seg.selectedSegment
            guard i >= 0, i < Section.allCases.count else { return }
            self.section = Section.allCases[i]
            self.rebuildSoon()
        }
        sectionTarget = target
        let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: target,
                                     action: #selector(ActionTarget.fire(_:)))
        seg.selectedSegment = Section.allCases.firstIndex(of: section) ?? 0
        seg.segmentDistribution = .fillProportionally
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

    // MARK: Controles comuns da análise

    /// Botão de varredura + progresso + avisos. Devolve a análise, ou nil se ainda não houver (a seção para por aí).
    private func analysisHeader() -> StorageAnalysis? {
        if analyzing {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.startAnimation(nil)
            stack.addFullWidth(bar)
            let label = addNote(L("maint.disk2.progress", 0, Fmt.bytes(0)))
            progressLabel = label
            stack.addArrangedSubview(button(L("maint.disk2.cancel")) { [weak self] in self?.cancelAnalysis() })
        } else {
            let b = button(analysis == nil ? L("maint.disk2.scan") : L("maint.disk2.rescan")) { [weak self] in self?.startAnalysis() }
            b.isEnabled = !working
            if analysis == nil {
                addNote(L("maint.disk2.intro"))
            }
            stack.addArrangedSubview(b)
        }
        guard let a = analysis else {
            if !analyzing { addNote(L("maint.disk2.needScan")) }
            return nil
        }
        if analyzing { return a }
        addNote(L("maint.disk2.scanned", a.fileCount, Fmt.bytes(a.totalBytes)))
        if a.deniedCount > 0 {
            addNote(L("maint.disk2.denied", a.deniedCount), color: Theme.warn)
            addNote(L("maint.disk2.fda"))
        }
        return a
    }

    private func finderButton(_ path: String) -> NSButton {
        let b = button(L("maint.showInFinder")) { MaintUI.revealInFinder(path) }
        b.controlSize = .small
        return b
    }

    private func trashButton(path: String, bytes: UInt64) -> NSButton {
        let b = button(L("maint.disk2.trash.button")) { [weak self] in self?.confirmTrash(path: path, bytes: bytes) }
        b.controlSize = .small
        b.isEnabled = !working
        return b
    }

    private func mutedLabel(_ text: String, width: CGFloat? = nil) -> NSTextField {
        let f = NSTextField.label(text, font: Theme.number(11), color: Theme.secondaryText, alignment: .right)
        f.setContentHuggingPriority(.required, for: .horizontal)
        if let w = width { f.widthAnchor.constraint(equalToConstant: w).isActive = true }
        return f
    }

    private static func color(for kind: FileKind) -> NSColor {
        switch kind {
        case .video: return .systemPurple
        case .image: return .systemPink
        case .audio: return .systemYellow
        case .document: return .systemBlue
        case .archive: return .systemOrange
        case .code: return .systemTeal
        case .app: return .systemGreen
        case .other: return .systemGray
        }
    }

    /// Linha de arquivo: nome + pasta, [data], tamanho, Mostrar no Finder e Mover para a Lixeira (com confirmação).
    private func fileRow(_ r: FileRecord, showDate: Bool) -> NSView {
        let name = NSTextField.label(r.name, font: Theme.body(), color: Theme.primaryText)
        let dir = NSTextField.label(StoragePath.parent(r.path), font: Theme.caption(10), color: Theme.tertiaryText)
        for l in [name, dir] {
            l.lineBreakMode = .byTruncatingMiddle
            l.toolTip = r.path
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let left = NSStackView.vertical([name, dir], spacing: 1)
        var right: [NSView] = []
        if showDate {
            let when = r.lastUsed.map { dateFormatter.string(from: $0) } ?? Fmt.dash
            right.append(mutedLabel(when, width: 96))
        }
        right.append(MaintUI.sizeLabel(Fmt.bytes(r.bytes)))
        right.append(finderButton(r.path))
        right.append(trashButton(path: r.path, bytes: r.bytes))
        return MaintUI.spread(left, right)
    }

    // MARK: Visão geral

    private func buildOverview() {
        addSection(L("maint.disk2.volTitle"))
        if let v = volume {
            let bar = SegmentedBarView(height: 14)
            let t = Double(max(v.total, 1))
            bar.segments = [
                .init(fraction: Double(v.used) / t, color: .systemBlue),
                .init(fraction: Double(v.purgeable) / t, color: .systemOrange)
            ]
            bar.toolTip = "\(L("maint.disk2.volUsed")): \(Fmt.bytes(v.used))"
            stack.addFullWidth(bar)
            func line(_ key: String, _ bytes: UInt64, _ dot: NSColor?) {
                stack.addFullWidth(KeyValueRowView(title: L(key), value: "\(Fmt.bytes(bytes)) · \(Fmt.percent(Double(bytes) / t, decimals: 1))", dotColor: dot))
            }
            line("maint.disk2.volUsed", v.used, .systemBlue)
            line("maint.disk2.volPurgeable", v.purgeable, .systemOrange)
            line("maint.disk2.volFree", v.free, Theme.track)
            stack.addFullWidth(KeyValueRowView(title: L("maint.disk.total"), value: Fmt.bytes(v.total)))
            addNote(L("maint.disk2.volNote"))
        } else {
            addNote(L("maint.disk2.volUnknown"))
        }

        addSection(L("maint.disk2.tm.title"))
        if let s = snapshots {
            if s.isEmpty {
                addNote(L("maint.disk2.tm.none"))
            } else {
                stack.addFullWidth(KeyValueRowView(title: L("maint.disk2.tm.count"), value: "\(s.count)"))
                for snap in s.suffix(5).reversed() { stack.addFullWidth(KeyValueRowView(title: snap.stamp, value: "")) }
                addNote(L("maint.disk2.tm.note"))
            }
        } else {
            addNote(L("maint.disk2.tm.loading"))
        }

        addSection(L("maint.disk2.sec.types"))
        guard let a = analysisHeader() else { return }
        if !analyzing { addTypeBreakdown(a) }
        if !analyzing {
            addSection(L("maint.disk2.export.title"))
            let csv = button(L("maint.disk2.export.csv")) { [weak self] in self?.export(csv: true) }
            let txt = button(L("maint.disk2.export.text")) { [weak self] in self?.export(csv: false) }
            stack.addArrangedSubview(NSStackView.horizontal([txt, csv], spacing: 8))
        }
    }

    private func addTypeBreakdown(_ a: StorageAnalysis) {
        let bar = SegmentedBarView(height: 14)
        bar.segments = a.types.map { .init(fraction: $0.fraction, color: Self.color(for: $0.kind)) }
        stack.addFullWidth(bar)
        for t in a.types {
            let value = "\(Fmt.bytes(t.bytes)) · \(Fmt.percent(t.fraction, decimals: 1)) · \(L("maint.disk2.types.files", t.fileCount))"
            stack.addFullWidth(KeyValueRowView(title: L("maint.disk2.kind.\(t.kind.rawValue)"), value: value, dotColor: Self.color(for: t.kind)))
        }
    }

    // MARK: Pastas

    private func buildFolders() {
        addSection(L("maint.disk2.folders.title"))
        addNote(L("maint.disk2.folders.note"))
        guard let a = analysisHeader(), !analyzing else { return }
        for f in a.folders.prefix(Self.maxRows) {
            stack.addFullWidth(folderRow(f, level: 0))
            if expanded.contains(f.path) {
                for c in f.children.prefix(Self.maxRowsPerCategory) { stack.addFullWidth(folderRow(c, level: 1)) }
                if f.children.count > Self.maxRowsPerCategory {
                    addNote(L("maint.disk.more", f.children.count - Self.maxRowsPerCategory))
                }
            }
        }
        if a.folders.count > Self.maxRows { addNote(L("maint.disk.more", a.folders.count - Self.maxRows)) }
    }

    private func folderRow(_ f: FolderUsage, level: Int) -> NSView {
        let indent = NSView(); indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: CGFloat(level) * 22).isActive = true
        let lead: NSView
        if level == 0 && f.isDirectory && !f.children.isEmpty {
            let isOpen = expanded.contains(f.path)
            let path = f.path
            let b = iconButton(symbol: isOpen ? "chevron.down" : "chevron.right", fallback: isOpen ? "▾" : "▸", label: f.name) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(path) { self.expanded.remove(path) } else { self.expanded.insert(path) }
                self.rebuildSoon()
            }
            b.controlSize = .small
            lead = b
        } else {
            let sp = NSView(); sp.translatesAutoresizingMaskIntoConstraints = false
            sp.widthAnchor.constraint(equalToConstant: 28).isActive = true
            lead = sp
        }
        let name = NSTextField.label(f.name, font: level == 0 ? Theme.body() : Theme.body(11),
                                     color: level == 0 ? Theme.primaryText : Theme.secondaryText)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = f.path
        let left = NSStackView.horizontal([indent, lead, name], spacing: 4)
        return MaintUI.spread(left, [mutedLabel(Fmt.percent(f.fraction, decimals: 1), width: 52),
                                     MaintUI.sizeLabel(Fmt.bytes(f.bytes)), finderButton(f.path)])
    }

    // MARK: Maiores arquivos

    private func buildLargest() {
        addSection(L("maint.disk2.largest.title"))
        addNote(L("maint.disk2.largest.note"))
        guard let a = analysisHeader(), !analyzing else { return }
        let list = a.largestFiles(limit: Self.maxRows)
        if list.isEmpty { addNote(L("maint.disk2.nothing")) }
        for r in list { stack.addFullWidth(fileRow(r, showDate: true)) }
    }

    // MARK: Tipos

    private func buildTypes() {
        addSection(L("maint.disk2.types.title"))
        guard let a = analysisHeader(), !analyzing else { return }
        addTypeBreakdown(a)
    }

    // MARK: Antigos

    private func buildOld() {
        addSection(L("maint.disk2.old.title"))
        addNote(L("maint.disk2.old.note"))
        let dayValues = [30, 90, 180, 365, 730]
        let sizeValues = [10, 100, 500, 1024]
        let days = popup(dayValues.map { L("maint.disk2.old.daysFmt", $0) }, selected: dayValues.firstIndex(of: oldDays) ?? 3) { [weak self] i in
            guard let self, i >= 0, i < dayValues.count else { return }
            self.oldDays = dayValues[i]; self.rebuildSoon()
        }
        let sizes = popup(sizeValues.map { L("maint.disk2.old.mbFmt", $0) }, selected: sizeValues.firstIndex(of: oldMinMB) ?? 0) { [weak self] i in
            guard let self, i >= 0, i < sizeValues.count else { return }
            self.oldMinMB = sizeValues[i]; self.rebuildSoon()
        }
        addRow(L("maint.disk2.old.days"), days)
        addRow(L("maint.disk2.old.minsize"), sizes)
        guard let a = analysisHeader(), !analyzing else { return }
        let old = a.oldFiles(olderThanDays: oldDays, minBytes: UInt64(oldMinMB) << 20, now: Date())
        if old.isEmpty { addNote(L("maint.disk2.nothing")) } else {
            addNote(L("maint.disk2.old.total", old.count, Fmt.bytes(old.reduce(0) { $0 + $1.bytes })))
        }
        for r in old.prefix(Self.maxRows) { stack.addFullWidth(fileRow(r, showDate: true)) }
        if old.count > Self.maxRows { addNote(L("maint.disk.more", old.count - Self.maxRows)) }
    }

    // MARK: Duplicados

    private func buildDuplicates() {
        addSection(L("maint.disk2.dup.title"))
        addNote(L("maint.disk2.dup.note"))
        guard let a = analysisHeader(), !analyzing else { return }
        if hashing {
            let bar = NSProgressIndicator()
            bar.style = .bar; bar.isIndeterminate = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.startAnimation(nil)
            stack.addFullWidth(bar)
            progressLabel = addNote(L("maint.disk2.dup.hashing", 0, a.duplicateCandidates.count))
            stack.addArrangedSubview(button(L("maint.disk2.cancel")) { [weak self] in self?.cancelHashing() })
            return
        }
        let find = button(duplicates == nil ? L("maint.disk2.dup.find") : L("maint.disk2.dup.findAgain")) { [weak self] in self?.startHashing() }
        find.isEnabled = !working && !a.duplicateCandidates.isEmpty
        stack.addArrangedSubview(find)
        guard let groups = duplicates else {
            if a.duplicateCandidates.isEmpty { addNote(L("maint.disk2.nothing")) }
            else { addNote(L("maint.disk2.dup.candidates", a.duplicateCandidates.count)) }
            return
        }
        if groups.isEmpty { addNote(L("maint.disk2.nothing")); return }
        addNote(L("maint.disk2.dup.reclaim", Fmt.bytes(DuplicateFinder.totalReclaimable(groups))))
        for g in groups.prefix(50) {
            stack.addFullWidth(SectionHeaderView("\(L("maint.disk2.dup.group", g.paths.count, Fmt.bytes(g.size)))  ·  \(L("maint.disk2.dup.reclaim", Fmt.bytes(g.reclaimableBytes)))"))
            for p in g.paths {
                let name = NSTextField.label(StoragePath.lastComponent(p) + (p == g.keep ? "  (\(L("maint.disk2.dup.keep")))" : ""),
                                             font: Theme.body(), color: Theme.primaryText)
                let dir = NSTextField.label(StoragePath.parent(p), font: Theme.caption(10), color: Theme.tertiaryText)
                for l in [name, dir] {
                    l.lineBreakMode = .byTruncatingMiddle; l.toolTip = p
                    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                }
                let left = NSStackView.vertical([name, dir], spacing: 1)
                let trash = trashButton(path: p, bytes: g.size)
                // Nunca oferece remover a última cópia: o grupo precisa continuar com pelo menos uma.
                trash.isEnabled = trash.isEnabled && g.isValidTrashSelection([p])
                stack.addFullWidth(MaintUI.spread(left, [finderButton(p), trash]))
            }
        }
        if groups.count > 50 { addNote(L("maint.disk.more", groups.count - 50)) }
    }

    // MARK: Apps

    private func buildApps() {
        addSection(L("maint.disk2.apps.title"))
        addNote(L("maint.disk2.apps.note"))
        guard let a = analysisHeader(), !analyzing else { return }
        if a.apps.isEmpty { addNote(L("maint.disk2.nothing")) }
        for u in a.apps.prefix(Self.maxRows) {
            let name = NSTextField.label(u.displayName, font: Theme.body(), color: Theme.primaryText)
            let detail = L("maint.disk2.apps.breakdown", Fmt.bytes(u.caches), Fmt.bytes(u.applicationSupport),
                           Fmt.bytes(u.containers), Fmt.bytes(u.logs))
            let sub = NSTextField.label(detail, font: Theme.caption(10), color: Theme.tertiaryText)
            for l in [name, sub] { l.lineBreakMode = .byTruncatingTail; l.toolTip = u.key; l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
            stack.addFullWidth(MaintUI.spread(NSStackView.vertical([name, sub], spacing: 1), [MaintUI.sizeLabel(Fmt.bytes(u.total))]))
        }
        if a.apps.count > Self.maxRows { addNote(L("maint.disk.more", a.apps.count - Self.maxRows)) }
    }

    // MARK: Caches e limpeza (fluxo original + categorias de desenvolvedor)

    private func buildCleanup() {
        addSection(L("maint.disk.volume"))
        stack.addFullWidth(KeyValueRowView(title: L("maint.disk.free"), value: Fmt.bytes(space.available)))
        stack.addFullWidth(KeyValueRowView(title: L("maint.disk.total"), value: Fmt.bytes(space.total)))

        addSection(L("maint.disk2.dev.title"))
        addNote(L("maint.disk2.dev.note"))
        if let a = analysis {
            if a.developer.isEmpty { addNote(L("maint.disk2.nothing")) }
            for d in a.developer {
                let name = NSTextField.label(L("maint.disk2.dev.\(d.kind.rawValue)"), font: Theme.body(), color: Theme.primaryText)
                let tag = NSTextField.label(d.isReportOnly ? L("maint.disk2.dev.reportOnly") : L("maint.disk2.dev.removable"),
                                            font: Theme.caption(10), color: d.isReportOnly ? Theme.warn : Theme.good)
                name.toolTip = d.path
                stack.addFullWidth(MaintUI.spread(NSStackView.horizontal([name, tag], spacing: 8),
                                                  [MaintUI.sizeLabel(Fmt.bytes(d.bytes)), finderButton(d.path)]))
            }
        } else {
            addNote(L("maint.disk2.dev.needScan"))
        }

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
        for cat in CleanupCategory.allCases where cat != .userSelected {
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
        return MaintUI.spread(label, [size, finderButton(item.path)])
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

    // MARK: Análise (somente leitura)

    private func startAnalysis() {
        guard !analyzing, !working else { return }
        let token = CancelToken()
        analysisToken = token
        analyzing = true
        duplicates = nil
        rebuildSoon()
        let home = NSHomeDirectory()
        Self.queue.async { [weak self] in
            let options = InstalledAppCatalog.options(base: StorageScanOptions())
            let analyzer = StorageAnalyzer(policy: CleanupPolicy(home: home), tree: DiskTreeProvider(), options: options)
            var lastTick = Date.distantPast
            let result = analyzer.analyze(isCancelled: { token.isCancelled }, progress: { p in
                let now = Date()
                guard now.timeIntervalSince(lastTick) > 0.25 else { return }
                lastTick = now
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.analysisToken === token else { return }
                    self.progressLabel?.stringValue = L("maint.disk2.progress", p.files, Fmt.bytes(p.bytes))
                }
            })
            let vol = VolumeBreakdown.read()
            DispatchQueue.main.async {
                guard let self, self.analysisToken === token else { return }
                self.analyzing = false
                self.analysisToken = nil
                self.volume = vol
                if !token.isCancelled && !result.wasCancelled { self.analysis = result }
                self.rebuildSoon()
            }
        }
    }

    private func cancelAnalysis() {
        analysisToken?.cancel()
        analysisToken = nil
        analyzing = false
        rebuildSoon()
    }

    private func startHashing() {
        guard let a = analysis, !hashing, !working else { return }
        let groups = a.duplicateCandidates
        let totalFiles = max(1, groups.reduce(0) { $0 + $1.paths.count })
        let token = CancelToken()
        hashToken = token
        hashing = true
        rebuildSoon()
        Self.queue.async { [weak self] in
            var done = 0
            var lastTick = Date.distantPast
            let found = DuplicateFinder.find(sizeGroups: groups, hash: { path in
                done += 1
                let now = Date()
                if now.timeIntervalSince(lastTick) > 0.25 {
                    lastTick = now
                    let n = done
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.hashToken === token else { return }
                        self.progressLabel?.stringValue = L("maint.disk2.dup.hashing", n, totalFiles)
                    }
                }
                return PartialHasher.hash(path: path)
            }, isCancelled: { token.isCancelled })
            DispatchQueue.main.async {
                guard let self, self.hashToken === token else { return }
                self.hashing = false
                self.hashToken = nil
                if !token.isCancelled { self.duplicates = found }
                self.rebuildSoon()
            }
        }
    }

    private func cancelHashing() {
        hashToken?.cancel()
        hashToken = nil
        hashing = false
        rebuildSoon()
    }

    private func loadSnapshotsIfNeeded() {
        guard snapshots == nil, !snapshotsLoading else { return }
        snapshotsLoading = true
        Self.queue.async { [weak self] in
            let list = TimeMachineInfo.localSnapshots()
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotsLoading = false
                self.snapshots = list
                if self.section == .overview { self.rebuildSoon() }
            }
        }
    }

    // MARK: Mover UM arquivo do usuário para a Lixeira (confirmação explícita por arquivo)

    private func confirmTrash(path: String, bytes: UInt64) {
        guard !working else { return }
        let name = StoragePath.lastComponent(path)
        MaintUI.confirm(window: view.window, title: L("maint.disk2.trash.title"),
                        text: L("maint.disk2.trash.text", name, Fmt.bytes(bytes), path),
                        action: L("maint.disk2.trash.action")) { [weak self] ok in
            if ok { self?.trashUserFile(path: path, bytes: bytes) }
        }
    }

    private func trashUserFile(path: String, bytes: UInt64) {
        guard !working else { return }
        working = true
        rebuildSoon()
        let home = NSHomeDirectory()
        Self.queue.async { [weak self] in
            let fm = FileManager()
            let executor = CleanupExecutor(
                policy: CleanupPolicy(home: home), fs: DiskFileSystem(),
                trash: { try fm.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) })
            let report = executor.run([CleanupItem(path: path, category: .userSelected, bytes: bytes)])
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                if report.moved.isEmpty {
                    let reason = report.failed.first?.error ?? L("maint.disk2.trash.blocked")
                    MaintUI.inform(window: self.view.window, title: L("maint.disk2.trash.failedTitle"), text: reason)
                } else {
                    self.forget(path)
                }
                self.volume = VolumeBreakdown.read()
                self.space = VolumeSpace.read()
                self.rebuildSoon()
            }
        }
    }

    /// Tira o arquivo das listas em memória (os totais de pasta só se atualizam numa nova varredura).
    private func forget(_ path: String) {
        analysis?.records.removeAll { $0.path == path }
        duplicates = duplicates?.compactMap { $0.removing(path) }
    }

    // MARK: Exportar relatório

    private func export(csv: Bool) {
        guard let a = analysis else { return }
        let old = a.oldFiles(olderThanDays: oldDays, minBytes: UInt64(oldMinMB) << 20, now: Date())
        let dups = duplicates ?? []
        let content = csv
            ? StorageReport.csv(analysis: a, duplicates: dups, oldFiles: old)
            : DiskReportText.make(a, duplicates: dups, oldFiles: old, volume: volume)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "OptiStats-disk.csv" : "OptiStats-disk.txt"
        panel.allowedContentTypes = [csv ? UTType.commaSeparatedText : UTType.plainText]
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.showError(L("maint.disk2.export.failed", error.localizedDescription)) }
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    // MARK: Varredura de caches (fluxo original)

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
            for cat in CleanupCategory.allCases where cat != .userSelected {
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

    // MARK: Execução da limpeza de caches

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
                self.volume = VolumeBreakdown.read()
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
