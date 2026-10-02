import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Apply edits")
struct EditApplierTests {
    // MARK: Basics

    @Test func noMarksLeavesTextUnchanged() throws {
        #expect(try EditApplier.apply([], to: "Hello world") == "Hello world")
    }

    @Test func replaceSwapsTheQuotedText() throws {
        let source = "An engineer with a proven track record of delivery."
        let marks = [mark(.replace, "with a proven track record", in: source, text: "who ships reliable systems")]
        #expect(try EditApplier.apply(marks, to: source) == "An engineer who ships reliable systems of delivery.")
    }

    @Test func insertAddsTextAtTheCaret() throws {
        let source = "Worked at CERN."
        let marks = [insert(" for five years", after: "CERN", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == "Worked at CERN for five years.")
    }

    @Test func commentsAndKeepsAreIgnored() throws {
        let source = "Keep this. Comment on that."
        let marks = [
            mark(.keep, "Keep this", in: source),
            mark(.comment, "Comment on that", in: source, note: "why?"),
        ]
        #expect(try EditApplier.apply(marks, to: source) == source)
    }

    @Test func pdfMarksAreIgnored() throws {
        let source = "Text on a page."
        let marks = [mark(.delete, "Text", in: source, page: 1)]
        #expect(try EditApplier.apply(marks, to: source) == source)
    }

    @Test func severalEditsApplyRegardlessOfMarkOrder() throws {
        let source = "one two three four"
        let marks = [
            mark(.replace, "four", in: source, text: "4"),
            mark(.replace, "one", in: source, text: "1"),
            insert(" and a half", after: "two", in: source),
        ]
        #expect(try EditApplier.apply(marks, to: source) == "1 two and a half three 4")
    }

    // MARK: Repeated phrases

    @Test func repeatedPhraseIsEditedAtTheMarkedOccurrence() throws {
        let source = "the cat and the dog and the bird"
        let second = [mark(.replace, "the", in: source, occurrence: 2, text: "a")]
        #expect(try EditApplier.apply(second, to: source) == "the cat and a dog and the bird")

        let third = [mark(.delete, "and the", in: source, occurrence: 2)]
        #expect(try EditApplier.apply(third, to: source) == "the cat and the dog bird")
    }

    @Test func staleOffsetsFallBackToTheSurroundingText() throws {
        let original = "alpha beta\ngamma beta\n"
        var stale = mark(.replace, "beta", in: original, occurrence: 2, text: "delta")
        // The text gained a line at the top, so the recorded offsets now point elsewhere.
        let revised = "intro line\nalpha beta\ngamma beta\n"
        #expect(try EditApplier.apply([stale], to: revised) == "intro line\nalpha beta\ngamma delta\n")

        stale.anchor.quote = "no longer there"
        #expect(throws: EditError.anchorNotFound(stale.id)) {
            try EditApplier.apply([stale], to: revised)
        }
    }

    @Test func staleInsertFindsItsPlaceByContext() throws {
        let original = "First point.\nSecond point.\n"
        let stale = insert(" Really.", after: "Second point.", in: original)
        let revised = "A new opening.\n" + original
        #expect(try EditApplier.apply([stale], to: revised) == "A new opening.\nFirst point.\nSecond point. Really.\n")
    }

    // MARK: Overlaps and adjacency

    @Test func overlappingRangeEditsAreRejected() {
        let source = "one two three four"
        let first = mark(.delete, "two three", in: source)
        let second = mark(.replace, "three four", in: source, text: "x")
        #expect(throws: EditError.overlapping(first.id, second.id)) {
            try EditApplier.apply([first, second], to: source)
        }
    }

    @Test func identicalRangeEditsAreRejected() {
        let source = "one two three"
        let first = mark(.delete, "two", in: source)
        let second = mark(.replace, "two", in: source, text: "2")
        #expect(throws: EditError.overlapping(first.id, second.id)) {
            try EditApplier.apply([first, second], to: source)
        }
    }

    @Test func insertInsideADeletedRangeIsRejected() {
        let source = "one two three four"
        let deletion = mark(.delete, "two three", in: source)
        let insertion = insert("!", after: "two", in: source)
        #expect(throws: EditError.overlapping(deletion.id, insertion.id)) {
            try EditApplier.apply([deletion, insertion], to: source)
        }
    }

    @Test func adjacentEditsDoNotCollide() throws {
        let source = "abcdef"
        let marks = [
            mark(.replace, "ab", in: source, text: "X"),
            mark(.replace, "cd", in: source, text: "Y"),
            mark(.delete, "ef", in: source),
        ]
        #expect(try EditApplier.apply(marks, to: source) == "XY")
    }

    @Test func insertAtTheEdgesOfAReplacement() throws {
        let source = "say hello now"
        let replacement = mark(.replace, "hello", in: source, text: "goodbye")
        let before = insert("[", after: "say ", in: source)
        let after = insert("]", after: "hello", in: source)
        #expect(try EditApplier.apply([replacement, before, after], to: source) == "say [goodbye] now")
    }

    @Test func insertsAtOneOffsetKeepMarkOrder() throws {
        let source = "ab"
        let marks = [insert("1", after: "a", in: source), insert("2", after: "a", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == "a12b")
    }

    @Test func conflictReportsTheEditInTheWay() {
        let source = "one two three four"
        let existing = [mark(.delete, "two three", in: source), mark(.comment, "four", in: source)]

        #expect(EditApplier.conflict(of: mark(.replace, "three", in: source, text: "3"), with: existing)?.id == existing[0].id)
        #expect(EditApplier.conflict(of: mark(.delete, "four", in: source), with: existing) == nil)
        #expect(EditApplier.conflict(of: mark(.comment, "two", in: source), with: existing) == nil)
        #expect(EditApplier.conflict(of: insert("!", after: "three", in: source), with: existing) == nil)
    }

    // MARK: Tidying after a deletion

    @Test func deletingAWordKeepsOneSpace() throws {
        let source = "a very good idea"
        #expect(try EditApplier.apply([mark(.delete, "very", in: source)], to: source) == "a good idea")
        #expect(try EditApplier.apply([mark(.delete, "very", in: source)], to: source, tidy: false) == "a  good idea")
    }

    @Test func deletingBeforePunctuationDropsTheSpace() throws {
        let source = "This is good really."
        #expect(try EditApplier.apply([mark(.delete, "really", in: source)], to: source) == "This is good.")
    }

    @Test func deletingTheLastWordOfALineDropsTheSpace() throws {
        let source = "foo bar\nbaz"
        #expect(try EditApplier.apply([mark(.delete, "bar", in: source)], to: source) == "foo\nbaz")
    }

    @Test func hardLineBreakSurvivesADeletion() throws {
        let source = "foo bar  \nbaz"
        #expect(try EditApplier.apply([mark(.delete, "bar", in: source)], to: source) == "foo  \nbaz")
    }

    @Test func deletingTheFirstWordOfALineDropsTheSpace() throws {
        let source = "Passionate engineer"
        #expect(try EditApplier.apply([mark(.delete, "Passionate", in: source)], to: source) == "engineer")
    }

    @Test func tidyingDoesNotEatAnAdjacentInsertion() throws {
        let source = "a very good idea"
        let marks = [mark(.delete, "very", in: source), insert(" quite", after: "very", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == "a  quite good idea")
    }

    // MARK: Edits next to markdown syntax

    @Test func deletingAListItemRemovesItsLine() throws {
        let source = "- alpha\n- beta\n- gamma\n"
        #expect(try EditApplier.apply([mark(.delete, "beta", in: source)], to: source) == "- alpha\n- gamma\n")
        #expect(try EditApplier.apply([mark(.delete, "gamma", in: source)], to: source) == "- alpha\n- beta\n")
        #expect(try EditApplier.apply([mark(.delete, "alpha", in: source)], to: source) == "- beta\n- gamma\n")
    }

    @Test func deletingTheLastLineWithoutATrailingBreak() throws {
        let source = "- alpha\n- beta"
        #expect(try EditApplier.apply([mark(.delete, "beta", in: source)], to: source) == "- alpha")
    }

    @Test func deletingANumberedOrTaskItemRemovesItsLine() throws {
        let numbered = "1. first\n2. second\n3. third\n"
        #expect(try EditApplier.apply([mark(.delete, "second", in: numbered)], to: numbered) == "1. first\n3. third\n")

        let tasks = "- [ ] write tests\n- [x] ship it\n"
        #expect(try EditApplier.apply([mark(.delete, "ship it", in: tasks)], to: tasks) == "- [ ] write tests\n")
    }

    @Test func deletingAHeadingRemovesItsLine() throws {
        let source = "# Title\n\n## Section\n\nBody.\n"
        #expect(try EditApplier.apply([mark(.delete, "Section", in: source)], to: source) == "# Title\n\nBody.\n")
    }

    @Test func deletingAParagraphLeavesOneBlankLine() throws {
        let source = "First.\n\nSecond.\n\nThird.\n"
        #expect(try EditApplier.apply([mark(.delete, "Second.", in: source)], to: source) == "First.\n\nThird.\n")
    }

    @Test func deletingAQuotedLineKeepsTheQuote() throws {
        let source = "> one\n> two\n> three\n"
        #expect(try EditApplier.apply([mark(.delete, "two", in: source)], to: source) == "> one\n> three\n")
    }

    @Test func deletingPartOfAListItemKeepsTheItem() throws {
        let source = "- alpha beta\n- gamma\n"
        #expect(try EditApplier.apply([mark(.delete, "alpha", in: source)], to: source) == "- beta\n- gamma\n")
    }

    @Test func twoDeletionsThatEmptyALineRemoveIt() throws {
        let source = "- alpha beta\n- gamma\n"
        let marks = [mark(.delete, "alpha", in: source), mark(.delete, "beta", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == "- gamma\n")
    }

    @Test func deletingSeveralWholeLines() throws {
        let source = "keep\nfirst\nsecond\nkeep too\n"
        #expect(try EditApplier.apply([mark(.delete, "first\nsecond", in: source)], to: source) == "keep\nkeep too\n")
        #expect(try EditApplier.apply([mark(.delete, "first\nsecond\n", in: source)], to: source) == "keep\nkeep too\n")
    }

    @Test func editsInsideEmphasisKeepTheDelimiters() throws {
        let source = "This is **very important** text."
        #expect(
            try EditApplier.apply([mark(.replace, "very important", in: source, text: "critical")], to: source)
                == "This is **critical** text."
        )
        #expect(try EditApplier.apply([mark(.delete, "very", in: source)], to: source) == "This is **important** text.")
        #expect(
            try EditApplier.apply([mark(.delete, "**very important**", in: source)], to: source) == "This is text."
        )
    }

    @Test func editsInsideALinkKeepTheDestination() throws {
        let source = "See [the old docs](https://example.com/docs) for more."
        let marks = [mark(.replace, "the old docs", in: source, text: "the docs")]
        #expect(try EditApplier.apply(marks, to: source) == "See [the docs](https://example.com/docs) for more.")
    }

    @Test func tidyingLeavesAnEditedListMarkerAlone() throws {
        let source = "- alpha\n- beta\n"
        let marks = [mark(.replace, "-", in: source, occurrence: 2, text: "*"), mark(.delete, "beta", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == "- alpha\n* \n")
    }

    // MARK: Offsets

    @Test func offsetsCountUTF16UnitsAfterEmoji() throws {
        let source = "Ship it 🚀🚀 today, not tomorrow 👩‍💻."
        let marks = [
            mark(.replace, "today", in: source, text: "now"),
            mark(.delete, "🚀", in: source, occurrence: 2),
            insert("!", after: "👩‍💻", in: source),
        ]
        #expect(try EditApplier.apply(marks, to: source) == "Ship it 🚀 now, not tomorrow 👩‍💻!.")
    }

    @Test func windowsLineEndingsArePreserved() throws {
        let source = "- alpha\r\n- beta\r\n- gamma\r\n"
        #expect(try EditApplier.apply([mark(.delete, "beta", in: source)], to: source) == "- alpha\r\n- gamma\r\n")
        #expect(
            try EditApplier.apply([mark(.replace, "alpha", in: source, text: "a")], to: source)
                == "- a\r\n- beta\r\n- gamma\r\n"
        )
    }

    @Test func editsAtTheVeryStartAndEnd() throws {
        let source = "start middle end"
        let marks = [
            insert(">> ", after: "", in: source),
            mark(.delete, "start", in: source),
            mark(.replace, "end", in: source, text: "finish"),
            insert(" <<", after: "end", in: source),
        ]
        #expect(try EditApplier.apply(marks, to: source) == ">> middle finish <<")
    }
}
