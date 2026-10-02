import AnnotatorCore
import AnnotatorStore
import AppKit
import SwiftUI
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Saved comments and history")
struct SnippetsAndHistoryTests {
    private func request(_ origin: ReviewOrigin = .planHook, text: String = "We will leverage a very robust approach here.") -> ReviewRequest {
        ReviewRequest(
            content: .text(text, format: .markdown), origin: origin,
            metadata: ReviewMetadata(projectPath: "/work/app", sessionId: "s-1", title: "Plan: rate limiting"),
            reply: .hookDecision, modes: [.feedback, .approve]
        )
    }

    private func snapshot(_ view: some View, size: NSSize, named name: String) {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"] else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: Picker

    @Test func thePickerPutsTheContextOfTheReviewFirst() throws {
        let snippets = try Store().snippets()
        #expect(SnippetContext.preferred(for: request(.planHook)) == .plans)
        #expect(SnippetContext.preferred(for: request(.agentRequest)) == .documents)
        #expect(SnippetContext.preferred(for: request(.hotkey)) == .gitlab)

        let ordered = SnippetPickerView.ordered(snippets, preferred: .documents)
        #expect(ordered.first?.context == .documents)
        #expect(ordered.count == snippets.count)
        #expect(ordered.map(\.context).reduce(into: [SnippetContext]()) { if $0.last != $1 { $0.append($1) } }
            == [.documents, .plans, .gitlab, .blog])
    }

    @Test func thePickerFiltersByEveryWordTyped() throws {
        let snippets = try Store().snippets()
        #expect(SnippetPickerView.matching(snippets, query: "").count == snippets.count)
        #expect(SnippetPickerView.matching(snippets, query: "simplify").map(\.text) == ["Too complex, simplify."])
        #expect(SnippetPickerView.matching(snippets, query: "TOO comp").map(\.text) == ["Too complex, simplify."])
        #expect(SnippetPickerView.matching(snippets, query: "too zebra").isEmpty)
    }

    @Test func aSnippetBecomesACommentThatRemembersWhereItCameFrom() throws {
        let store = try Store()
        let session = ReviewSession(request: request())
        session.loadSnippets = { (try? store.snippets()) ?? [] }
        let snippet = try #require(session.loadSnippets().first)

        let anchor = Anchor.make(in: session.source, span: TextSpan(8, 16))
        let mark = try #require(session.addComment(from: snippet, anchor: anchor))
        #expect(mark.kind == .comment)
        #expect(mark.note == "Too complex, simplify.")
        #expect(mark.anchor.quote == "leverage")
        #expect(session.snippetUses == [mark.id: snippet.id])
        #expect(session.feedback().contains("### 1. Comment\n> leverage\nToo complex, simplify.\n"))
    }

    // MARK: History

    @Test func aFinishedReviewGoesIntoTheHistory() throws {
        _ = NSApplication.shared
        let store = try Store()
        let coordinator = ReviewCoordinator(presentsWindows: false, store: store)
        let request = request()
        coordinator.open(request)
        let window = try #require(coordinator.windows[request.id])
        let snippet = try #require(window.session.loadSnippets().first)

        window.session.addMark(.delete, span: TextSpan(19, 31), note: "filler")
        window.session.addComment(from: snippet, anchor: Anchor.make(in: window.session.source, span: TextSpan(8, 16)))
        window.session.generalComment = "  Shorter overall. \n"
        window.finish(.feedback)

        let saved = try #require(try store.history().first)
        #expect(saved.id == request.id)
        #expect(saved.title == "Plan: rate limiting")
        #expect(saved.markCount == 2)
        #expect(saved.decision == .feedback)

        let detail = try #require(try store.review(request.id))
        // Marks are kept in the order they appear in the document.
        #expect(detail.marks.map(\.kind) == [.comment, .delete])
        #expect(detail.generalComment == "Shorter overall.")
        #expect(detail.feedback?.hasPrefix("## Feedback on Plan: rate limiting") == true)
        #expect(try store.history(matching: "shorter").count == 1)
    }

    @Test func approvalsAreKeptAndCancelledReviewsAreNot() throws {
        _ = NSApplication.shared
        let store = try Store()
        let coordinator = ReviewCoordinator(presentsWindows: false, store: store)

        let approved = request()
        coordinator.open(approved)
        coordinator.windows[approved.id]?.finish(.approve)

        let cancelled = request()
        coordinator.open(cancelled)
        coordinator.windows[cancelled.id]?.finish(.cancel)

        #expect(try store.history().map(\.id) == [approved.id])
        #expect(try store.history().first?.decision == .approve)
    }

    // MARK: How they look

    @Test func windowsLayOut() throws {
        let store = try Store()
        let text = "We will leverage a very robust approach here."
        for (index, title) in ["Plan: rate limiting", "Cover letter for Acme", "Selection from Safari"].enumerated() {
            let origin: ReviewOrigin = [.planHook, .agentRequest, .hotkey][index]
            let request = ReviewRequest(
                content: .text(text, format: .markdown), origin: origin,
                metadata: ReviewMetadata(projectPath: "/Users/ada/projects/api", title: title), reply: .stdout, modes: [.feedback]
            )
            let range = (text as NSString).range(of: "very robust ")
            let mark = Mark(kind: .delete, anchor: Anchor.make(in: text, span: TextSpan(range.location, NSMaxRange(range)))!, note: "filler")
            let feedback = FeedbackFormatter.format(.init(title: title, document: .text(text), marks: [mark], generalComment: "Too complex, simplify."))
            try store.saveReview(
                request, result: ReviewResult(id: request.id, decision: .feedback, feedback: feedback),
                marks: [mark], generalComment: "Too complex, simplify.", at: Date().addingTimeInterval(Double(-3600 * (index * 30 + 1)))
            )
        }
        snapshot(HistoryView(store: store), size: NSSize(width: 860, height: 520), named: "history")
        snapshot(SnippetSettings(store: store).frame(width: 520, height: 560), size: NSSize(width: 520, height: 560), named: "snippet-settings")
        snapshot(
            SnippetPickerView(snippets: SnippetPickerView.ordered(try store.snippets(), preferred: .plans)) { _ in },
            size: NSSize(width: 340, height: 380), named: "snippet-picker"
        )
    }
}
