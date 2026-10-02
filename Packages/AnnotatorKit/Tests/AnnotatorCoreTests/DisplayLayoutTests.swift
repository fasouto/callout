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

    @Test func marksWithoutTextAddNoGhost() {
        let layout = layout([mark(.replace, "cache", in: source, text: ""), insert("", after: "Use", in: source)])
        #expect(layout.ghosts.isEmpty)
    }
}
