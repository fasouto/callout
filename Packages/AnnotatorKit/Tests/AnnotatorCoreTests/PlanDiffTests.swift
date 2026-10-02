import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Plan diff")
struct PlanDiffTests {
    private func added(_ changes: PlanChanges, in new: String) -> [String] {
        changes.added.compactMap { new.slice($0) }
    }

    @Test func identicalVersionsHaveNoChanges() {
        let text = "# Plan\n\n1. One\n2. Two\n"
        #expect(PlanDiff.changes(from: text, to: text).isEmpty)
    }

    @Test func aNewLineIsAnAddition() {
        let old = "# Plan\n\n1. Add a cache\n"
        let new = "# Plan\n\n1. Add a cache\n2. Invalidate it on writes\n"
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == ["2. Invalidate it on writes"])
        #expect(changes.removed.isEmpty)
    }

    @Test func aDroppedLineIsARemovalWhereItUsedToBe() {
        let old = "# Plan\n\n1. Add a cache\n2. Use Redis\n3. Tests\n"
        let new = "# Plan\n\n1. Add a cache\n3. Tests\n"
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(changes.added.isEmpty)
        #expect(changes.removed == [.init(offset: span(of: "3. Tests", in: new).start, text: "2. Use Redis", isWholeLine: true)])
    }

    @Test func aRewordedLineShowsTheWordsThatChanged() {
        let old = "We will leverage a very robust approach here."
        let new = "We will use a simple approach here."
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == ["use", "simple"])
        #expect(changes.removed.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["leverage", "very robust"])
        #expect(changes.removed.allSatisfy { !$0.isWholeLine })
        // Each removal sits where its replacement now is.
        #expect(changes.removed.map(\.offset) == [span(of: "use", in: new).start, span(of: "simple", in: new).start])
    }

    @Test func wordsRemovedWithoutReplacementSitAtTheGap() {
        let old = "Return 429 with a Retry-After header and a body."
        let new = "Return 429 with a Retry-After header."
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(changes.added.isEmpty)
        #expect(changes.removed.count == 1)
        #expect(changes.removed[0].text == " and a body")
        #expect(changes.removed[0].offset == span(of: "header", in: new).end)
    }

    @Test func wordsAddedInsideALine() {
        let old = "Add a rate limiter."
        let new = "Add a token-bucket rate limiter per API key."
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == ["token-bucket", "per API key"])
        #expect(changes.removed.isEmpty)
    }

    @Test func aCompletelyDifferentLineIsRemovedAndAddedWhole() {
        let old = "# Plan\n\nUse Redis for everything.\n"
        let new = "# Plan\n\nKeep state in Postgres instead.\n"
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == ["Keep state in Postgres instead."])
        #expect(changes.removed == [.init(offset: span(of: "Keep", in: new).start, text: "Use Redis for everything.", isWholeLine: true)])
    }

    @Test func linesRemovedAtTheEndSitAtTheEnd() {
        let old = "One\nTwo\nThree"
        let new = "One"
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(changes.removed.map(\.text) == ["Two", "Three"])
        #expect(changes.removed.allSatisfy { $0.offset == new.utf16.count && $0.isWholeLine })
    }

    @Test func blankLinesAreNotChanges() {
        let old = "One\nTwo\n"
        let new = "One\n\n\nTwo\n"
        #expect(PlanDiff.changes(from: old, to: new).isEmpty)
        #expect(PlanDiff.changes(from: new, to: old).isEmpty)
    }

    @Test func offsetsAreUTF16AfterEmoji() {
        let old = "🚀 Ship the first version\nDone"
        let new = "🚀 Ship the second version\nDone"
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == ["second"])
        #expect(changes.removed.map(\.text) == ["first"])
    }

    @Test func aRevisedPlan() {
        let old = """
        # Plan: add rate limiting

        1. Add a RateLimiter middleware
        2. Return 429 with a Retry-After header
        3. Use Redis to share the buckets
        """
        let new = """
        # Plan: add rate limiting

        1. Add a RateLimiter middleware, with a token bucket per API key
        2. Return 429 with a Retry-After header
        3. Tests for the bucket
        """
        let changes = PlanDiff.changes(from: old, to: new)
        #expect(added(changes, in: new) == [", with a token bucket per API key", "3. Tests for the bucket"])
        #expect(new.slice(changes.added[0]) == ", with a token bucket per API key")
        #expect(changes.removed.map(\.text) == ["3. Use Redis to share the buckets"])
    }
}
