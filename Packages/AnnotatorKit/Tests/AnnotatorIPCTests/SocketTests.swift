import AnnotatorCore
import Foundation
import Testing
@testable import AnnotatorIPC

/// A socket path short enough for `sockaddr_un`, unique per test.
func temporarySocketPath() -> String {
    NSTemporaryDirectory() + "ant-\(UUID().uuidString.prefix(8)).sock"
}

func sampleRequest(session: String? = nil) -> ReviewRequest {
    ReviewRequest(
        content: .text("# Plan", format: .markdown),
        origin: .agentRequest,
        metadata: ReviewMetadata(sessionId: session, title: "Plan"),
        reply: .stdout,
        modes: [.feedback]
    )
}

@Suite("Socket protocol")
struct ProtocolTests {
    private func object(_ message: some Encodable) throws -> [String: Any] {
        let line = try Wire.line(message)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        return try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func messagesCarryVersionAndType() throws {
        let review = try object(ClientMessage.review(sampleRequest()))
        #expect(review["v"] as? Int == 1)
        #expect(review["type"] as? String == "review")
        #expect((review["request"] as? [String: Any])?["origin"] as? String == "agent-request")

        let id = UUID()
        let query = try object(ClientMessage.resultQuery(id: id, sessionId: nil))
        #expect(query["type"] as? String == "result?")
        #expect(query["id"] as? String == id.uuidString)
        #expect(query["sessionId"] == nil)

        #expect(try object(ServerMessage.pong(appVersion: "0.1.0"))["appVersion"] as? String == "0.1.0")
        #expect(try object(ServerMessage.unknown)["type"] as? String == "unknown")
    }

    @Test func messagesRoundTrip() throws {
        let id = UUID()
        let client: [ClientMessage] = [
            .review(sampleRequest(session: "abc")), .resultQuery(id: id, sessionId: nil),
            .resultQuery(id: nil, sessionId: "abc"), .resultQuery(id: nil, sessionId: nil), .ping,
        ]
        for message in client {
            #expect(try JSONDecoder().decode(ClientMessage.self, from: Wire.line(message)) == message)
        }
        let server: [ServerMessage] = [
            .accepted(id: id), .result(ReviewResult(id: id, decision: .feedback, feedback: "## Feedback\n\nline two\n")),
            .pending(id: id), .unknown, .pong(appVersion: "dev"), .error("nope"),
        ]
        for message in server {
            #expect(try JSONDecoder().decode(ServerMessage.self, from: Wire.line(message)) == message)
        }
    }

    @Test func unknownTypesAreRejected() {
        let data = Data(#"{"v":1,"type":"selfdestruct"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClientMessage.self, from: data) }
    }

    @Test func linesAreReassembledFromChunks() {
        var buffer = LineBuffer()
        buffer.append(Data("{\"a\":".utf8))
        #expect(buffer.nextLine() == nil)
        buffer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        #expect(buffer.nextLine() == Data("{\"a\":1}".utf8))
        #expect(buffer.nextLine() == Data("{\"b\":2}".utf8))
        #expect(buffer.nextLine() == nil)
        buffer.append(Data(":3}\n".utf8))
        #expect(buffer.nextLine() == Data("{\"c\":3}".utf8))
    }

    @Test func socketPathCanBeOverridden() {
        #expect(AnnotatorPaths.socketPath(environment: [:]).hasSuffix("/Library/Application Support/Annotator/annotator.sock"))
        #expect(AnnotatorPaths.socketPath(environment: ["ANNOTATOR_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
    }
}

@Suite("Socket client and server")
struct SocketTests {
    @Test func requestGetsAcceptedThenAnswered() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { message, connection in
            switch message {
            case .ping:
                connection.send(.pong(appVersion: "test"))
            case .review(let request):
                connection.send(.accepted(id: request.id))
                connection.send(.result(ReviewResult(id: request.id, decision: .feedback, feedback: "ok")))
            case .resultQuery:
                connection.send(.unknown)
            }
        }
        defer { server.stop() }

        let client = try SocketClient(path: path)
        try client.send(.ping)
        #expect(try client.receive(timeout: 2) == .pong(appVersion: "test"))

        let request = sampleRequest()
        try client.send(.review(request))
        #expect(try client.receive(timeout: 2) == .accepted(id: request.id))
        #expect(try client.receive(timeout: 2) == .result(ReviewResult(id: request.id, decision: .feedback, feedback: "ok")))
    }

    @Test func largeMessagesArriveWhole() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { message, connection in
            guard case .review(let request) = message, case .text(let text, _) = request.content else { return }
            connection.send(.result(ReviewResult(id: request.id, decision: .feedback, editedText: text)))
        }
        defer { server.stop() }

        // Far larger than one read, with line breaks and non-ASCII text inside.
        let text = String(repeating: "línea con ñ y 🚀\n", count: 40_000)
        var request = sampleRequest()
        request.content = .text(text, format: .plain)

        let client = try SocketClient(path: path)
        try client.send(.review(request))
        guard case .result(let result) = try client.receive(timeout: 10) else {
            Issue.record("expected a result")
            return
        }
        #expect(result.editedText == text)
    }

    @Test func clientNoticesTheServerGoingAway() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { _, connection in connection.close() }
        defer { server.stop() }

        let client = try SocketClient(path: path)
        try client.send(.ping)
        #expect(throws: SocketError.closed) { try client.receive(timeout: 2) }
    }

    @Test func serverNoticesTheClientGoingAway() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        let seen = Locked<SocketConnection?>(nil)
        try server.start { _, connection in seen.set(connection) }
        defer { server.stop() }

        var client: SocketClient? = try SocketClient(path: path)
        try client?.send(.ping)
        let connection = try #require(waitFor { seen.get() })
        #expect(connection.isOpen)

        client?.close()
        client = nil
        #expect(waitFor { connection.isOpen ? nil : true } == true)
        #expect(connection.send(.unknown) == false)
    }

    @Test func receiveTimesOutWhenNothingComes() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }

        let client = try SocketClient(path: path)
        let started = Date()
        #expect(throws: SocketError.timedOut) { try client.receive(timeout: 0.2) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func nothingListeningMeansNoConnection() {
        #expect(throws: SocketError.self) { try SocketClient(path: temporarySocketPath()) }
    }

    @Test func staleSocketFileIsReplaced() throws {
        let path = temporarySocketPath()
        // A previous run that died left its socket file behind.
        let first = SocketServer(path: path)
        try first.start { _, _ in }
        first.stop()
        FileManager.default.createFile(atPath: path, contents: nil)

        let second = SocketServer(path: path)
        try second.start { _, connection in connection.send(.pong(appVersion: "second")) }
        defer { second.stop() }
        let client = try SocketClient(path: path)
        try client.send(.ping)
        #expect(try client.receive(timeout: 2) == .pong(appVersion: "second"))
    }

    @Test func secondServerOnALiveSocketIsRefused() throws {
        let path = temporarySocketPath()
        let first = SocketServer(path: path)
        try first.start { _, _ in }
        defer { first.stop() }

        #expect(throws: SocketError.alreadyRunning) { try SocketServer(path: path).start { _, _ in } }
        // The first server is still the one answering.
        #expect((try? SocketClient(path: path)) != nil)
    }

    @Test func socketIsPrivateToTheUser() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func overlongPathIsRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: SocketError.pathTooLong) { try SocketClient(path: path) }
    }

    @Test func stoppingRemovesTheSocketFile() throws {
        let path = temporarySocketPath()
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

/// A value shared between the test and server threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

/// Polls until `produce` returns a value, for up to two seconds.
func waitFor<Value>(_ produce: () -> Value?) -> Value? {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if let value = produce() { return value }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return produce()
}
