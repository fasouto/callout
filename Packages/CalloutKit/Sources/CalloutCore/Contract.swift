import Foundation

// The capture contract. Every way of starting a review produces a `ReviewRequest`
// and gets a `ReviewResult` back; nothing here knows about a specific agent.

public enum ReviewOrigin: String, Codable, Sendable, CaseIterable {
    case planHook = "plan-hook"
    case lastReply = "last-reply"
    case agentRequest = "agent-request"
    case hotkey
    case service
    case fileDrop = "file-drop"
    case share
}

public enum ReplyChannel: String, Codable, Sendable {
    case hookDecision = "hook-decision"
    case stdout
    case clipboard
}

public enum ReviewMode: String, Codable, Sendable, CaseIterable {
    case feedback
    case applyEdits = "apply-edits"
    case approve
}

public enum TextFormat: String, Codable, Sendable {
    case markdown
    case plain
}

public enum ReviewContent: Equatable, Sendable {
    case text(String, format: TextFormat)
    /// A file the app opens itself. PDF only for now; text files are sent as `.text`.
    case file(path: String)
}

extension ReviewContent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, format, path }
    private enum Kind: String, Codable { case text, file }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(
                try container.decode(String.self, forKey: .text),
                format: try container.decodeIfPresent(TextFormat.self, forKey: .format) ?? .markdown
            )
        case .file:
            self = .file(path: try container.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let format):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(format, forKey: .format)
        case .file(let path):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

public struct ReviewMetadata: Codable, Equatable, Sendable {
    public var sourceApp: String?
    public var projectPath: String?
    public var sessionId: String?
    public var title: String?
    /// Where text content was read from, when it came from a file.
    public var filePath: String?
    /// The capture before terminal cleanup, so the app can offer a raw toggle.
    public var rawCapture: String?

    public init(
        sourceApp: String? = nil,
        projectPath: String? = nil,
        sessionId: String? = nil,
        title: String? = nil,
        filePath: String? = nil,
        rawCapture: String? = nil
    ) {
        self.sourceApp = sourceApp
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.title = title
        self.filePath = filePath
        self.rawCapture = rawCapture
    }
}

public struct ReviewRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var content: ReviewContent
    public var origin: ReviewOrigin
    public var metadata: ReviewMetadata
    public var reply: ReplyChannel
    public var modes: [ReviewMode]

    public init(
        id: UUID = UUID(),
        content: ReviewContent,
        origin: ReviewOrigin,
        metadata: ReviewMetadata = ReviewMetadata(),
        reply: ReplyChannel,
        modes: [ReviewMode]
    ) {
        self.id = id
        self.content = content
        self.origin = origin
        self.metadata = metadata
        self.reply = reply
        self.modes = modes
    }
}

public enum ReviewDecision: String, Codable, Sendable {
    case approve
    case feedback
    case cancel
}

public struct ReviewResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var decision: ReviewDecision
    /// Structured markdown produced by `FeedbackFormatter`.
    public var feedback: String?
    /// The source with delete/replace/insert applied. Text content only.
    public var editedText: String?

    public init(id: UUID, decision: ReviewDecision, feedback: String? = nil, editedText: String? = nil) {
        self.id = id
        self.decision = decision
        self.feedback = feedback
        self.editedText = editedText
    }
}
