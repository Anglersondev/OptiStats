import Cocoa
import OptiStatsCore

/// Linguagem visual: cores semânticas do sistema (Claro/Escuro automáticos), tipografia nativa e
/// cores moderadas. Nada de assets de terceiros.
enum Theme {
    static let popoverWidth: CGFloat = 380
    static let maxPopoverHeight: CGFloat = 600
    static let padding: CGFloat = 16
    static let cardPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 7
    static let sectionSpacing: CGFloat = 12

    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    static let separator = NSColor.separatorColor
    static let track = NSColor.quaternaryLabelColor

    static let good = NSColor.systemGreen
    static let warn = NSColor.systemOrange
    static let bad = NSColor.systemRed
    static let accent = NSColor.controlAccentColor

    static func title(_ size: CGFloat = 15) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    static func body(_ size: CGFloat = 12) -> NSFont { .systemFont(ofSize: size) }
    static func caption(_ size: CGFloat = 10.5) -> NSFont { .systemFont(ofSize: size, weight: .medium) }
    static func number(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// Verde → laranja → vermelho conforme a utilização (0...1). Limiares conservadores e discretos.
    static func usageColor(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.70: return good
        case ..<0.90: return warn
        default: return bad
        }
    }

    static func pressureColor(_ band: PressureBand) -> NSColor {
        switch band {
        case .normal: return good
        case .attention: return warn
        case .high: return bad
        case .unknown: return track
        }
    }

    static func temperatureColor(_ celsius: Double) -> NSColor {
        switch celsius {
        case ..<70: return good
        case ..<90: return warn
        default: return bad
        }
    }
}

/// A static native surface: no layers, blur, animations or timers.
final class PanelSectionView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.rowSpacing
        edgeInsets = NSEdgeInsets(top: 12, left: Theme.cardPadding, bottom: 12, right: Theme.cardPadding)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.65).setFill()
        path.fill()
        Theme.separator.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension NSTextField {
    /// Rótulo estático (não editável) sem borda.
    static func label(_ text: String = "", font: NSFont = Theme.body(), color: NSColor = Theme.primaryText,
                      alignment: NSTextAlignment = .left, lines: Int = 1) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = alignment
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
}

/// View com origem no topo: necessária como `documentView` para rolagem começar de cima.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
