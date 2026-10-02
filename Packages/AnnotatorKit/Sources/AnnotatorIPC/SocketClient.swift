import Darwin
import Foundation

/// The command-line tool's side of the conversation. Blocking, single-threaded.
public final class SocketClient {
    private var descriptor: Int32
    private var buffer = LineBuffer()

    /// Connects, or throws when nothing is listening at `path`.
    public init(path: String) throws {
        descriptor = try Socket.connect(to: path)
    }

    deinit {
        close()
    }

    public func send(_ message: ClientMessage) throws {
        try Socket.write(try Wire.line(message), to: descriptor)
    }

    /// The next message from the app.
    /// - Parameter timeout: nil waits as long as it takes.
    /// - Throws: `SocketError.closed` when the app went away, `.timedOut` when it said nothing in time.
    public func receive(timeout: TimeInterval?) throws -> ServerMessage {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let line = buffer.nextLine() {
                guard let message = try? JSONDecoder().decode(ServerMessage.self, from: line) else {
                    throw SocketError.malformedMessage
                }
                return message
            }
            try Socket.waitReadable(descriptor, timeout: deadline.map { max(0, $0.timeIntervalSinceNow) })
            buffer.append(try Socket.read(from: descriptor))
        }
    }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
