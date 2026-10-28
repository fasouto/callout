import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

extension OnTheMainThread {
    /// Builds the real review view off screen and checks what the text view shows.
    /// Set `ANNOTATOR_SNAPSHOT_DIR` to also write a PNG of the window for a look.
    @MainActor
    @Suite("Review window")
    struct ReviewWindowTests {
        private static let source = """
        # Plan: add rate limiting

        The API has **no limits** today, so a single client can exhaust the pool.
        See [the incident report](https://example.com/incidents/42) for details.

        1. Add a `RateLimiter` middleware
           - token bucket, *per API key*
        2. Return `429` with a `Retry-After` header

        ```python
        class RateLimiter:
            def allow(self, key: str) -> bool:
                return self.bucket(key).take()
        ```

        | Setting | Default | Notes |
        |---|---|---|
        | `RATE_LIMIT_RPS` | 10 | Requests per second for each API key, refilled continuously |
        | `RATE_LIMIT_BURST` | 20 | Bucket size |

        > Note: this does not cover websockets.

        We will leverage a very robust approach here.
        """

        private struct Harness {
            let session: ReviewSession
            let window: NSWindow
            let textView: AnnotationTextView
        }

        private func makeHarness() throws -> Harness {
            _ = NSApplication.shared
            let request = ReviewRequest(
                content: .text(Self.source, format: .markdown),
                origin: .planHook,
                metadata: ReviewMetadata(title: "Plan"),
                reply: .clipboard,
                modes: [.feedback, .applyEdits]
            )
            let session = ReviewSession(request: request)
            let window = SnapshotWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
            settle(window)
            let textView = try #require(findTextView(in: window.contentView))
            return Harness(session: session, window: window, textView: textView)
        }

        /// Lets SwiftUI and AppKit finish pending layout and updates.
        private func settle(_ window: NSWindow) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        private func findTextView(in view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let textView = view as? AnnotationTextView { return textView }
            for subview in view.subviews {
                if let found = findTextView(in: subview) { return found }
            }
            return nil
        }

        private func sourceSpan(of quote: String, occurrence: Int = 1) -> TextSpan {
            let text = Self.source as NSString
            var range = NSRange(location: 0, length: 0)
            for _ in 0..<occurrence {
                let from = NSMaxRange(range)
                range = text.range(of: quote, options: .literal, range: NSRange(location: from, length: text.length - from))
            }
            return TextSpan(range.location, NSMaxRange(range))
        }

        /// Writes the window as PNGs, in light and in dark, when a snapshot folder is set.
        private func snapshot(_ window: NSWindow, named name: String) {
            guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"],
                  let view = window.contentView else { return }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                settle(window)
                guard let bitmap = view.snapshotBitmap() else { continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.appearance = nil
        }

        /// Presses ⌥ and a mark's letter.
        private func mark(_ letter: String, keyCode: UInt16, in harness: Harness) throws {
            try press(letter, keyCode: keyCode, modifiers: .option, in: harness)
        }

        private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in harness: Harness) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            harness.textView.keyDown(with: event)
        }

        private func select(_ phrase: String, in harness: Harness) {
            harness.textView.setSelectedRange((harness.textView.string as NSString).range(of: phrase))
        }

        @Test func letterKeysMarkTheSelection() throws {
            let harness = try makeHarness()
            let session = harness.session

            select("very robust ", in: harness)
            try mark("d", keyCode: 2, in: harness)
            #expect(session.marks.map(\.kind) == [.delete])
            #expect(session.marks.first?.anchor.quote == "very robust ")

            select("no limits", in: harness)
            try mark("K", keyCode: 40, in: harness)
            #expect(session.marks.last?.kind == .keep)
            #expect(session.marks.last?.anchor.quote == "**no limits**")

            // The mark keys never type into the document.
            settle(harness.window)
            #expect(harness.textView.string == session.document.text)
        }

        @Test func whileAddingWordsOptionLettersAreText() throws {
            let harness = try makeHarness()
            let session = harness.session
            harness.textView.usesVimKeys = false
            // Right after "Plan:" in the heading.
            harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
            try mark("i", keyCode: 34, in: harness)
            try mark("d", keyCode: 2, in: harness)
            try mark("x", keyCode: 7, in: harness)

            #expect(session.marks.map(\.kind) == [.insert])
            #expect(session.marks.first?.text == "dx")
            #expect(harness.textView.string.hasPrefix("Plan:dx add rate limiting"))
            #expect(harness.textView.selectedRange() == NSRange(location: 7, length: 0))
            #expect(try session.editedText().hasPrefix("# Plan:dx add rate limiting"))
        }

        @Test func backspaceRemovesTheSelectedMark() throws {
            let harness = try makeHarness()
            select("very robust ", in: harness)
            try mark("d", keyCode: 2, in: harness)
            #expect(harness.session.marks.count == 1)
            harness.session.endEditing()

            try press("\u{7F}", keyCode: KeyCode.delete, in: harness)
            #expect(harness.session.marks.isEmpty)
        }

        @Test func aSecondEditOnTheSameTextIsRefused() throws {
            let harness = try makeHarness()
            select("very robust ", in: harness)
            try mark("d", keyCode: 2, in: harness)
            settle(harness.window)
            select("robust approach", in: harness)
            try mark("d", keyCode: 2, in: harness)
            #expect(harness.session.marks.count == 1)
        }

        // MARK: Writing in the margin

        @Test func aReplacementIsTypedInPlace() throws {
            let harness = try makeHarness()
            let session = harness.session
            harness.textView.usesVimKeys = false
            select("leverage", in: harness)
            try mark("r", keyCode: 15, in: harness)

            let mark = try #require(session.marks.first)
            #expect(mark.kind == .replace)
            #expect(session.selectedMarkID == mark.id)
            #expect(session.editing == nil)
            #expect(session.isAddingWords)
            let struck = (harness.textView.string as NSString).range(of: "leverage")
            #expect(harness.textView.selectedRange() == NSRange(location: NSMaxRange(struck), length: 0))

            harness.textView.insertText("use", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(session.marks.first?.text == "use")
            #expect(harness.textView.string.contains("We will leverageuse a very robust"))
            #expect(try session.editedText().contains("We will use a very robust"))
            #expect(session.feedback().contains("> leverage\nWith: use\n"))

            // Moving on leaves it as it is.
            harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(session.marks.map(\.kind) == [.replace])
        }

        @Test func aReplacementLeftEmptyBecomesADeletion() throws {
            let harness = try makeHarness()
            let session = harness.session
            select("leverage", in: harness)
            try mark("r", keyCode: 15, in: harness)
            #expect(session.marks.map(\.kind) == [.replace])
            // Even before the caret moves on, nothing goes out as a replacement with no words.
            #expect(session.feedback().contains("### 1. Delete\n> leverage\n"))

            harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(session.marks.map(\.kind) == [.delete])
            #expect(session.marks.first?.text == nil)
        }

        @Test func aCommentLeftEmptyIsDropped() throws {
            let harness = try makeHarness()
            let session = harness.session

            select("token bucket", in: harness)
            try mark("c", keyCode: 8, in: harness)
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.editing?.field == .note)
            session.endEditing()
            #expect(session.marks.isEmpty)

            // A written one stays.
            select("token bucket", in: harness)
            try mark("c", keyCode: 8, in: harness)
            session.update(try #require(session.marks.first).id, note: "Why?")
            session.endEditing()
            #expect(session.marks.first?.note == "Why?")
        }

        @Test func optionIPutsTheCaretAfterTheSelectionAddingWords() throws {
            let harness = try makeHarness()
            let session = harness.session
            harness.textView.usesVimKeys = false
            select("websockets", in: harness)
            try mark("i", keyCode: 34, in: harness)
            // Nothing is marked until something is typed.
            #expect(session.marks.isEmpty)
            let word = (harness.textView.string as NSString).range(of: "websockets")
            #expect(harness.textView.selectedRange() == NSRange(location: NSMaxRange(word), length: 0))
            #expect(session.isAddingWords)

            harness.textView.insertText(" or streaming", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(session.marks.map(\.kind) == [.insert])
            #expect(try session.editedText().contains("cover websockets or streaming."))
        }

        // MARK: Comments pinned to a point

        @Test func aPointCommentIsPinnedWithoutChangingTheText() throws {
            let harness = try makeHarness()
            let session = harness.session
            let before = harness.textView.snapshotBitmap()?.tiffRepresentation
            let point = sourceSpan(of: "very robust").end
            try #require(session.addMark(.comment, span: TextSpan(point, point), note: "Says who?"))
            settle(harness.window)

            #expect(harness.textView.string == session.document.text)
            let storage = try #require(harness.textView.textStorage)
            let after = NSMaxRange((harness.textView.string as NSString).range(of: "very robust"))
            #expect(storage.attribute(.annotatorPin, at: after, effectiveRange: nil) as? Pin == Pin(isAfter: false, selected: true))
            #expect(storage.attribute(.annotatorPin, at: after - 1, effectiveRange: nil) == nil)
            #expect(harness.textView.snapshotBitmap()?.tiffRepresentation != before)

            session.selectedMarkID = nil
            settle(harness.window)
            #expect(storage.attribute(.annotatorPin, at: after, effectiveRange: nil) as? Pin == Pin(isAfter: false, selected: false))
        }

        @Test func theCaretOnAPointCommentSelectsItAndCommandBackspaceRemovesIt() throws {
            let harness = try makeHarness()
            let session = harness.session
            let point = sourceSpan(of: "very robust").end
            let comment = try #require(session.addMark(.comment, span: TextSpan(point, point), note: "Says who?"))
            settle(harness.window)
            let at = NSMaxRange((harness.textView.string as NSString).range(of: "very robust"))

            harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(session.selectedMarkID == nil)
            harness.textView.setSelectedRange(NSRange(location: at, length: 0))
            #expect(session.selectedMarkID == comment.id)
            harness.textView.setSelectedRange(NSRange(location: at + 1, length: 0))
            #expect(session.selectedMarkID == nil)

            harness.textView.setSelectedRange(NSRange(location: at, length: 0))
            try press("\u{7F}", keyCode: KeyCode.delete, modifiers: .command, in: harness)
            #expect(session.marks.isEmpty)

            try #require(session.addMark(.comment, span: TextSpan(point, point), note: "Says who?"))
            let insert = try #require(session.addMark(.insert, span: TextSpan(point, point), text: " and simple"))
            settle(harness.window)
            let end = NSMaxRange((harness.textView.string as NSString).range(of: "very robust and simple"))
            session.selectedMarkID = nil
            harness.textView.setSelectedRange(NSRange(location: end, length: 0))
            #expect(session.selectedMarkID == insert.id)
        }

        @Test func twoCommentsAtOnePointAreTwoMarks() throws {
            let harness = try makeHarness()
            let session = harness.session
            harness.textView.usesVimKeys = false
            let at = NSMaxRange((harness.textView.string as NSString).range(of: "very robust"))

            harness.textView.setSelectedRange(NSRange(location: at, length: 0))
            harness.textView.insertText("Says who?", replacementRange: NSRange(location: NSNotFound, length: 0))
            try press("\r", keyCode: KeyCode.return, in: harness)
            settle(harness.window)
            harness.textView.setSelectedRange(NSRange(location: at, length: 0))
            let first = try #require(session.marks.first)
            #expect(session.selectedMarkID == first.id)
            harness.textView.insertText("Measured how?", replacementRange: NSRange(location: NSNotFound, length: 0))
            try press("\r", keyCode: KeyCode.return, in: harness)
            settle(harness.window)

            #expect(session.marks.map(\.kind) == [.comment, .comment])
            #expect(session.marks.map(\.anchor.span) == [first.anchor.span, first.anchor.span])
            #expect(harness.textView.string == session.document.text)
            session.selectedMarkID = nil
            try press("\t", keyCode: KeyCode.tab, in: harness)
            #expect(session.selectedMarkID == first.id)
            try press("\t", keyCode: KeyCode.tab, in: harness)
            #expect(session.selectedMarkID == session.marks.last?.id)
            #expect(session.feedback().contains("""
            ### 1. Comment after
            > We will leverage a very robust
            Says who?

            ### 2. Comment after
            > We will leverage a very robust
            Measured how?
            """))
        }

        @Test func pointCommentsArePinsInTheText() throws {
            let harness = try makeHarness()
            let session = harness.session
            for (words, note) in [("# Plan:", "Which plan?"), ("token bucket", "Why a bucket?"), ("Bucket size", "In what unit?"), ("today,", "Since when?")] {
                let point = sourceSpan(of: words).end
                try #require(session.addMark(.comment, span: TextSpan(point, point), note: note))
            }
            settle(harness.window)
            #expect(harness.textView.string == session.document.text)
            let selected = NSMaxRange((harness.textView.string as NSString).range(of: "today,"))
            #expect(harness.textView.textStorage?.attribute(.annotatorPin, at: selected, effectiveRange: nil) as? Pin == Pin(isAfter: false, selected: true))
            snapshot(harness.window, named: "review-point-comments")
        }

        @Test func returnOpensTheSelectedMarkForWriting() throws {
            let harness = try makeHarness()
            let session = harness.session
            select("very robust ", in: harness)
            try press("\u{7F}", keyCode: KeyCode.delete, in: harness)
            #expect(session.editing == nil)

            try press("\r", keyCode: KeyCode.return, in: harness)
            #expect(session.editing == EditTarget(markID: try #require(session.marks.first).id, field: .note))

            // A keep has nothing to write.
            session.endEditing()
            select("no limits", in: harness)
            try mark("k", keyCode: 40, in: harness)
            try press("\r", keyCode: KeyCode.return, in: harness)
            #expect(session.editing == nil)
        }

        @Test func movingTheCaretPicksUpAndLetsGoOfMarks() throws {
            let harness = try makeHarness()
            let session = harness.session
            select("very robust ", in: harness)
            try mark("d", keyCode: 2, in: harness)
            let mark = try #require(session.marks.first)
            settle(harness.window)

            let text = harness.textView.string as NSString
            harness.textView.setSelectedRange(NSRange(location: text.range(of: "Plan:").location, length: 0))
            #expect(session.selectedMarkID == nil)

            harness.textView.setSelectedRange(NSRange(location: text.range(of: "robust").location, length: 0))
            #expect(session.selectedMarkID == mark.id)
        }

        // MARK: Undo and moving between marks

        private func undoable(_ session: ReviewSession) -> UndoManager {
            let manager = UndoManager()
            // No event loop runs here to close a group per event.
            manager.groupsByEvent = false
            session.undoManager = manager
            return manager
        }

        @Test func marksCanBeUndoneAndRedone() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)

            let first = try #require(session.addMark(.delete, span: sourceSpan(of: "very robust ")))
            let second = try #require(session.addMark(.keep, span: sourceSpan(of: "no limits")))
            #expect(undo.undoActionName == "Keep")

            undo.undo()
            #expect(session.marks.map(\.id) == [first.id])
            undo.undo()
            #expect(session.marks.isEmpty)
            #expect(!undo.canUndo)

            undo.redo()
            undo.redo()
            #expect(session.marks.map(\.id) == [first.id, second.id])

            session.remove(first.id)
            #expect(session.marks.map(\.id) == [second.id])
            undo.undo()
            #expect(session.marks.map(\.id) == [first.id, second.id])
            // The selection goes back to what it was before the removal, too.
            #expect(session.selectedMarkID == second.id)

            settle(harness.window)
            #expect(harness.textView.string == session.layout.text)
        }

        @Test func aTypedReplacementIsOneUndoStep() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)
            harness.textView.usesVimKeys = false

            select("leverage", in: harness)
            try mark("r", keyCode: 15, in: harness)
            for character in ["u", "s", "e"] {
                harness.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            #expect(session.marks.first?.text == "use")

            // The strike and every letter typed after it come back out together.
            undo.undo()
            #expect(session.marks.isEmpty)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(session.marks.first?.text == "use")
        }

        @Test func addedWordsAreOneUndoStep() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)
            harness.textView.usesVimKeys = false
            harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
            try mark("i", keyCode: 34, in: harness)
            for character in ["!", "!", "!"] {
                harness.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            #expect(session.marks.first?.text == "!!!")
            undo.undo()
            #expect(session.marks.isEmpty)
            #expect(!undo.canUndo)
        }

        @Test func wordsAddedAgainAfterStoppingAreTheirOwnUndoStep() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)
            harness.textView.usesVimKeys = false
            harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
            try mark("i", keyCode: 34, in: harness)
            harness.textView.insertText("!!", replacementRange: NSRange(location: NSNotFound, length: 0))
            try press("\u{1B}", keyCode: KeyCode.escape, in: harness)
            try mark("i", keyCode: 34, in: harness)
            harness.textView.insertText("?", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(session.marks.map(\.text) == ["!!?"])

            undo.undo()
            #expect(session.marks.map(\.text) == ["!!"])
            undo.undo()
            #expect(session.marks.isEmpty)
        }

        @Test func aCommentLeftEmptyLeavesNothingToUndo() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)

            select("token bucket", in: harness)
            try mark("c", keyCode: 8, in: harness)
            session.endEditing()
            #expect(session.marks.isEmpty)
            #expect(!undo.canUndo)
        }

        @Test func editingANoteIsOneUndoStepPerNote() throws {
            let harness = try makeHarness()
            let session = harness.session
            let undo = undoable(session)
            let mark = try #require(session.addMark(.delete, span: sourceSpan(of: "very robust ")))

            session.beginEditing(mark.id)
            for note in ["f", "fi", "filler"] { session.update(mark.id, note: note) }
            session.endEditing()
            #expect(session.marks.first?.note == "filler")

            undo.undo()
            #expect(session.marks.first?.note == nil)
            #expect(session.marks.count == 1)
            undo.undo()
            #expect(session.marks.isEmpty)
        }

        @Test func tabMovesThroughMarksInDocumentOrder() throws {
            let harness = try makeHarness()
            let session = harness.session
            let last = try #require(session.addMark(.delete, span: sourceSpan(of: "very robust ")))
            let first = try #require(session.addMark(.keep, span: sourceSpan(of: "no limits")))
            let middle = try #require(session.addMark(.comment, span: sourceSpan(of: "token bucket"), note: "why"))

            session.selectedMarkID = nil
            try press("\t", keyCode: KeyCode.tab, in: harness)
            #expect(session.selectedMarkID == first.id)
            try press("\t", keyCode: KeyCode.tab, in: harness)
            #expect(session.selectedMarkID == middle.id)
            try press("\t", keyCode: KeyCode.tab, in: harness)
            try press("\t", keyCode: KeyCode.tab, in: harness)
            #expect(session.selectedMarkID == first.id)

            session.selectMark(offsetBy: -1)
            #expect(session.selectedMarkID == last.id)
        }

        @Test func narrowWindowKeepsTheMargin() throws {
            let harness = try makeHarness()
            let session = harness.session
            session.addMark(.comment, span: sourceSpan(of: "token bucket"), note: "Why not a sliding window? It handles bursts at the edges better.")
            session.addMark(.delete, span: sourceSpan(of: "very robust "), note: "filler")
            session.selectedMarkID = nil
            harness.window.setContentSize(NSSize(width: 760, height: 560))
            settle(harness.window)

            let frame = harness.textView.frame
            #expect(frame.width >= Theme.minimumMeasure)
            #expect(frame.maxX + Theme.gutter + Theme.narrowMarginWidth <= 760)
            snapshot(harness.window, named: "review-narrow")
        }

        @Test func selectionBarShowsTheFiveMarks() throws {
            _ = NSApplication.shared
            var pressed: [MarkKind] = []
            let bar = SelectionToolbar { pressed.append($0) }
            let view = bar.makeContentView()
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            #expect(view.fittingSize.width > 150 && view.fittingSize.height < 40)

            guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"] else { return }
            let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width + 40, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let backdrop = NSView(frame: window.contentLayoutRect)
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            view.setFrameOrigin(NSPoint(x: 20, y: 18))
            backdrop.addSubview(view)
            window.contentView = backdrop
            settle(window)
            guard let bitmap = backdrop.snapshotBitmap() else { return }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("selection-bar.png"))
        }

        @Test func expandAndSummarizeAreOneKeyEach() throws {
            let harness = try makeHarness()
            let session = harness.session
            select("token bucket", in: harness)
            try mark("x", keyCode: 7, in: harness)
            select("The API has no limits today, so a single client can exhaust the pool.", in: harness)
            try mark("m", keyCode: 46, in: harness)

            #expect(session.marks.map(\.kind) == [.expand, .summarize])
            // Nothing to write is asked for: the instruction is complete as it is.
            #expect(session.editing == nil)
            #expect(session.feedback().contains("### 1. Summarize\n> The API has **no limits** today"))
            #expect(session.feedback().contains("### 2. Expand\n> token bucket\n"))

            // A note can still be added with Return.
            try press("\r", keyCode: KeyCode.return, in: harness)
            #expect(session.editing?.field == .note)
            session.update(try #require(session.selectedMarkID), note: "One sentence is enough.")
            session.endEditing()
            #expect(session.feedback().contains("exhaust the pool.\nOne sentence is enough.\n"))
        }

        @Test func optionOGoesToTheOverallCommentExceptWhileAddingWords() throws {
            let harness = try makeHarness()
            let session = harness.session
            harness.textView.usesVimKeys = false
            let token = session.overallFocusToken
            select("token bucket", in: harness)
            try mark("o", keyCode: 31, in: harness)
            #expect(session.overallFocusToken == token + 1)

            harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
            try mark("o", keyCode: 31, in: harness)
            #expect(session.overallFocusToken == token + 2)
            #expect(session.marks.isEmpty)

            try mark("i", keyCode: 34, in: harness)
            try mark("o", keyCode: 31, in: harness)
            #expect(session.overallFocusToken == token + 2)
            #expect(session.marks.map(\.text) == ["o"])
        }

        @Test func theAnswerThatAppliesLeads() throws {
            _ = NSApplication.shared
            let request = ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown), origin: .planHook,
                metadata: ReviewMetadata(title: "Plan"), reply: .hookDecision, modes: [.feedback, .approve]
            )
            let session = ReviewSession(request: request)
            let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
            settle(window)
            snapshot(window, named: "buttons-nothing-marked")

            session.addMark(.delete, span: TextSpan(19, 31))
            settle(window)
            snapshot(window, named: "buttons-marked")
        }

        @Test func showsTheRenderedDocument() throws {
            let harness = try makeHarness()
            #expect(harness.textView.string == harness.session.document.text)
            #expect(harness.textView.string.hasPrefix("Plan: add rate limiting\nThe API has no limits today"))
            snapshot(harness.window, named: "review-empty")
        }

        @Test func marksChangeWhatIsShown() throws {
            let harness = try makeHarness()
            let session = harness.session

            session.addMark(.delete, span: sourceSpan(of: "very robust "))
            session.addMark(.replace, span: sourceSpan(of: "leverage"), text: "use")
            session.addMark(.comment, span: sourceSpan(of: "token bucket"), note: "Why not a sliding window?")
            session.addMark(.keep, span: sourceSpan(of: "Return `429` with a `Retry-After` header"))
            session.addMark(.expand, span: sourceSpan(of: "Add a `RateLimiter` middleware"), note: "Where does it sit?")
            session.addMark(.summarize, span: sourceSpan(of: "The API has **no limits** today, so a single client can exhaust the pool."))
            let end = sourceSpan(of: "websockets").end
            session.addMark(.insert, span: TextSpan(end, end), text: " or streaming")
            session.generalComment = "Too complex, simplify."
            settle(harness.window)

            let shown = harness.textView.string
            #expect(shown == session.layout.text)
            #expect(shown.contains("We will leverageuse a very robust approach here."))
            #expect(shown.contains("websockets or streaming."))

            // The struck text and the ghost text carry the id of their mark.
            let storage = try #require(harness.textView.textStorage)
            let struck = (shown as NSString).range(of: "very robust ")
            #expect(storage.attribute(.strikethroughStyle, at: struck.location, effectiveRange: nil) != nil)
            let ghost = (shown as NSString).range(of: " or streaming")
            let insert = try #require(session.marks.first { $0.kind == .insert })
            #expect(storage.attribute(.annotatorMark, at: ghost.location, effectiveRange: nil) as? String == insert.id.uuidString)

            #expect(session.mark(atView: ghost.location + 2)?.id == insert.id)
            #expect(try session.editedText().contains("We will use a approach here."))
            snapshot(harness.window, named: "review-marked")
        }

        @Test func overlappingEditsAreRefused() throws {
            let harness = try makeHarness()
            let session = harness.session
            #expect(session.addMark(.delete, span: sourceSpan(of: "very robust")) != nil)
            #expect(session.addMark(.replace, span: sourceSpan(of: "robust approach"), text: "x") == nil)
            #expect(session.statusMessage != nil)
            // A comment may sit on top of an edit.
            #expect(session.addMark(.comment, span: sourceSpan(of: "robust approach"), note: "hm") != nil)
            #expect(session.marks.count == 2)
        }

        @Test func removingAMarkSelectsItsNeighbour() throws {
            let harness = try makeHarness()
            let session = harness.session
            let first = try #require(session.addMark(.keep, span: sourceSpan(of: "no limits")))
            let second = try #require(session.addMark(.delete, span: sourceSpan(of: "very robust")))
            #expect(session.selectedMarkID == second.id)

            session.remove(second.id)
            #expect(session.selectedMarkID == first.id)
            session.remove(first.id)
            #expect(session.selectedMarkID == nil)
            settle(harness.window)
            #expect(harness.textView.string == session.document.text)
        }

        @Test func selectingInTheViewMapsToSource() throws {
            let harness = try makeHarness()
            let session = harness.session
            session.addMark(.replace, span: sourceSpan(of: "leverage"), text: "use")

            // "no limits" is bold: selecting all of it takes the asterisks too.
            let shown = session.layout.text as NSString
            let bold = shown.range(of: "no limits")
            let span = try #require(session.sourceSpan(forView: bold.location..<NSMaxRange(bold)))
            #expect(Self.source.slice(span) == "**no limits**")

            // A selection inside ghost text is not document text.
            let ghost = shown.range(of: "use a very")
            #expect(session.sourceSpan(forView: ghost.location..<(ghost.location + 3)) == nil)
        }
    }
}
