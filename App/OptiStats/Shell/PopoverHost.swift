import Cocoa
import OptiStatsCore

/// Ponto de extensão: a área "Popovers" registra aqui a fábrica dos painéis por tipo de widget.
/// Enquanto não houver fábrica (ou ela devolver nil) é exibido um painel provisório.
///
///     PopoverRegistry.factory = { kind, env in
///         switch kind { case .cpu: return CPUPopoverViewController(env: env) ... default: return nil }
///     }
enum PopoverRegistry {
    static var factory: ((WidgetKind, AppEnvironment) -> ModulePopoverViewController?)?

    static func make(_ kind: WidgetKind, env: AppEnvironment) -> ModulePopoverViewController {
        // "Grupos de núcleos" é uma visão da CPU.
        let target: WidgetKind = kind == .coreGroups ? .cpu : kind
        return factory?(target, env) ?? PopoverFactory.make(kind: target, env: env)
    }
}

/// Painel mínimo usado até o painel real existir. Não declara coletores para não gerar custo.
final class PlaceholderModulePopover: ModulePopoverViewController {
    init(env: AppEnvironment, kind: WidgetKind) {
        super.init(env: env, moduleID: kind.rawValue, title: L("shell.kind.\(kind.rawValue)"),
                   collectors: kind.collectors, kinds: [])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func buildContent() {
        let note = NSTextField.label(L("shell.popover.unavailable"), font: Theme.body(), color: Theme.secondaryText, lines: 0)
        note.preferredMaxLayoutWidth = Theme.popoverWidth - 2 * Theme.padding
        content.addFullWidth(note)
    }
}

/// Painel único para um ícone com 2–3 indicadores: seletor no topo troca entre os painéis (cada um mantém sua demanda
/// só enquanto está visível). O painel clicado abre primeiro.
final class CombinedPopoverContainer: NSViewController {
    private let panels: [(title: String, controller: ModulePopoverViewController)]
    private var current = 0
    private var presented = false
    private let segmented = NSSegmentedControl()
    private let holder = NSView()

    init(panels: [(title: String, controller: ModulePopoverViewController)], selected: Int) {
        self.panels = panels
        self.current = min(max(0, selected), panels.count - 1)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func loadView() {
        let root = NSView()
        segmented.segmentCount = panels.count
        for (i, p) in panels.enumerated() { segmented.setLabel(p.title, forSegment: i) }
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = current
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(segmented); root.addSubview(holder)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            holder.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        install(current)
    }

    func setPresented(_ on: Bool) {
        presented = on
        panels[current].controller.setPresented(on)
    }

    @objc private func segmentChanged() {
        let next = segmented.selectedSegment
        guard next != current, next >= 0 else { return }
        panels[current].controller.setPresented(false)
        let old = panels[current].controller
        old.view.removeFromSuperview()
        old.removeFromParent()
        current = next
        install(next)
        if presented { panels[next].controller.setPresented(true) }
    }

    private func install(_ index: Int) {
        let child = panels[index].controller
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: holder.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        syncSize()
    }

    private func syncSize() {
        let child = panels[current].controller
        let h = child.preferredContentSize.height
        preferredContentSize = NSSize(width: Theme.popoverWidth, height: (h > 0 ? h : 320) + 40)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) { syncSize() }
}

/// Um NSPopover transient por vez. Cria o painel ao abrir e o descarta ao fechar (memória e demanda zeradas).
final class PopoverHost: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var controller: ModulePopoverViewController?
    private var combined: CombinedPopoverContainer?
    /// Chamado após o fechamento (qualquer motivo).
    var onClose: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init(controller: ModulePopoverViewController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = self
    }

    init(combined: CombinedPopoverContainer) {
        self.combined = combined
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = combined
        popover.delegate = self
    }

    func show(relativeTo button: NSView) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Garante o foco para que o comportamento transient (fechar ao clicar fora) funcione em app acessório.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        controller?.setPresented(true)
        combined?.setPresented(true)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) } else { finish() }
    }

    func popoverDidClose(_ notification: Notification) { finish() }

    private func finish() {
        controller?.setPresented(false)
        combined?.setPresented(false)
        popover.contentViewController = nil
        controller = nil
        combined = nil
        let cb = onClose
        onClose = nil
        cb?()
    }
}
