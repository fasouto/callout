import Darwin
import Foundation

// A note on closing descriptors. A descriptor number is reused as soon as it is
// closed, so a thread that is about to read or accept on a number another thread
// just closed would operate on somebody else's socket. Each descriptor here is
// therefore closed only by the thread that reads from it; other threads ask it
// to stop (`shutdown` for a connection, a wake-up pipe for the listener).

/// One client talking to the app.
public final class SocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var isClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// False once the client has gone away or the connection was closed.
    public var isOpen: Bool {
        lock.withLock { !isClosed }
    }

    /// Sends a message. Returns false when the client is no longer there.
    @discardableResult
    public func send(_ message: ServerMessage) -> Bool {
        guard let line = try? Wire.line(message) else { return false }
        return lock.withLock {
            guard !isClosed else { return false }
            do {
                try Socket.write(line, to: descriptor)
                return true
            } catch {
                return false
            }
        }
    }

    /// Ends the conversation. The reading thread notices and releases the descriptor.
    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    /// Reads until the client goes away or the connection is closed. Runs on the
    /// connection's own thread, which is the only one that closes the descriptor.
    fileprivate func readMessages(_ handle: (ClientMessage) -> Void) {
        var buffer = LineBuffer()
        reading: while let chunk = try? Socket.read(from: descriptor) {
            buffer.append(chunk)
            while let line = buffer.nextLine() {
                guard let message = try? JSONDecoder().decode(ClientMessage.self, from: line) else {
                    send(.error("The message could not be understood."))
                    break reading
                }
                handle(message)
            }
        }
        lock.withLock {
            isClosed = true
            Darwin.close(descriptor)
        }
    }
}

/// The app's side: listens on the socket and hands each message to a handler.
/// The handler runs on a background thread, one per connection.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ClientMessage, SocketConnection) -> Void

    public let path: String
    private let lock = NSLock()
    /// Write end of the pipe that wakes the accepting thread to stop. -1 when not listening.
    private var wake: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    /// Starts listening.
    /// - Throws: `SocketError.alreadyRunning` when another process answers on the socket.
    public func start(handler: @escaping Handler) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if FileManager.default.fileExists(atPath: path) {
            // A socket file with nobody behind it is left over from a crash.
            if let probe = try? Socket.connect(to: path) {
                Darwin.close(probe)
                throw SocketError.alreadyRunning
            }
            unlink(path)
        }

        let listener = try Socket.listen(at: path)
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else {
            let code = errno
            Darwin.close(listener)
            unlink(path)
            throw SocketError.system(call: "pipe", code: code)
        }
        let wakeRead = pipeEnds[0]
        lock.withLock { wake = pipeEnds[1] }

        let thread = Thread {
            accepting: while true {
                var entries = [
                    pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                ]
                let status = poll(&entries, 2, -1)
                if status < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // Anything on the pipe, including its closing, means stop.
                if entries[1].revents != 0 { break }
                guard entries[0].revents & Int16(POLLIN) != 0 else { break }

                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    break accepting
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Self.serve(SocketConnection(descriptor: client), handler: handler)
            }
            Darwin.close(listener)
            Darwin.close(wakeRead)
        }
        thread.name = "callout.ipc.accept"
        thread.start()
    }

    private static func serve(_ connection: SocketConnection, handler: @escaping Handler) {
        let thread = Thread {
            connection.readMessages { handler($0, connection) }
        }
        thread.name = "callout.ipc.connection"
        thread.start()
    }

    /// Stops accepting connections and removes the socket file. Connections that
    /// are already open stay open until their client leaves.
    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            let current = wake
            wake = -1
            return current
        }
        guard descriptor >= 0 else { return }
        unlink(path)
        // Closing the write end wakes the accepting thread, which then closes the listener.
        Darwin.close(descriptor)
    }
}
