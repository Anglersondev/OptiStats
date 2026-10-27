import Cocoa
import OptiStatsCore

/// Gráfico de linhas leve, desenhado com Core Graphics. Só redesenha quando `series` muda.
final class LineChartView: NSView {
    struct Line {
        var values: [Double]
        var color: NSColor
        var filled: Bool = true
    }

    var lines: [Line] = [] { didSet { needsDisplay = true } }
    /// nil = escala automática (de 0 ao máximo + folga).
    var fixedRange: ClosedRange<Double>? = 0...100 { didSet { needsDisplay = true } }
    var showsGrid = true
    private let fixedHeight: CGFloat

    init(height: CGFloat = 56) {
        fixedHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: fixedHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        Theme.track.withAlphaComponent(0.12).setFill()
        bg.fill()

        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        if showsGrid {
            Theme.separator.withAlphaComponent(0.5).setStroke()
            for f in [0.25, 0.5, 0.75] {
                let y = r.minY + r.height * CGFloat(f)
                let p = NSBezierPath()
                p.lineWidth = 0.5
                p.move(to: NSPoint(x: r.minX, y: y))
                p.line(to: NSPoint(x: r.maxX, y: y))
                p.stroke()
            }
        }
        let range = resolvedRange()
        for line in lines where line.values.count >= 2 {
            let n = line.values.count
            let stepX = r.width / CGFloat(n - 1)
            func point(_ i: Int) -> NSPoint {
                let v = min(max(line.values[i], range.lowerBound), range.upperBound)
                let t = range.upperBound > range.lowerBound ? (v - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
                return NSPoint(x: r.minX + stepX * CGFloat(i), y: r.minY + r.height * CGFloat(t))
            }
            let path = NSBezierPath()
            path.move(to: point(0))
            for i in 1..<n { path.line(to: point(i)) }
            if line.filled {
                let fill = path.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: r.maxX, y: r.minY))
                fill.line(to: NSPoint(x: r.minX, y: r.minY))
                fill.close()
                line.color.withAlphaComponent(0.16).setFill()
                fill.fill()
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            line.color.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func resolvedRange() -> ClosedRange<Double> {
        if let fixed = fixedRange { return fixed }
        let maxValue = lines.flatMap(\.values).filter(\.isFinite).max() ?? 1
        return 0...max(1, maxValue * 1.15)
    }
}

/// Indicador circular de porcentagem com texto central.
final class RingGaugeView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var centerText: String = "" { didSet { needsDisplay = true } }
    var subtitle: String = "" { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 9

    init(size: CGFloat = 92) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        Theme.track.withAlphaComponent(0.35).setStroke()
        track.stroke()

        let f = fraction.isFinite ? min(max(fraction, 0), 0.9999) : 0
        if f > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let main: [NSAttributedString.Key: Any] = [.font: Theme.number(20, weight: .semibold), .foregroundColor: Theme.primaryText, .paragraphStyle: para]
        let sub: [NSAttributedString.Key: Any] = [.font: Theme.caption(10), .foregroundColor: Theme.secondaryText, .paragraphStyle: para]
        let mainSize = (centerText as NSString).size(withAttributes: main)
        let subSize = subtitle.isEmpty ? .zero : (subtitle as NSString).size(withAttributes: sub)
        let total = mainSize.height + subSize.height
        var y = bounds.midY - total / 2
        if !subtitle.isEmpty {
            (subtitle as NSString).draw(in: NSRect(x: bounds.minX, y: y, width: bounds.width, height: subSize.height), withAttributes: sub)
            y += subSize.height
        }
        (centerText as NSString).draw(in: NSRect(x: bounds.minX, y: y, width: bounds.width, height: mainSize.height), withAttributes: main)
    }
}

/// Medidor de pressão de memória em três zonas (Normal / Atenção / Alta).
final class PressureGaugeView: NSView {
    var band: PressureBand = .unknown { didSet { needsDisplay = true } }
    var labels: (String, String, String) = ("Normal", "Atenção", "Alta") { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    override func draw(_ dirtyRect: NSRect) {
        let barRect = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 8)
        let colors: [NSColor] = [Theme.good, Theme.warn, Theme.bad]
        let segW = (barRect.width - 4) / 3
        for i in 0..<3 {
            let seg = NSRect(x: barRect.minX + CGFloat(i) * (segW + 2), y: barRect.minY, width: segW, height: barRect.height)
            let active = (band == .normal && i == 0) || (band == .attention && i == 1) || (band == .high && i == 2)
            colors[i].withAlphaComponent(active ? 1.0 : 0.28).setFill()
            NSBezierPath(roundedRect: seg, xRadius: 4, yRadius: 4).fill()
        }
        let names = [labels.0, labels.1, labels.2]
        for i in 0..<3 {
            let active = (band == .normal && i == 0) || (band == .attention && i == 1) || (band == .high && i == 2)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: active ? Theme.caption(10.5) : Theme.body(10),
                .foregroundColor: active ? Theme.primaryText : Theme.secondaryText,
                .paragraphStyle: para]
            let seg = NSRect(x: CGFloat(i) * (segW + 2), y: 0, width: segW, height: 14)
            (names[i] as NSString).draw(in: seg, withAttributes: attrs)
        }
    }
}

/// Barra empilhada (composição da memória, uso de volume).
final class SegmentedBarView: NSView {
    struct Segment { var fraction: Double; var color: NSColor }
    var segments: [Segment] = [] { didSet { needsDisplay = true } }

    init(height: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.track.withAlphaComponent(0.3).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var x = bounds.minX
        for s in segments where s.fraction.isFinite && s.fraction > 0 {
            let w = bounds.width * CGFloat(min(s.fraction, 1))
            s.color.setFill()
            NSRect(x: x, y: bounds.minY, width: w, height: bounds.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
