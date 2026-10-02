import Foundation
import Testing
@testable import AnnotatorCore

@Suite("Capture contract")
struct ContractTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func requestUsesTheDocumentedNames() throws {
        let request = ReviewRequest(
            content: .text("# Plan", format: .markdown),
            origin: .planHook,
            metadata: ReviewMetadata(projectPath: "/work/app", sessionId: "abc", title: "Plan"),
            reply: .hookDecision,
            modes: [.feedback, .approve]
        )
        let object = try json(request)

        #expect(object["origin"] as? String == "plan-hook")
        #expect(object["reply"] as? String == "hook-decision")
        #expect(object["modes"] as? [String] == ["feedback", "approve"])
        let content = try #require(object["content"] as? [String: Any])
        #expect(content["kind"] as? String == "text")
        #expect(content["text"] as? String == "# Plan")
        #expect(content["format"] as? String == "markdown")
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["sessionId"] as? String == "abc")
        #expect(metadata["sourceApp"] == nil)
    }

    @Test func requestRoundTrips() throws {
        let requests = [
            ReviewRequest(content: .text("hello", format: .plain), origin: .hotkey,
                          metadata: ReviewMetadata(sourceApp: "com.apple.Terminal", rawCapture: "│ hello │"),
                          reply: .clipboard, modes: [.feedback, .applyEdits]),
            ReviewRequest(content: .file(path: "/tmp/cv.pdf"), origin: .agentRequest,
                          reply: .stdout, modes: [.feedback]),
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ReviewRequest.self, from: data) == request)
        }
    }

    @Test func everyOriginHasItsDocumentedName() {
        #expect(ReviewOrigin.allCases.map(\.rawValue) ==
            ["plan-hook", "last-reply", "agent-request", "hotkey", "service", "file-drop", "share"])
        #expect(ReviewMode.allCases.map(\.rawValue) == ["feedback", "apply-edits", "approve"])
    }

    @Test func textContentDefaultsToMarkdown() throws {
        let data = Data(#"{"kind":"text","text":"hi"}"#.utf8)
        #expect(try JSONDecoder().decode(ReviewContent.self, from: data) == .text("hi", format: .markdown))
    }

    @Test func fileContentCarriesAPath() throws {
        let object = try json(ReviewContent.file(path: "/tmp/cv.pdf"))
        #expect(object["kind"] as? String == "file")
        #expect(object["path"] as? String == "/tmp/cv.pdf")
    }

    @Test func resultRoundTripsAndOmitsWhatIsMissing() throws {
        let id = UUID()
        let result = ReviewResult(id: id, decision: .feedback, feedback: "## Feedback\n")
        let object = try json(result)
        #expect(object["decision"] as? String == "feedback")
        #expect(object["editedText"] == nil)

        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(ReviewResult.self, from: data) == result)
    }

    @Test func markKindsKeepTheirNames() {
        // These names are stored in the history and travel over the socket.
        #expect(MarkKind.allCases.map(\.rawValue) == ["delete", "replace", "insert", "comment", "expand", "summarize", "keep"])
    }

    @Test func marksRoundTrip() throws {
        let source = "Some text to mark up."
        let marks = [
            mark(.replace, "text", in: source, text: "words", note: "clearer"),
            mark(.delete, "Some", in: source, page: 3),
            insert("!", after: "up", in: source),
        ]
        let data = try JSONEncoder().encode(marks)
        #expect(try JSONDecoder().decode([Mark].self, from: data) == marks)
    }
}

@Suite("Anchors")
struct AnchorTests {
    @Test func anchorCapturesQuoteAndSurroundings() throws {
        let source = "The quick brown fox jumps over the lazy dog."
        let anchor = try #require(Anchor.make(in: source, span: span(of: "fox", in: source)))
        #expect(anchor.quote == "fox")
        #expect(anchor.prefix == "The quick brown ")
        #expect(anchor.suffix == " jumps over the lazy dog.")
        #expect(anchor.page == nil)
    }

    @Test func contextIsLimitedInLength() throws {
        let source = String(repeating: "a", count: 100) + "TARGET" + String(repeating: "b", count: 100)
        let anchor = try #require(Anchor.make(in: source, span: span(of: "TARGET", in: source)))
        #expect(anchor.prefix == String(repeating: "a", count: Anchor.contextLength))
        #expect(anchor.suffix == String(repeating: "b", count: Anchor.contextLength))
    }

    @Test func contextNeverSplitsACharacter() throws {
        // Each rocket is two UTF-16 units, so a fixed-length cut can land inside one.
        let source = String(repeating: "🚀", count: 20) + "x" + "TARGET" + String(repeating: "🚀", count: 20)
        let anchor = try #require(Anchor.make(in: source, span: span(of: "TARGET", in: source)))
        #expect(anchor.prefix == String(repeating: "🚀", count: 15) + "x")
        #expect(anchor.suffix == String(repeating: "🚀", count: 16))
    }

    @Test func spansOutsideTheTextGiveNoAnchor() {
        #expect(Anchor.make(in: "short", span: TextSpan(2, 99)) == nil)
        // Offset 1 is in the middle of the emoji.
        #expect(Anchor.make(in: "🚀", span: TextSpan(1, 2)) == nil)
    }

    @Test func unchangedTextResolvesToTheRecordedSpan() throws {
        let source = "one two one two one"
        for occurrence in 1...3 {
            let recorded = span(of: "one", in: source, occurrence: occurrence)
            let anchor = try #require(Anchor.make(in: source, span: recorded))
            #expect(AnchorResolver.resolve(anchor, in: source) == recorded)
        }
    }

    @Test func revisedTextResolvesByContext() throws {
        let original = "Intro.\nUse the cache here.\nDrop the cache there.\n"
        let anchor = try #require(Anchor.make(in: original, span: span(of: "the cache", in: original, occurrence: 2)))

        let revised = "A much longer introduction than before.\nUse the cache here.\nNew line.\nDrop the cache there.\n"
        #expect(AnchorResolver.resolve(anchor, in: revised) == span(of: "the cache", in: revised, occurrence: 2))
    }

    @Test func missingQuoteDoesNotResolve() throws {
        let anchor = try #require(Anchor.make(in: "alpha beta", span: span(of: "beta", in: "alpha beta")))
        #expect(AnchorResolver.resolve(anchor, in: "alpha gamma") == nil)
    }

    @Test func insertWithoutContextOnlyResolvesInPlace() {
        let anchor = Anchor(span: TextSpan(0, 0), quote: "")
        #expect(AnchorResolver.resolve(anchor, in: "") == TextSpan(0, 0))
        #expect(AnchorResolver.resolve(Anchor(span: TextSpan(9, 9), quote: ""), in: "short") == nil)
    }
}
