import Foundation
import Markdown

/// Turns markdown into displayable segments that remember their source offsets.
///
/// The parser reports where each node sits, but inline positions are not always
/// reliable, so they are only used as hints: every piece of displayed text is
/// checked against the source, and looked for after the previous piece when the
/// hint is wrong.
public enum MarkdownRenderer {
    public static func render(_ source: String, format: TextFormat = .markdown) -> RenderedDocument {
        guard format == .markdown else { return RenderedDocument(plain: source) }
        var builder = Builder(source: source)
        // The parser would otherwise turn quotes curly and `--`, `...` into single
        // characters. Text that no longer matches the source maps only as a
        // whole, and a word selected in it would stand for its whole paragraph.
        builder.blocks(of: Document(parsing: source, options: [.disableSmartOpts]), Context())
        builder.dropTrailingLineBreak()
        return RenderedDocument(source: source, segments: builder.segments, containers: builder.containers)
    }
}

private struct Context {
    var quoteDepth = 0
    var listDepth = 0

    func style(_ block: SegmentStyle.Block = .paragraph) -> SegmentStyle {
        var style = SegmentStyle()
        style.block = block
        style.quoteDepth = quoteDepth
        style.listDepth = listDepth
        return style
    }
}

private struct Builder {
    let source: String
    let units: NSString
    let lines: LineIndex
    var segments: [RenderSegment] = []
    var containers: [InlineContainer] = []
    /// Source offset up to which text has been placed. Later text is matched at or after it.
    var cursor = 0

    init(source: String) {
        self.source = source
        self.units = source as NSString
        self.lines = LineIndex(source)
    }

    // MARK: - Blocks

    mutating func blocks(of parent: Markup, _ context: Context) {
        for child in parent.children { block(child, context) }
    }

    mutating func block(_ node: Markup, _ context: Context) {
        let span = lines.span(of: node.range)
        if let span, span.start > cursor { cursor = span.start }
        let limit = span.map { min($0.end, units.length) } ?? units.length

        switch node {
        case let paragraph as Paragraph:
            let style = context.style()
            inlines(of: paragraph, style, limit)
            lineBreak(style)
        case let heading as Heading:
            let style = context.style(.heading(heading.level))
            inlines(of: heading, style, limit)
            lineBreak(style)
        case let code as CodeBlock:
            codeBlock(code, context.style(.codeBlock(language: code.language)), limit)
        case let quote as BlockQuote:
            var inner = context
            inner.quoteDepth += 1
            blocks(of: quote, inner)
        case let list as UnorderedList:
            for item in list.listItems { listItem(item, marker: "•", context) }
        case let list as OrderedList:
            var number = Int(list.startIndex)
            for item in list.listItems {
                listItem(item, marker: "\(number).", context)
                number += 1
            }
        case is ThematicBreak:
            let style = context.style(.thematicBreak)
            added("———", style)
            lineBreak(style)
        case let table as Table:
            switch Self.layout(for: table) {
            case .columns: rows(of: table, context, limit)
            case .fields: fields(of: table, context, limit)
            case .source: raw(node, span, context.style(.table))
            }
        default:
            raw(node, span, context.style(.html))
        }
        if let span { cursor = max(cursor, min(span.end, units.length)) }
    }

    // MARK: - Tables

    private enum TableLayout {
        case columns, fields, source
    }

    /// Columns are laid out with tab stops, so only the last one can wrap. A
    /// table goes in columns when those before the last are short enough to
    /// leave it room. A wider one shows each row as its cells one under the
    /// other, each after the name of its column. Cells that span rows or
    /// columns fit neither, and the table is shown as it is written.
    private static func layout(for table: Table) -> TableLayout {
        let body = Array(table.body.rows).map { Array($0.cells) }
        let rows = [Array(table.head.cells)] + body
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return .source }
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() {
                guard cell.colspan == 1, cell.rowspan == 1 else { return .source }
                widths[index] = max(widths[index], cell.plainText.count)
            }
        }
        if widths.dropLast().reduce(0, +) + 3 * (columns - 1) <= 46 { return .columns }
        // With no rows there would be nothing to show under the names.
        return body.isEmpty ? .source : .fields
    }

    /// One line per row, with a tab between cells.
    private mutating func rows(of table: Table, _ context: Context, _ limit: Int) {
        var all: [(cells: [Table.Cell], range: SourceRange?, header: Bool)] = [(Array(table.head.cells), table.head.range, true)]
        all += table.body.rows.map { (Array($0.cells), $0.range, false) }

        for row in all {
            if let span = lines.span(of: row.range), span.start > cursor { cursor = span.start }
            var style = context.style(.tableRow(header: row.header))
            for (index, cell) in row.cells.enumerated() {
                style.tableColumn = nil
                if index > 0 { added("\t", style) }
                style.tableColumn = index
                var cellStyle = style
                cellStyle.bold = row.header
                // A cell's text is looked for inside the cell, so equal cells do not swap places.
                let cellSpan = lines.span(of: cell.range)
                if let cellSpan, cellSpan.start > cursor { cursor = cellSpan.start }
                inlines(of: cell, cellStyle, min(cellSpan?.end ?? limit, limit))
                if let cellSpan { cursor = max(cursor, min(cellSpan.end, limit)) }
            }
            style.tableColumn = nil
            lineBreak(style)
        }
    }

    /// One line per cell: the name of its column, a tab, the cell. The header
    /// row is not shown on its own. Its names are added text before every cell,
    /// so a selection that runs over a name takes only the cells.
    private mutating func fields(of table: Table, _ context: Context, _ limit: Int) {
        let names = Array(table.head.cells).map(\.plainText)
        for row in table.body.rows {
            if let span = lines.span(of: row.range), span.start > cursor { cursor = span.start }
            let cells = Array(row.cells)
            for (index, cell) in cells.enumerated() {
                var style = context.style(.tableField(endsRow: index == cells.count - 1))
                style.tableColumn = 0
                if index < names.count, !names[index].isEmpty { added(names[index], style) }
                style.tableColumn = nil
                added("\t", style)
                style.tableColumn = 1
                // A cell's text is looked for inside the cell, so equal cells do not swap places.
                let cellSpan = lines.span(of: cell.range)
                if let cellSpan, cellSpan.start > cursor { cursor = cellSpan.start }
                inlines(of: cell, style, min(cellSpan?.end ?? limit, limit))
                if let cellSpan { cursor = max(cursor, min(cellSpan.end, limit)) }
                style.tableColumn = nil
                lineBreak(style)
            }
        }
    }

    private mutating func listItem(_ item: ListItem, marker: String, _ context: Context) {
        var inner = context
        inner.listDepth += 1
        var markerStyle = inner.style()
        markerStyle.isListMarker = true

        switch item.checkbox {
        case .checked: added("☑ ", markerStyle)
        case .unchecked: added("☐ ", markerStyle)
        case nil: added(marker + " ", markerStyle)
        }
        if item.childCount == 0 {
            lineBreak(inner.style())
        } else {
            block(item, children: inner)
        }
    }

    private mutating func block(_ item: ListItem, children context: Context) {
        let span = lines.span(of: item.range)
        if let span, span.start > cursor { cursor = span.start }
        blocks(of: item, context)
        if let span { cursor = max(cursor, min(span.end, units.length)) }
    }

    private mutating func codeBlock(_ node: CodeBlock, _ style: SegmentStyle, _ limit: Int) {
        var code = node.code
        if code.hasSuffix("\n") { code.removeLast() }

        // Skip the opening fence line, whose info string could look like the code.
        if cursor < limit, isFence(units.character(at: cursor)) {
            let lineEnd = NSMaxRange(units.lineRange(for: NSRange(location: cursor, length: 0)))
            cursor = min(lineEnd, limit)
        }

        if !code.isEmpty {
            if let found = find(code, in: TextSpan(cursor, limit)) {
                segments.append(RenderSegment(text: code, source: found, isExact: true, style: style))
                cursor = found.end
            } else {
                // Indented or nested code: the source has a prefix on every line.
                let codeLines = code.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in codeLines.enumerated() {
                    if index > 0 { added("\n", style) }
                    guard !line.isEmpty else { continue }
                    let found = find(String(line), in: TextSpan(cursor, limit))
                    segments.append(RenderSegment(text: String(line), source: found, isExact: true, style: style))
                    if let found { cursor = found.end }
                }
            }
        }
        lineBreak(style)
    }

    /// Shows a block's source as it is written. Used for tables and HTML.
    private mutating func raw(_ node: Markup, _ span: TextSpan?, _ style: SegmentStyle) {
        if let span, var text = source.slice(span) {
            var end = span.end
            while text.hasSuffix("\n") || text.hasSuffix("\r") {
                end -= text.last!.utf16.count
                text.removeLast()
            }
            if !text.isEmpty {
                segments.append(RenderSegment(text: text, source: TextSpan(span.start, end), isExact: true, style: style))
            }
        } else {
            let text = node.format().trimmingCharacters(in: .newlines)
            if !text.isEmpty { added(text, style) }
        }
        lineBreak(style)
    }

    // MARK: - Inlines

    /// Renders the children of `parent`. Returns the source they cover, delimiters included.
    @discardableResult
    private mutating func inlines(of parent: Markup, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        var covered: TextSpan?
        for child in parent.children {
            if let span = inline(child, style, limit) {
                covered = covered?.union(span) ?? span
            }
        }
        return covered
    }

    private mutating func inline(_ node: Markup, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        let hint = lines.span(of: node.range)
        var style = style

        switch node {
        case let node as Markdown.Text:
            return text(node.string, hint: hint, style, limit)
        case is Strong:
            style.bold = true
            return container(node, delimiters: "*_", width: 2, style, limit)
        case is Emphasis:
            style.italic = true
            return container(node, delimiters: "*_", width: 1, style, limit)
        case is Strikethrough:
            style.strikethrough = true
            return container(node, delimiters: "~", width: 2, style, limit)
        case let code as InlineCode:
            style.code = true
            return inlineCode(code.code, hint: hint, style, limit)
        case let link as Markdown.Link:
            style.link = link.destination
            let covered = inlines(of: link, style, limit)
            // Step over the destination so later text is not matched inside it.
            if let hint, hint.end <= limit { cursor = max(cursor, hint.end) }
            return covered.map { hint.map($0.union) ?? $0 }
        case let image as Markdown.Image:
            let alt = image.plainText
            segments.append(RenderSegment(
                text: alt.isEmpty ? "[image]" : "[image: \(alt)]", source: hint, isExact: false, style: style
            ))
            if let hint, hint.end <= limit { cursor = max(cursor, hint.end) }
            return hint
        case is SoftBreak:
            return sourceLineBreak(shownAs: " ", style, limit)
        case is LineBreak:
            return sourceLineBreak(shownAs: "\n", style, limit)
        case let html as InlineHTML:
            return literal(html.rawHTML, hint: hint, style, limit)
        case let symbol as SymbolLink:
            style.code = true
            return inlineCode(symbol.destination ?? "", hint: hint, style, limit)
        default:
            if node.childCount > 0 { return inlines(of: node, style, limit) }
            let shown = (node as? InlineMarkup)?.plainText ?? ""
            guard !shown.isEmpty else { return nil }
            segments.append(RenderSegment(text: shown, source: hint, isExact: false, style: style))
            return hint
        }
    }

    /// Emphasis-like nodes: renders the content, then records where its delimiters are.
    private mutating func container(
        _ node: Markup, delimiters: String, width: Int, _ style: SegmentStyle, _ limit: Int
    ) -> TextSpan? {
        guard let content = inlines(of: node, style, limit) else { return nil }
        let allowed = Set(delimiters.utf16)
        var count = 0
        while count < width,
              content.start - count - 1 >= 0, content.end + count < units.length,
              allowed.contains(units.character(at: content.start - count - 1)),
              units.character(at: content.end + count) == units.character(at: content.start - count - 1) {
            count += 1
        }
        let full = TextSpan(content.start - count, content.end + count)
        containers.append(InlineContainer(content: content, full: full))
        cursor = max(cursor, full.end)
        return full
    }

    private mutating func inlineCode(_ code: String, hint: TextSpan?, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        guard let content = literal(code, hint: hint, style, limit) else { return nil }
        let backtick: unichar = 0x60
        let space: unichar = 0x20

        // Delimiters are equal runs of backticks, with an optional space of padding inside.
        var start = content.start
        var end = content.end
        if start > 0, end < units.length, units.character(at: start - 1) == space, units.character(at: end) == space {
            start -= 1
            end += 1
        }
        var count = 0
        while start - count - 1 >= 0, end + count < units.length,
              units.character(at: start - count - 1) == backtick, units.character(at: end + count) == backtick {
            count += 1
        }
        guard count > 0 else { return content }
        let full = TextSpan(start - count, end + count)
        containers.append(InlineContainer(content: content, full: full))
        cursor = max(cursor, full.end)
        return full
    }

    /// A line break written in the source: shown as a space inside a paragraph,
    /// or as a break when it is a hard one.
    private mutating func sourceLineBreak(shownAs shown: String, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        let search = NSRange(location: cursor, length: max(0, limit - cursor))
        let found = units.range(of: "\n", options: .literal, range: search)
        guard found.location != NSNotFound else {
            added(shown, style)
            return nil
        }
        let span = TextSpan(found.location, found.location + 1)
        segments.append(RenderSegment(text: shown, source: span, isExact: true, style: style))
        cursor = span.end
        return span
    }

    // MARK: - Matching text against the source

    /// Places text that appears in the source unchanged.
    private mutating func literal(_ shown: String, hint: TextSpan?, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        guard !shown.isEmpty else { return nil }
        var found: TextSpan?
        if let hint, hint.start >= cursor, hint.end <= limit {
            found = find(shown, in: hint)
        }
        found = found ?? find(shown, in: TextSpan(cursor, limit))

        guard let found else {
            segments.append(RenderSegment(text: shown, source: hint, isExact: false, style: style))
            return hint
        }
        segments.append(RenderSegment(text: shown, source: found, isExact: true, style: style))
        cursor = found.end
        return found
    }

    private func find(_ needle: String, in span: TextSpan) -> TextSpan? {
        guard span.start <= span.end, span.end <= units.length else { return nil }
        let found = units.range(of: needle, options: .literal, range: NSRange(span))
        return found.location == NSNotFound ? nil : TextSpan(found.location, NSMaxRange(found))
    }

    /// Places a text node. Its string differs from the source where the source
    /// has backslash escapes or entities, so it is matched run by run.
    private mutating func text(_ shown: String, hint: TextSpan?, _ style: SegmentStyle, _ limit: Int) -> TextSpan? {
        guard !shown.isEmpty else { return nil }
        let shownUnits = Array(shown.utf16)

        var match: Match?
        if let hint, hint.start >= cursor, hint.start < limit {
            match = self.match(shownUnits, at: hint.start, limit)
        }
        if match == nil {
            var position = cursor
            while position < limit, match == nil {
                match = self.match(shownUnits, at: position, limit)
                position += 1
            }
        }

        guard let match else {
            // Not found: the node still maps as a whole when the parser says where it is.
            segments.append(RenderSegment(text: shown, source: hint, isExact: false, style: style))
            if let hint, hint.end <= limit { cursor = max(cursor, hint.end) }
            return hint
        }
        for run in match.runs {
            let piece = String(utf16CodeUnits: Array(shownUnits[run.shown]), count: run.shown.count)
            segments.append(RenderSegment(text: piece, source: run.source, isExact: run.isExact, style: style))
        }
        cursor = match.end
        return TextSpan(match.runs.first?.source.start ?? match.end, match.end)
    }

    private struct Match {
        struct Run {
            var shown: Range<Int>
            var source: TextSpan
            var isExact: Bool
        }
        var runs: [Run] = []
        var end = 0
    }

    private func match(_ shown: [unichar], at start: Int, _ limit: Int) -> Match? {
        let backslash: unichar = 0x5C
        let ampersand: unichar = 0x26

        var result = Match()
        var shownIndex = 0
        var sourceIndex = start
        var runShown = 0
        var runSource = start

        func closeRun() {
            if shownIndex > runShown {
                result.runs.append(.init(
                    shown: runShown..<shownIndex, source: TextSpan(runSource, sourceIndex), isExact: true
                ))
            }
        }

        while shownIndex < shown.count {
            guard sourceIndex < limit else { return nil }
            let unit = units.character(at: sourceIndex)

            // An escape hides its backslash: `\*` is shown as `*` and maps as a whole,
            // so a selection never takes the character and leaves the backslash.
            if unit == backslash, sourceIndex + 1 < limit,
               units.character(at: sourceIndex + 1) == shown[shownIndex],
               isASCIIPunctuation(shown[shownIndex]) {
                closeRun()
                result.runs.append(.init(
                    shown: shownIndex..<(shownIndex + 1),
                    source: TextSpan(sourceIndex, sourceIndex + 2),
                    isExact: false
                ))
                shownIndex += 1
                sourceIndex += 2
                runShown = shownIndex
                runSource = sourceIndex
                continue
            }
            // An entity such as `&amp;` is shown as one character and maps as a whole.
            if unit == ampersand, let entityEnd = entityEnd(at: sourceIndex, limit),
               !continues(shown, from: shownIndex, with: TextSpan(sourceIndex, entityEnd)) {
                closeRun()
                let width = UTF16.isLeadSurrogate(shown[shownIndex]) ? 2 : 1
                guard shownIndex + width <= shown.count else { return nil }
                result.runs.append(.init(
                    shown: shownIndex..<(shownIndex + width),
                    source: TextSpan(sourceIndex, entityEnd),
                    isExact: false
                ))
                shownIndex += width
                sourceIndex = entityEnd
                runShown = shownIndex
                runSource = sourceIndex
                continue
            }
            if unit == shown[shownIndex] {
                shownIndex += 1
                sourceIndex += 1
                continue
            }
            return nil
        }
        closeRun()
        result.end = sourceIndex
        return result
    }

    /// The offset after the `;` of an entity starting at `start`, when there is one.
    private func entityEnd(at start: Int, _ limit: Int) -> Int? {
        var index = start + 1
        while index < limit, index - start <= 33 {
            let unit = units.character(at: index)
            if unit == 0x3B { return index > start + 1 ? index + 1 : nil }
            let isNameUnit = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit)
                || (0x61...0x7A).contains(unit) || unit == 0x23
            guard isNameUnit else { return nil }
            index += 1
        }
        return nil
    }

    /// Whether the shown text carries on with the source text as written, which
    /// means the parser left something that looks like an entity alone.
    private func continues(_ shown: [unichar], from index: Int, with span: TextSpan) -> Bool {
        guard index + span.length <= shown.count else { return false }
        return (0..<span.length).allSatisfy { shown[index + $0] == units.character(at: span.start + $0) }
    }

    private func isASCIIPunctuation(_ unit: unichar) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
            || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    private func isFence(_ unit: unichar) -> Bool { unit == 0x60 || unit == 0x7E }

    // MARK: - Added text

    private mutating func added(_ text: String, _ style: SegmentStyle) {
        segments.append(RenderSegment(text: text, source: nil, isExact: false, style: style))
    }

    private mutating func lineBreak(_ style: SegmentStyle) {
        added("\n", style)
    }

    mutating func dropTrailingLineBreak() {
        if let last = segments.last, last.source == nil, last.text == "\n" {
            segments.removeLast()
        }
    }
}

/// Converts the parser's line and UTF-8 column positions to UTF-16 offsets.
private struct LineIndex {
    private let source: String
    private var lineStarts: [String.Index] = []

    init(_ source: String) {
        self.source = source
        lineStarts.append(source.startIndex)
        var index = source.utf8.startIndex
        while index < source.utf8.endIndex {
            let next = source.utf8.index(after: index)
            if source.utf8[index] == 0x0A { lineStarts.append(next) }
            index = next
        }
    }

    func offset(of location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1 else { return nil }
        let start = lineStarts[location.line - 1]
        guard let index = source.utf8.index(start, offsetBy: location.column - 1, limitedBy: source.utf8.endIndex) else {
            return nil
        }
        return index.utf16Offset(in: source)
    }

    func span(of range: SourceRange?) -> TextSpan? {
        guard let range,
              let start = offset(of: range.lowerBound),
              let end = offset(of: range.upperBound),
              start <= end else { return nil }
        return TextSpan(start, end)
    }
}
