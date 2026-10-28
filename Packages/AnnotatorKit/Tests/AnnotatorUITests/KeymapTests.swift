import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Keys")
struct KeymapTests {
    @Test func everyMarkHasItsOwnKey() {
        let keys = MarkKind.allCases.map(\.key) + ["S", "O"]
        #expect(Set(keys).count == keys.count)
        #expect(Keymap.command(for: "d", modifiers: .option, vim: false) == .mark(.delete))
        #expect(Keymap.command(for: "X", modifiers: .option, vim: false) == .mark(.expand))
        #expect(Keymap.command(for: "m", modifiers: .option, vim: false) == .mark(.summarize))
        #expect(Keymap.command(for: "k", modifiers: .option, vim: false) == .mark(.keep))
        #expect(Keymap.command(for: "s", modifiers: .option, vim: false) == .snippets)
        #expect(Keymap.command(for: "o", modifiers: .option, vim: false) == .overall)
        #expect(Keymap.command(for: "q", modifiers: .option, vim: false) == nil)
        #expect(Keymap.command(for: "", modifiers: .option, vim: false) == nil)
        // A plain letter types: a comment, on a selection or at the caret.
        #expect(Keymap.command(for: "d", modifiers: [], vim: false) == nil)
        #expect(Keymap.command(for: "D", modifiers: .shift, vim: false) == nil)
        #expect(Keymap.command(for: "d", modifiers: .command, vim: false) == nil)
        #expect(MarkKind.delete.keyLabel(vim: false) == "⌥D")
    }

    @Test func everyMarkShowsItsKeyInsideItsName() throws {
        // The toolbar sets the key letter in bold within the word, so each
        // name has to contain its key.
        for kind in MarkKind.allCases {
            let parts = try #require(MarkWord.split(kind.label, key: kind.key), "\(kind.label) has no \(kind.key)")
            #expect(String(parts.before + parts.key + parts.after) == kind.label)
            #expect(parts.key.uppercased() == kind.key)
        }
        #expect(MarkWord.split("Expand", key: "X").map { String($0.before) } == "E")
        #expect(MarkWord.split("Summarize", key: "M").map { String($0.key) } == "m")
        #expect(MarkWord.split("Saved…", key: "S") != nil)
    }

    @Test func withVimKeysAPlainKMovesAndShiftKKeeps() {
        #expect(Keymap.command(for: "k", modifiers: [], vim: true) == nil)
        #expect(Keymap.command(for: "K", modifiers: [], vim: true) == .mark(.keep))
        #expect(Keymap.command(for: "d", modifiers: [], vim: true) == .mark(.delete))
        #expect(MarkKind.keep.keyLabel(vim: true) == "⇧K")
        #expect(MarkKind.keep.keyLabel(vim: false) == "⌥K")
        #expect(MarkKind.delete.keyLabel(vim: true) == "D")
        // ⌥ and the letter work with vim keys too.
        #expect(Keymap.command(for: "k", modifiers: .option, vim: true) == .mark(.keep))
    }

    @Test func typingGoesWhereTheMomentSays() {
        // A margin field on its way takes every key, whatever else holds.
        for vim in [false, true] {
            for selection in [false, true] {
                for adding in [false, true] {
                    for inside in [false, true] {
                        #expect(Keymap.typing(
                            fieldOnItsWay: true, vim: vim, hasSelection: selection, addingWords: adding, insideAddedWords: inside
                        ) == .field)
                    }
                }
            }
        }
        let rows: [(vim: Bool, selection: Bool, adding: Bool, inside: Bool, typing: Keymap.Typing)] = [
            // Without vim keys typing comments, on the selection or at the caret, except while
            // adding words and in the middle of words added before.
            (false, false, false, false, .comment),
            (false, false, false, true, .words),
            (false, false, true, false, .words),
            (false, false, true, true, .words),
            (false, true, false, false, .comment),
            (false, true, false, true, .comment),
            (false, true, true, false, .comment),
            (false, true, true, true, .comment),
            // With vim keys only insert mode types, and only at a caret.
            (true, false, false, false, .nowhere),
            (true, false, false, true, .nowhere),
            (true, false, true, false, .words),
            (true, false, true, true, .words),
            (true, true, false, false, .nowhere),
            (true, true, false, true, .nowhere),
            (true, true, true, false, .nowhere),
            (true, true, true, true, .nowhere),
        ]
        for row in rows {
            let typing = Keymap.typing(
                fieldOnItsWay: false, vim: row.vim, hasSelection: row.selection, addingWords: row.adding, insideAddedWords: row.inside
            )
            #expect(typing == row.typing, "\(row)")
        }
    }

    @Test func wordMovements() {
        let text = "Add a rate-limiter, then  test it." as NSString
        // w: to the start of the next word, punctuation counting as its own word.
        #expect(VimMotion.nextWordStart(in: text, from: 0) == 4)
        #expect(VimMotion.nextWordStart(in: text, from: 6) == 10)
        #expect(VimMotion.nextWordStart(in: text, from: 10) == 11)
        #expect(VimMotion.nextWordStart(in: text, from: 20) == 26)
        #expect(VimMotion.nextWordStart(in: text, from: text.length) == text.length)
        // e: to the end of the word.
        #expect(VimMotion.wordEnd(in: text, from: 0) == 3)
        #expect(VimMotion.wordEnd(in: text, from: 3) == 5)
        #expect(VimMotion.wordEnd(in: text, from: 24) == 30)
        // b: back to the start of the word.
        #expect(VimMotion.previousWordStart(in: text, from: 5) == 4)
        #expect(VimMotion.previousWordStart(in: text, from: 4) == 0)
        #expect(VimMotion.previousWordStart(in: text, from: 26) == 20)
        #expect(VimMotion.previousWordStart(in: text, from: 0) == 0)
    }

    @Test func paragraphMovements() {
        let text = "First line\nSecond line\n\nFourth" as NSString
        #expect(VimMotion.paragraphEnd(in: text, from: 0) == 10)
        #expect(VimMotion.paragraphEnd(in: text, from: 10) == 22)
        #expect(VimMotion.paragraphEnd(in: text, from: 22) == text.length)
        #expect(VimMotion.paragraphStart(in: text, from: 15) == 11)
        #expect(VimMotion.paragraphStart(in: text, from: 11) == 0)
        #expect(VimMotion.paragraphStart(in: text, from: text.length) == 24)
    }
}

@MainActor
@Suite("Vim keys in a review")
struct VimReviewTests {
    private static let source = "We will leverage a very robust approach here.\n\nSecond paragraph of the plan."

    private struct Harness {
        let session: ReviewSession
        let window: NSWindow
        let textView: AnnotationTextView
    }

    private func makeHarness(vim: Bool = true) throws -> Harness {
        _ = NSApplication.shared
        let request = ReviewRequest(
            content: .text(Self.source, format: .markdown), origin: .planHook,
            metadata: ReviewMetadata(title: "Plan"), reply: .clipboard, modes: [.feedback, .applyEdits]
        )
        let session = ReviewSession(request: request)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        settle(window)
        func find(_ view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let match = view as? AnnotationTextView { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        let textView = try #require(find(window.contentView))
        textView.usesVimKeys = vim
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        return Harness(session: session, window: window, textView: textView)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Presses each character as its own key.
    private func type(_ keys: String, in harness: Harness, flags: NSEvent.ModifierFlags = []) throws {
        for key in keys {
            let isUpper = key.isUppercase || "${}".contains(key)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags.union(isUpper ? .shift : []), timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil,
                characters: String(key), charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: 0
            ))
            harness.textView.keyDown(with: event)
        }
    }

    private func escape(in harness: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: KeyCode.escape
        ))
        harness.textView.keyDown(with: event)
    }

    private var selected: (Harness) -> String { { ($0.textView.string as NSString).substring(with: $0.textView.selectedRange()) } }

    @Test func lettersOnAVisualSelectionAreCommandsNotAComment() throws {
        let harness = try makeHarness()
        try type("vw", in: harness)
        #expect(harness.textView.selectedRange().length > 0)
        try type("q", in: harness)
        #expect(harness.session.marks.isEmpty)
        try type("c", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.comment])
    }

    @Test func movingTheCaret() throws {
        let harness = try makeHarness()
        try type("ww", in: harness)
        #expect(harness.textView.selectedRange() == NSRange(location: 8, length: 0))
        try type("l", in: harness)
        #expect(harness.textView.selectedRange().location == 9)
        try type("hb", in: harness)
        #expect(harness.textView.selectedRange().location == 3)
        try type("G", in: harness)
        #expect(harness.textView.selectedRange().location == (harness.textView.string as NSString).length)
        try type("gg", in: harness)
        #expect(harness.textView.selectedRange().location == 0)
        try type("}", in: harness)
        #expect(harness.textView.selectedRange().location == 45)
        // Nothing was marked or typed along the way.
        #expect(harness.session.marks.isEmpty)
        #expect(harness.textView.string == harness.session.document.text)
    }

    @Test func selectingInVisualModeAndMarking() throws {
        let harness = try makeHarness()
        try type("ww", in: harness)
        try type("v", in: harness)
        #expect(harness.session.isSelectingByKeyboard)
        try type("e", in: harness)
        #expect(selected(harness) == "leverage")

        try type("d", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.delete])
        #expect(harness.session.marks.first?.anchor.quote == "leverage")
        // Marking leaves visual mode.
        #expect(!harness.session.isSelectingByKeyboard)
    }

    @Test func selectionCanGrowBackwardsAndOverLines() throws {
        let harness = try makeHarness()
        try type("wwwvbb", in: harness)
        #expect(selected(harness) == "will leverage ")

        try escape(in: harness)
        try type("ggVj", in: harness)
        #expect(selected(harness).hasPrefix("We will leverage a very robust approach here.\n"))
    }

    @Test func plainKMovesAndShiftKKeeps() throws {
        let harness = try makeHarness()
        try type("G", in: harness)
        let end = harness.textView.selectedRange().location
        try type("k", in: harness)
        #expect(harness.textView.selectedRange().location < end)
        #expect(harness.session.marks.isEmpty)

        try type("ggve", in: harness)
        try type("K", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.keep])
    }

    @Test func escapeLetsGoOfTheSelectionAndNeverCancels() throws {
        let harness = try makeHarness()
        var cancelled = false
        harness.textView.onCancelKey = { cancelled = true }
        try type("vee", in: harness)
        #expect(harness.textView.selectedRange().length > 0)
        try escape(in: harness)
        #expect(harness.textView.selectedRange().length == 0)
        #expect(!harness.session.isSelectingByKeyboard)
        try escape(in: harness)
        #expect(!cancelled)
    }

    @Test func undoAndMarkNavigation() throws {
        let harness = try makeHarness()
        let undo = UndoManager()
        undo.groupsByEvent = false
        harness.session.undoManager = undo
        let first = try #require(harness.session.addMark(.delete, span: TextSpan(8, 16)))
        let second = try #require(harness.session.addMark(.keep, span: TextSpan(19, 30)))

        harness.session.selectedMarkID = nil
        try type("n", in: harness)
        #expect(harness.session.selectedMarkID == first.id)
        try type("n", in: harness)
        #expect(harness.session.selectedMarkID == second.id)
        try type("N", in: harness)
        #expect(harness.session.selectedMarkID == first.id)
    }

    @Test func withoutVimKeysTheLettersAreNotMovements() throws {
        let harness = try makeHarness(vim: false)
        harness.textView.setSelectedRange(NSRange(location: 8, length: 8))
        try type("k", in: harness, flags: .option)
        #expect(harness.session.marks.map(\.kind) == [.keep])
        // On a selection a plain letter starts a comment: it does not type over it.
        harness.textView.setSelectedRange(NSRange(location: 19, length: 4))
        try type("u", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.keep, .comment])
        harness.session.endEditing()
        // At a caret, w, h and j are not movements either: they start a comment pinned there.
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        try type("whj", in: harness)
        let pinned = try #require(harness.session.marks.last)
        #expect(pinned.kind == .comment)
        #expect(pinned.anchor.span == TextSpan(3, 3))
        #expect(pinned.note == "whj")
        #expect(harness.textView.string == harness.session.document.text)
    }

    @Test func withoutVimKeysOptionIStartsAddingWords() throws {
        // ⌥I on a selection puts the caret after it, adding words; the letter itself is not typed.
        let harness = try makeHarness(vim: false)
        harness.textView.setSelectedRange(NSRange(location: 8, length: 8))
        try type("i", in: harness, flags: .option)
        #expect(harness.session.marks.isEmpty)
        #expect(harness.textView.selectedRange() == NSRange(location: 16, length: 0))
        #expect(harness.session.isAddingWords)
        try type("now", in: harness)
        #expect(harness.session.marks.map(\.text) == ["now"])
        try escape(in: harness)
        #expect(!harness.session.isAddingWords)

        // At a caret, i is a letter like any other, and starts a comment; after ⌥I it is a word.
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        try type("is", in: harness)
        #expect(harness.session.marks.last?.kind == .comment)
        #expect(harness.session.marks.last?.note == "is")
        harness.session.endEditing()
        try type("i", in: harness, flags: .option)
        try type("is", in: harness)
        #expect(harness.session.marks.last?.kind == .insert)
        #expect(harness.session.marks.last?.text == "is")
        #expect(harness.session.marks.last?.anchor.span == TextSpan(3, 3))
    }

    // MARK: Insert mode

    private func insert(_ text: String, in harness: Harness) {
        harness.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func inNormalModeNothingTypes() throws {
        let harness = try makeHarness()
        insert("stray", in: harness)
        #expect(harness.session.marks.isEmpty)
        #expect(harness.textView.string == harness.session.document.text)
    }

    @Test func iStartsTypingAndEscapeStops() throws {
        let harness = try makeHarness()
        try type("ww", in: harness)
        try type("i", in: harness)
        #expect(harness.session.isAddingWords)
        // In insert mode every key is text, the movement letters included.
        try type("jk ", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.insert])
        #expect(harness.session.marks.first?.text == "jk ")
        #expect(harness.textView.string.hasPrefix("We will jk leverage"))

        try escape(in: harness)
        #expect(!harness.session.isAddingWords)
        // Back to moving: h is a movement again.
        let caret = harness.textView.selectedRange().location
        try type("h", in: harness)
        #expect(harness.textView.selectedRange().location == caret - 1)
        #expect(harness.session.marks.first?.text == "jk ")
    }

    @Test func aAppendsAfterTheCharacterUnderTheCaret() throws {
        let harness = try makeHarness()
        try type("a", in: harness)
        #expect(harness.session.isAddingWords)
        try type("X", in: harness)
        #expect(harness.textView.string.hasPrefix("WXe will"))
    }

    @Test func replacingAVisualSelectionGoesStraightToTyping() throws {
        let harness = try makeHarness()
        try type("wwve", in: harness)
        try type("r", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.replace])
        #expect(harness.session.isAddingWords)
        #expect(!harness.session.isSelectingByKeyboard)
        try type("use", in: harness)
        #expect(harness.session.marks.first?.text == "use")
        #expect(try harness.session.editedText().hasPrefix("We will use a very robust"))
    }

    @Test func cAtACaretPinsACommentAndTheNextLettersAreItsNote() throws {
        let harness = try makeHarness()
        try type("ww", in: harness)
        try type("c", in: harness)
        let comment = try #require(harness.session.marks.first)
        #expect(comment.kind == .comment)
        #expect(comment.anchor.span == TextSpan(8, 8))
        #expect(harness.session.editing == EditTarget(markID: comment.id, field: .note))

        try type("why", in: harness)
        #expect(harness.session.marks.map(\.note) == ["why"])
        #expect(harness.textView.string == harness.session.document.text)
        #expect(try harness.session.editedText() == Self.source)
    }

    @Test func cInsideAddedWordsIsRefused() throws {
        let harness = try makeHarness()
        try type("ww", in: harness)
        try type("i", in: harness)
        insert("abc", in: harness)
        try escape(in: harness)
        try type("h", in: harness)
        try type("c", in: harness)
        #expect(harness.session.marks.map(\.kind) == [.insert])
        #expect(harness.session.statusMessage == "A comment can't be pinned here.")

        // Nor a saved one.
        harness.session.statusMessage = nil
        try type("s", in: harness)
        #expect(harness.session.statusMessage == "A comment can't be pinned here.")
    }
}
