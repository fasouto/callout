import CalloutCore
import CalloutIPC
import AppKit

/// Serves the command-line tool: opens reviews it asks for and answers when the
/// user responds.
@MainActor
final class IPCService {
    private struct Finished {
        var result: ReviewResult
        var sessionId: String?
    }

    private let server: SocketServer
    private let coordinator: ReviewCoordinator
    private let pasteboard: NSPasteboard
    private let notify: (String) -> Void
    private var openRequests: [UUID: ReviewRequest] = [:]
    /// Finished reviews, oldest first, so a requester that was stopped can still collect its result.
    /// Kept in memory for now; they move to the history store when it exists.
    private var finished: [Finished] = []

    init(
        coordinator: ReviewCoordinator,
        socketPath: String = CalloutPaths.socketPath(),
        pasteboard: NSPasteboard = .general,
        notify: @escaping (String) -> Void = { Toast.show($0, for: 4) }
    ) {
        self.coordinator = coordinator
        self.pasteboard = pasteboard
        self.notify = notify
        server = SocketServer(path: socketPath)
    }

    /// - Throws: `SocketError.alreadyRunning` when another copy of the app owns the socket.
    func start() throws {
        try server.start { [weak self] message, connection in
            // Messages arrive on the connection's thread; all state lives on the main actor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(message, from: connection) }
            }
        }
    }

    func stop() {
        server.stop()
    }

    private func handle(_ message: ClientMessage, from connection: SocketConnection) {
        switch message {
        case .ping:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            connection.send(.pong(appVersion: version ?? "development"))

        case .review(let request):
            connection.send(.accepted(id: request.id))
            openRequests[request.id] = request
            coordinator.open(request) { [weak self] result in
                self?.finish(request, with: result, for: connection)
            }

        case .resultQuery(let id, let sessionId):
            connection.send(answer(id: id, sessionId: sessionId))
        }
    }

    private func finish(_ request: ReviewRequest, with result: ReviewResult, for connection: SocketConnection) {
        openRequests[request.id] = nil
        finished.append(Finished(result: result, sessionId: request.metadata.sessionId))

        if connection.send(.result(result)) { return }
        // The requester is gone (stopped, timed out, session closed). The work is
        // not lost: it goes to the clipboard and stays available to `callout result`.
        guard request.reply != .clipboard, result.decision == .feedback,
              let text = result.editedText ?? result.feedback else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        notify("The requester is gone. Response copied instead")
    }

    private func answer(id: UUID?, sessionId: String?) -> ServerMessage {
        // What this run of the app finished, then what is still open, then the
        // history: a review finished before the app was restarted is still an answer.
        let remembered = { self.coordinator.rememberedResult(id: id, sessionId: sessionId).map(ServerMessage.result) }
        if let id {
            if let match = finished.last(where: { $0.result.id == id }) { return .result(match.result) }
            return openRequests[id] != nil ? .pending(id: id) : remembered() ?? .unknown
        }
        if let sessionId {
            if let match = finished.last(where: { $0.sessionId == sessionId }) { return .result(match.result) }
            if let open = openRequests.values.first(where: { $0.metadata.sessionId == sessionId }) {
                return .pending(id: open.id)
            }
            return remembered() ?? .unknown
        }
        if let latest = finished.last { return .result(latest.result) }
        return openRequests.keys.first.map { .pending(id: $0) } ?? remembered() ?? .unknown
    }
}
