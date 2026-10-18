import AnnotatorCore
import AppKit

/// The page the text view shows, kept up to date one change at a time.
///
/// Setting a whole page again costs seconds on a long document: it is styled
/// anew, and the text view throws away its layout. A mark only changes the
/// page where it is, so only that part is built again and swapped in.
@MainActor
final class StyledPage {
    /// What a page shows of a mark. Its note is written in the margin, not here.
    private struct Footprint: Hashable {
        var id: UUID
        var kind: MarkKind
        var span: TextSpan
        var text: String?
        var selected: Bool
    }

    /// One part of the page to replace: `range` in the page as it was, `text` as it is now.
    struct Edit {
        var range: NSRange
        var text: NSAttributedString
    }

    private let base: NSAttributedString
    private let added: [TextSpan]
    private var layout: DisplayLayout
    private var footprints: [Footprint]
    /// The whole page, as built when it was made.
    let text: NSAttributedString

    init(layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?, added: [TextSpan]) {
        base = TextStyler.basePage(of: layout.document, added: added)
        self.added = added
        self.layout = layout
        footprints = Self.footprints(of: marks, selectedMarkID: selectedMarkID)
        text = TextStyler.marked(base, layout: layout, marks: marks, selectedMarkID: selectedMarkID, displayed: 0..<base.length)
    }

    /// The parts of the page to replace, last first, so that each range is
    /// still where it was when its turn comes. Empty when the page shows the
    /// same; nil when the page has to be made again.
    func update(to layout: DisplayLayout, marks: [Mark], selectedMarkID: UUID?, added: [TextSpan]) -> [Edit]? {
        let document = layout.document
        guard document.source == self.layout.document.source, added == self.added,
              Self.removals(in: layout) == Self.removals(in: self.layout) else { return nil }

        let new = Self.footprints(of: marks, selectedMarkID: selectedMarkID)
        // Marks are only ever added, changed or taken away, so the ones on both
        // pages are in the same order, and overlapping ones are drawn the same.
        let old = footprints
        let oldIDs = Set(old.map(\.id)), newIDs = Set(new.map(\.id))
        guard old.map(\.id).filter(newIDs.contains) == new.map(\.id).filter(oldIDs.contains) else { return nil }

        let changed = Set(old).symmetricDifference(Set(new))
        var spans: [ClosedRange<Int>] = changed.compactMap { footprint in
            let ranges = document.displayedRanges(forSource: footprint.span)
            if let first = ranges.first, let last = ranges.last { return first.lowerBound...last.upperBound }
            // An insertion sits at a caret.
            return document.displayedOffset(forSource: footprint.span.start).map { $0...$0 }
        }
        // Whole paragraphs: text storage gives each paragraph the style of its
        // first character, so words typed at the start of one restyle all of it,
        // and it has to be set again as a whole when they go.
        let characters = base.string as NSString
        spans = spans.map { span in
            let lower = min(span.lowerBound, characters.length)
            let upper = min(span.upperBound + 1, characters.length)
            let paragraphs = characters.paragraphRange(for: NSRange(location: lower, length: max(0, upper - lower)))
            return paragraphs.location...NSMaxRange(paragraphs)
        }
        spans.sort { $0.lowerBound < $1.lowerBound }

        // Parts that meet are one: each ghost belongs to exactly one part.
        var parts: [ClosedRange<Int>] = []
        for span in spans {
            if let last = parts.last, span.lowerBound <= last.upperBound {
                parts[parts.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                parts.append(span)
            }
        }
        // Most of the page changed: making it again is as quick.
        guard parts.reduce(0, { $0 + $1.count }) <= base.length / 2 + 1 else { return nil }

        let edits = parts.reversed().map { part in
            let lower = self.layout.viewOffset(beforeGhostsAtDisplayed: part.lowerBound)
            let upper = self.layout.viewOffset(forDisplayed: part.upperBound)
            let text = TextStyler.marked(
                base, layout: layout, marks: marks, selectedMarkID: selectedMarkID, displayed: part.lowerBound..<part.upperBound
            )
            return Edit(range: NSRange(location: lower, length: upper - lower), text: text)
        }
        self.layout = layout
        footprints = new
        return edits
    }

    private static func footprints(of marks: [Mark], selectedMarkID: UUID?) -> [Footprint] {
        marks.map { mark in
            let ghost = mark.kind == .replace || mark.kind == .insert ? mark.text : nil
            return Footprint(id: mark.id, kind: mark.kind, span: mark.anchor.span, text: ghost, selected: mark.id == selectedMarkID)
        }
    }

    /// Text shown as removed since the previous version.
    private static func removals(in layout: DisplayLayout) -> [DisplayLayout.Ghost] {
        layout.ghosts.filter { $0.markID == nil }.map { ghost in
            var shown = ghost
            // Where it is in the view moves with the marks before it; where it sits does not.
            shown.range = 0..<0
            return shown
        }
    }
}
