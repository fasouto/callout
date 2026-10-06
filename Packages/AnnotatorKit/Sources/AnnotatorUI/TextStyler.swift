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
    /// A table row, with a hairline under it unless it is the last. `indent` is the table's left edge.
    case tableRow(header: Bool, last: Bool, indent: CGFloat)
}

/// Builds what the text view shows from the rendered document and the marks.
@MainActor
enum TextStyler {
    /// - Parameter added: source spans that are new since the previous version, to be tinted.
    static func attributedString(
        layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?, added: [TextSpan] = []
    ) -> NSAttributedString {
        let document = layout.document
        let result = NSMutableAttributedString()

        var tableCells: [TableCell] = []
        // A page has thousands of segments and a handful of styles: each is worked out once.
        var known: [SegmentStyle: [NSAttributedString.Key: Any]] = [:]
        var panel: Panel?
        var markerWidths: [String: CGFloat] = [:]
        for (index, segment) in document.segments.enumerated() {
            let start = result.length
            let attributes = known[segment.style] ?? attributes(for: segment.style)
            known[segment.style] = attributes
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
            let range = NSRange(location: start, length: result.length - start)
            if segment.style.isListMarker { hang(markerIn: range, in: result, widths: &markerWidths) }
            if isPanel(segment.style) {
                if let source = segment.source, range.length > 0 {
                    if let open = panel, open.style == segment.style, isInsideBlock(document.source, from: open.source.end, to: source.start) {
                        panel = Panel(range: NSUnionRange(open.range, range), source: source, style: open.style)
                    } else {
                        if let panel { decorate(panel, in: result) }
                        panel = Panel(range: range, source: source, style: segment.style)
                    }
                } else if segment.text != "\n" || segment.style != panel?.style {
                    if let panel { decorate(panel, in: result) }
                    panel = nil
                }
            } else if let open = panel {
                decorate(open, in: result)
                panel = nil
            }
            if isTableLine(segment.style) {
                tableCells.append(TableCell(segment: index, range: range, style: segment.style, endsRow: segment.text == "\n"))
            }
        }
        if let panel { decorate(panel, in: result) }

        endQuoteBars(in: result)
        layOutTables(tableCells, in: result)
        Typography.setPunctuation(in: result)

        // New since the previous version: a quiet tint, under whatever the reviewer marks.
        for span in added {
            for range in document.displayedRanges(forSource: span) {
                result.addAttribute(.backgroundColor, value: Theme.revisionWash, range: NSRange(range))
            }
        }

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
            guard let mark = marks.first(where: { $0.id == ghost.markID }) else {
                // Not a mark's words: text that was removed since the previous version.
                let removed = NSMutableAttributedString(string: ghost.text, attributes: removalAttributes(for: ghost, in: result))
                if !ghost.text.hasSuffix("\n"), !ghost.text.hasSuffix(" "), removed.length > 0 {
                    // A little air before the words that took its place.
                    removed.addAttribute(.kern, value: 3, range: NSRange(location: removed.length - 1, length: 1))
                }
                result.insert(removed, at: ghost.anchor)
                continue
            }
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
        case .comment, .expand, .summarize:
            // All three are notes to the author about a passage: the highlighter
            // says "look here", the margin says what about it.
            attributes[.backgroundColor] = Theme.highlightWash(selected: selected)
            attributes[.foregroundColor] = Theme.highlightedText
        case .keep:
            attributes[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            attributes[.underlineColor] = Theme.keep
            attributes[.backgroundColor] = Theme.keepWash(selected: selected)
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

    /// Text from the previous version: faint and struck with a thin line, so it
    /// reads as gone and cannot be mistaken for the reviewer's red pen.
    private static func removalAttributes(for ghost: DisplayLayout.Ghost, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        var attributes = self.attributes(for: SegmentStyle())
        let isOwnLine = ghost.text.hasSuffix("\n") || ghost.text.hasPrefix("\n")
        if !isOwnLine, text.length > 0 {
            let neighbour = text.attributes(at: min(max(ghost.anchor - 1, 0), text.length - 1), effectiveRange: nil)
            if let paragraph = neighbour[.paragraphStyle] { attributes[.paragraphStyle] = paragraph }
            if let block = neighbour[.annotatorBlock] { attributes[.annotatorBlock] = block }
            if let font = neighbour[.font] { attributes[.font] = font }
        }
        if isOwnLine {
            // A removed line sits close to its neighbours, like one more item among them.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 5
            attributes[.paragraphStyle] = paragraph
        }
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
        attributes[.backgroundColor] = nil
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
        case .codeBlock, .table, .html, .tableRow:
            break
        case .tableField:
            // The column's name, before its cell.
            if style.tableColumn == 0 { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        }
        return attributes
    }

    /// A line of a table that is laid out in columns: a row, or one cell of a wide table.
    private static func isTableLine(_ style: SegmentStyle) -> Bool {
        switch style.block {
        case .tableRow, .tableField: true
        default: false
        }
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
        case .tableField where style.tableColumn == 0:
            return .systemFont(ofSize: 12, weight: .medium)
        case .tableRow, .tableField:
            let size = Theme.bodySize - 1
            if style.code { return Theme.mono(size - 2.5, weight: style.bold ? .semibold : .regular) }
            return Theme.serif(size, weight: style.bold ? .semibold : .regular, italic: style.italic)
        case .paragraph, .thematicBreak:
            if style.code { return Theme.mono(Theme.bodySize - 2.5, weight: style.bold ? .semibold : .regular) }
            return Theme.serif(Theme.bodySize, weight: style.bold ? .semibold : .regular, italic: style.italic)
        }
    }

    private static let quoteIndent: CGFloat = 18
    private static let listIndent: CGFloat = 22
    private static let markerWidth: CGFloat = 22

    /// A list's bullets and numbers hang in a column of their own, set against
    /// the text: numbers line up on their points, and every line of an item,
    /// the first included, starts at the same edge.
    private static func hang(markerIn range: NSRange, in result: NSMutableAttributedString, widths: inout [String: CGFloat]) {
        let marker = result.attributedSubstring(from: range)
        let width = widths[marker.string] ?? ceil(marker.size().width)
        widths[marker.string] = width
        // The paragraph takes its style from its first character, which is the marker.
        guard width < markerWidth,
              let current = marker.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.firstLineHeadIndent += markerWidth - width
        result.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private static func blockIndent(for style: SegmentStyle) -> CGFloat {
        CGFloat(style.quoteDepth) * quoteIndent + CGFloat(max(0, style.listDepth - 1)) * listIndent
            + (style.listDepth > 0 ? markerWidth : 0)
    }

    private static func paragraphStyle(for style: SegmentStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        // Break lines as a typesetter would: no word left alone on a paragraph's last line.
        paragraph.lineBreakStrategy = .standard
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
        case .paragraph, .tableRow, .tableField:
            // A table row gets its columns once the whole table is known.
            break
        }
        return paragraph
    }

    // MARK: - Tables

    private struct TableCell {
        var segment: Int
        var range: NSRange
        var style: SegmentStyle
        var endsRow: Bool
    }

    private static let columnGap: CGFloat = 28
    private static let rowPadding: CGFloat = 7
    /// Between the cells of one row of a wide table.
    private static let fieldPadding: CGFloat = 1.5

    /// Gives each table its columns: a tab stop where each column starts, as wide
    /// as its widest cell, with the last column wrapping under its own start.
    private static func layOutTables(_ cells: [TableCell], in result: NSMutableAttributedString) {
        // Segments of one table follow each other without a gap.
        var tables: [[TableCell]] = []
        for cell in cells {
            if let last = tables.last?.last, last.segment + 1 == cell.segment {
                tables[tables.count - 1].append(cell)
            } else {
                tables.append([cell])
            }
        }

        for table in tables {
            var rows: [[TableCell]] = [[]]
            for cell in table {
                rows[rows.count - 1].append(cell)
                if cell.endsRow { rows.append([]) }
            }
            rows.removeAll(where: \.isEmpty)
            guard let first = rows.first?.first else { continue }

            var widths: [CGFloat] = []
            for row in rows {
                var rowWidths: [Int: CGFloat] = [:]
                for cell in row {
                    guard let column = cell.style.tableColumn else { continue }
                    rowWidths[column, default: 0] += ceil(result.attributedSubstring(from: cell.range).size().width)
                }
                for (column, width) in rowWidths {
                    while widths.count <= column { widths.append(0) }
                    widths[column] = max(widths[column], width)
                }
            }
            guard !widths.isEmpty else { continue }

            let indent = blockIndent(for: first.style)
            var starts: [CGFloat] = [indent]
            for width in widths.dropLast() { starts.append((starts.last ?? indent) + width + columnGap) }

            // In a wide table a row is several lines, one per cell: they sit close
            // together, and only the last has the row's padding and line under it.
            var startsRow = true
            for (index, row) in rows.enumerated() {
                guard let start = row.first?.range.location, let end = row.last.map({ NSMaxRange($0.range) }) else { continue }
                let isLast = index == rows.count - 1
                let isHeader: Bool = { if case .tableRow(let header) = row[0].style.block { return header } else { return false } }()
                let endsRow: Bool = { if case .tableField(let endsRow) = row[0].style.block { return endsRow } else { return true } }()

                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = starts.last ?? indent
                paragraph.tabStops = starts.dropFirst().map { NSTextTab(textAlignment: .left, location: $0) }
                paragraph.lineSpacing = 3
                paragraph.lineBreakStrategy = .standard
                paragraph.paragraphSpacingBefore = (startsRow ? rowPadding : fieldPadding) + (index == 0 ? 4 : 0)
                paragraph.paragraphSpacing = (endsRow ? rowPadding : fieldPadding) + (isLast ? 12 : 0)

                let range = NSRange(location: start, length: end - start)
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
                if endsRow {
                    result.addAttribute(.annotatorBlock, value: BlockDecoration.tableRow(header: isHeader, last: isLast, indent: indent), range: range)
                }
                startsRow = endsRow
            }
        }
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

    /// A block drawn on a panel: code, or a table or HTML shown as written.
    private struct Panel {
        /// Where it is in the styled text.
        var range: NSRange
        /// The source of its last segment so far.
        var source: TextSpan
        var style: SegmentStyle
    }

    /// Whether the source between two segments is only what a line of one block
    /// starts with: the line break, indentation, and the `>` of a quotation. Code
    /// inside a list item or a quotation comes as one segment per line, and a
    /// fence in between means the next segment is another block.
    private static func isInsideBlock(_ source: String, from start: Int, to end: Int) -> Bool {
        let units = source as NSString
        guard start <= end, end <= units.length else { return false }
        return (start..<end).allSatisfy { " \t\r\n>".utf16.contains(units.character(at: $0)) }
    }

    /// Each line learns where it sits in the block, so the background is drawn
    /// as one panel with room around it.
    private static func decorate(_ panel: Panel, in result: NSMutableAttributedString) {
        let text = result.attributedSubstring(from: panel.range).string as NSString
        guard text.length > 0 else { return }
        let start = panel.range.location
        let indent = blockIndent(for: panel.style)

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
