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

/// Um NSPopover transient por vez. Cria o painel ao abrir e o descarta ao fechar (memória e demanda zeradas).
final class PopoverHost: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var controller: ModulePopoverViewController?
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

    func show(relativeTo button: NSView) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Garante o foco para que o comportamento transient (fechar ao clicar fora) funcione em app acessório.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        controller?.setPresented(true)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) } else { finish() }
    }

    func popoverDidClose(_ notification: Notification) { finish() }

    private func finish() {
        controller?.setPresented(false)
        popover.contentViewController = nil
        controller = nil
        let cb = onClose
        onClose = nil
        cb?()
    }
}
