import Cocoa
import OptiStatsCore

/// Base de todos os popovers: cabeçalho, rolagem, rodapé "Atualizado há Ns" + "Atualizar agora",
/// faixa de estado das fontes e ciclo de vida de demanda.
///
/// Regras de eficiência (obrigatórias para subclasses):
/// - `buildContent()` cria a hierarquia UMA vez; `render()` só atualiza valores (nada de recriar views).
/// - Enquanto o popover não está visível, nenhuma demanda `.popover` existe, não há assinatura e `render()` não roda.
class ModulePopoverViewController: NSViewController {
    let env: AppEnvironment
    let moduleID: String
    let titleText: String
    /// Coletores com demanda `.popover` enquanto este painel está aberto.
    let collectors: [CollectorID]
    /// Tipos do `MetricsStore` que disparam `render()`.
    let kinds: [MetricKind]

    /// Pilha onde as subclasses adicionam o conteúdo (largura total).
    let content = NSStackView.vertical(spacing: Theme.sectionSpacing)

    private let scroll = NSScrollView()
    private let banner = BannerView()
    private let updatedLabel = NSTextField.label(font: Theme.body(10), color: Theme.secondaryText)
    private let refreshButton = NSButton()
    private var scrollHeight: NSLayoutConstraint!
    private var tokens: [SubscriptionToken] = []
    private var renderScheduled = false
    private var ageTimer: Timer?
    private(set) var isPresented = false

    init(env: AppEnvironment, moduleID: String, title: String, collectors: [CollectorID], kinds: [MetricKind]) {
        self.env = env
        self.moduleID = moduleID
        self.titleText = title
        self.collectors = collectors
        self.kinds = kinds
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    // MARK: Ganchos para subclasses

    /// Cria a hierarquia estática dentro de `content`.
    func buildContent() {}
    /// Atualiza os valores a partir de `env.store`. Chamado na main thread, somente com o painel visível.
    func render() {}
    /// Instante monotônico do dado mais recente exibido (para "Atualizado há Ns").
    var lastDataTimestamp: TimeInterval? { nil }
    /// Subclasses podem adicionar controles ao lado do título.
    func headerAccessories() -> [NSView] { [] }

    // MARK: Menu "…" (Preferências, Manutenção, Sobre, Sair)

    private let moreButton = NSButton()

    @objc private func moreTapped() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add(L("shell.menu.preferences"), #selector(menuPreferences))
        add(L("shell.menu.maintenance"), #selector(menuMaintenance))
        add(L("shell.menu.about"), #selector(menuAbout))
        menu.addItem(.separator())
        add(L("shell.menu.quit"), #selector(menuQuit))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 2), in: moreButton)
    }
    @objc private func menuPreferences() { env.openPreferences?() }
    @objc private func menuMaintenance() { env.openMaintenance?() }
    @objc private func menuAbout() { env.openAbout?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Layout

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField.label(titleText, font: Theme.title(), lines: 1)
        title.setAccessibilityRole(.staticText)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("common.refreshNow"))
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .regularSquare
        refreshButton.contentTintColor = Theme.secondaryText
        refreshButton.toolTip = L("common.refreshNow")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.setAccessibilityLabel(L("common.refreshNow"))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("common.more"))
        moreButton.isBordered = false
        moreButton.bezelStyle = .regularSquare
        moreButton.contentTintColor = Theme.secondaryText
        moreButton.toolTip = L("common.more")
        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.setAccessibilityLabel(L("common.more"))
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView.horizontal([title, spacer] + headerAccessories() + [moreButton, refreshButton], spacing: 8)

        buildContent()
        content.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 300)
        scrollHeight.isActive = true
        // Largura do conteúdo = largura visível do scroll.
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        updatedLabel.stringValue = ""
        let footer = NSStackView.horizontal([updatedLabel], spacing: 6)

        let separatorTop = NSBox(); separatorTop.boxType = .separator; separatorTop.translatesAutoresizingMaskIntoConstraints = false
        let separatorBottom = NSBox(); separatorBottom.boxType = .separator; separatorBottom.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView.vertical([header, separatorTop, banner, scroll, separatorBottom, footer], spacing: 8)
        column.alignment = .leading
        root.addSubview(column)
        let p = Theme.padding
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Theme.popoverWidth),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        for v in [header, separatorTop, banner, scroll, separatorBottom, footer] {
            v.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }
        view = root
        updatePreferredSize()
    }

    // MARK: Ciclo de vida

    override func viewWillAppear() { super.viewWillAppear(); setPresented(true) }
    override func viewDidDisappear() { super.viewDidDisappear(); setPresented(false) }

    /// Idempotente: chamado pelo delegate do popover e pelos ganchos de view.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        env.setDemand(consumer: "popover.\(moduleID)", collectors: collectors, visibility: presented ? .popover : nil)
        if presented {
            _ = view   // garante loadView
            tokens = kinds.map { kind in env.store.subscribe(kind) { [weak self] in self?.scheduleRender() } }
            refreshAll()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateAge() }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            ageTimer = t
        } else {
            tokens.forEach { $0.cancel() }
            tokens = []
            ageTimer?.invalidate()
            ageTimer = nil
            renderScheduled = false
        }
    }

    private func refreshAll() {
        refreshBanner()
        render()
        updateAge()
        updatePreferredSize()
    }

    private func scheduleRender() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, !self.renderScheduled else { return }
            self.renderScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.renderScheduled = false
                guard self.isPresented else { return }
                self.refreshAll()
            }
        }
    }

    @objc private func refreshTapped() { env.refreshNow(collectors) }

    // MARK: Estado e idade

    private func refreshBanner() {
        for id in collectors {
            if let text = Self.message(for: env.store.state(id)) {
                banner.message = text
                return
            }
        }
        banner.message = nil
    }

    static func message(for state: SourceState) -> String? {
        switch state {
        case .available, .stale: return nil
        case .loading: return L("state.loading")
        case .unsupported(let reason): return L("state.unsupported", reason)
        case .permissionDenied(let hint): return L("state.denied", hint)
        case .failed(let message): return L("state.failed", message)
        case .paused: return L("state.paused")
        }
    }

    private func updateAge() {
        guard let ts = lastDataTimestamp else {
            if updatedLabel.stringValue != "" { updatedLabel.stringValue = "" }
            return
        }
        let age = max(0, Int(env.clock.now - ts))
        let text = age <= 1 ? L("common.updatedNow") : L("common.updatedAgo", age)
        if updatedLabel.stringValue != text { updatedLabel.stringValue = text }
    }

    func updatePreferredSize() {
        content.layoutSubtreeIfNeeded()
        let contentHeight = content.fittingSize.height + 8
        let chrome: CGFloat = 112 + (banner.isHidden ? 0 : 44)
        let maxScroll = Theme.maxPopoverHeight - chrome
        let target = min(max(80, contentHeight), maxScroll)
        if abs(scrollHeight.constant - target) > 1 {
            scrollHeight.constant = target
            view.layoutSubtreeIfNeeded()
            preferredContentSize = NSSize(width: Theme.popoverWidth, height: view.fittingSize.height)
        } else if preferredContentSize.width == 0 {
            preferredContentSize = NSSize(width: Theme.popoverWidth, height: view.fittingSize.height)
        }
    }

    deinit {
        ageTimer?.invalidate()
        tokens.forEach { $0.cancel() }
    }
}
