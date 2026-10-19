import AppKit

/// Hands out layout fragments that draw a paragraph's decoration: the panel
/// behind code and tables, the bar beside a quotation, the rule of a break.
final class BlockDecorator: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(.annotatorBlock, at: 0, effectiveRange: nil) as? BlockDecoration {
            return BlockFragment(decoration: decoration, textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

final class BlockFragment: NSTextLayoutFragment {
    private let decoration: BlockDecoration

    init(decoration: BlockDecoration, textElement: NSTextElement, range: NSTextRange?) {
        self.decoration = decoration
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
    private var decorationRect: CGRect {
        let frame = layoutFragmentFrame
        // The fragment's origin can sit to the right of the container's edge.
        let left = -frame.minX
        switch decoration {
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

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(decorationRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)

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
        super.draw(at: point, in: context)
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
