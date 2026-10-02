import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Display layout")
struct DisplayLayoutTests {
    private let source = "Use **the old** cache here.\n"

    private func layout(_ marks: [Mark]) -> DisplayLayout {
        DisplayLayout(document: MarkdownRenderer.render(source), marks: marks)
    }

    @Test func withoutGhostsTheViewIsTheDocument() {
        let layout = layout([mark(.delete, "cache", in: source), mark(.comment, "here", in: source, note: "why")])
        #expect(layout.ghosts.isEmpty)
        #expect(layout.text == "Use the old cache here.")
        #expect(layout.displayedOffset(forView: 7) == 7)
        #expect(layout.viewRanges(forDisplayed: 4..<11) == [4..<11])
    }

    @Test func replacementTextFollowsWhatItReplaces() {
        let layout = layout([mark(.replace, "**the old**", in: source, text: "a new")])
        #expect(layout.text == "Use the olda new cache here.")
        #expect(layout.ghosts.map(\.range) == [11..<16])

        // The replaced text keeps its place; the text after the ghost shifts.
        #expect(layout.viewRanges(forSource: span(of: "**the old**", in: source)) == [4..<11])
        #expect(layout.viewRanges(forSource: span(of: "cache", in: source)) == [17..<22])
    }

    @Test func insertedTextSitsAtItsCaret() {
        let layout = layout([insert(" shared", after: "**the old**", in: source)])
        #expect(layout.text == "Use the old shared cache here.")
        #expect(layout.viewRanges(forSource: span(of: "cache", in: source)) == [19..<24])
    }

    @Test func viewOffsetsMapBackPastGhosts() {
        let layout = layout([
            mark(.replace, "Use", in: source, text: "Reuse"),
            insert(" shared", after: "**the old**", in: source),
        ])
        #expect(layout.text == "UseReuse the old shared cache here.")

        #expect(layout.displayedOffset(forView: 2) == 2)
        // Inside and at the end of the first ghost: the place the ghost sits at.
        #expect(layout.displayedOffset(forView: 5) == 3)
        #expect(layout.displayedOffset(forView: 8) == 3)
        #expect(layout.displayedOffset(forView: 9) == 4)
        // After both ghosts.
        let cache = span(of: "cache", in: layout.text)
        #expect(layout.displayedRange(forView: cache.start..<cache.end) == 12..<17)
    }

    @Test func aSelectionInsideAGhostCoversNoDocumentText() {
        let layout = layout([mark(.replace, "Use", in: source, text: "Reuse")])
        #expect(layout.displayedRange(forView: 4..<7).isEmpty)
        // A selection running from a ghost into real text keeps the real part.
        #expect(layout.displayedRange(forView: 5..<12) == 3..<7)
    }

    @Test func aRangeAroundAGhostIsSplit() {
        // A comment over text that also contains an insertion.
        let layout = layout([
            mark(.comment, "**the old** cache", in: source, note: "hm"),
            insert(" shared", after: "**the old**", in: source),
        ])
        #expect(layout.viewRanges(forSource: span(of: "**the old** cache", in: source)) == [4..<11, 18..<24])
    }

    @Test func ghostsAtOneCaretKeepMarkOrder() {
        let layout = layout([
            insert("[1]", after: "Use", in: source),
            insert("[2]", after: "Use", in: source),
        ])
        #expect(layout.text == "Use[1][2] the old cache here.")
        #expect(layout.viewOffset(forDisplayed: 3) == 9)
        #expect(layout.viewOffset(forDisplayed: 2) == 2)
    }

    // MARK: Text removed since the previous version

    @Test func removedWordsAreShownWhereTheyWere() {
        let old = "Use the old slow cache here.\n"
        let new = "Use the cache here.\n"
        let changes = PlanDiff.changes(from: old, to: new)
        let layout = DisplayLayout(document: MarkdownRenderer.render(new), marks: [], removals: changes.removed)
        #expect(layout.text == "Use the old slow cache here.")
        #expect(layout.ghosts.count == 1)
        #expect(layout.ghosts[0].markID == nil)
        // The ghost is not document text: a selection inside it maps to nothing.
        let ghost = layout.ghosts[0].range
        #expect(layout.displayedRange(forView: ghost).isEmpty)
    }

    @Test func removedLinesGetTheirOwnLineWithoutTheirMarker() {
        let old = "# Plan\n\n1. Add a cache\n2. Use Redis\n3. Tests\n\n## Notes\n"
        let new = "# Plan\n\n1. Add a cache\n3. Tests\n"
        let changes = PlanDiff.changes(from: old, to: new)
        let layout = DisplayLayout(document: MarkdownRenderer.render(new), marks: [], removals: changes.removed)
        // The removed item sits before the line that now follows it; the removed
        // heading, which had nothing after it, goes at the end. (Markdown numbers
        // a list from its first item, so the source's "3." is shown as "2.".)
        #expect(layout.text == "Plan\n1. Add a cache\nUse Redis\n2. Tests\nNotes")
    }

    @Test func removalsAndMarkGhostsShareTheLayout() {
        let old = "Use the old cache here.\n"
        let new = "Use the cache here.\n"
        let changes = PlanDiff.changes(from: old, to: new)
        let marks = [mark(.replace, "cache", in: new, text: "store")]
        let layout = DisplayLayout(document: MarkdownRenderer.render(new), marks: marks, removals: changes.removed)
        #expect(layout.text == "Use the old cachestore here.")
        #expect(layout.ghosts.map(\.markID) == [nil, marks[0].id])
        #expect(layout.viewRanges(forSource: span(of: "cache", in: new)) == [12..<17])
    }

    @Test func blockMarkersAreStrippedFromRemovedLines() {
        #expect(DisplayLayout.withoutBlockMarker("- [ ] write tests") == "write tests")
        #expect(DisplayLayout.withoutBlockMarker("  12. step twelve") == "step twelve")
        #expect(DisplayLayout.withoutBlockMarker("## A heading") == "A heading")
        #expect(DisplayLayout.withoutBlockMarker("> > quoted") == "quoted")
        #expect(DisplayLayout.withoutBlockMarker("plain text") == "plain text")
    }

    @Test func marksWithoutTextAddNoGhost() {
        let layout = layout([mark(.replace, "cache", in: source, text: ""), insert("", after: "Use", in: source)])
        #expect(layout.ghosts.isEmpty)
    }
}
