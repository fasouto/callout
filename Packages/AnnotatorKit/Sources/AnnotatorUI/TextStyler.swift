import AnnotatorCore
import AppKit

extension NSAttributedString.Key {
    /// The id of the mark a run of text belongs to, as a UUID string.
    static let annotatorMark = NSAttributedString.Key("annotatorMark")
    /// A `BlockDecoration` drawn behind a paragraph.
    static let annotatorBlock = NSAttributedString.Key("annotatorBlock")
}

/// Something drawn behind a paragraph rather than set in type.
enum BlockDecoration: Equatable {
    /// A line of a code block or table. `indent` is the block's left edge.
    case panel(first: Bool, last: Bool, indent: CGFloat)
    /// A bar per level of quotation. `trim` is how much shorter than the
    /// paragraph the bar is, so it ends with the text of the last paragraph.
    case quote(depth: Int, trim: CGFloat)
    /// A thematic break, drawn as a rule.
    case rule
}

/// Builds what the text view shows from the rendered document and the marks.
@MainActor
enum TextStyler {
    static func attributedString(layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?) -> NSAttributedString {
        let document = layout.document
        let result = NSMutableAttributedString()

        for segment in document.segments {
            let start = result.length
            result.append(NSAttributedString(string: segment.text, attributes: attributes(for: segment.style)))
            decoratePanel(segment, at: start, in: result)
        }

        endQuoteBars(in: result)

        // Marks are applied in displayed offsets, before ghosts shift anything.
        for mark in marks {
            let selected = mark.id == selectedMarkID
            let ranges = document.displayedRanges(forSource: mark.anchor.span)
            for range in ranges {
                result.addAttributes(attributes(for: mark, selected: selected), range: NSRange(range))
            }
            // A little air between struck text and the words that replace it.
            if mark.kind == .replace, mark.text?.isEmpty == false, let end = ranges.last?.upperBound, end > 0 {
                result.addAttribute(.kern, value: 3, range: NSRange(location: end - 1, length: 1))
            }
        }

        for ghost in layout.ghosts.reversed() {
            guard let mark = marks.first(where: { $0.id == ghost.markID }) else { continue }
            result.insert(
                NSAttributedString(string: ghost.text, attributes: ghostAttributes(for: mark, at: ghost.anchor, in: result, selected: mark.id == selectedMarkID)),
                at: ghost.anchor
            )
        }
        return result
    }

    // MARK: - Marks

    private static func attributes(for mark: Mark, selected: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.annotatorMark: mark.id.uuidString]
        switch mark.kind {
        case .delete, .replace:
            // The pen stroke carries the meaning; the words recede.
            attributes[.strikethroughStyle] = NSUnderlineStyle.thick.rawValue
            attributes[.strikethroughColor] = Theme.pen
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            if selected { attributes[.backgroundColor] = Theme.pen.withAlphaComponent(0.14) }
        case .comment:
            attributes[.backgroundColor] = Theme.highlighter.withAlphaComponent(selected ? 0.62 : 0.34)
        case .keep:
            attributes[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            attributes[.underlineColor] = Theme.keep
            attributes[.backgroundColor] = Theme.keep.withAlphaComponent(selected ? 0.30 : 0.12)
        case .insert:
            break
        }
        return attributes
    }

    /// Your own words: blue ink, italic, set like the text around them.
    private static func ghostAttributes(
        for mark: Mark, at anchor: Int, in text: NSAttributedString, selected: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attributes = self.attributes(for: SegmentStyle())
        if text.length > 0 {
            let neighbour = text.attributes(at: min(max(anchor - 1, 0), text.length - 1), effectiveRange: nil)
            if let paragraph = neighbour[.paragraphStyle] { attributes[.paragraphStyle] = paragraph }
            if let block = neighbour[.annotatorBlock] { attributes[.annotatorBlock] = block }
            if let font = neighbour[.font] as? NSFont {
                let isMono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                attributes[.font] = isMono ? font : Theme.serif(font.pointSize, italic: true)
            }
        }
        attributes[.foregroundColor] = Theme.ink
        attributes[.backgroundColor] = selected ? Theme.ink.withAlphaComponent(0.14) : nil
        attributes[.annotatorMark] = mark.id.uuidString
        return attributes
    }

    // MARK: - Segments

    private static func attributes(for style: SegmentStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: style.quoteDepth > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraphStyle(for: style),
        ]
        if style.code, !isPanel(style) {
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.09)
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.secondaryLabelColor
        }
        if style.link != nil {
            // Shown as a link but not clickable: a click here places the caret.
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = NSColor.tertiaryLabelColor
            attributes[.toolTip] = style.link
        }
        if style.isListMarker {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.font] = Theme.serif(Theme.bodySize)
        }
        switch style.block {
        case .thematicBreak:
            attributes[.foregroundColor] = NSColor.clear
            attributes[.annotatorBlock] = BlockDecoration.rule
        case .paragraph, .heading:
            if style.quoteDepth > 0 { attributes[.annotatorBlock] = BlockDecoration.quote(depth: style.quoteDepth, trim: 0) }
        case .codeBlock, .table, .html:
            break
        }
        return attributes
    }

    private static func isPanel(_ style: SegmentStyle) -> Bool {
        switch style.block {
        case .codeBlock, .table, .html: true
        default: false
        }
    }

    private static func font(for style: SegmentStyle) -> NSFont {
        switch style.block {
        case .heading(let level):
            let size = Theme.headingSize(level)
            if style.code { return Theme.mono(size - 2, weight: .semibold) }
            return Theme.serif(size, weight: level <= 2 ? .bold : .semibold, italic: style.italic)
        case .codeBlock, .table, .html:
            return Theme.mono(13)
        case .paragraph, .thematicBreak:
            if style.code { return Theme.mono(Theme.bodySize - 2.5, weight: style.bold ? .semibold : .regular) }
            return Theme.serif(Theme.bodySize, weight: style.bold ? .semibold : .regular, italic: style.italic)
        }
    }

    private static let quoteIndent: CGFloat = 18
    private static let listIndent: CGFloat = 22
    private static let markerWidth: CGFloat = 22

    private static func blockIndent(for style: SegmentStyle) -> CGFloat {
        CGFloat(style.quoteDepth) * quoteIndent + CGFloat(max(0, style.listDepth - 1)) * listIndent
            + (style.listDepth > 0 ? markerWidth : 0)
    }

    private static func paragraphStyle(for style: SegmentStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let base = CGFloat(style.quoteDepth) * quoteIndent + CGFloat(max(0, style.listDepth - 1)) * listIndent

        if style.listDepth > 0 {
            // The style of a paragraph's first character wins, so a paragraph that
            // starts with a marker hangs, and a continuation paragraph lines up with it.
            paragraph.firstLineHeadIndent = style.isListMarker ? base : base + markerWidth
            paragraph.headIndent = base + markerWidth
            paragraph.paragraphSpacing = 5
        } else {
            paragraph.firstLineHeadIndent = base
            paragraph.headIndent = base
            paragraph.paragraphSpacing = 12
        }
        switch style.block {
        case .heading(let level):
            paragraph.paragraphSpacingBefore = level <= 2 ? 18 : 12
            paragraph.paragraphSpacing = level <= 2 ? 8 : 6
            paragraph.lineSpacing = 2
        case .codeBlock, .table, .html:
            let indent = blockIndent(for: style) + Theme.panelPadding
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.tailIndent = -Theme.panelPadding
            paragraph.paragraphSpacing = 0
            paragraph.lineSpacing = 3
            paragraph.lineBreakMode = .byCharWrapping
        case .thematicBreak:
            paragraph.paragraphSpacing = 12
            paragraph.paragraphSpacingBefore = 4
        case .paragraph:
            break
        }
        return paragraph
    }

    /// The bar beside a quotation runs unbroken from paragraph to paragraph, and
    /// stops with the text of the last one instead of running into the space below.
    private static func endQuoteBars(in result: NSMutableAttributedString) {
        let string = result.string as NSString
        var location = 0
        var lastQuote: (range: NSRange, depth: Int)?

        func close() {
            guard let quote = lastQuote else { return }
            let spacing = (result.attribute(.paragraphStyle, at: quote.range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0
            result.addAttribute(.annotatorBlock, value: BlockDecoration.quote(depth: quote.depth, trim: spacing), range: quote.range)
            lastQuote = nil
        }
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if case .quote(let depth, _)? = result.attribute(.annotatorBlock, at: paragraph.location, effectiveRange: nil) as? BlockDecoration {
                lastQuote = (paragraph, depth)
            } else {
                close()
            }
            location = NSMaxRange(paragraph)
        }
        close()
    }

    /// Code and tables are one segment of several lines. Each line learns where it
    /// sits in the block, so the background is drawn as one panel with room around it.
    private static func decoratePanel(_ segment: RenderSegment, at start: Int, in result: NSMutableAttributedString) {
        guard isPanel(segment.style), segment.source != nil else { return }
        let text = segment.text as NSString
        guard text.length > 0 else { return }
        let indent = blockIndent(for: segment.style)

        var lines: [NSRange] = []
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            location = NSMaxRange(line)
        }
        for (index, line) in lines.enumerated() {
            let isFirst = index == 0
            let isLast = index == lines.count - 1
            let range = NSRange(location: start + line.location, length: line.length)
            result.addAttribute(.annotatorBlock, value: BlockDecoration.panel(first: isFirst, last: isLast, indent: indent), range: range)

            guard isFirst || isLast,
                  let current = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let style = current.mutableCopy() as? NSMutableParagraphStyle else { continue }
            if isFirst { style.paragraphSpacingBefore = Theme.panelGap + Theme.panelInset }
            if isLast { style.paragraphSpacing = Theme.panelGap + Theme.panelInset }
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }
}

extension NSRange {
    init(_ range: Range<Int>) {
        self.init(location: range.lowerBound, length: range.count)
    }
}
