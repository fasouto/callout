import AnnotatorCore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

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

    | Setting | Default |
    |---|---|
    | `RATE_LIMIT_RPS` | 10 |

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
        let window = NSWindow(
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
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.appearance = nil
    }

    private func press(_ characters: String, keyCode: UInt16, in harness: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
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
        try press("d", keyCode: 2, in: harness)
        #expect(session.marks.map(\.kind) == [.delete])
        #expect(session.marks.first?.anchor.quote == "very robust ")

        select("no limits", in: harness)
        try press("K", keyCode: 40, in: harness)
        #expect(session.marks.last?.kind == .keep)
        #expect(session.marks.last?.anchor.quote == "**no limits**")

        // The mark keys never type into the document.
        settle(harness.window)
        #expect(harness.textView.string == session.document.text)
    }

    @Test func keysDoNothingWithoutASelection() throws {
        let harness = try makeHarness()
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
        try press("d", keyCode: 2, in: harness)
        try press("x", keyCode: 7, in: harness)
        #expect(harness.session.marks.isEmpty)
        #expect(harness.textView.string == harness.session.document.text)
        #expect(harness.session.statusMessage != nil)
    }

    @Test func backspaceRemovesTheSelectedMark() throws {
        let harness = try makeHarness()
        select("very robust ", in: harness)
        try press("d", keyCode: 2, in: harness)
        #expect(harness.session.marks.count == 1)

        try press("\u{7F}", keyCode: KeyCode.delete, in: harness)
        #expect(harness.session.marks.isEmpty)
    }

    @Test func aSecondEditOnTheSameTextIsRefused() throws {
        let harness = try makeHarness()
        select("very robust ", in: harness)
        try press("d", keyCode: 2, in: harness)
        settle(harness.window)
        select("robust approach", in: harness)
        try press("d", keyCode: 2, in: harness)
        #expect(harness.session.marks.count == 1)
    }

    // MARK: Writing in the margin

    @Test func replaceKeyOpensTheMarginForWriting() throws {
        let harness = try makeHarness()
        let session = harness.session
        select("leverage", in: harness)
        try press("r", keyCode: 15, in: harness)

        let mark = try #require(session.marks.first)
        #expect(mark.kind == .replace)
        #expect(session.editing == EditTarget(markID: mark.id, field: .text))
        #expect(session.selectedMarkID == mark.id)

        // What is typed in the margin shows in the document as it is typed.
        session.update(mark.id, text: "use")
        settle(harness.window)
        #expect(harness.textView.string.contains("We will leverageuse a very robust"))

        let token = session.documentFocusToken
        session.endEditing()
        #expect(session.editing == nil)
        #expect(session.documentFocusToken == token + 1)
        #expect(session.marks.first?.kind == .replace)
        #expect(session.marks.first?.text == "use")
    }

    @Test func aReplacementLeftEmptyBecomesADeletion() throws {
        let harness = try makeHarness()
        select("leverage", in: harness)
        try press("r", keyCode: 15, in: harness)
        harness.session.endEditing()
        #expect(harness.session.marks.map(\.kind) == [.delete])
        #expect(harness.session.marks.first?.text == nil)
    }

    @Test func commentsAndInsertionsLeftEmptyAreDropped() throws {
        let harness = try makeHarness()
        let session = harness.session

        select("token bucket", in: harness)
        try press("c", keyCode: 8, in: harness)
        #expect(session.marks.map(\.kind) == [.comment])
        #expect(session.editing?.field == .note)
        session.endEditing()
        #expect(session.marks.isEmpty)

        select("websockets", in: harness)
        try press("i", keyCode: 34, in: harness)
        #expect(session.marks.map(\.kind) == [.insert])
        #expect(session.editing?.field == .text)
        session.endEditing()
        #expect(session.marks.isEmpty)

        // Written ones stay.
        select("token bucket", in: harness)
        try press("c", keyCode: 8, in: harness)
        session.update(try #require(session.marks.first).id, note: "Why?")
        session.endEditing()
        #expect(session.marks.first?.note == "Why?")
    }

    @Test func insertionGoesAfterTheSelection() throws {
        let harness = try makeHarness()
        let session = harness.session
        select("websockets", in: harness)
        try press("i", keyCode: 34, in: harness)
        session.update(try #require(session.marks.first).id, text: " or streaming")
        session.endEditing()
        #expect(try session.editedText().contains("cover websockets or streaming."))
    }

    @Test func returnOpensTheSelectedMarkForWriting() throws {
        let harness = try makeHarness()
        let session = harness.session
        select("very robust ", in: harness)
        try press("d", keyCode: 2, in: harness)
        #expect(session.editing == nil)

        try press("\r", keyCode: KeyCode.return, in: harness)
        #expect(session.editing == EditTarget(markID: try #require(session.marks.first).id, field: .note))

        // A keep has nothing to write.
        session.endEditing()
        select("no limits", in: harness)
        try press("k", keyCode: 40, in: harness)
        try press("\r", keyCode: KeyCode.return, in: harness)
        #expect(session.editing == nil)
    }

    @Test func movingTheCaretPicksUpAndLetsGoOfMarks() throws {
        let harness = try makeHarness()
        let session = harness.session
        select("very robust ", in: harness)
        try press("d", keyCode: 2, in: harness)
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

    @Test func aWrittenMarkIsOneUndoStep() throws {
        let harness = try makeHarness()
        let session = harness.session
        let undo = undoable(session)

        select("leverage", in: harness)
        try press("r", keyCode: 15, in: harness)
        let id = try #require(session.marks.first).id
        for text in ["u", "us", "use"] { session.update(id, text: text) }
        // Nothing to undo until the note is finished: ⌘Z belongs to the field while writing.
        #expect(!undo.canUndo)
        session.endEditing()
        #expect(undo.undoActionName == "Replace")

        undo.undo()
        #expect(session.marks.isEmpty)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(session.marks.first?.text == "use")
    }

    @Test func aMarkLeftEmptyLeavesNothingToUndo() throws {
        let harness = try makeHarness()
        let session = harness.session
        let undo = undoable(session)

        select("token bucket", in: harness)
        try press("c", keyCode: 8, in: harness)
        session.endEditing()
        #expect(session.marks.isEmpty)
        #expect(!undo.canUndo)

        // A replacement left empty is a deletion, and that is one step.
        select("leverage", in: harness)
        try press("r", keyCode: 15, in: harness)
        session.endEditing()
        #expect(session.marks.map(\.kind) == [.delete])
        undo.undo()
        #expect(session.marks.isEmpty)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width + 40, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let backdrop = NSView(frame: window.contentLayoutRect)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        view.setFrameOrigin(NSPoint(x: 20, y: 18))
        backdrop.addSubview(view)
        window.contentView = backdrop
        settle(window)
        guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("selection-bar.png"))
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
