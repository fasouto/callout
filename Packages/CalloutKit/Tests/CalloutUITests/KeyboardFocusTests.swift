import CalloutCore
import AppKit
import SwiftUI
import Testing
@testable import CalloutUI

extension OnTheMainThread {
    /// Where the keyboard goes. These are the paths a person takes with their hands
    /// on the keys: open, mark, write the note, finish, carry on.
    @MainActor
    @Suite("Keyboard focus")
    struct KeyboardFocusTests {
        private struct Harness {
            let session: ReviewSession
            let window: NSWindow
        }

        private func makeHarness(
            modes: [ReviewMode] = [.feedback, .applyEdits], finish: @escaping (ReviewOutcome) -> Void = { _ in }
        ) async -> Harness {
            _ = NSApplication.shared
            let request = ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown), origin: .planHook,
                metadata: ReviewMetadata(title: "Plan"), reply: .clipboard, modes: modes
            )
            let session = ReviewSession(request: request)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReviewView(session: session, finish: finish))
            let harness = Harness(session: session, window: window)
            await settle(harness)
            return harness
        }

        /// Lets both kinds of pending work happen: SwiftUI's updates, which ride on
        /// the run loop, and blocks queued on the main queue, which only run while
        /// this test is suspended.
        private func settle(_ harness: Harness) async {
            for _ in 0..<3 {
                spin(harness.window)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }

        private func spin(_ window: NSWindow) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        /// The text field being typed in, when the keyboard is in one.
        private func fieldInFocus(_ harness: Harness) -> NSTextField? {
            guard let editor = harness.window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
            return editor.delegate as? NSTextField
        }

        private func type(_ text: String, in harness: Harness) throws {
            let editor = try #require(harness.window.firstResponder as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        private func press(_ selector: Selector, in harness: Harness) throws {
            let editor = try #require(harness.window.firstResponder as? NSTextView)
            editor.doCommand(by: selector)
        }

        private func press(
            _ keys: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], on textView: AnnotationTextView
        ) throws {
            for key in keys {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: textView.window?.windowNumber ?? 0,
                    context: nil, characters: String(key), charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: keyCode
                ))
                textView.keyDown(with: event)
            }
        }

        /// The document view, with the keyboard in it and vim keys off.
        private func document(_ harness: Harness) throws -> AnnotationTextView {
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)
            textView.usesVimKeys = false
            return textView
        }

        private func caret(after phrase: String, in textView: AnnotationTextView) {
            textView.setSelectedRange(NSRange(location: NSMaxRange((textView.string as NSString).range(of: phrase)), length: 0))
        }

        @Test func aReviewOpensWithTheKeyboardInTheDocument() async {
            let harness = await makeHarness()
            #expect(harness.window.firstResponder is AnnotationTextView)
        }

        @Test func replacingPutsTheKeyboardInTheMarginAndTypingLandsInTheNote() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let mark = try #require(session.addMarkToWrite(.replace, span: TextSpan(8, 16)))
            await settle(harness)

            let field = try #require(fieldInFocus(harness))
            #expect(field is NoteTextField)
            #expect(field.accessibilityLabel() == "Replace with")

            try type("use", in: harness)
            #expect(session.marks.first?.text == "use")

            // Return finishes the note and hands the keyboard back to the document.
            try press(#selector(NSResponder.insertNewline(_:)), in: harness)
            await settle(harness)
            #expect(session.editing == nil)
            #expect(harness.window.firstResponder is AnnotationTextView)
            #expect(session.marks.first?.id == mark.id)
            #expect(try session.editedText() == "We will use a very robust approach here.")
        }

        @Test func commentingAndInsertingAlsoTakeTheKeyboard() async throws {
            let harness = await makeHarness()
            let session = harness.session

            session.addMarkToWrite(.comment, span: TextSpan(19, 30))
            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Comment")
            try type("filler", in: harness)
            try press(#selector(NSResponder.insertNewline(_:)), in: harness)
            await settle(harness)
            #expect(session.marks.first?.note == "filler")

            session.addMarkToWrite(.insert, span: TextSpan(16, 16))
            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Text to add")
            try type(" gladly", in: harness)
            #expect(session.marks.last?.text == " gladly")
        }

        @Test func escapeInANoteDropsAnEmptyOneAndReturnsToTheDocument() async throws {
            let harness = await makeHarness()
            harness.session.addMarkToWrite(.comment, span: TextSpan(19, 30))
            await settle(harness)
            #expect(fieldInFocus(harness) != nil)

            try press(#selector(NSResponder.cancelOperation(_:)), in: harness)
            await settle(harness)
            #expect(harness.session.marks.isEmpty)
            #expect(harness.window.firstResponder is AnnotationTextView)
        }

        /// ⌥D takes the keyboard to the reason as ⌥C does to the comment. The reason is
        /// optional: ↩ or Esc goes back to the document and the strike stays, undoable.
        @Test func strikingTakesTheKeyboardForTheReason() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let undoManager = UndoManager()
            session.undoManager = undoManager
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)

            func select(_ phrase: String) {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange((textView.string as NSString).range(of: phrase))
            }
            func press(_ key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: harness.window.windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
                ))
                textView.keyDown(with: event)
            }

            select("very robust ")
            try press("d", keyCode: 2, modifiers: .option)
            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Reason (optional)")
            try type("filler", in: harness)
            try self.press(#selector(NSResponder.insertNewline(_:)), in: harness)
            await settle(harness)
            #expect(harness.window.firstResponder is AnnotationTextView)
            #expect(session.marks.map(\.kind) == [.delete])
            #expect(session.marks.first?.note == "filler")
            #expect(session.marks.first?.text == nil)

            // Left without a reason, the strike stays and is one undo step.
            select("here")
            try press("d", keyCode: 2, modifiers: .option)
            await settle(harness)
            #expect(fieldInFocus(harness) != nil)
            try self.press(#selector(NSResponder.cancelOperation(_:)), in: harness)
            await settle(harness)
            #expect(harness.window.firstResponder is AnnotationTextView)
            #expect(session.marks.map(\.kind) == [.delete, .delete])
            #expect(session.marks.last?.note == nil)
            #expect(undoManager.undoActionName == "Delete")
            undoManager.undo()
            #expect(session.marks.map(\.note) == ["filler"])

            // ⌫ strikes as an editor deletes, and the keyboard stays in the document.
            select("leverage")
            try press("\u{7F}", keyCode: KeyCode.delete)
            await settle(harness)
            #expect(session.marks.count == 2)
            #expect(session.editing == nil)
            #expect(harness.window.firstResponder is AnnotationTextView)
        }

        /// Typing on a selection writes a comment on it, keys pressed before the
        /// comment's field has the keyboard included. Nothing goes into the document.
        @Test func typingOnASelectionWritesAComment() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)
            textView.setSelectedRange((textView.string as NSString).range(of: "very robust"))

            // Faster than the field can take the keyboard, and with an i, which used to insert.
            for key in "this " {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                    context: nil, characters: String(key), charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: 0
                ))
                textView.keyDown(with: event)
            }
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.marks.first?.note == "this ")

            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Comment")
            // The caret is after what was typed so far.
            try type("is wrong", in: harness)
            #expect(session.marks.first?.note == "this is wrong")
            try press(#selector(NSResponder.insertNewline(_:)), in: harness)
            await settle(harness)
            #expect(harness.window.firstResponder is AnnotationTextView)
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(try session.editedText() == "We will leverage a very robust approach here.")
        }

        /// The page redraws as soon as the comment starts, which lets go of the
        /// selection, and the comment's field takes the keyboard only after that.
        /// Keys pressed in between are part of the comment, not words added to the document.
        @Test func keysPressedWhileTheCommentsFieldTakesTheKeyboardAreInTheComment() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)
            textView.setSelectedRange((textView.string as NSString).range(of: "very robust"))

            for (index, key) in "too vague".enumerated() {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                    context: nil, characters: String(key), charactersIgnoringModifiers: String(key), isARepeat: false, keyCode: 0
                ))
                textView.keyDown(with: event)
                if index == 0 {
                    spin(harness.window)
                    #expect(harness.window.firstResponder === textView, "the field has not taken the keyboard yet")
                }
            }
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.marks.first?.note == "too vague")
            #expect(try session.editedText() == "We will leverage a very robust approach here.")
        }

        /// ⌥D's reason, typed before its field has the keyboard, is the reason.
        /// Backspace then takes back what was typed, as in the field, and never
        /// strikes more of the document.
        @Test func aReasonTypedBeforeItsFieldHasTheKeyboardIsTheReason() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)
            textView.setSelectedRange((textView.string as NSString).range(of: "very robust "))

            try press("d", keyCode: 2, modifiers: .option, on: textView)
            spin(harness.window)
            #expect(harness.window.firstResponder === textView, "the field has not taken the keyboard yet")
            try press("\u{7F}", keyCode: KeyCode.delete, on: textView)
            try press("fillx", on: textView)
            try press("\u{7F}", keyCode: KeyCode.delete, on: textView)
            try press("er", on: textView)

            #expect(session.marks.map(\.kind) == [.delete])
            #expect(session.marks.first?.note == "filler")
            #expect(try session.editedText() == "We will leverage a approach here.")
        }

        /// Return or Esc pressed before the field has the keyboard finishes the
        /// note, as either does in the field. Esc does not cancel the review, and
        /// the keyboard stays in the document.
        @Test func returnOrEscapeBeforeTheFieldHasTheKeyboardFinishesTheNote() async throws {
            var outcomes: [ReviewOutcome] = []
            let harness = await makeHarness { outcomes.append($0) }
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)

            textView.setSelectedRange((textView.string as NSString).range(of: "very robust"))
            try press("o", on: textView)
            spin(harness.window)
            try press("k", on: textView)
            try press("\r", keyCode: KeyCode.return, on: textView)
            await settle(harness)
            #expect(session.editing == nil)
            #expect(harness.window.firstResponder === textView)
            #expect(session.marks.map(\.note) == ["ok"])

            textView.setSelectedRange((textView.string as NSString).range(of: "here"))
            try press("d", keyCode: 2, modifiers: .option, on: textView)
            spin(harness.window)
            try press("\u{1B}", keyCode: KeyCode.escape, on: textView)
            await settle(harness)
            #expect(outcomes.isEmpty)
            #expect(session.editing == nil)
            #expect(harness.window.firstResponder === textView)
            #expect(session.marks.map(\.kind) == [.comment, .delete])
        }

        /// With vim keys, letters are commands, except while a note's field is on
        /// its way to the keyboard: then they are the note.
        @Test func withVimKeysLettersTypedBeforeTheFieldHasTheKeyboardAreTheNote() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)
            textView.usesVimKeys = true
            textView.setSelectedRange((textView.string as NSString).range(of: "leverage"))

            try press("c", on: textView)
            spin(harness.window)
            #expect(harness.window.firstResponder === textView, "the field has not taken the keyboard yet")
            try press("jargon", on: textView)

            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.marks.first?.note == "jargon")
            #expect(try session.editedText() == "We will leverage a very robust approach here.")
        }

        @Test func returnOnAMarkOpensItsNoteForTyping() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let mark = try #require(session.addMark(.delete, span: TextSpan(19, 31)))
            await settle(harness)
            #expect(harness.window.firstResponder is AnnotationTextView)

            session.beginEditing(mark.id)
            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Reason (optional)")
            try type("filler", in: harness)
            #expect(session.marks.first?.note == "filler")
        }

        @Test func oPutsTheKeyboardInTheOverallComment() async throws {
            let harness = await makeHarness()
            harness.session.focusOverallComment()
            await settle(harness)
            let editor = try #require(harness.window.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
            try type("Too complex, simplify.", in: harness)
            #expect(harness.session.generalComment == "Too complex, simplify.")
        }

        private func writeSnapshots(of harness: Harness, named name: String) {
            guard let folder = ProcessInfo.processInfo.environment["CALLOUT_SNAPSHOT_DIR"],
                  let view = harness.window.contentView else { return }
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                harness.window.appearance = NSAppearance(named: appearance)
                spin(harness.window)
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png")
                try? view.snapshotBitmap()?.representation(using: .png, properties: [:])?.write(to: url)
            }
            harness.window.appearance = nil
        }

        @Test func commandReturnSendsWhileWritingTheOverallComment() async throws {
            var outcomes: [ReviewOutcome] = []
            let harness = await makeHarness { outcomes.append($0) }
            harness.session.focusOverallComment()
            await settle(harness)
            try type("Too complex, simplify.", in: harness)
            await settle(harness)
            writeSnapshots(of: harness, named: "overall-send-hint")
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: harness.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: KeyCode.return
            ))
            #expect(harness.window.performKeyEquivalent(with: event))
            #expect(outcomes == [.feedback])
            #expect(harness.session.generalComment == "Too complex, simplify.")
        }

        enum Keyboard: CaseIterable { case document, overallComment, note }

        /// Puts the keyboard where a reviewer can be when they answer, with something written there.
        private func putKeyboard(in place: Keyboard, _ harness: Harness) async throws {
            switch place {
            case .document:
                #expect(harness.window.firstResponder is AnnotationTextView)
            case .overallComment:
                harness.session.focusOverallComment()
                await settle(harness)
                #expect(fieldInFocus(harness) != nil && !(fieldInFocus(harness) is NoteTextField))
                try type("Simpler.", in: harness)
            case .note:
                harness.session.addMarkToWrite(.comment, span: TextSpan(19, 30))
                await settle(harness)
                #expect(fieldInFocus(harness) is NoteTextField)
                try type("Why?", in: harness)
            }
            await settle(harness)
        }

        /// Presses Return with modifiers, as AppKit offers a key equivalent: to the
        /// window, before the view with the keyboard sees the key.
        private func pressReturn(_ modifiers: NSEvent.ModifierFlags, in harness: Harness) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: harness.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: KeyCode.return
            ))
            _ = harness.window.performKeyEquivalent(with: event)
        }

        @Test(arguments: Keyboard.allCases)
        func commandReturnSendsAndCommandShiftReturnApprovesOrAppliesTheEdits(from place: Keyboard) async throws {
            for (modes, answer) in [([ReviewMode.feedback, .approve], ReviewOutcome.approve), ([.feedback, .applyEdits], .applyEdits)] {
                var outcomes: [ReviewOutcome] = []
                let harness = await makeHarness(modes: modes) { outcomes.append($0) }
                try #require(harness.session.addMark(.delete, span: TextSpan(8, 17)))
                try await putKeyboard(in: place, harness)

                try pressReturn(.command, in: harness)
                #expect(outcomes == [.feedback], "⌘↩ with \(modes)")
                try pressReturn([.command, .shift], in: harness)
                #expect(outcomes == [.feedback, answer], "⌘⇧↩ with \(modes)")
            }
        }

        /// With nothing marked, ⌘↩ meant for Send Feedback must not approve the plan;
        /// with only a comment, ⌘⇧↩ meant for Apply Edits must not send it.
        @Test(arguments: [Keyboard.document, .overallComment])
        func aReturnChordWhoseButtonIsOffDoesNothing(from place: Keyboard) async throws {
            var outcomes: [ReviewOutcome] = []
            let plan = await makeHarness(modes: [.feedback, .approve]) { outcomes.append($0) }
            if place == .overallComment {
                plan.session.focusOverallComment()
                await settle(plan)
            }
            try pressReturn(.command, in: plan)
            #expect(outcomes.isEmpty, "⌘↩ with nothing to send")
            try pressReturn([.command, .shift], in: plan)
            #expect(outcomes == [.approve])

            outcomes.removeAll()
            let document = await makeHarness(modes: [.feedback, .applyEdits]) { outcomes.append($0) }
            try #require(document.session.addMark(.comment, span: TextSpan(19, 30), note: "Why?"))
            try await putKeyboard(in: place, document)
            try pressReturn([.command, .shift], in: document)
            #expect(outcomes.isEmpty, "⌘⇧↩ with no edits to apply")
            try pressReturn(.command, in: document)
            #expect(outcomes == [.feedback])
        }

        @Test func backspaceStrikesTheSelectionAndTakesTheStrikeBack() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try #require(harness.window.firstResponder as? AnnotationTextView)

            func backspace() throws {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                    context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: KeyCode.delete
                ))
                textView.keyDown(with: event)
            }

            textView.setSelectedRange((textView.string as NSString).range(of: "very robust "))
            try backspace()
            #expect(session.marks.map(\.kind) == [.delete])
            #expect(session.marks.first?.anchor.quote == "very robust ")
            // The document itself is never changed.
            #expect(textView.string == "We will leverage a very robust approach here.")

            // The same selection again: the strike comes off.
            await settle(harness)
            textView.setSelectedRange((textView.string as NSString).range(of: "very robust "))
            try backspace()
            #expect(session.marks.isEmpty)

            // ⌘⌫ takes away the mark the caret is on.
            let mark = try #require(session.addMark(.keep, span: TextSpan(8, 16)))
            await settle(harness)
            textView.setSelectedRange(NSRange(location: 10, length: 0))
            #expect(session.selectedMarkID == mark.id)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: harness.window.windowNumber,
                context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: KeyCode.delete
            ))
            textView.keyDown(with: event)
            #expect(session.marks.isEmpty)
        }

        // MARK: Typing at a caret

        /// With nothing selected, typing adds words at the caret.
        @Test func typingAtABareCaretAddsWords() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            caret(after: "robust", in: textView)

            try press(" and", on: textView)
            try press(" simple", on: textView)
            #expect(session.marks.map(\.kind) == [.insert])
            #expect(session.marks.first?.text == " and simple")
            #expect(session.editing == nil)
            #expect(harness.window.firstResponder === textView)
        }

        /// ⌥C pins a comment at a bare caret, keys pressed before its field has
        /// the keyboard included. Nothing goes into the document.
        @Test func optionCAtABareCaretWritesACommentPinnedThere() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            caret(after: "very robust", in: textView)

            try press("c", keyCode: 8, modifiers: .option, on: textView)
            try press("this ", on: textView)
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.marks.first?.anchor.span == TextSpan(30, 30))
            #expect(session.marks.first?.note == "this ")

            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Comment")
            try type("is vague", in: harness)
            try press(#selector(NSResponder.insertNewline(_:)), in: harness)
            await settle(harness)
            #expect(harness.window.firstResponder is AnnotationTextView)
            #expect(try session.editedText() == "We will leverage a very robust approach here.")
            #expect(session.feedback().contains("### 1. Comment after\n> We will leverage a very robust\nthis is vague\n"))
        }

        @Test func optionCAtABareCaretOpensAnEmptyCommentThere() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let undoManager = UndoManager()
            session.undoManager = undoManager
            let textView = try document(harness)
            caret(after: "We will", in: textView)

            try press("c", keyCode: 8, modifiers: .option, on: textView)
            #expect(session.marks.map(\.anchor.span) == [TextSpan(7, 7)])
            #expect(session.marks.first?.note == nil)
            await settle(harness)
            #expect(fieldInFocus(harness)?.accessibilityLabel() == "Comment")

            try press(#selector(NSResponder.cancelOperation(_:)), in: harness)
            await settle(harness)
            #expect(session.marks.isEmpty)
            #expect(!undoManager.canUndo)
            #expect(harness.window.firstResponder is AnnotationTextView)
        }

        @Test func optionLettersAtABareCaretAreCommands() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            caret(after: "robust", in: textView)

            try press("d", keyCode: 2, modifiers: .option, on: textView)
            try press("k", keyCode: 40, modifiers: .option, on: textView)
            #expect(session.marks.isEmpty)
            #expect(session.statusMessage == "Select some text of the document first.")

            let token = session.overallFocusToken
            try press("o", keyCode: 31, modifiers: .option, on: textView)
            #expect(session.overallFocusToken == token + 1)

            try press("i", keyCode: 34, modifiers: .option, on: textView)
            #expect(session.marks.isEmpty)
            #expect(textView.selectedRange() == NSRange(location: NSMaxRange((textView.string as NSString).range(of: "robust")), length: 0))
        }

        /// Esc is the Cancel button's, also after words were added: there is no
        /// adding-words mode to stop.
        @Test func escapeAfterAddingWordsCancels() async throws {
            var outcomes: [ReviewOutcome] = []
            let harness = await makeHarness { outcomes.append($0) }
            let session = harness.session
            let textView = try document(harness)
            caret(after: "robust", in: textView)

            try press(" and", on: textView)
            try press("\u{1B}", keyCode: KeyCode.escape, on: textView)
            #expect(outcomes == [.cancel])
            #expect(session.marks.map(\.text) == [" and"])
        }

        /// Typing right after added words, at their edge or in the middle, edits them.
        @Test func typingInsideOrRightAfterAddedWordsExtendsThem() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            caret(after: "robust", in: textView)
            try press(" and simple", on: textView)

            caret(after: "robust an", in: textView)
            try press("x", on: textView)
            #expect(session.marks.map(\.text) == [" anxd simple"])

            caret(after: "simple", in: textView)
            try press("y", on: textView)
            #expect(session.marks.map(\.kind) == [.insert])
            #expect(session.marks.first?.text == " anxd simpley")
        }

        @Test func pasteAddsWordsAtABareCaretButNotOverASelection() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("callout-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString(" gladly", forType: .string)
            textView.pasteboard = pasteboard
            let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

            textView.setSelectedRange((textView.string as NSString).range(of: "approach"))
            #expect(!textView.validateUserInterfaceItem(paste))
            textView.paste(nil)
            #expect(session.marks.isEmpty)

            caret(after: "leverage", in: textView)
            #expect(textView.validateUserInterfaceItem(paste))
            textView.paste(nil)
            #expect(session.marks.map(\.text) == [" gladly"])
        }

        /// Selecting words turns typing into a comment on them; a caret adds words again.
        @Test func typingOnASelectionCommentsAndAtTheCaretAddsWords() async throws {
            let harness = await makeHarness()
            let session = harness.session
            let textView = try document(harness)
            textView.setSelectedRange((textView.string as NSString).range(of: "approach"))
            try press("v", on: textView)
            #expect(session.marks.map(\.kind) == [.comment])
            #expect(session.marks.first?.anchor.quote == "approach")
        }
    }
}
