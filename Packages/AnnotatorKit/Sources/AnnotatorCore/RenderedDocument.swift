import Foundation

public struct SegmentStyle: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case codeBlock(language: String?)
        /// A table shown as it is written, because its cells span rows or columns.
        case table
        /// One row of a table laid out in columns.
        case tableRow(header: Bool)
        /// One cell of a table too wide for columns: on a line of its own, after
        /// the name of its column. `endsRow` is true for the last cell of its row.
        case tableField(endsRow: Bool)
        case html
        case thematicBreak
    }

    public var block: Block = .paragraph
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    public var link: String?
    public var quoteDepth = 0
    public var listDepth = 0
    /// A bullet, number or task box the renderer added.
    public var isListMarker = false
    /// The column a table cell's text belongs to. Nil for the separators between cells.
    /// In a `tableField` line, 0 is the column's name and 1 the cell.
    public var tableColumn: Int?

    public init() {}
}

/// A run of displayed text and the source it came from.
public struct RenderSegment: Equatable, Sendable {
    public var text: String
    /// Nil for text the renderer added (bullets, line breaks between blocks).
    public var source: TextSpan?
    /// True when every UTF-16 unit of `text` is the same unit of the source, so
    /// offsets map one to one. False when the segment only maps as a whole.
    public var isExact: Bool
    public var style: SegmentStyle

    public init(text: String, source: TextSpan?, isExact: Bool, style: SegmentStyle) {
        self.text = text
        self.source = source
        self.isExact = isExact && source != nil
        self.style = style
    }
}

/// Emphasis, strong, strikethrough or inline code: `content` is what is shown,
/// `full` adds the delimiters around it.
struct InlineContainer: Equatable, Sendable {
    var content: TextSpan
    var full: TextSpan
}

/// What the text view shows, with the mapping between displayed offsets and
/// source offsets that marks are anchored to. All offsets are UTF-16.
public struct RenderedDocument: Equatable, Sendable {
    public let source: String
    public let segments: [RenderSegment]
    public let text: String
    /// Displayed offset at which each segment starts.
    let starts: [Int]
    let containers: [InlineContainer]

    init(source: String, segments: [RenderSegment], containers: [InlineContainer]) {
        self.source = source
        self.segments = segments
        self.containers = containers
        self.text = segments.map(\.text).joined()
        var starts: [Int] = []
        var offset = 0
        for segment in segments {
            starts.append(offset)
            offset += segment.text.utf16Length
        }
        self.starts = starts
    }

    /// Plain text is shown as is.
    public init(plain source: String) {
        let segment = RenderSegment(
            text: source, source: TextSpan(0, source.utf16Length), isExact: true, style: SegmentStyle()
        )
        self.init(source: source, segments: source.isEmpty ? [] : [segment], containers: [])
    }

    private func displayedRange(_ index: Int) -> Range<Int> {
        starts[index]..<(starts[index] + segments[index].text.utf16Length)
    }

    // MARK: - Displayed to source

    /// The source covered by a selection. A selection that takes all of an
    /// emphasised or code run also takes its delimiters, so deleting it leaves
    /// no `****` behind.
    public func sourceSpan(forDisplayed range: Range<Int>) -> TextSpan? {
        guard !range.isEmpty else { return nil }
        var result: TextSpan?
        for index in segments.indices {
            guard let source = segments[index].source else { continue }
            let displayed = displayedRange(index)
            let overlap = displayed.clamped(to: range)
            guard !overlap.isEmpty else { continue }

            var piece = source
            if segments[index].isExact {
                piece = TextSpan(
                    source.start + overlap.lowerBound - displayed.lowerBound,
                    source.start + overlap.upperBound - displayed.lowerBound
                )
            }
            result = result?.union(piece) ?? piece
        }
        guard var span = result else { return nil }

        var changed = true
        while changed {
            changed = false
            for container in containers
            where span.start <= container.content.start && span.end >= container.content.end {
                let widened = span.union(container.full)
                if widened != span {
                    span = widened
                    changed = true
                }
            }
        }
        return span
    }

    /// The source offset an insertion at a displayed caret position goes to.
    /// Prefers the end of the text before the caret.
    public func sourceOffset(forDisplayed offset: Int) -> Int? {
        var nearest: (distance: Int, offset: Int)?
        for index in segments.indices {
            guard let source = segments[index].source else { continue }
            let displayed = displayedRange(index)

            if segments[index].isExact, displayed.lowerBound < offset, offset <= displayed.upperBound {
                return source.start + offset - displayed.lowerBound
            }
            let candidates = [
                (abs(offset - displayed.upperBound), source.end),
                (abs(offset - displayed.lowerBound), source.start),
            ]
            for candidate in candidates where nearest == nil || candidate.0 < nearest!.distance {
                nearest = candidate
            }
        }
        return nearest?.offset
    }

    // MARK: - Source to displayed

    /// Where a source span is displayed. Several ranges when added text, such as
    /// a list bullet, sits in between.
    public func displayedRanges(forSource span: TextSpan) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for index in segments.indices {
            guard let source = segments[index].source, source.overlaps(span) else { continue }
            var displayed = displayedRange(index)
            if segments[index].isExact {
                let lower = displayed.lowerBound + max(span.start, source.start) - source.start
                let upper = displayed.lowerBound + min(span.end, source.end) - source.start
                displayed = lower..<upper
            }
            if let last = ranges.last, last.upperBound == displayed.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<displayed.upperBound
            } else {
                ranges.append(displayed)
            }
        }
        return ranges
    }

    /// Where the displayed line begins that holds the source at or after `offset`,
    /// a line start in the source. Syntax at the start of the source line, such
    /// as a list marker, is not displayed, so the text after it is what is looked for.
    public func displayedLineStart(forSource offset: Int) -> Int? {
        guard let index = segments.indices.first(where: { ($0 < segments.count) && (segments[$0].source.map { $0.end > offset } ?? false) }) else {
            return nil
        }
        let start = starts[index]
        let before = (text as NSString).substring(to: start) as NSString
        let lineBreak = before.range(of: "\n", options: .backwards)
        return lineBreak.location == NSNotFound ? 0 : lineBreak.location + 1
    }

    /// Where a source offset is displayed, for drawing an insertion point.
    public func displayedOffset(forSource offset: Int) -> Int? {
        var nearest: (distance: Int, offset: Int)?
        for index in segments.indices {
            guard let source = segments[index].source else { continue }
            let displayed = displayedRange(index)

            if segments[index].isExact, source.start < offset, offset <= source.end {
                return displayed.lowerBound + offset - source.start
            }
            let candidates = [
                (abs(offset - source.end), displayed.upperBound),
                (abs(offset - source.start), displayed.lowerBound),
            ]
            for candidate in candidates where nearest == nil || candidate.0 < nearest!.distance {
                nearest = candidate
            }
        }
        return nearest?.offset
    }
}
