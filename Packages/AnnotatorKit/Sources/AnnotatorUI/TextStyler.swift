import AnnotatorCore
import AppKit

extension NSAttributedString.Key {
    /// The id of the mark a run of text belongs to, as a UUID string.
    static let annotatorMark = NSAttributedString.Key("annotatorMark")
    /// A `BlockDecoration` drawn behind a paragraph.
    static let annotatorBlock = NSAttributedString.Key("annotatorBlock")
    /// A `Pin` drawn between two characters.
    static let annotatorPin = NSAttributedString.Key("annotatorPin")
}

/// A comment pinned to a point between two characters. It is set on the
/// character after the point, or at the very end of the text on the last one.
struct Pin: Hashable {
    /// The point is after its character: only at the end of the text.
    var isAfter: Bool
    /// Comments pinned to one point are one pin, selected when any of them is.
    var selected: Bool
}

/// Something drawn behind a paragraph rather than set in type.
enum BlockDecoration: Hashable {
    /// A line of a code block or table. `indent` is the block's left edge.
    case panel(first: Bool, last: Bool, indent: CGFloat)
    /// A bar per level of quotation. `trim` is how much shorter than the
    /// paragraph the bar is, so it ends with the text of the last paragraph.
    case quote(depth: Int, trim: CGFloat)
    /// A thematic break, drawn as a rule.
    case rule
    /// A table row, with a line under it. `indent` is the table's left edge, and
    /// `width` how far the line goes: nil to the page's edge.
    case tableRow(header: Bool, last: Bool, indent: CGFloat, width: CGFloat?)
}

/// How a comment on no words shows on a page.
enum PinStyle {
    /// A `Pin` for the page's layout to draw as a bar between two characters.
    case bar
    /// A wash on one character, for a picture drawn without the page's layout.
    case wash
}

/// Builds what the text view shows from the rendered document and the marks.
///
/// A page is built in two layers: the document as set in type, which stays the
/// same for the whole review, and the marks with their words laid over it.
@MainActor
enum TextStyler {
    /// - Parameters:
    ///   - added: source spans that are new since the previous version, to be tinted.
    ///   - measure: how wide the page is.
    static func attributedString(
        layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?, added: [TextSpan] = [], measure: CGFloat = Theme.measure,
        pins: PinStyle = .bar
    ) -> NSAttributedString {
        let base = basePage(of: layout.document, added: added, measure: measure).text
        return marked(base, layout: layout, marks: marks, selectedMarkID: selectedMarkID, displayed: 0..<base.length, pins: pins)
    }

    /// The document as set in type, without marks: one character for each of
    /// its displayed text. With it, how wide each of its tables is at full size.
    static func basePage(
        of document: RenderedDocument, added: [TextSpan] = [], measure: CGFloat = Theme.measure
    ) -> (text: NSAttributedString, tables: [TableFit]) {
        // A line broken by hand stays in its paragraph: a new line, without
        // the space that parts one paragraph from the next. One character for one.
        let texts = document.segments.map { segment in
            segment.text == "\n" && segment.source != nil && !isPanel(segment.style) && !isTableLine(segment.style) ? "\u{2028}" : segment.text
        }
        let result = NSMutableAttributedString(string: texts.joined())

        var tableCells: [TableCell] = []
        // A page has thousands of segments and a handful of styles: each is worked
        // out once, and kept as AppKit's own attribute dictionary. Handed over as
        // it is, it is taken as it is; a Swift dictionary would be converted and
        // looked up again for every segment, which is most of the time on a long page.
        var known: [SegmentStyle: CFDictionary] = [:]
        var panel: Panel?
        var markerWidths: [String: CGFloat] = [:]
        var location = 0
        for (index, segment) in document.segments.enumerated() {
            let range = NSRange(location: location, length: texts[index].utf16.count)
            location = NSMaxRange(range)
            let attributes = known[segment.style] ?? attributeDictionary(for: segment.style)
            known[segment.style] = attributes
            if range.length > 0 {
                CFAttributedStringSetAttributes(result as CFMutableAttributedString, CFRange(location: range.location, length: range.length), attributes, true)
            }
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

        // Plain text is shown line for line, as in its file: a line is not a
        // paragraph to set apart from the next, and an empty line is the space there is.
        if isPlainText(document), result.length > 0,
           let current = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let style = current.mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 0
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        }

        endQuoteBars(in: result)
        let tables = layOutTables(tableCells, in: result, measure: measure)
        Typography.setPunctuation(in: result)

        // New since the previous version: a quiet tint, under whatever the reviewer marks.
        for span in added {
            for range in document.displayedRanges(forSource: span) {
                result.addAttribute(.backgroundColor, value: Theme.revisionWash, range: NSRange(range))
            }
        }
        return (result, tables)
    }

    /// Part of a page: the base page's text in `displayed`, with the marks on it
    /// and the ghosts that sit anywhere from its start to its end, both included.
    static func marked(
        _ base: NSAttributedString, layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?, displayed: Range<Int>,
        pins: PinStyle = .bar
    ) -> NSAttributedString {
        let document = layout.document
        let start = displayed.lowerBound
        let result = NSMutableAttributedString(attributedString: base.attributedSubstring(from: NSRange(displayed)))

        // Marks are applied in displayed offsets, before ghosts shift anything.
        for mark in marks {
            let selected = mark.id == selectedMarkID
            if mark.isPointComment {
                if let point = document.displayedOffset(forSource: mark.anchor.span.start) {
                    pin(at: point, selected: selected, style: pins, in: result, base: base, displayed: displayed)
                }
                continue
            }
            let ranges = document.displayedRanges(forSource: mark.anchor.span)
            for range in ranges {
                let part = range.clamped(to: displayed)
                guard !part.isEmpty else { continue }
                result.addAttributes(attributes(for: mark, selected: selected), range: NSRange(location: part.lowerBound - start, length: part.count))
            }
            // A little air between struck text and the words that replace it.
            if mark.kind == .replace, mark.text?.isEmpty == false, let end = ranges.last?.upperBound, end > 0, displayed.contains(end - 1) {
                result.addAttribute(.kern, value: 3, range: NSRange(location: end - 1 - start, length: 1))
            }
        }

        // What a ghost looks like is taken from the base page around it.
        for ghost in layout.ghosts.reversed() where displayed.lowerBound <= ghost.anchor && ghost.anchor <= displayed.upperBound {
            guard let mark = marks.first(where: { $0.id == ghost.markID }) else {
                // Not a mark's words: text that was removed since the previous version.
                let removed = NSMutableAttributedString(string: ghost.text, attributes: removalAttributes(for: ghost, in: base))
                if !ghost.text.hasSuffix("\n"), !ghost.text.hasSuffix(" "), removed.length > 0 {
                    // A little air before the words that took its place.
                    removed.addAttribute(.kern, value: 3, range: NSRange(location: removed.length - 1, length: 1))
                }
                result.insert(removed, at: ghost.anchor - start)
                continue
            }
            result.insert(
                NSAttributedString(string: ghost.text, attributes: ghostAttributes(for: mark, at: ghost.anchor, in: base, selected: mark.id == selectedMarkID)),
                at: ghost.anchor - start
            )
        }
        return result
    }

    // MARK: - Marks

    /// A comment on no words, pinned to `point`, a displayed offset.
    private static func pin(
        at point: Int, selected: Bool, style: PinStyle, in result: NSMutableAttributedString, base: NSAttributedString, displayed: Range<Int>
    ) {
        let characters = base.string as NSString
        guard characters.length > 0 else { return }
        var isAfter = point >= characters.length
        // A wash on a line break would run to the end of the line.
        if style == .wash, !isAfter, point > 0, characters.character(at: point) == 0x0A || characters.character(at: point) == 0x2028 {
            isAfter = true
        }
        let index = isAfter ? min(point, characters.length) - 1 : point
        guard displayed.contains(index) else { return }
        let character = NSIntersectionRange(characters.rangeOfComposedCharacterSequence(at: index), NSRange(displayed))
        let range = NSRange(location: character.location - displayed.lowerBound, length: character.length)
        switch style {
        case .bar:
            let shared = result.attribute(.annotatorPin, at: range.location, effectiveRange: nil) as? Pin
            result.addAttribute(.annotatorPin, value: Pin(isAfter: isAfter, selected: selected || shared?.selected == true), range: range)
        case .wash:
            result.addAttribute(.backgroundColor, value: Theme.highlightWash(selected: selected), range: range)
        }
    }

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
            // It starts where their text does: among list items, in from the numbers.
            let beside = min(max(ghost.text.hasSuffix("\n") ? ghost.anchor : ghost.anchor - 1, 0), text.length - 1)
            if beside >= 0, let neighbour = text.attribute(.paragraphStyle, at: beside, effectiveRange: nil) as? NSParagraphStyle {
                switch text.attribute(.annotatorBlock, at: beside, effectiveRange: nil) as? BlockDecoration {
                case .panel, .tableRow:
                    break
                default:
                    paragraph.firstLineHeadIndent = neighbour.headIndent
                    paragraph.headIndent = neighbour.headIndent
                }
            }
            attributes[.paragraphStyle] = paragraph
        }
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
        attributes[.backgroundColor] = nil
        return attributes
    }

    // MARK: - Segments

    /// A style's attributes as the dictionary AppKit keeps for them.
    private static func attributeDictionary(for style: SegmentStyle) -> CFDictionary {
        CFAttributedStringGetAttributes(NSAttributedString(string: " ", attributes: attributes(for: style)) as CFAttributedString, 0, nil)
    }

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
        case .tableRow(let header, _):
            if header { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        case .codeBlock, .table, .html:
            break
        case .tableField:
            // The column's name, before its cell.
            if style.tableColumn == 0 { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        }
        return attributes
    }

    /// Text that was not read as Markdown: the whole of it is one run, as written.
    private static func isPlainText(_ document: RenderedDocument) -> Bool {
        document.segments.count == 1 && document.segments[0].style == SegmentStyle() && document.segments[0].text.contains("\n")
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
        case .tableRow(true, _):
            // The names of the columns, small and quiet over the figures they name.
            if style.code { return Theme.mono(11, weight: .semibold) }
            return .systemFont(ofSize: 12, weight: .semibold)
        case .tableRow, .tableField:
            let size = Theme.bodySize - 1
            if style.code { return Theme.mono(size - 2.5, weight: style.bold ? .semibold : .regular) }
            let font = Theme.serif(size, weight: style.bold ? .semibold : .regular, italic: style.italic)
            return style.columnAlignment == .leading ? font : Theme.tabularFigures(font)
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
        guard range.length > 0 else { return }
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
            // A line of code too long for the page breaks between words, as an
            // editor wraps it. A table shown as written keeps its grid: it breaks anywhere.
            if case .table = style.block { paragraph.lineBreakMode = .byCharWrapping }
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

    /// A cell's text as it is set, for measuring it once.
    private struct Measured: Hashable {
        var text: String
        var style: SegmentStyle
    }

    private static let rowPadding: CGFloat = 7
    /// Between the lines of one row: the cells of a wide table, or a name that wraps.
    private static let fieldPadding: CGFloat = 1.5

    /// How wide a table is when set at full size, and how far in it starts.
    struct TableFit: Equatable {
        var natural: CGFloat
        var indent: CGFloat

        /// The size the table is set at on a page `measure` wide.
        func scale(on measure: CGFloat) -> CGFloat {
            let available = measure - indent
            guard natural > available, natural > 0 else { return 1 }
            // In steps, so that resizing a window does not set the page again at every point.
            return max(0.5, (available / natural * 20).rounded(.down) / 20)
        }
    }

    /// Gives each table its columns: a tab stop where each column starts, as wide
    /// as its widest cell, with the last column wrapping under its own start.
    /// Numbers are set against the right edge of their column. A table wider
    /// than the page is set smaller, all of it, until it fits.
    private static func layOutTables(_ cells: [TableCell], in result: NSMutableAttributedString, measure: CGFloat) -> [TableFit] {
        // The lines of one table follow each other without a gap, and the next table starts anew.
        var tables: [[TableCell]] = []
        for cell in cells {
            if let last = tables.last?.last, last.segment + 1 == cell.segment, last.style.table == cell.style.table {
                tables[tables.count - 1].append(cell)
            } else {
                tables.append([cell])
            }
        }

        var fits: [TableFit] = []
        let characters = result.string as NSString
        for table in tables {
            var rows: [[TableCell]] = [[]]
            for cell in table {
                rows[rows.count - 1].append(cell)
                if cell.endsRow { rows.append([]) }
            }
            rows.removeAll(where: \.isEmpty)
            guard let first = rows.first?.first, let lastColumn = table.compactMap(\.style.tableColumn).max() else { continue }
            let isFields: Bool = { if case .tableField = first.style.block { return true } else { return false } }()
            var alignments = [SegmentStyle.ColumnAlignment](repeating: .leading, count: lastColumn + 1)
            for cell in table {
                if let column = cell.style.tableColumn { alignments[column] = cell.style.columnAlignment }
            }

            // Where a column starts depends on the columns before it. The last,
            // when it wraps, is measured only until it is as wide as the page,
            // and in a wide table not at all: it has thousands of cells, but
            // the column before it is the names, the same few in every row.
            // A text set the same way is measured once.
            let indent = blockIndent(for: first.style)
            let lastWraps = alignments[lastColumn] == .leading
            let wrapping = CGFloat(TableMeasure.wrappingColumn)
            var widths = [CGFloat](repeating: 0, count: lastColumn + 1)
            var measured: [Measured: CGFloat] = [:]
            for row in rows {
                var rowWidths: [Int: CGFloat] = [:]
                for cell in row {
                    guard let column = cell.style.tableColumn else { continue }
                    if column == lastColumn, lastWraps, isFields || widths[column] >= measure - indent { continue }
                    let key = Measured(text: characters.substring(with: cell.range), style: cell.style)
                    let width = measured[key] ?? ceil(result.attributedSubstring(from: cell.range).size().width)
                    measured[key] = width
                    rowWidths[column, default: 0] += width
                }
                for (column, width) in rowWidths {
                    widths[column] = max(widths[column], width)
                }
            }

            var gap = CGFloat(TableMeasure.gap)
            let lastNeeds = isFields ? 0 : lastWraps ? min(widths[lastColumn], wrapping) : widths[lastColumn]
            let fit = TableFit(natural: widths.dropLast().reduce(lastNeeds) { $0 + $1 + gap }, indent: indent)
            fits.append(fit)
            let scale = isFields ? 1 : fit.scale(on: measure)
            if scale < 1, let end = table.last.map({ NSMaxRange($0.range) }) {
                let range = NSRange(location: first.range.location, length: end - first.range.location)
                result.enumerateAttribute(.font, in: range) { value, run, _ in
                    guard let font = value as? NSFont else { return }
                    let smaller = NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * scale * 2).rounded() / 2) ?? font
                    result.addAttribute(.font, value: smaller, range: run)
                }
                widths = widths.map { ceil($0 * scale) }
                gap = (gap * scale).rounded()
            }

            var starts: [CGFloat] = [indent]
            for width in widths.dropLast() { starts.append((starts.last ?? indent) + width + gap) }
            // The lines under the rows end with the table, unless its last column runs on to the page's edge.
            let end = (starts.last ?? indent) + widths[lastColumn]
            let width = isFields || end >= measure ? nil : end - indent
            let stops = starts.indices.dropFirst().map { column in
                switch alignments[column] {
                case .leading: NSTextTab(textAlignment: .left, location: starts[column])
                case .center: NSTextTab(textAlignment: .center, location: starts[column] + widths[column] / 2)
                case .trailing: NSTextTab(textAlignment: .right, location: starts[column] + widths[column])
                }
            }

            // A row of several lines, a wide table's or a header whose names
            // wrap, has them close together, and only the last has the row's
            // padding and line under it.
            var startsRow = true
            for (index, row) in rows.enumerated() {
                guard let start = row.first?.range.location, let end = row.last.map({ NSMaxRange($0.range) }) else { continue }
                let isLast = index == rows.count - 1
                let (isHeader, endsRow): (Bool, Bool) = switch row[0].style.block {
                case .tableRow(let header, let endsRow): (header, endsRow)
                case .tableField(let endsRow): (false, endsRow)
                default: (false, true)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = starts.last ?? indent
                paragraph.tabStops = stops
                paragraph.lineSpacing = 3
                paragraph.lineBreakStrategy = .standard
                paragraph.paragraphSpacingBefore = (startsRow ? rowPadding : fieldPadding) + (index == 0 ? 4 : 0)
                paragraph.paragraphSpacing = (endsRow ? rowPadding : fieldPadding) + (isLast ? 12 : 0)

                let range = NSRange(location: start, length: end - start)
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
                if endsRow {
                    result.addAttribute(.annotatorBlock, value: BlockDecoration.tableRow(header: isHeader, last: isLast, indent: indent, width: width), range: range)
                }
                startsRow = endsRow
            }
        }
        return fits
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
