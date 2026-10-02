import AnnotatorCore
import AppKit

extension NSAttributedString.Key {
    /// The id of the mark a run of text belongs to, as a UUID string.
    static let annotatorMark = NSAttributedString.Key("annotatorMark")
}

/// Builds what the text view shows from the rendered document and the marks.
@MainActor
enum TextStyler {
    static let bodySize: CGFloat = 14

    static func attributedString(layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?) -> NSAttributedString {
        let document = layout.document
        let result = NSMutableAttributedString()

        for segment in document.segments {
            let start = result.length
            result.append(NSAttributedString(string: segment.text, attributes: attributes(for: segment.style)))
            spaceOutBlock(segment, at: start, in: result)
        }

        // Marks are applied in displayed offsets, before ghosts shift anything.
        for mark in marks {
            let selected = mark.id == selectedMarkID
            for range in document.displayedRanges(forSource: mark.anchor.span) {
                result.addAttributes(attributes(for: mark, selected: selected), range: NSRange(range))
            }
        }

        for ghost in layout.ghosts.reversed() {
            guard let mark = marks.first(where: { $0.id == ghost.markID }) else { continue }
            // Take the paragraph's look from the text the ghost follows.
            var attributes: [NSAttributedString.Key: Any] = [:]
            if result.length > 0 {
                let neighbour = min(max(ghost.anchor - 1, 0), result.length - 1)
                attributes = result.attributes(at: neighbour, effectiveRange: nil)
            } else {
                attributes = self.attributes(for: SegmentStyle())
            }
            attributes[.strikethroughStyle] = nil
            attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(mark.id == selectedMarkID ? 0.32 : 0.16)
            attributes[.foregroundColor] = NSColor.systemGreen.blended(withFraction: 0.35, of: .labelColor) ?? .systemGreen
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = NSColor.systemGreen
            attributes[.annotatorMark] = mark.id.uuidString
            result.insert(NSAttributedString(string: ghost.text, attributes: attributes), at: ghost.anchor)
        }
        return result
    }

    // MARK: - Marks

    private static func attributes(for mark: Mark, selected: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.annotatorMark: mark.id.uuidString]
        switch mark.kind {
        case .delete, .replace:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.systemRed
            attributes[.foregroundColor] = NSColor.systemRed.blended(withFraction: 0.4, of: .labelColor) ?? .systemRed
            attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(selected ? 0.25 : 0.10)
        case .comment:
            attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(selected ? 0.55 : 0.30)
        case .keep:
            attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(selected ? 0.40 : 0.20)
        case .insert:
            break
        }
        return attributes
    }

    // MARK: - Segments

    private static func attributes(for style: SegmentStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: style.quoteDepth > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraphStyle(for: style),
        ]
        if style.code, !isBlockCode(style) {
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.secondaryLabelColor
        }
        if style.link != nil {
            // Shown as a link but not clickable: a click here places the caret.
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.toolTip] = style.link
        }
        if style.isListMarker {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        if style.block == .thematicBreak {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        return attributes
    }

    private static func isBlockCode(_ style: SegmentStyle) -> Bool {
        switch style.block {
        case .codeBlock, .table, .html: true
        default: false
        }
    }

    private static func font(for style: SegmentStyle) -> NSFont {
        var size = bodySize
        var bold = style.bold
        switch style.block {
        case .heading(let level):
            size = [1: 24, 2: 20, 3: 17][level] ?? 15
            bold = true
        case .codeBlock, .table, .html:
            return .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular)
        case .paragraph, .thematicBreak:
            break
        }
        if style.code {
            return .monospacedSystemFont(ofSize: size - 1, weight: bold ? .semibold : .regular)
        }
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard style.italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private static let quoteIndent: CGFloat = 16
    private static let listIndent: CGFloat = 20
    private static let markerWidth: CGFloat = 18

    private static func paragraphStyle(for style: SegmentStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let base = CGFloat(style.quoteDepth) * quoteIndent + CGFloat(max(0, style.listDepth - 1)) * listIndent

        if style.listDepth > 0 {
            // The style of a paragraph's first character wins, so a paragraph that
            // starts with a marker hangs, and a continuation paragraph lines up with it.
            paragraph.firstLineHeadIndent = style.isListMarker ? base : base + markerWidth
            paragraph.headIndent = base + markerWidth
            paragraph.paragraphSpacing = 3
        } else {
            paragraph.firstLineHeadIndent = base
            paragraph.headIndent = base
            paragraph.paragraphSpacing = 8
        }
        switch style.block {
        case .heading(let level):
            paragraph.paragraphSpacingBefore = level <= 2 ? 12 : 8
            paragraph.paragraphSpacing = 6
        case .codeBlock, .table, .html:
            paragraph.paragraphSpacing = 0
            paragraph.lineSpacing = 1
        case .thematicBreak:
            paragraph.alignment = .center
        case .paragraph:
            break
        }
        return paragraph
    }

    /// Code and tables are one segment of several lines with no space between
    /// them, so the gap around the block goes on its first and last line.
    private static func spaceOutBlock(_ segment: RenderSegment, at start: Int, in result: NSMutableAttributedString) {
        guard isBlockCode(segment.style), segment.source != nil else { return }
        let text = segment.text as NSString
        guard text.length > 0 else { return }
        let firstLine = text.lineRange(for: NSRange(location: 0, length: 0))
        let lastLine = text.lineRange(for: NSRange(location: text.length - 1, length: 0))

        func adjust(_ line: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            let range = NSRange(location: start + line.location, length: line.length)
            guard let current = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
            change(style)
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        adjust(firstLine) { $0.paragraphSpacingBefore = 4 }
        adjust(lastLine) { $0.paragraphSpacing = 8 }
    }
}

extension NSRange {
    init(_ range: Range<Int>) {
        self.init(location: range.lowerBound, length: range.count)
    }
}
