import AnnotatorCore
import AnnotatorStore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// Set `ANNOTATOR_SNAPSHOT_DIR` to also write the practice review as a PNG.
@MainActor
@Suite("The first review")
struct WelcomeTests {
    private func span(of phrase: String, in session: ReviewSession) throws -> TextSpan {
        let range = (session.source as NSString).range(of: phrase)
        try #require(range.location != NSNotFound, "\(phrase) is in the plan")
        return TextSpan(range.location, NSMaxRange(range))
    }

    @Test func everyWordTheLessonAsksForIsInThePlan() throws {
        let session = ReviewSession(request: Welcome.request(), isWelcome: true)
        let phrases = Lesson.steps.compactMap(\.phrase)
        #expect(phrases == ["very robust and comprehensive", "leverage", "keeps every result forever"])
        for phrase in phrases {
            _ = try span(of: phrase, in: session)
            // Also as displayed, where the Markdown is gone.
            #expect(session.document.text.contains(phrase))
        }
    }

    @Test func eachStepIsDoneByMakingItsMark() throws {
        let session = ReviewSession(request: Welcome.request(), isWelcome: true)
        #expect(Lesson.current(in: session) == 0)

        _ = try #require(session.addMark(.delete, span: try span(of: "very robust and comprehensive", in: session)))
        #expect(Lesson.current(in: session) == 1)

        // A replacement with nothing written yet does not count.
        let replace = try #require(session.addMark(.replace, span: try span(of: "leverage", in: session)))
        #expect(Lesson.current(in: session) == 1)
        session.update(replace.id, text: "use")
        #expect(Lesson.current(in: session) == 2)

        // A comment pinned to a point inside the claim is not about its words.
        let inside = try span(of: "every result", in: session).start
        _ = try #require(session.addMark(.comment, span: TextSpan(inside, inside), note: "Here?"))
        #expect(Lesson.current(in: session) == 2)
        _ = try #require(session.addMark(.comment, span: try span(of: "keeps every result forever", in: session), note: "Stale results?"))
        #expect(Lesson.current(in: session) == 3)
        #expect(session.feedback().contains("> very robust and comprehensive"))
    }

    @Test func aStrayCommentDoesNotQuestionTheClaim() throws {
        let session = ReviewSession(request: Welcome.request(), isWelcome: true)
        _ = try #require(session.addMark(.delete, span: try span(of: "very robust and comprehensive", in: session)))
        _ = try #require(session.addMark(.replace, span: try span(of: "leverage", in: session), text: "use"))
        // A key pressed by chance at the top of the page, and a comment on other words.
        _ = try #require(session.addMark(.comment, span: TextSpan(0, 0), note: "x"))
        _ = try #require(session.addMark(.comment, span: try span(of: "Friday", in: session), note: "Too soon?"))
        #expect(Lesson.current(in: session) == 2)
    }

    @Test func thePracticeIsNeitherKeptNorCopied() throws {
        _ = NSApplication.shared
        let store = try Store()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("annotator-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let coordinator = ReviewCoordinator(presentsWindows: false, store: store, pasteboard: pasteboard) { _ in }

        var received: ReviewResult?
        let id = coordinator.openWelcome { received = $0 }
        let window = try #require(coordinator.windows[id])
        #expect(window.session.isWelcome)
        let session = window.session
        _ = session.addMark(.delete, span: try span(of: "very robust and comprehensive", in: session))
        window.finish(.feedback)

        #expect(received?.decision == .feedback)
        #expect(received?.feedback?.contains("very robust and comprehensive") == true)
        #expect(coordinator.windows[id] == nil)
        #expect(try store.history().isEmpty)
        #expect(pasteboard.string(forType: .string) == "untouched")
    }

    @Test func theLessonSitsAboveTheActionBar() throws {
        _ = NSApplication.shared
        let session = ReviewSession(request: Welcome.request(), isWelcome: true)
        _ = session.addMark(.delete, span: try span(of: "very robust and comprehensive", in: session))
        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"], let view = window.contentView else { return }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.snapshotBitmap() else { continue }
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("welcome-\(suffix).png"))
        }

        let finish = NSHostingView(rootView: WelcomeFinishView(feedback: session.feedback(), setUpHotkey: {}, close: {}))
        finish.frame = NSRect(origin: .zero, size: finish.fittingSize)
        let finishWindow = SnapshotWindow(contentRect: finish.frame, styleMask: [.titled], backing: .buffered, defer: false)
        finishWindow.isReleasedWhenClosed = false
        finishWindow.contentView = finish
        finish.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        if let bitmap = finish.snapshotBitmap() {
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("welcome-handed-in.png"))
        }
    }
}
