import AppKit

/// Hands out layout fragments that draw what is not set in type: a paragraph's
/// decoration (the panel behind code and tables, the bar beside a quotation,
/// the rule of a break), the pins of comments on no words, and the pen's
/// strokes through struck text.
final class BlockDecorator: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let text = paragraph.attributedString
            let decoration = text.attribute(.calloutBlock, at: 0, effectiveRange: nil) as? BlockDecoration
            let pins = Self.pins(in: text)
            let strikes = Self.strikes(in: text)
            if decoration != nil || !pins.isEmpty || !strikes.isEmpty {
                return BlockFragment(
                    decoration: decoration, pins: pins, strikes: strikes, textElement: textElement, range: textElement.elementRange
                )
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    /// The pins in a paragraph, one for each character that carries one:
    /// neighbouring pins that look alike share a run of the attribute.
    static func pins(in text: NSAttributedString) -> [BlockFragment.PinnedPoint] {
        let characters = text.string as NSString
        var pins: [BlockFragment.PinnedPoint] = []
        text.enumerateAttribute(.calloutPin, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let pin = value as? Pin else { return }
            var index = range.location
            while index < NSMaxRange(range) {
                let character = characters.rangeOfComposedCharacterSequence(at: index)
                pins.append(.init(offset: pin.isAfter ? NSMaxRange(character) : character.location, selected: pin.selected))
                index = NSMaxRange(character)
            }
        }
        return pins
    }

    static func strikes(in text: NSAttributedString) -> [BlockFragment.Strike] {
        var strikes: [BlockFragment.Strike] = []
        text.enumerateAttribute(.calloutStrike, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let color = value as? NSColor { strikes.append(.init(range: range, color: color)) }
        }
        return strikes
    }
}

final class BlockFragment: NSTextLayoutFragment {
    /// A comment pinned between two characters of the paragraph.
    struct PinnedPoint: Equatable {
        /// The point, as an offset into the paragraph.
        var offset: Int
        var selected: Bool
    }

    /// Struck text: a range of the paragraph and the colour of its stroke.
    struct Strike: Equatable {
        var range: NSRange
        var color: NSColor
    }

    private let decoration: BlockDecoration?
    private let pins: [PinnedPoint]
    private let strikes: [Strike]

    init(decoration: BlockDecoration?, pins: [PinnedPoint], strikes: [Strike], textElement: NSTextElement, range: NSTextRange?) {
        self.decoration = decoration
        self.pins = pins
        self.strikes = strikes
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The decoration's rectangle, in the fragment's own coordinates.
    private var decorationRect: CGRect? {
        let frame = layoutFragmentFrame
        // The fragment's origin can sit to the right of the container's edge.
        let left = -frame.minX
        switch decoration {
        case nil:
            return nil
        case .panel(let first, let last, let indent):
            var rect = CGRect(x: left + indent, y: 0, width: containerWidth - indent, height: frame.height)
            if first {
                rect.origin.y += Theme.panelGap
                rect.size.height -= Theme.panelGap
            }
            if last { rect.size.height -= Theme.panelGap }
            return rect
        case .quote(let depth, let trim):
            return CGRect(x: left, y: 0, width: CGFloat(depth) * 18, height: frame.height - trim)
        case .rule:
            return CGRect(x: left, y: 0, width: containerWidth, height: frame.height)
        case .tableRow(_, let last, let indent, let width):
            // The last row's frame also holds the space under the table.
            return CGRect(x: left + indent, y: 0, width: width ?? containerWidth - indent, height: frame.height - (last ? 12 : 0))
        }
    }

    /// A pin's bar, in the fragment's own coordinates: at its point, as tall as
    /// the letters there.
    private func bar(at offset: Int) -> CGRect? {
        guard let line = line(at: offset) else { return nil }
        let text = line.attributedString
        guard text.length > 0 else { return nil }
        let font = text.attribute(.font, at: min(offset, text.length - 1), effectiveRange: nil) as? NSFont ?? Theme.serif(Theme.bodySize)
        let bounds = line.typographicBounds
        let x = bounds.minX + line.locationForCharacter(at: offset).x
        let baseline = bounds.minY + line.glyphOrigin.y
        return CGRect(x: x, y: baseline - font.ascender, width: 0, height: font.ascender - font.descender)
    }

    /// The line a point is on. A point where a line wraps is on the line it starts.
    private func line(at offset: Int) -> NSTextLineFragment? {
        textLineFragments.first { NSLocationInRange(offset, $0.characterRange) }
            ?? textLineFragments.last { NSMaxRange($0.characterRange) == offset }
    }

    /// A strike's strokes, one per line it is on, in the fragment's own
    /// coordinates: through the middle of the lowercase letters.
    private func strokes(of strike: Strike) -> [(start: CGPoint, end: CGPoint, width: CGFloat)] {
        textLineFragments.compactMap { line in
            let text = line.attributedString
            var range = NSIntersectionRange(strike.range, line.characterRange)
            // A struck paragraph's line break has no width to strike.
            while range.length > 0, [0x0A, 0x2028].contains((text.string as NSString).character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            guard range.length > 0 else { return nil }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Theme.serif(Theme.bodySize)
            let bounds = line.typographicBounds
            let y = bounds.minY + line.glyphOrigin.y - font.xHeight / 2
            return (
                CGPoint(x: bounds.minX + line.locationForCharacter(at: range.location).x, y: y),
                CGPoint(x: bounds.minX + line.locationForCharacter(at: NSMaxRange(range)).x, y: y),
                Theme.penWidth(forTextOf: font.pointSize)
            )
        }
    }

    /// How far a pin's head and its wash reach around its bar.
    private static let pinReach: CGFloat = 4

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let decorationRect { bounds = bounds.union(decorationRect) }
        for pin in pins {
            if let bar = bar(at: pin.offset) { bounds = bounds.union(bar.insetBy(dx: -Self.pinReach, dy: -Self.pinReach)) }
        }
        for stroke in strikes.flatMap(strokes(of:)) {
            let reach = stroke.width
            bounds = bounds.union(CGRect(x: stroke.start.x - reach, y: stroke.start.y - reach, width: stroke.end.x - stroke.start.x + 2 * reach, height: 2 * reach))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decorationRect { drawDecoration(in: decorationRect.offsetBy(dx: point.x, dy: point.y), context: context) }
        let bars = pins.compactMap { pin in bar(at: pin.offset).map { (rect: $0.offsetBy(dx: point.x, dy: point.y), selected: pin.selected) } }
        drawWashes(behind: bars.filter(\.selected).map(\.rect), context: context)
        super.draw(at: point, in: context)
        drawStrikes(at: point, context: context)
        drawPins(bars, context: context)
    }

    private func drawStrikes(at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        for strike in strikes {
            context.setStrokeColor(strike.color.cgColor)
            for stroke in strokes(of: strike) {
                context.setLineWidth(stroke.width)
                context.move(to: CGPoint(x: stroke.start.x + point.x, y: stroke.start.y + point.y))
                context.addLine(to: CGPoint(x: stroke.end.x + point.x, y: stroke.end.y + point.y))
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private func drawWashes(behind bars: [CGRect], context: CGContext) {
        context.saveGState()
        context.setFillColor(Theme.highlightWash(selected: true).cgColor)
        for bar in bars {
            context.addPath(CGPath(roundedRect: bar.insetBy(dx: -3, dy: -1), cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawPins(_ bars: [(rect: CGRect, selected: Bool)], context: CGContext) {
        context.saveGState()
        for bar in bars {
            context.setFillColor(Theme.pointBar(selected: bar.selected).cgColor)
            let width: CGFloat = bar.selected ? 2 : 1.5
            let head: CGFloat = bar.selected ? 6 : 5
            context.fill(CGRect(x: bar.rect.midX - width / 2, y: bar.rect.minY, width: width, height: bar.rect.height))
            context.fillEllipse(in: CGRect(x: bar.rect.midX - head / 2, y: bar.rect.minY - head / 2, width: head, height: head))
        }
        context.restoreGState()
    }

    private func drawDecoration(in rect: CGRect, context: CGContext) {
        guard let decoration else { return }
        context.saveGState()
        switch decoration {
        case .panel(let first, let last, _):
            context.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.07).cgColor)
            context.addPath(Self.panelPath(rect, roundTop: first, roundBottom: last))
            context.fillPath()
        case .quote(let depth, _):
            context.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.5).cgColor)
            // Square ends: each paragraph draws its own length of the bar, and
            // rounded ones would leave a nick wherever two of them meet.
            for level in 0..<depth {
                context.fill(CGRect(x: rect.minX + CGFloat(level) * 18 + 1, y: rect.minY, width: 3, height: rect.height))
            }
        case .rule:
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.midY.rounded(), width: rect.width, height: 1))
        case .tableRow(let header, _, _, _):
            // A firmer line under the header, hairlines between rows, one to close the table.
            let color = header ? NSColor.tertiaryLabelColor : NSColor.separatorColor
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.maxY.rounded() - 1, width: rect.width, height: 1))
        }
        context.restoreGState()
    }

    /// A rectangle rounded only where the panel begins and ends.
    private static func panelPath(_ rect: CGRect, roundTop: Bool, roundBottom: Bool) -> CGPath {
        let radius: CGFloat = 8
        let top = roundTop ? radius : 0
        let bottom = roundBottom ? radius : 0
        let path = CGMutablePath()
        // The text view is flipped: minY is the top edge.
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        path.closeSubpath()
        return path
    }
}
