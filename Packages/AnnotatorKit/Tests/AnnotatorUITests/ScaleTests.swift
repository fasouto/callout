import AnnotatorCore
import AnnotatorStore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

extension OnTheMainThread {
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
            // 100 KB, ten times a long plan. A change sets only its own part of the
            // page again; setting all of it took seconds per keystroke at a megabyte.
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
            // Words typed in place of struck ones, one key at a time.
            let replaced = page.range(of: "Section 245")
            let replacedSpan = try #require(session.sourceSpan(forView: replaced.location..<NSMaxRange(replaced)))
            let placed = try #require(session.replaceInPlace(span: replacedSpan))
            settle(window)
            var caret = placed.caret
            let keystroke = clock.measure {
                caret = session.type("x", atView: caret) ?? caret
                settle(window)
            }
            print("scale: \(source.utf16.count) units; open \(opening), mark \(marking), note \(typing), key \(keystroke)")
            // Each change includes the 50 ms that `settle` waits.
            #expect(opening < .seconds(1.5))
            #expect(marking < .milliseconds(200))
            #expect(typing < .milliseconds(200))
            #expect(keystroke < .milliseconds(200))
        }

        @Test func aLongPageIsLaidOutToItsEndAfterItOpens() throws {
            _ = NSApplication.shared
            let session = ReviewSession(request: ReviewRequest(
                content: .text(Self.longDocument(sections: 500), format: .markdown), origin: .agentRequest, reply: .stdout, modes: [.feedback]
            ))
            session.announce = { _ in }
            let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
            settle(window)
            let textView = try #require(findTextView(in: window.contentView))

            // The rest is laid out a part at a time; then the page is as tall as its text.
            let deadline = Date().addingTimeInterval(20)
            var height = textView.frame.height
            var unchangedSince = Date()
            while Date() < deadline, Date().timeIntervalSince(unchangedSince) < 0.5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                if textView.frame.height != height { height = textView.frame.height; unchangedSince = Date() }
            }
            #expect(abs(textView.frame.height - textView.layoutHeight()) < 1)
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
}
