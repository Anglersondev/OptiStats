import Cocoa
import Darwin
import OptiStatsCore

/// Janela "todos os processos": tabela completa (nome, PID, memória, CPU, usuário), com busca, ordenação,
/// agrupamento por app e ações seguras. Amostra por conta própria, só enquanto estiver visível.
final class ProcessBrowserWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Row {
        var name: String
        var pid: Int32
        var count: Int
        var bytes: UInt64
        var cores: Double
        var user: String
        var path: String?
        var identity: ProcessIdentity?
        var ownedByMe: Bool
    }

    private let appsController = MacAppController()
    private var window: NSWindow?
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let groupBox = NSButton(checkboxWithTitle: L("procs.group"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let quitButton = NSButton(title: L("procs.quit"), target: nil, action: nil)
    private let revealButton = NSButton(title: L("procs.reveal"), target: nil, action: nil)

    private var rows: [Row] = []
    private var shown: [Row] = []
    private var sortKey = "bytes"
    private var ascending = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.optistats.procbrowser", qos: .utility)
    private let calculator = ProcessCPUCalculator()   // só acessado em `queue`
    private let timebase = Sys.machTimebase
    private var userNames: [UInt32: String] = [:]
    private var grouped = true
    private let myUID = getuid()

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startSampling()
    }

    // MARK: Janela

    private func build() {
        let columns: [(String, String, CGFloat, Bool)] = [
            ("name", L("procs.col.name"), 260, true), ("pid", L("procs.col.pid"), 70, false),
            ("bytes", L("procs.col.memory"), 100, false), ("cpu", L("procs.col.cpu"), 70, false),
            ("user", L("procs.col.user"), 110, true)
        ]
        for (id, title, width, asc) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: asc)
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "bytes", ascending: false)]
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L("procs.search")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        groupBox.state = .on
        groupBox.target = self; groupBox.action = #selector(groupToggled)
        quitButton.target = self; quitButton.action = #selector(quitTapped)
        revealButton.target = self; revealButton.action = #selector(revealTapped)
        quitButton.isEnabled = false; revealButton.isEnabled = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [searchField, groupBox, NSView(), revealButton, quitButton])
        top.spacing = 10
        top.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(top); content.addSubview(scroll); content.addSubview(status)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("procs.title")
        w.contentView = content
        w.minSize = NSSize(width: 560, height: 320)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("OptiStatsProcesses")
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) { stopSampling() }

    // MARK: Amostragem (só com a janela aberta)

    private func startSampling() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func stopSampling() {
        timer?.cancel(); timer = nil
        queue.async { [calculator] in _ = calculator.update(cpuTimeNs: [:], at: 0) }
        rows = []; shown = []
        table.reloadData()
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var samples: [ProcessSample] = []
        var cpuNs: [ProcessIdentity: UInt64] = [:]
        var denied = 0
        for pid in ProcReader.allPIDs() {
            guard let bsd = ProcReader.bsdInfo(pid) else { continue }
            let identity = ProcessIdentity(pid: pid, startTime: ProcReader.startTime(bsd))
            guard let ru = ProcReader.rusage(pid) else { denied += 1; continue }
            let path = ProcReader.path(pid)
            let name = ProcReader.name(pid) ?? path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
            let ns = timebase.nanoseconds(ru.ri_user_time &+ ru.ri_system_time)
            cpuNs[identity] = ns
            samples.append(ProcessSample(identity: identity, name: name, executablePath: path, uid: bsd.pbi_uid,
                                         footprintBytes: ru.ri_phys_footprint, residentBytes: ru.ri_resident_size, cpuTimeNs: ns))
        }
        var cpu: [ProcessIdentity: Double] = [:]
        for r in calculator.update(cpuTimeNs: cpuNs, at: now) { cpu[r.identity] = r.coresBusy }

        var flat: [Row] = []
        for s in samples {
            flat.append(Row(name: s.name, pid: s.identity.pid, count: 1, bytes: s.footprintBytes ?? 0,
                            cores: cpu[s.identity] ?? 0, user: userName(s.uid), path: s.executablePath,
                            identity: s.identity, ownedByMe: s.uid == myUID))
        }
        var groupedRows: [Row] = []
        for g in ProcessGrouper.group(samples) {
            let leader = g.members.first { $0.identity == g.leader } ?? g.members.max { ($0.footprintBytes ?? 0) < ($1.footprintBytes ?? 0) }
            groupedRows.append(Row(name: g.displayName, pid: leader?.identity.pid ?? 0, count: g.processCount, bytes: g.footprintBytes,
                                   cores: g.members.reduce(0) { $0 + (cpu[$1.identity] ?? 0) }, user: leader.map { userName($0.uid) } ?? "",
                                   path: g.bundlePath ?? leader?.executablePath, identity: g.leader ?? leader?.identity,
                                   ownedByMe: g.members.allSatisfy { $0.uid == myUID }))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.rows = self.grouped ? groupedRows : flat
            self.denied = denied
            self.total = flat.count
            self.applyFilter()
        }
    }

    private var denied = 0
    private var total = 0

    private func userName(_ uid: UInt32) -> String {
        if let n = userNames[uid] { return n }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = n
        return n
    }

    // MARK: Lista

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = q.isEmpty ? rows : rows.filter { $0.name.lowercased().contains(q) || String($0.pid) == q || $0.user.lowercased().contains(q) }
        list.sort { a, b in
            let r: Bool
            switch sortKey {
            case "name": r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "pid": r = a.pid < b.pid
            case "cpu": r = a.cores < b.cores
            case "user": r = a.user < b.user
            default: r = a.bytes < b.bytes
            }
            return ascending ? r : !r
        }
        let selectedPID = selectedRow?.pid
        shown = list
        table.reloadData()
        if let p = selectedPID, let i = shown.firstIndex(where: { $0.pid == p }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        let sum = shown.reduce(UInt64(0)) { $0 + $1.bytes }
        var text = L("procs.status", shown.count, total, Fmt.bytes(sum))
        if denied > 0 { text += " · " + L("procs.denied", denied) }
        status.stringValue = text
        updateButtons()
    }

    private var selectedRow: Row? {
        let i = table.selectedRow
        return i >= 0 && i < shown.count ? shown[i] : nil
    }

    private func updateButtons() {
        let r = selectedRow
        revealButton.isEnabled = r?.path != nil
        quitButton.isEnabled = r?.ownedByMe == true && r?.identity != nil && r?.pid != getpid()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < shown.count else { return nil }
        let r = shown[row]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.font = id.rawValue == "name" || id.rawValue == "user" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            return f
        }()
        switch id.rawValue {
        case "name": cell.stringValue = r.count > 1 ? "\(r.name)  (\(r.count))" : r.name
        case "pid": cell.stringValue = r.pid > 0 ? String(r.pid) : "—"
        case "bytes": cell.stringValue = Fmt.bytes(r.bytes)
        case "cpu": cell.stringValue = String(format: "%.1f%%", r.cores * 100)
        default: cell.stringValue = r.user
        }
        cell.alignment = (id.rawValue == "pid" || id.rawValue == "bytes" || id.rawValue == "cpu") ? .right : .left
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; ascending = d.ascending
        applyFilter()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    // MARK: Ações

    @objc private func groupToggled() {
        grouped = groupBox.state == .on
        queue.async { [weak self] in self?.sample() }
    }

    @objc private func revealTapped() {
        guard let path = selectedRow?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func quitTapped() {
        guard let r = selectedRow, let identity = r.identity, r.ownedByMe, let w = window else { return }
        let alert = NSAlert()
        alert.messageText = L("procs.quit.title", r.name)
        alert.informativeText = L("procs.quit.text")
        alert.addButton(withTitle: L("procs.quit"))
        alert.addButton(withTitle: L("procs.cancel"))
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            _ = self?.appsController.requestGracefulQuit(identity)   // pedido normal; nunca força
        }
    }
}
