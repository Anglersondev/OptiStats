import Cocoa
import OptiStatsCore

/// Linguagem visual: cores semânticas do sistema (Claro/Escuro automáticos), tipografia nativa e
/// cores moderadas. Nada de assets de terceiros.
enum Theme {
    static let popoverWidth: CGFloat = 340
    static let maxPopoverHeight: CGFloat = 560
    static let padding: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 14

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
