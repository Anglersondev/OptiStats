import Cocoa
import OptiStatsCore

/// Cabeçalho de seção em caixa-alta, discreto.
final class SectionHeaderView: NSTextField {
    convenience init(_ title: String) {
        self.init(labelWithString: title.uppercased(with: Localizer.shared.locale))
        font = Theme.caption(10)
        textColor = Theme.secondaryText
        translatesAutoresizingMaskIntoConstraints = false
    }
}

final class ColorDotView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    init(size: CGFloat = 8) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Linha "rótulo ........ valor". `value` aceita "—" para indisponível (nunca zero fictício).
final class KeyValueRowView: NSStackView {
    private let dot = ColorDotView()
    private let titleLabel = NSTextField.label(font: Theme.body(), color: Theme.secondaryText)
    private let valueLabel = NSTextField.label(font: Theme.number(12, weight: .medium), alignment: .right)

    var title: String { get { titleLabel.stringValue } set { if titleLabel.stringValue != newValue { titleLabel.stringValue = newValue } } }
    var value: String {
        get { valueLabel.stringValue }
        set {
            if valueLabel.stringValue != newValue {
                valueLabel.stringValue = newValue
                setAccessibilityLabel("\(titleLabel.stringValue): \(newValue)")
            }
        }
    }
    var valueColor: NSColor { get { valueLabel.textColor ?? Theme.primaryText } set { valueLabel.textColor = newValue } }
    var dotColor: NSColor? { didSet { dot.isHidden = dotColor == nil; dot.color = dotColor ?? .clear } }

    init(title: String, value: String = "—", dotColor: NSColor? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(dot)
        addArrangedSubview(titleLabel)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        addArrangedSubview(valueLabel)
        self.title = title
        self.value = value
        self.dotColor = dotColor
        dot.isHidden = dotColor == nil
        dot.color = dotColor ?? .clear
        setAccessibilityElement(true)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }
}

/// Linha de processo/aplicativo: ícone, nome, detalhe e valor.
final class ProcessRowView: NSStackView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField.label(font: Theme.body(12))
    private let detailLabel = NSTextField.label(font: Theme.body(10), color: Theme.secondaryText)
    private let valueLabel = NSTextField.label(font: Theme.number(12, weight: .medium), alignment: .right)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let texts = NSStackView(views: [nameLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(iconView)
        addArrangedSubview(texts)
        addArrangedSubview(valueLabel)
        setAccessibilityElement(true)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    func configure(icon: NSImage?, name: String, detail: String?, value: String) {
        iconView.image = icon
        iconView.isHidden = icon == nil
        if nameLabel.stringValue != name { nameLabel.stringValue = name }
        let d = detail ?? ""
        if detailLabel.stringValue != d { detailLabel.stringValue = d }
        detailLabel.isHidden = d.isEmpty
        if valueLabel.stringValue != value { valueLabel.stringValue = value }
        setAccessibilityLabel("\(name), \(value)")
    }
}

/// Faixa de estado/aviso (carregando, indisponível, permissão negada…).
final class BannerView: NSView {
    private let label = NSTextField.label(font: Theme.body(11), color: Theme.secondaryText, lines: 3)

    var message: String? {
        didSet {
            label.stringValue = message ?? ""
            isHidden = (message ?? "").isEmpty
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

extension NSStackView {
    /// Pilha vertical com espaçamento padrão do app.
    static func vertical(_ views: [NSView] = [], spacing: CGFloat = Theme.rowSpacing) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    static func horizontal(_ views: [NSView] = [], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    /// Adiciona e estica a subview na largura da pilha vertical.
    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }
}
