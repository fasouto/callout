import Darwin
import Foundation

public enum SocketError: Error, Equatable {
    /// Unix socket paths are limited to 103 bytes.
    case pathTooLong
    case system(call: String, code: Int32)
    /// The other side closed the connection.
    case closed
    case timedOut
    /// Another process is already listening on the socket.
    case alreadyRunning
    case malformedMessage
}

/// Thin wrappers over the POSIX calls for Unix stream sockets.
enum Socket {
    static func open() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.system(call: "socket", code: errno) }
        // A write to a closed peer must fail with an error, not kill the process.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let descriptor = try open()
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.system(call: "connect", code: code)
        }
        return descriptor
    }

    static func listen(at path: String) throws -> Int32 {
        var address = try address(for: path)
        let descriptor = try open()
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.system(call: "bind", code: code)
        }
        // Only the user may talk to the app.
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.system(call: "listen", code: code)
        }
        return descriptor
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw errno == EPIPE ? SocketError.closed : SocketError.system(call: "write", code: errno)
                }
                sent += count
            }
        }
    }

    /// Reads what is available. Throws `closed` at end of stream.
    static func read(from descriptor: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { throw SocketError.closed }
            if errno == EINTR { continue }
            // A reset or a descriptor closed under us both mean the conversation is over.
            throw SocketError.closed
        }
    }

    /// Waits until the descriptor is readable. `timeout` nil waits forever.
    static func waitReadable(_ descriptor: Int32, timeout: TimeInterval?) throws {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.map { max(0, Int32($0.timeIntervalSinceNow * 1000)) } ?? -1
            let status = poll(&entry, 1, remaining)
            if status > 0 { return }
            if status == 0 { throw SocketError.timedOut }
            if errno != EINTR { throw SocketError.system(call: "poll", code: errno) }
        }
    }
}
