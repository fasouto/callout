import Foundation
import Testing
@testable import CalloutCore

@Suite("Feedback formatter")
struct FeedbackFormatterTests {
    private func format(
        _ title: String, _ document: ReviewDocument, _ marks: [Mark], general: String = ""
    ) -> String {
        FeedbackFormatter.format(.init(title: title, document: document, marks: marks, generalComment: general))
    }

    @Test func pdfFeedbackMatchesTheDocumentedFormat() {
        let page1 = """
        Senior engineer with a proven track record in delivery.
        Passionate, results-driven builder.
        Built browser automation for insurance price comparison.
        """
        let page2 = "Worked at CERN on databases."
        let marks = [
            mark(.comment, "Worked at CERN", in: page2, page: 2,
                 note: "Mention the Oracle scale and the three-state availability model."),
            mark(.keep, "Built browser automation for insurance price comparison", in: page1, page: 1),
            mark(.delete, "Passionate, results-driven", in: page1, page: 1),
            mark(.replace, "with a proven track record", in: page1, page: 1,
                 text: "who ships reliable systems in production"),
        ]

        let expected = """
        ## Feedback on cv.pdf

        Apply these changes to the source this document was generated from, then regenerate it.

        ### 1. Replace (page 1)
        > with a proven track record
        With: who ships reliable systems in production

        ### 2. Delete (page 1)
        > Passionate, results-driven

        ### 3. Comment (page 2)
        > Worked at CERN
        Mention the Oracle scale and the three-state availability model.

        ### Keep as is
        > Built browser automation for insurance price comparison

        ### General
        Keep it to one page.

        """
        #expect(format("cv.pdf", .pdf(pages: [page1, page2]), marks, general: "Keep it to one page.") == expected)
    }

    @Test func textFeedbackHasNoPagesAndNoRegenerateLine() {
        let source = "Step one: rewrite everything.\nStep two: add a cache.\n"
        let marks = [
            mark(.delete, "rewrite everything", in: source, note: "too risky"),
            mark(.comment, "add a cache", in: source, note: "Which cache? Reuse the existing one."),
        ]
        let expected = """
        ## Feedback on Plan

        ### 1. Delete
        > rewrite everything
        Reason: too risky

        ### 2. Comment
        > add a cache
        Which cache? Reuse the existing one.

        """
        #expect(format("Plan", .text(source), marks) == expected)
    }

    @Test func marksAreNumberedInDocumentOrder() {
        let source = "alpha beta gamma"
        let marks = [
            mark(.delete, "gamma", in: source),
            mark(.delete, "alpha", in: source),
            mark(.delete, "beta", in: source),
        ]
        let output = format("", .text(source), marks)
        #expect(output.hasPrefix("## Feedback\n\n### 1. Delete\n> alpha\n\n### 2. Delete\n> beta\n\n### 3. Delete\n> gamma\n"))
    }

    @Test func repeatedPhraseSaysWhichOccurrence() {
        let source = "the cat and the dog and the bird"
        let marks = [mark(.comment, "the", in: source, occurrence: 2, note: "which animal?")]
        let expected = """
        ## Feedback on notes

        ### 1. Comment
        > the
        Which one: occurrence 2 of 3 in the document, right after "the cat and"
        which animal?

        """
        #expect(format("notes", .text(source), marks) == expected)
    }

    @Test func uniquePhraseHasNoOccurrenceLine() {
        let source = "the cat and the dog"
        let output = format("notes", .text(source), [mark(.delete, "cat", in: source)])
        #expect(!output.contains("Which one"))
    }

    @Test func repeatedPhraseOnAPDFPageIgnoresLineBreaks() {
        // The page text wraps inside the phrase; the selection was captured on one line.
        let page = "We deliver value fast.\nAgain: we deliver\nvalue every week."
        var second = mark(.delete, "deliver\nvalue", in: page, page: 1)
        second.anchor.quote = "deliver value"

        let output = format("deck.pdf", .pdf(pages: [page]), [second])
        #expect(output.contains("> deliver value\nWhich one: occurrence 2 of 2 on this page, right after \"…"))
    }

    @Test func samePhraseOnDifferentPagesIsNotAmbiguous() {
        let pages = ["Revenue grew.", "Revenue fell."]
        let output = format("deck.pdf", .pdf(pages: pages), [mark(.delete, "Revenue", in: pages[1], page: 2)])
        #expect(output.contains("### 1. Delete (page 2)\n> Revenue\n"))
        #expect(!output.contains("Which one"))
    }

    @Test func insertQuotesTheTextItGoesAfter() {
        let source = "Worked at CERN.\nBuilt things.\n"
        let marks = [insert(" for five years", after: "CERN", in: source)]
        let expected = """
        ## Feedback on cv

        ### 1. Insert after
        > Worked at CERN
        Add: for five years

        """
        #expect(format("cv", .text(source), marks) == expected)
    }

    @Test func insertAtALineStartQuotesTheTextItGoesBefore() {
        let source = "Worked at CERN.\nBuilt things.\n"
        let marks = [insert("Also: ", after: "CERN.\n", in: source)]
        let output = format("cv", .text(source), marks)
        #expect(output.contains("### 1. Insert before\n> Built things.\nAdd: Also:\n"))
    }

    @Test func insertOnAPDFPageCarriesThePage() {
        let page = "Worked at CERN\non databases."
        let output = format("cv.pdf", .pdf(pages: ["First page.", page]), [insert(" (2019–2024)", after: "CERN", in: page, page: 2)])
        #expect(output.contains("### 1. Insert after (page 2)\n> Worked at CERN\nAdd: (2019–2024)\n"))
    }

    @Test func insertIntoAnEmptyDocumentHasNoContext() {
        let output = format("", .text(""), [insert("Hello", after: "", in: "")])
        #expect(output == "## Feedback\n\n### 1. Insert\nAdd: Hello\n")
    }

    @Test func aCommentAtAPointQuotesTheTextItFollows() {
        let source = "Worked at CERN.\nBuilt things.\n"
        let marks = [Mark(kind: .comment, anchor: point(after: "CERN", in: source), note: "Why leave?")]
        let expected = """
        ## Feedback on cv

        ### 1. Comment after
        > Worked at CERN
        Why leave?

        """
        #expect(format("cv", .text(source), marks) == expected)
    }

    @Test func aCommentAtALineStartQuotesTheTextItGoesBefore() {
        let source = "Worked at CERN.\nBuilt things.\n"
        let marks = [Mark(kind: .comment, anchor: point(after: "CERN.\n", in: source), note: "Which things?")]
        #expect(format("cv", .text(source), marks).contains("### 1. Comment before\n> Built things.\nWhich things?\n"))
    }

    @Test func commentsAtOnePointAreSeparateItems() {
        let source = "Worked at CERN.\nBuilt things.\n"
        let marks = [
            Mark(kind: .comment, anchor: point(after: "CERN", in: source), note: "Why leave?"),
            Mark(kind: .comment, anchor: point(after: "CERN", in: source), note: "Which years?"),
        ]
        let output = format("cv", .text(source), marks)
        #expect(output.contains("### 1. Comment after\n> Worked at CERN\nWhy leave?\n\n### 2. Comment after\n> Worked at CERN\nWhich years?\n"))
    }

    @Test func aCommentInAnEmptyDocumentHasNoBareQuote() {
        let marks = [Mark(kind: .comment, anchor: point(after: "", in: ""), note: "Say something.")]
        #expect(format("", .text(""), marks) == "## Feedback\n\n### 1. Comment\nSay something.\n")
    }

    @Test func aCommentOnAPDFPageStillQuotesItsWords() {
        let page = "Worked at CERN on databases."
        let output = format("cv.pdf", .pdf(pages: ["First.", page]), [mark(.comment, "on databases", in: page, page: 2, note: "Which ones?")])
        #expect(output.contains("### 1. Comment (page 2)\n> on databases\nWhich ones?\n"))
    }

    @Test func longInsertContextIsCutAtAWord() {
        let source = String(repeating: "word ", count: 40) + "end"
        let output = format("", .text(source), [insert("!", after: "end", in: source)])
        let quote = output.split(separator: "\n").first { $0.hasPrefix("> ") }!
        #expect(quote.hasPrefix("> …word "))
        #expect(quote.hasSuffix(" word end"))
        #expect(quote.count < 90)
    }

    @Test func multiLineQuotesAndReplacementsStayReadable() {
        let source = "First line\nsecond line\n\nfourth line\n"
        let marks = [mark(.replace, "First line\nsecond line\n\nfourth line", in: source, text: "One\nTwo")]
        let expected = """
        ## Feedback

        ### 1. Replace
        > First line
        > second line
        >
        > fourth line
        With:
        One
        Two

        """
        #expect(format("", .text(source), marks) == expected)
    }

    @Test func quotesAreTrimmedForDisplay() {
        let source = "Keep.  Drop this. \nNext.\n"
        let output = format("", .text(source), [mark(.delete, "  Drop this. \n", in: source)])
        #expect(output.contains("### 1. Delete\n> Drop this.\n"))
    }

    @Test func veryLongQuotesAreShortenedInTheMiddle() {
        let source = "START " + String(repeating: "filler ", count: 200) + "END"
        let output = format("", .text(source), [mark(.delete, source, in: source)])
        #expect(output.contains("> START filler"))
        #expect(output.contains("\n> […]\n"))
        #expect(output.contains("filler END\n"))
        #expect(output.count < 700)
    }

    @Test func keepsAreGroupedAfterTheNumberedMarks() {
        let source = "Strong opening. Weak middle. Solid ending."
        let marks = [
            mark(.keep, "Solid ending", in: source),
            mark(.delete, "Weak middle", in: source),
            mark(.keep, "Strong opening", in: source),
        ]
        let expected = """
        ## Feedback on draft

        ### 1. Delete
        > Weak middle

        ### Keep as is
        > Strong opening

        > Solid ending

        """
        #expect(format("draft", .text(source), marks) == expected)
    }

    @Test func onlyKeepsOnAPDFDoNotAskToRegenerate() {
        let page = "A strong opening line."
        let output = format("cv.pdf", .pdf(pages: [page]), [mark(.keep, "A strong opening line.", in: page, page: 1)])
        #expect(output == "## Feedback on cv.pdf\n\n### Keep as is\n> A strong opening line.\n")
    }

    @Test func generalCommentAlone() {
        #expect(format("Plan", .text("anything"), [], general: "  Too complex, simplify.\n") ==
            "## Feedback on Plan\n\n### General\nToo complex, simplify.\n")
    }

    @Test func nothingToSay() {
        #expect(format("Plan", .text("anything"), []) == "## Feedback on Plan\n\nNo changes requested.\n")
    }

    @Test func expandAndSummarizeAreInstructionsOnAPassage() {
        let source = "We add a cache. The rollout has four phases, each gated on error rates, with a rollback after any phase."
        let marks = [
            mark(.summarize, "The rollout has four phases, each gated on error rates, with a rollback after any phase.", in: source),
            mark(.expand, "We add a cache", in: source, note: "Which cache, and where does it sit?"),
        ]
        let expected = """
        ## Feedback on Plan

        ### 1. Expand
        > We add a cache
        Which cache, and where does it sit?

        ### 2. Summarize
        > The rollout has four phases, each gated on error rates, with a rollback after any phase.

        """
        #expect(format("Plan", .text(source), marks) == expected)
    }

    @Test func instructionsLeaveTheTextAlone() throws {
        let source = "Short text to expand."
        let marks = [mark(.expand, "Short text", in: source), mark(.summarize, "to expand", in: source)]
        #expect(try EditApplier.apply(marks, to: source) == source)
        // They are not edits, so they can sit on top of one.
        #expect(EditApplier.conflict(of: marks[0], with: [mark(.delete, "Short text", in: source)]) == nil)
    }

    @Test func instructionsOnAPDFCarryThePage() {
        let page = "Worked at CERN on databases."
        let output = format("cv.pdf", .pdf(pages: ["First.", page]), [mark(.expand, "Worked at CERN", in: page, page: 2)])
        #expect(output.contains("### 1. Expand (page 2)\n> Worked at CERN\n"))
        #expect(output.contains("Apply these changes to the source"))
    }

    @Test func replaceCanCarryAReason() {
        let source = "We leverage synergies."
        let marks = [mark(.replace, "leverage synergies", in: source, text: "work together", note: "plain words")]
        #expect(format("", .text(source), marks).contains("> leverage synergies\nWith: work together\nReason: plain words\n"))
    }
}
