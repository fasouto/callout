import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// Typing and deleting straight in the document. Everything typed is tracked as
/// marks: the document's own text never changes.
@MainActor
@Suite("Typing in the document")
struct TypingTests {
    private static let source = "We will leverage a very robust approach here.\n\n- first item\n- second item\n"

    @MainActor private struct Harness {
        let session: ReviewSession
        let window: NSWindow
        let textView: AnnotationTextView
        var text: NSString { textView.string as NSString }
    }

    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let request = ReviewRequest(
            content: .text(Self.source, format: .markdown), origin: .hotkey,
            metadata: ReviewMetadata(title: "Selection"), reply: .clipboard, modes: [.feedback, .applyEdits]
        )
        let session = ReviewSession(request: request)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        func find(_ view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let match = view as? AnnotationTextView { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        let textView = try #require(find(window.contentView))
        textView.usesVimKeys = false
        return Harness(session: session, window: window, textView: textView)
    }

    private func caret(after phrase: String, in harness: Harness) {
        harness.textView.setSelectedRange(NSRange(location: NSMaxRange(harness.text.range(of: phrase)), length: 0))
    }

    private func type(_ text: String, in harness: Harness) {
        harness.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func key(_ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], in harness: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: harness.window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        harness.textView.keyDown(with: event)
    }

    private func backspace(_ times: Int = 1, in harness: Harness) throws {
        for _ in 0..<times { try key(KeyCode.delete, "\u{7F}", in: harness) }
    }

    private func addWords(in harness: Harness) throws {
        try key(34, "i", flags: .option, in: harness)
    }

    @Test func wordsAddedWithOptionIGoInWhereTheCaretIs() throws {
        let harness = try makeHarness()
        caret(after: "robust", in: harness)
        try addWords(in: harness)
        type(" and simple", in: harness)

        #expect(harness.session.marks.map(\.kind) == [.insert])
        #expect(harness.textView.string.hasPrefix("We will leverage a very robust and simple approach here."))
        #expect(try harness.session.editedText().hasPrefix("We will leverage a very robust and simple approach here."))
        // The document itself is untouched; the words are a mark.
        #expect(harness.session.source == Self.source)
        #expect(harness.session.feedback().contains("### 1. Insert after\n> We will leverage a very robust\nAdd: and simple\n"))
    }

    @Test func typingContinuesTheSameInsertionAndCanGoBackIntoIt() throws {
        let harness = try makeHarness()
        caret(after: "robust", in: harness)
        try addWords(in: harness)
        type(" and", in: harness)
        type(" simple", in: harness)
        #expect(harness.session.marks.count == 1)

        // Move the caret back into the typed words and add one in the middle.
        caret(after: "robust and", in: harness)
        type(" very", in: harness)
        #expect(harness.session.marks.count == 1)
        #expect(harness.session.marks.first?.text == " and very simple")
        // The caret stays where the typing is, not at the end of the words.
        #expect(harness.textView.selectedRange().location == NSMaxRange(harness.text.range(of: "robust and very")))
    }

    @Test func backspaceOverAddedWordsDeletesThem() throws {
        let harness = try makeHarness()
        caret(after: "robust", in: harness)
        try addWords(in: harness)
        type(" annd", in: harness)
        try backspace(2, in: harness)
        type("d", in: harness)
        #expect(harness.session.marks.first?.text == " and")

        try backspace(4, in: harness)
        // Nothing left of it: the insertion is gone, not left empty.
        #expect(harness.session.marks.isEmpty)
        #expect(harness.textView.string == harness.session.document.text)
    }

    @Test func backspaceOverTheDocumentStrikesItOut() throws {
        let harness = try makeHarness()
        caret(after: "very ", in: harness)
        try backspace(5, in: harness)

        // One growing strike, not five marks.
        #expect(harness.session.marks.map(\.kind) == [.delete])
        #expect(harness.session.marks.first?.anchor.quote == "very ")
        #expect(harness.textView.string == harness.session.document.text)
        #expect(harness.textView.selectedRange().location == harness.text.range(of: "very ").location)
        #expect(try harness.session.editedText().hasPrefix("We will leverage a robust approach here."))
    }

    @Test func forwardDeleteStrikesTheOtherWay() throws {
        let harness = try makeHarness()
        harness.textView.setSelectedRange(NSRange(location: harness.text.range(of: "very ").location, length: 0))
        for _ in 0..<5 { try key(KeyCode.forwardDelete, "\u{F728}", in: harness) }
        #expect(harness.session.marks.map(\.kind) == [.delete])
        #expect(harness.session.marks.first?.anchor.quote == "very ")
        #expect(harness.textView.selectedRange().location == NSMaxRange(harness.text.range(of: "very ")))
    }

    @Test func strikingThenAddingWordsReadsAsAReplacementInTheResult() throws {
        let harness = try makeHarness()
        caret(after: "leverage", in: harness)
        try backspace(8, in: harness)
        try addWords(in: harness)
        type("use", in: harness)
        #expect(try harness.session.editedText().hasPrefix("We will use a very robust approach here."))
        #expect(harness.session.marks.count == 2)
    }

    @Test func backspaceStepsOverWhatIsAlreadyStruckAndOverBullets() throws {
        let harness = try makeHarness()
        let session = harness.session
        session.addMark(.delete, span: TextSpan(19, 31))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        caret(after: "very robust ", in: harness)
        try backspace(3, in: harness)
        // The caret walked back through the struck words; nothing new was struck.
        #expect(session.marks.count == 1)
        #expect(harness.textView.selectedRange().location == NSMaxRange(harness.text.range(of: "very robust ")) - 3)

        // A bullet is not text of the document: backspace passes over it.
        harness.textView.setSelectedRange(NSRange(location: harness.text.range(of: "first item").location, length: 0))
        try backspace(2, in: harness)
        #expect(session.marks.count == 1)
    }

    @Test func wordsCannotBeAddedInTheMiddleOfAStrike() throws {
        let harness = try makeHarness()
        let session = harness.session
        session.addMark(.delete, span: TextSpan(19, 31))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        caret(after: "very ro", in: harness)
        try addWords(in: harness)
        type("x", in: harness)
        #expect(session.marks.count == 1)
        #expect(session.statusMessage != nil)
    }

    @Test func aCommentCanBePinnedInsideAStrike() throws {
        let harness = try makeHarness()
        let session = harness.session
        session.addMark(.delete, span: TextSpan(19, 31))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        caret(after: "very ro", in: harness)
        type("x", in: harness)
        #expect(session.marks.map(\.kind) == [.delete, .comment])
        #expect(session.marks.last?.anchor.span == TextSpan(26, 26))
        #expect(session.marks.last?.note == "x")
    }

    @Test func addedWordsTakeAccentsAndEmojiWhole() throws {
        let harness = try makeHarness()
        caret(after: "here", in: harness)
        try addWords(in: harness)
        type(" mañana 🚀", in: harness)
        #expect(harness.session.marks.first?.text == " mañana 🚀")
        try backspace(1, in: harness)
        // One backspace takes the whole emoji, not half of it.
        #expect(harness.session.marks.first?.text == " mañana ")
        #expect(try harness.session.editedText().hasPrefix("We will leverage a very robust approach here mañana ."))
    }

    @Test func optionReturnAddsALineBreakWhileAddingWords() throws {
        let harness = try makeHarness()
        caret(after: "here.", in: harness)
        try addWords(in: harness)
        try key(KeyCode.return, "\r", flags: .option, in: harness)
        type("One more line.", in: harness)
        #expect(harness.session.marks.first?.text == "\nOne more line.")
        #expect(try harness.session.editedText().hasPrefix("We will leverage a very robust approach here.\nOne more line.\n"))
    }

    @Test func withASelectionTypingCommentsAndOptionLettersMark() throws {
        let harness = try makeHarness()
        harness.textView.setSelectedRange(harness.text.range(of: "very robust "))
        // Typing does not replace the selection: it comments on it.
        try key(0, "a", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.comment])
        #expect(harness.session.marks.first?.note == "a")
        #expect(harness.textView.string == harness.session.document.text)
        harness.session.endEditing()

        harness.textView.setSelectedRange(harness.text.range(of: "approach"))
        try key(2, "d", flags: .option, in: harness)
        #expect(harness.session.marks.map(\.kind) == [.comment, .delete])
    }

    @Test func theMarginFieldShowsWhatWasTypedInTheDocument() throws {
        let harness = try makeHarness()
        harness.textView.setSelectedRange(harness.text.range(of: "leverage"))
        try key(15, "r", flags: .option, in: harness)
        type("use", in: harness)
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func fields(in view: NSView?) -> [NoteTextField] {
            guard let view else { return [] }
            return ((view as? NoteTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        let field = try #require(fields(in: harness.window.contentView).first { $0.accessibilityLabel() == "Replace with" })
        #expect(field.stringValue == "use")
    }
}
