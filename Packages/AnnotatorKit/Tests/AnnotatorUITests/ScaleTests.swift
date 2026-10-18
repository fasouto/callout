import AnnotatorCore
import AnnotatorStore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// A review of a long document stays responsive, and a finished review
/// leaves nothing behind in an app that runs for weeks.
@MainActor
@Suite("Scale")
struct ScaleTests {
    /// What replies are made of, about 400 bytes a section.
    private static func longDocument(sections: Int) -> String {
        (0..<sections).map { index in
            """
            ## Section \(index)

            The **service** reads `config_\(index).toml` before it starts, and it's slow when the cache is cold.
            See [issue \(index)](https://example.com/issues/\(index)) for the measurements.

            1. Warm the cache
               - only for keys used in the last *hour*
            2. Read the file once

            ```swift
            let value\(index) = try load("config_\(index).toml")
            ```

            | Key | Default |
            |---|---|
            | `timeout_\(index)` | 30 |

            > A quotation about section \(index).

            """
        }.joined(separator: "\n")
    }

    private func findTextView(in view: NSView?) -> AnnotationTextView? {
        guard let view else { return nil }
        if let textView = view as? AnnotationTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func aLongDocumentOpensAndTakesMarksQuickly() throws {
        _ = NSApplication.shared
        // 100 KB, ten times a long plan. Every change restyles the whole page, so
        // a megabyte takes seconds per keystroke; this keeps that from creeping down.
        let source = Self.longDocument(sections: 250)
        let clock = ContinuousClock()

        var session: ReviewSession!
        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let opening = clock.measure {
            session = ReviewSession(request: ReviewRequest(
                content: .text(source, format: .markdown), origin: .agentRequest, reply: .stdout, modes: [.feedback, .applyEdits]
            ))
            session.announce = { _ in }
            window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
            settle(window)
        }
        let textView = try #require(findTextView(in: window.contentView))
        #expect(textView.string.utf16.count == session.layout.text.utf16.count)

        // A mark near the end, where a whole-page restyle would cost the most.
        let page = textView.string as NSString
        let target = page.range(of: "Section 247")
        let span = try #require(session.sourceSpan(forView: target.location..<NSMaxRange(target)))
        let marking = clock.measure {
            session.addMark(.delete, span: span)
            settle(window)
        }
        let typing = clock.measure {
            if let id = session.marks.last?.id { session.update(id, note: "Too long") }
            settle(window)
        }
        print("scale: \(source.utf16.count) units; open \(opening), mark \(marking), note \(typing)")
        #expect(opening < .seconds(2))
        #expect(marking < .milliseconds(500))
        #expect(typing < .milliseconds(500))
    }

    @Test func aFinishedReviewIsReleased() throws {
        _ = NSApplication.shared
        weak var controller: ReviewWindowController?
        weak var session: ReviewSession?
        let coordinator = ReviewCoordinator(presentsWindows: false, store: try Store())
        try autoreleasepool {
            let request = ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown),
                origin: .planHook, reply: .hookDecision, modes: [.feedback, .approve]
            )
            coordinator.open(request) { _ in }
            let window = try #require(coordinator.windows[request.id])
            controller = window
            session = window.session
            window.session.addMark(.delete, span: TextSpan(19, 31))
            window.finish(.feedback)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(controller == nil)
        #expect(session == nil)
    }
}
