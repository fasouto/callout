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

    /// The panels of a page: for each, the lines it has.
    private func panels(_ markdown: String) -> [[String]] {
        let session = ReviewSession(request: ReviewRequest(
            content: .text(markdown, format: .markdown), origin: .lastReply, reply: .clipboard, modes: [.feedback]
        ))
        let styled = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil)
        var panels: [[String]] = []
        styled.enumerateAttribute(.annotatorBlock, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            guard case .panel(let first, _, _)? = value as? BlockDecoration else { return }
            let line = (styled.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
            if first { panels.append([line]) } else { panels[panels.count - 1].append(line) }
        }
        return panels
    }

    @Test func codeInsideAListItemIsOnePanel() {
        // Its lines come one by one, each after the item's indentation.
        let nested = "1. Read first:\n   ```swift\n   let a = 1\n\n   let b = 2\n   ```\n2. Done."
        #expect(panels(nested) == [["let a = 1", "", "let b = 2"]])
        #expect(panels("> ```\n> one\n> two\n> ```") == [["one", "two"]])
        #expect(panels("```\none\ntwo\n```") == [["one", "two"]])
    }

    @Test func twoCodeBlocksInARowAreTwoPanels() {
        #expect(panels("- A:\n  ```\n  one\n  ```\n  ```\n  two\n  ```") == [["one"], ["two"]])
        #expect(panels("```\none\n```\n```\ntwo\n```") == [["one"], ["two"]])
    }

    @Test func aLineBrokenByHandStaysInItsParagraph() throws {
        // An address or a sign-off: lines, not paragraphs with space between them.
        let source = "Kind regards,  \nAda Lovelace\\\nLondon\n\nNext paragraph."
        #expect(shown(source) == "Kind regards,\u{2028}Ada Lovelace\u{2028}London\nNext paragraph.")

        // The words after the break are still themselves in the source.
        let session = ReviewSession(request: ReviewRequest(
            content: .text(source, format: .markdown), origin: .lastReply, reply: .clipboard, modes: [.feedback]
        ))
        session.announce = { _ in }
        let page = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string as NSString
        let range = page.range(of: "London")
        let span = try #require(session.sourceSpan(forView: range.location..<NSMaxRange(range)))
        #expect(session.addMark(.delete, span: span)?.anchor.quote == "London")
    }

    @Test func plainTextIsSetLineForLine() {
        func spacing(_ text: String, _ format: TextFormat) -> [CGFloat] {
            let session = ReviewSession(request: ReviewRequest(
                content: .text(text, format: format), origin: .fileDrop, reply: .clipboard, modes: [.feedback]
            ))
            let styled = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil)
            var found: [CGFloat] = []
            styled.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
                found.append((value as? NSParagraphStyle)?.paragraphSpacing ?? -1)
            }
            return found
        }
        // A commit message or a .txt file, wrapped by hand: its lines are not paragraphs.
        #expect(spacing("Fix the race\n\nThe store read the file\nbefore taking the lock.", .plain) == [0])
        // Markdown paragraphs keep the space between them.
        #expect(spacing("One.\n\nTwo.", .markdown).allSatisfy { $0 == 12 })
    }

    @Test func quotesAndDashesAreSetAsInPrint() {
        #expect(shown("We don't say \"never\" - we say 'rarely'.") == "We don\u{2019}t say \u{201C}never\u{201D} \u{2013} we say \u{2018}rarely\u{2019}.")
        // A hyphen inside a word stays a hyphen.
        #expect(shown("A well-known plan.") == "A well-known plan.")
    }

    @Test func aHyphenThatStartsALineOfPlainTextStaysAHyphen() {
        let session = ReviewSession(request: ReviewRequest(
            content: .text("Changes - all small:\n  - one thing\n- another", format: .plain), origin: .fileDrop, reply: .clipboard, modes: [.feedback]
        ))
        let page = TextStyler.attributedString(layout: session.layout, marks: [], selectedMarkID: nil).string
        #expect(page == "Changes \u{2013} all small:\n  - one thing\n- another")
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
