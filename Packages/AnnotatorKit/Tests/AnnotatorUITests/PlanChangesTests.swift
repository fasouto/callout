import AnnotatorCore
import AnnotatorIPC
import AnnotatorStore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Plan changes")
struct PlanChangesTests {
    private static let first = """
    # Plan: add rate limiting

    The API has no limits today, so a single client can exhaust the pool.

    1. Add a RateLimiter middleware
    2. Return 429 with a Retry-After header
    3. Use Redis to share the buckets between workers

    We will leverage a very robust approach here.
    """

    private static let second = """
    # Plan: add rate limiting

    The API has no limits today, so a single client can exhaust the pool.

    1. Add a RateLimiter middleware, with a token bucket per API key
    2. Return 429 with a Retry-After header
    3. Unit tests for the bucket

    We will use a simple approach here.
    """

    private func request(_ plan: String, session: String = "s-1") -> ReviewRequest {
        ReviewRequest(
            content: .text(plan, format: .markdown), origin: .planHook,
            metadata: ReviewMetadata(sessionId: session, title: "Plan"), reply: .hookDecision, modes: [.feedback, .approve]
        )
    }

    private func makeWindow(_ session: ReviewSession) -> (NSWindow, AnnotationTextView)? {
        _ = NSApplication.shared
        let window = SnapshotWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        settle(window)
        func find(_ view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let match = view as? AnnotationTextView { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.contentView).map { (window, $0) }
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func snapshot(_ window: NSWindow, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"], let view = window.contentView else { return }
        // In light, and in dark as <name>-dark.png.
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.snapshotBitmap() else { continue }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
        }
        window.appearance = nil
    }

    @Test func aRevisedPlanShowsWhatChanged() throws {
        let session = ReviewSession(request: request(Self.second), previousVersion: Self.first, planVersion: 2)
        let (window, textView) = try #require(makeWindow(session))

        let changes = try #require(session.changes)
        #expect(changes.added.compactMap { Self.second.slice($0) } == [
            ", with a token bucket per API key", "3. Unit tests for the bucket", "use", "simple",
        ])
        // The text removed since the first version is on the page, where it was.
        #expect(textView.string.contains("Use Redis to share the buckets between workers\n"))
        #expect(textView.string.contains("We will leverageuse a very robust simple approach here."))
        snapshot(window, named: "plan-changes")

        session.showsChanges = false
        settle(window)
        #expect(textView.string == session.document.text)
        #expect(!textView.string.contains("Redis"))
    }

    @Test func removedTextCannotBeMarkedButTheRestCan() throws {
        let session = ReviewSession(request: request(Self.second), previousVersion: Self.first, planVersion: 2)
        let (window, textView) = try #require(makeWindow(session))
        let text = textView.string as NSString

        let removed = text.range(of: "Use Redis to share")
        #expect(session.sourceSpan(forView: removed.location..<NSMaxRange(removed)) == nil)

        let kept = text.range(of: "simple approach")
        let span = try #require(session.sourceSpan(forView: kept.location..<NSMaxRange(kept)))
        #expect(Self.second.slice(span) == "simple approach")
        session.addMark(.delete, span: span)
        settle(window)
        #expect(try session.editedText().hasSuffix("We will use a here."))
        // The feedback is about the new plan only.
        #expect(!session.feedback().contains("Redis"))
    }

    @Test func aFirstPlanOrAnUnchangedOneHasNothingToShow() {
        #expect(ReviewSession(request: request(Self.first)).changes == nil)
        #expect(ReviewSession(request: request(Self.first), previousVersion: Self.first, planVersion: 2).changes == nil)
    }

    @Test func plansOfASessionAreComparedAsTheyArrive() throws {
        _ = NSApplication.shared
        let coordinator = ReviewCoordinator(presentsWindows: false, store: try Store())

        let first = request(Self.first)
        coordinator.open(first)
        let firstWindow = try #require(coordinator.windows[first.id])
        #expect(firstWindow.session.changes == nil)
        #expect(firstWindow.session.planVersion == 1)
        firstWindow.finish(.approve)

        let second = request(Self.second)
        coordinator.open(second)
        let secondWindow = try #require(coordinator.windows[second.id])
        #expect(secondWindow.session.planVersion == 2)
        #expect(secondWindow.session.changes?.removed.contains { $0.text.contains("Redis") } == true)

        // Another session's plan is a first plan.
        let other = request(Self.second, session: "s-2")
        coordinator.open(other)
        #expect(coordinator.windows[other.id]?.session.changes == nil)
    }
}
