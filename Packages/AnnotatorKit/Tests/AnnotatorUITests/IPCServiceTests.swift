import AnnotatorCore
import AnnotatorIPC
import AppKit
import Testing
@testable import AnnotatorUI

/// The app's side of the socket, driven by a real client, with windows kept off screen.
@MainActor
@Suite("Socket service")
struct IPCServiceTests {
    @MainActor
    private final class Harness {
        let path = NSTemporaryDirectory() + "ant-\(UUID().uuidString.prefix(8)).sock"
        let coordinator = ReviewCoordinator(presentsWindows: false)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("annotator-test-\(UUID().uuidString)"))
        var notices: [String] = []
        private(set) var service: IPCService!

        init() throws {
            _ = NSApplication.shared
            service = IPCService(coordinator: coordinator, socketPath: path, pasteboard: pasteboard) { [weak self] in
                self?.notices.append($0)
            }
            try service.start()
        }

        func tearDown() {
            service.stop()
            pasteboard.releaseGlobally()
        }
    }

    private func request(session: String? = nil, reply: ReplyChannel = .stdout) -> ReviewRequest {
        ReviewRequest(
            content: .text("Use the old cache here.", format: .markdown),
            origin: .agentRequest,
            metadata: ReviewMetadata(sessionId: session, title: "Plan"),
            reply: reply,
            modes: [.feedback, .applyEdits]
        )
    }

    /// Waits until `condition` holds. Suspending lets the main queue run, which
    /// is where the service handles what arrives on the socket.
    private func wait(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func open(_ request: ReviewRequest, with client: SocketClient, in harness: Harness) async throws -> ReviewWindowController {
        try client.send(.review(request))
        await wait { harness.coordinator.windows[request.id] != nil }
        #expect(try client.receive(timeout: 2) == .accepted(id: request.id))
        return try #require(harness.coordinator.windows[request.id])
    }

    @Test func reviewIsAnsweredWhenTheUserResponds() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let client = try SocketClient(path: harness.path)
        let request = request()
        let window = try await open(request, with: client, in: harness)

        window.session.addMark(.delete, span: TextSpan(8, 12))
        window.finish(.feedback)

        guard case .result(let result) = try client.receive(timeout: 2) else {
            Issue.record("expected a result")
            return
        }
        #expect(result.id == request.id)
        #expect(result.decision == .feedback)
        #expect(result.feedback == "## Feedback on Plan\n\n### 1. Delete\n> old\n")
        #expect(harness.coordinator.windows.isEmpty)
        // Answered to the requester, so nothing went to the clipboard.
        #expect(harness.pasteboard.string(forType: .string) == nil)
    }

    @Test func applyingEditsReturnsTheText() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let client = try SocketClient(path: harness.path)
        let window = try await open(request(), with: client, in: harness)

        window.session.addMark(.delete, span: TextSpan(8, 12))
        window.finish(.applyEdits)
        #expect(try client.receive(timeout: 2) == .result(
            ReviewResult(id: window.session.request.id, decision: .feedback, editedText: "Use the cache here.")
        ))
    }

    @Test func finishedAndOpenReviewsCanBeAskedFor() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let client = try SocketClient(path: harness.path)
        let first = request(session: "s-1")
        let second = request(session: "s-2")

        func ask(id: UUID? = nil, session: String? = nil) async throws -> ServerMessage {
            let asker = try SocketClient(path: harness.path)
            try asker.send(.resultQuery(id: id, sessionId: session))
            var answer: ServerMessage?
            await wait {
                answer = try? asker.receive(timeout: 0.01)
                return answer != nil
            }
            return try #require(answer)
        }

        #expect(try await ask() == .unknown)
        let window = try await open(first, with: client, in: harness)
        _ = try await open(second, with: client, in: harness)
        #expect(try await ask(id: first.id) == .pending(id: first.id))
        #expect(try await ask(session: "s-2") == .pending(id: second.id))

        window.finish(.approve)
        let approved = ServerMessage.result(ReviewResult(id: first.id, decision: .approve))
        #expect(try await ask(id: first.id) == approved)
        #expect(try await ask(session: "s-1") == approved)
        #expect(try await ask() == approved)
        #expect(try await ask(session: "s-2") == .pending(id: second.id))
        #expect(try await ask(id: UUID()) == .unknown)
    }

    @Test func responseForAGoneRequesterGoesToTheClipboard() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        var client: SocketClient? = try SocketClient(path: harness.path)
        let request = request(session: "s-1")
        let window = try await open(request, with: try #require(client), in: harness)

        // The command-line tool is stopped while the review is still open.
        client?.close()
        client = nil
        await settle()

        window.session.generalComment = "Simplify."
        window.finish(.feedback)
        #expect(harness.pasteboard.string(forType: .string) == "## Feedback on Plan\n\n### General\nSimplify.\n")
        #expect(harness.notices.count == 1)

        // And it can still be collected.
        let asker = try SocketClient(path: harness.path)
        try asker.send(.resultQuery(id: nil, sessionId: "s-1"))
        var answer: ServerMessage?
        await wait {
            answer = try? asker.receive(timeout: 0.01)
            return answer != nil
        }
        guard case .result(let result) = answer else {
            Issue.record("expected the stored result")
            return
        }
        #expect(result.id == request.id)
    }

    @Test func cancellingForAGoneRequesterCopiesNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        var client: SocketClient? = try SocketClient(path: harness.path)
        let window = try await open(request(), with: try #require(client), in: harness)
        client?.close()
        client = nil
        await settle()

        window.finish(.cancel)
        #expect(harness.pasteboard.string(forType: .string) == nil)
        #expect(harness.notices.isEmpty)
    }

    @Test func aSecondServiceOnTheSameSocketIsRefused() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let second = IPCService(coordinator: ReviewCoordinator(presentsWindows: false), socketPath: harness.path)
        #expect(throws: SocketError.alreadyRunning) { try second.start() }
    }
}
