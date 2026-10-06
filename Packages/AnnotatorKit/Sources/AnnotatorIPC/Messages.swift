import AnnotatorCore
import Foundation

/// Where the app and its command-line tool meet.
public enum AnnotatorPaths {
    /// Placeholder until the project has its own identifier; must match `project.yml`.
    public static let bundleIdentifier = "me.fabiosouto.Annotator"

    public static var supportDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/Annotator"
    }

    /// The socket the app listens on. `ANNOTATOR_SOCKET` overrides it, for tests and development.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["ANNOTATOR_SOCKET"], !override.isEmpty { return override }
        return supportDirectory + "/annotator.sock"
    }
}

// The protocol: one JSON object per line in each direction, each carrying the
// protocol version `v` and a `type`.

public let protocolVersion = 1

public enum ClientMessage: Equatable, Sendable {
    /// Open a review. Answered with `accepted`, then `result` when the user responds.
    case review(ReviewRequest)
    /// Ask for a finished review: by id, else the latest of a session, else the latest of all.
    case resultQuery(id: UUID?, sessionId: String?)
    case ping
}

public enum ServerMessage: Equatable, Sendable {
    case accepted(id: UUID)
    case result(ReviewResult)
    /// The review asked about is still open.
    case pending(id: UUID)
    /// No review matches the query.
    case unknown
    case pong(appVersion: String)
    case error(String)
}

private enum MessageKeys: String, CodingKey {
    case v, type, request, result, id, sessionId, appVersion, message
}

extension ClientMessage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "review":
            self = .review(try container.decode(ReviewRequest.self, forKey: .request))
        case "result?":
            self = .resultQuery(
                id: try container.decodeIfPresent(UUID.self, forKey: .id),
                sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId)
            )
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MessageKeys.self)
        try container.encode(protocolVersion, forKey: .v)
        switch self {
        case .review(let request):
            try container.encode("review", forKey: .type)
            try container.encode(request, forKey: .request)
        case .resultQuery(let id, let sessionId):
            try container.encode("result?", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }
}

extension ServerMessage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "accepted":
            self = .accepted(id: try container.decode(UUID.self, forKey: .id))
        case "result":
            self = .result(try container.decode(ReviewResult.self, forKey: .result))
        case "pending":
            self = .pending(id: try container.decode(UUID.self, forKey: .id))
        case "unknown":
            self = .unknown
        case "pong":
            self = .pong(appVersion: try container.decode(String.self, forKey: .appVersion))
        case "error":
            self = .error(try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MessageKeys.self)
        try container.encode(protocolVersion, forKey: .v)
        switch self {
        case .accepted(let id):
            try container.encode("accepted", forKey: .type)
            try container.encode(id, forKey: .id)
        case .result(let result):
            try container.encode("result", forKey: .type)
            try container.encode(result, forKey: .result)
        case .pending(let id):
            try container.encode("pending", forKey: .type)
            try container.encode(id, forKey: .id)
        case .unknown:
            try container.encode("unknown", forKey: .type)
        case .pong(let appVersion):
            try container.encode("pong", forKey: .type)
            try container.encode(appVersion, forKey: .appVersion)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Splits a byte stream into the lines of the protocol.
struct LineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) {
        data.append(chunk)
    }

    /// The next complete line, without its line break.
    mutating func nextLine() -> Data? {
        guard let end = data.firstIndex(of: 0x0A) else { return nil }
        let line = data[data.startIndex..<end]
        data = Data(data[data.index(after: end)...])
        return Data(line)
    }
}

enum Wire {
    /// One message as a line. JSON escapes line breaks inside strings, so the
    /// encoded object never contains one.
    static func line(_ message: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }
}
