import CalloutCore
import CalloutStore
import AppKit
import SwiftUI
import Testing
@testable import CalloutUI

extension OnTheMainThread {
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
            guard let directory = ProcessInfo.processInfo.environment["CALLOUT_SNAPSHOT_DIR"] else { return }
            let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            // In light, and in dark as <name>-dark.png.
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let bitmap = host.snapshotBitmap() else { continue }
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
            }
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
            #expect(mark.note == "Do it.")
            #expect(mark.anchor.quote == "leverage")
            #expect(session.snippetUses == [mark.id: snippet.id])
            #expect(session.feedback().contains("### 1. Comment\n> leverage\nDo it.\n"))
        }

        // MARK: History

        @Test func aPointCommentShowsInItsThumbnail() throws {
            let store = try Store()
            let text = "We will leverage a very robust approach here."
            let point = NSMaxRange((text as NSString).range(of: "very robust"))
            let comment = Mark(kind: .comment, anchor: try #require(Anchor.make(in: text, span: TextSpan(point, point))), note: "Says who?")
            var thumbnails: [Data?] = []
            for marks in [[], [comment]] {
                let request = request(text: text)
                try store.saveReview(request, result: ReviewResult(id: request.id, decision: .feedback, feedback: ""), marks: marks, generalComment: "")
                let detail = try #require(try store.review(request.id))
                thumbnails.append(try #require(HistoryThumbnails.draw(detail)).tiffRepresentation)
            }
            #expect(thumbnails[0] != nil)
            #expect(thumbnails[0] != thumbnails[1])
        }

        @Test func thePageDrawsAPenStrokeAndAThumbnailTheSystemsStrike() throws {
            let text = "We will leverage a very robust approach here."
            let found = (text as NSString).range(of: "very robust")
            let strike = Mark(kind: .delete, anchor: try #require(Anchor.make(in: text, span: TextSpan(found.location, NSMaxRange(found)))))
            let layout = DisplayLayout(document: MarkdownRenderer.render(text, format: .markdown), marks: [strike], removals: [])
            let page = TextStyler.attributedString(layout: layout, marks: [strike], selectedMarkID: nil)
            let thumbnail = TextStyler.attributedString(layout: layout, marks: [strike], selectedMarkID: nil, ornaments: .inText)
            let struck = (page.string as NSString).range(of: "very robust")

            #expect(page.attribute(.strikethroughColor, at: struck.location, effectiveRange: nil) as? NSColor == .clear)
            #expect(BlockDecorator.strikes(in: page) == [BlockFragment.Strike(range: struck, color: Theme.pen)])
            #expect(thumbnail.attribute(.strikethroughColor, at: struck.location, effectiveRange: nil) as? NSColor == Theme.pen)
            #expect(BlockDecorator.strikes(in: thumbnail).isEmpty)
        }

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

        @Test func aFinishedReviewCanBeAskedForAfterTheAppRestarts() throws {
            _ = NSApplication.shared
            let store = try Store()
            let first = ReviewCoordinator(presentsWindows: false, store: store)
            let request = request()
            first.open(request)
            let window = try #require(first.windows[request.id])
            window.session.addMark(.delete, span: TextSpan(19, 31))
            window.finish(.feedback)

            // Another run of the app, with the same database and nothing in memory.
            let later = ReviewCoordinator(presentsWindows: false, store: store)
            let byID = try #require(later.rememberedResult(id: request.id, sessionId: nil))
            #expect(byID.decision == .feedback)
            #expect(byID.feedback?.hasPrefix("## Feedback on Plan: rate limiting") == true)
            #expect(later.rememberedResult(id: nil, sessionId: "s-1")?.id == request.id)
            #expect(later.rememberedResult(id: nil, sessionId: nil)?.id == request.id)
            #expect(later.rememberedResult(id: nil, sessionId: "another-session") == nil)
            #expect(later.rememberedResult(id: UUID(), sessionId: nil) == nil)
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

        // MARK: Answers that would drop marks

        @Test func approvingWithMarksAsksFirst() throws {
            _ = NSApplication.shared
            let coordinator = ReviewCoordinator(presentsWindows: false)
            var results: [ReviewResult] = []

            func review(answering answer: NSApplication.ModalResponse) throws -> (ReviewWindowController, [String]) {
                let request = request()
                coordinator.open(request) { results.append($0) }
                let window = try #require(coordinator.windows[request.id])
                var asked: [String] = []
                window.ask = { message, _, _ in
                    asked.append(message)
                    return answer
                }
                window.session.addMark(.delete, span: TextSpan(19, 31))
                window.finish(.approve)
                return (window, asked)
            }

            // "Send Feedback": the marks go after all.
            var (_, asked) = try review(answering: .alertFirstButtonReturn)
            #expect(asked == ["Approve without your feedback?"])
            #expect(results.last?.decision == .feedback)

            // "Approve Anyway".
            (_, asked) = try review(answering: .alertSecondButtonReturn)
            #expect(results.last?.decision == .approve)

            // "Keep Reviewing": nothing is answered and the window stays.
            let count = results.count
            let (window, _) = try review(answering: .alertThirdButtonReturn)
            #expect(results.count == count)
            #expect(coordinator.windows[window.session.request.id] != nil)
        }

        @Test func approvingWithNothingMarkedDoesNotAsk() throws {
            _ = NSApplication.shared
            let coordinator = ReviewCoordinator(presentsWindows: false)
            let request = request()
            var result: ReviewResult?
            coordinator.open(request) { result = $0 }
            let window = try #require(coordinator.windows[request.id])
            window.ask = { _, _, _ in
                Issue.record("should not ask")
                return .alertFirstButtonReturn
            }
            window.finish(.approve)
            #expect(result?.decision == .approve)
        }

        @Test func applyingOnlyEditsDoesNotAsk() throws {
            _ = NSApplication.shared
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("callout-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            var announced: [String] = []
            let coordinator = ReviewCoordinator(presentsWindows: false, pasteboard: pasteboard) { announced.append($0) }
            let request = ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown), origin: .hotkey,
                metadata: ReviewMetadata(title: "Selection"), reply: .clipboard, modes: [.feedback, .applyEdits]
            )
            var result: ReviewResult?
            coordinator.open(request) { result = $0 }
            let window = try #require(coordinator.windows[request.id])
            var asked: [String] = []
            window.ask = { message, _, _ in
                asked.append(message)
                return .alertSecondButtonReturn
            }
            window.session.addMark(.delete, span: TextSpan(19, 31))
            window.finish(.applyEdits)
            // Only edits: no question.
            #expect(asked.isEmpty)
            #expect(result?.editedText == "We will leverage a approach here.")
            #expect(pasteboard.string(forType: .string) == "We will leverage a approach here.")
            #expect(announced == ["Corrected text copied"])
        }

        @Test func theButtonsSayWhereTheResponseGoes() throws {
            _ = NSApplication.shared
            func session(_ origin: ReviewOrigin, _ reply: ReplyChannel) -> ReviewSession {
                ReviewSession(request: ReviewRequest(
                    content: .text("We will leverage a very robust approach here.", format: .markdown), origin: origin,
                    reply: reply, modes: [.feedback, .applyEdits]
                ))
            }
            // Nobody waits for a selection, a dropped file or the clipboard: the response is copied.
            for origin in [ReviewOrigin.hotkey, .service, .fileDrop, .share] {
                let copied = session(origin, .clipboard)
                #expect(copied.feedbackAction == "Copy Feedback")
                #expect(copied.editsAction == "Copy Corrected Text")
            }
            // Claude Code waits for it.
            let sent = session(.lastReply, .stdout)
            #expect(sent.feedbackAction == "Send Feedback")
            #expect(sent.editsAction == "Apply Edits")

            // Leaving comments out of the corrected text is asked about in the same words.
            let coordinator = ReviewCoordinator(presentsWindows: false, pasteboard: NSPasteboard(name: NSPasteboard.Name("callout-test-\(UUID().uuidString)"))) { _ in }
            let request = ReviewRequest(
                content: .text("We will leverage a very robust approach here.", format: .markdown), origin: .hotkey,
                reply: .clipboard, modes: [.feedback, .applyEdits]
            )
            coordinator.open(request)
            let window = try #require(coordinator.windows[request.id])
            var asked: [(String, [String])] = []
            window.ask = { message, _, buttons in
                asked.append((message, buttons))
                return .alertSecondButtonReturn
            }
            window.session.addMark(.delete, span: TextSpan(19, 31))
            window.session.addMark(.comment, span: TextSpan(8, 16), note: "Plainer word?")
            window.finish(.applyEdits)
            #expect(asked.first?.0 == "Copy only the corrected text?")
            #expect(asked.first?.1 == ["Copy Corrected Text", "Keep Reviewing"])
        }

        // MARK: How they look

        @Test func windowsLayOut() throws {
            let store = try Store()
            let samples: [(title: String, origin: ReviewOrigin, text: String, marks: [(MarkKind, String, String?)], approved: Bool)] = [
                ("Plan: rate limiting", .planHook, """
                # Plan: add rate limiting

                The API has no limits today, so a single client can exhaust the pool.

                1. Add a RateLimiter middleware with a token bucket per API key.
                2. Return 429 with a Retry-After header.
                3. We will leverage a very robust approach to testing it.
                """, [(.delete, "very robust ", nil), (.replace, "leverage", "use"), (.comment, "token bucket", "Why not a sliding window?")], false),
                ("Cover letter for Acme", .agentRequest, """
                Dear hiring team,

                I am a passionate, results-driven engineer with a proven track record in delivery. I built browser automation for insurance price comparison and mentored a team of five.
                """, [(.delete, "passionate, results-driven ", nil), (.keep, "mentored a team of five", nil)], false),
                ("Plan: search cache", .planHook, """
                # Plan: make search faster

                Put a cache in front of the session store, so repeated queries skip the disk. Measure latency before and after.
                """, [], true),
            ]
            for (index, sample) in samples.enumerated() {
                let request = ReviewRequest(
                    content: .text(sample.text, format: .markdown), origin: sample.origin,
                    metadata: ReviewMetadata(projectPath: "/Users/ada/projects/api", title: sample.title), reply: .stdout, modes: [.feedback]
                )
                let marks = sample.marks.map { kind, quote, text in
                    let range = (sample.text as NSString).range(of: quote)
                    return Mark(kind: kind, anchor: Anchor.make(in: sample.text, span: TextSpan(range.location, NSMaxRange(range)))!,
                                text: text, note: kind == .comment ? text : nil)
                }
                let feedback = FeedbackFormatter.format(.init(title: sample.title, document: .text(sample.text), marks: marks, generalComment: ""))
                let result = sample.approved
                    ? ReviewResult(id: request.id, decision: .approve)
                    : ReviewResult(id: request.id, decision: .feedback, feedback: feedback)
                try store.saveReview(
                    request, result: result, marks: marks, generalComment: "",
                    at: Date().addingTimeInterval(Double(-3600 * (index * 30 + 1)))
                )
            }
            // Each card shows its page, drawn with its marks.
            let first = try #require(try store.history().first)
            let detail = try #require(try store.review(first.id))
            let thumbnail = try #require(HistoryThumbnails.draw(detail))
            #expect(thumbnail.size == HistoryThumbnails.size)
            snapshot(HistoryView(store: store), size: NSSize(width: 860, height: 520), named: "history")
            snapshot(SnippetSettings(store: store).frame(width: 520, height: 560), size: NSSize(width: 520, height: 560), named: "snippet-settings")
            snapshot(
                SnippetPickerView(snippets: SnippetPickerView.ordered(try store.snippets(), preferred: .plans)) { _ in },
                size: NSSize(width: 340, height: 380), named: "snippet-picker"
            )
        }
    }
}
