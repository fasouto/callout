import AnnotatorCore
import AppKit
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Typography")
struct TypographyTests {
    private func shown(_ markdown: String) -> String {
        let session = ReviewSession(request: ReviewRequest(
            content: .text(markdown, format: .markdown), origin: .lastReply, reply: .clipboard, modes: [.feedback]
        ))
        return TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string
    }

    @Test func quotesAndDashesAreSetAsInPrint() {
        #expect(shown("We don't say \"never\" - we say 'rarely'.") == "We don\u{2019}t say \u{201C}never\u{201D} \u{2013} we say \u{2018}rarely\u{2019}.")
        // A hyphen inside a word stays a hyphen.
        #expect(shown("A well-known plan.") == "A well-known plan.")
    }

    @Test func codeKeepsItsStraightQuotes() {
        #expect(shown("Run `echo \"hi\"` - it's quick.").contains("echo \"hi\""))
        #expect(shown("Run `echo \"hi\"` - it's quick.").contains("it\u{2019}s"))
        #expect(shown("```\nlet name = \"Ada\"\n```").contains("\"Ada\""))
    }

    @Test func aWordSelectedOnThePageIsMarkedAlone() throws {
        // A paragraph with apostrophes once mapped only as a whole, so marking
        // one word marked all of it.
        let source = "What's actually slow is this conversation. It's very long by now, and that's fine."
        let session = ReviewSession(request: ReviewRequest(
            content: .text(source, format: .markdown), origin: .lastReply, reply: .clipboard, modes: [.feedback]
        ))
        session.announce = { _ in }
        let shown = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string as NSString
        for word in ["slow", "long", "fine"] {
            let range = shown.range(of: word)
            let span = try #require(session.sourceSpan(forView: range.location..<NSMaxRange(range)))
            let mark = try #require(session.addMark(.keep, span: span))
            #expect(mark.anchor.quote == word)
        }
        #expect(session.feedback().contains("> slow\n"))
    }

    @Test func thePageCountsAsTheSourceDoes() throws {
        let source = "We don't \"leverage\" things."
        let session = ReviewSession(request: ReviewRequest(
            content: .text(source, format: .markdown), origin: .lastReply, reply: .clipboard, modes: [.feedback, .applyEdits]
        ))
        session.announce = { _ in }
        let shownText = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string
        #expect((shownText as NSString).length == (session.document.text as NSString).length)

        // A mark on the curly-quoted word still quotes and edits the source as written.
        let range = (source as NSString).range(of: "\"leverage\"")
        session.addMark(.replace, span: TextSpan(range.location, NSMaxRange(range)), text: "use")
        #expect(session.feedback().contains("> \"leverage\""))
        #expect(try session.editedText() == "We don't use things.")
    }
}
