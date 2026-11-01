import Foundation

/// What the text view shows: the rendered document plus "ghost" text for
/// replacements and insertions, which exists in no source. Maps between view
/// offsets and the rendered document's displayed offsets. All offsets are UTF-16.
public struct DisplayLayout: Equatable, Sendable {
    public struct Ghost: Equatable, Sendable {
        /// The mark whose words these are. Nil for text removed since the previous version.
        public var markID: UUID?
        public var text: String
        /// Displayed offset in the rendered document the ghost sits at.
        public var anchor: Int
        /// Where the ghost is in the view.
        public var range: Range<Int>
    }

    public let document: RenderedDocument
    /// In view order.
    public let ghosts: [Ghost]

    /// - Parameter removals: text that was in the previous version, shown where it used to be.
    public init(document: RenderedDocument, marks: [Mark], removals: [PlanChanges.Removal] = []) {
        self.document = document

        var pending: [(order: Int, markID: UUID?, text: String, anchor: Int)] = []
        let end = document.text.utf16Length
        for (index, removal) in removals.enumerated() {
            // Removals come before a mark's words at the same place, in their own order.
            let order = index - removals.count
            if !removal.isWholeLine {
                guard let anchor = document.displayedOffset(forSource: removal.offset) else { continue }
                pending.append((order, nil, removal.text, anchor))
            } else if removal.offset >= document.source.utf16Length {
                pending.append((order, nil, (end > 0 ? "\n" : "") + Self.withoutBlockMarker(removal.text), end))
            } else if let anchor = document.displayedLineStart(forSource: removal.offset) {
                pending.append((order, nil, Self.withoutBlockMarker(removal.text) + "\n", anchor))
            }
        }
        for (order, mark) in marks.enumerated() where mark.anchor.page == nil {
            guard let text = mark.text, !text.isEmpty else { continue }
            switch mark.kind {
            case .replace:
                guard let end = document.displayedRanges(forSource: mark.anchor.span).last?.upperBound else { continue }
                pending.append((order, mark.id, text, end))
            case .insert:
                guard let offset = document.displayedOffset(forSource: mark.anchor.span.start) else { continue }
                pending.append((order, mark.id, text, offset))
            case .delete, .comment, .expand, .summarize, .keep:
                continue
            }
        }
        pending.sort { ($0.anchor, $0.order) < ($1.anchor, $1.order) }

        var ghosts: [Ghost] = []
        var shift = 0
        for item in pending {
            let start = item.anchor + shift
            let length = item.text.utf16Length
            ghosts.append(Ghost(markID: item.markID, text: item.text, anchor: item.anchor, range: start..<(start + length)))
            shift += length
        }
        self.ghosts = ghosts
    }

    /// A removed line without the syntax that started it: its text is shown, not its markdown.
    static func withoutBlockMarker(_ line: String) -> String {
        let marker = /[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]*)?|\#{1,6}[ \t]+)?/
        guard let match = line.prefixMatch(of: marker) else { return line }
        return String(line[match.range.upperBound...])
    }

    /// The view text: the document's text with every ghost in place.
    public var text: String {
        let result = NSMutableString(string: document.text)
        for ghost in ghosts.reversed() {
            result.insert(ghost.text, at: ghost.anchor)
        }
        return result as String
    }

    /// The displayed offset behind a view offset. A position inside a ghost maps
    /// to the place the ghost sits at.
    public func displayedOffset(forView offset: Int) -> Int {
        var shift = 0
        for ghost in ghosts {
            if offset <= ghost.range.lowerBound { break }
            if offset < ghost.range.upperBound { return ghost.anchor }
            shift += ghost.range.count
        }
        return offset - shift
    }

    /// The displayed range behind a view selection, without any ghost text in it.
    public func displayedRange(forView range: Range<Int>) -> Range<Int> {
        let lower = displayedOffset(forView: range.lowerBound)
        return lower..<max(lower, displayedOffset(forView: range.upperBound))
    }

    /// Where displayed text is in the view. Ghosts sitting inside the range split it.
    public func viewRanges(forDisplayed range: Range<Int>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var shift = 0
        var lower = range.lowerBound
        for ghost in ghosts {
            if ghost.anchor >= range.upperBound { break }
            if ghost.anchor > lower {
                ranges.append((lower + shift)..<(ghost.anchor + shift))
                lower = ghost.anchor
            }
            // A ghost at the start of the range comes before it in the view.
            shift += ghost.range.count
        }
        if lower < range.upperBound {
            ranges.append((lower + shift)..<(range.upperBound + shift))
        }
        return ranges
    }

    /// Where a mark's source text is in the view.
    public func viewRanges(forSource span: TextSpan) -> [Range<Int>] {
        document.displayedRanges(forSource: span).flatMap(viewRanges(forDisplayed:))
    }

    /// The view offset of a caret at a displayed offset, placed after any ghost there.
    public func viewOffset(forDisplayed offset: Int) -> Int {
        offset + ghosts.filter { $0.anchor <= offset }.reduce(0) { $0 + $1.range.count }
    }

    /// The view offset of a displayed offset, placed before any ghost there.
    public func viewOffset(beforeGhostsAtDisplayed offset: Int) -> Int {
        offset + ghosts.filter { $0.anchor < offset }.reduce(0) { $0 + $1.range.count }
    }
}
