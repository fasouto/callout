import CalloutCore
import Foundation

// Everything that knows Claude Code's formats lives in this module, so the app
// and the rest of the tool stay agent-agnostic.

public enum ClaudeCode {
    /// The session a tool call or hook runs in. Claude Code sets this in the
    /// environment of Bash and hook subprocesses.
    public static func sessionID(in variables: [String: String]) -> String? {
        variables["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What Claude Code writes to a hook's standard input. Only the fields used here.
public struct HookInput: Decodable, Equatable, Sendable {
    public var hookEventName: String
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var toolName: String?
    public var toolInput: ToolInput?

    /// The tool's input as received, every field kept, so a decision can hand it back untouched.
    public struct ToolInput: Decodable, Equatable, Sendable {
        public var fields: [String: JSONValue]

        public init(fields: [String: JSONValue]) {
            self.fields = fields
        }

        public init(from decoder: Decoder) throws {
            fields = try [String: JSONValue](from: decoder)
        }

        /// Claude Code injects the plan's markdown and its file path for `ExitPlanMode`.
        public var plan: String? { fields["plan"]?.string }
        public var planFilePath: String? { fields["planFilePath"]?.string }
    }

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public static func decode(_ data: Data) -> HookInput? {
        try? JSONDecoder().decode(HookInput.self, from: data)
    }
}

/// Any JSON value, for data that must pass through without being modelled.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? {
        if case .string(let value) = self { return value } else { return nil }
    }

    /// The value as `JSONSerialization` takes it.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundation)
        case .object(let value): return value.mapValues(\.foundation)
        }
    }
}

/// The `PermissionRequest` hook on `ExitPlanMode`: the plan goes to the app, and
/// the user's response becomes the hook's decision.
public enum PlanHook {
    /// The permission mode Claude Code switches to when a plan is approved.
    public static let modeAfterApproval = "acceptEdits"

    /// The review to open for a hook call, or nil when the call is not a plan to review.
    public static func request(for input: HookInput) -> ReviewRequest? {
        guard input.hookEventName == "PermissionRequest", input.toolName == "ExitPlanMode",
              let plan = input.toolInput?.plan,
              !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReviewRequest(
            content: .text(plan, format: .markdown),
            origin: .planHook,
            metadata: ReviewMetadata(
                projectPath: input.cwd,
                sessionId: input.sessionId,
                title: title(of: plan),
                filePath: input.toolInput?.planFilePath
            ),
            reply: .hookDecision,
            modes: [.feedback, .approve]
        )
    }

    /// What the hook prints for a result. Nil means print nothing, which leaves
    /// Claude Code's own dialog in charge.
    /// An allow must carry the tool's input back as `updatedInput`, or Claude Code ignores it.
    public static func output(for result: ReviewResult, input: HookInput) -> String? {
        let decision: [String: Any]
        switch result.decision {
        case .cancel:
            return nil
        case .approve:
            var updatedInput = (input.toolInput?.fields ?? [:]).mapValues(\.foundation)
            if let plan = input.toolInput?.plan { updatedInput["plan"] = plan }
            decision = [
                "behavior": "allow",
                "updatedInput": updatedInput,
                "updatedPermissions": [
                    ["type": "setMode", "mode": modeAfterApproval, "destination": "session"],
                ],
            ]
        case .feedback:
            guard let feedback = result.feedback?.trimmingCharacters(in: .whitespacesAndNewlines), !feedback.isEmpty else {
                return nil
            }
            decision = ["behavior": "deny", "message": denialLead + feedback]
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static let denialLead = """
    The user reviewed this plan in Callout and wants changes. Revise the plan to address every point below, \
    then present it again. Quoted lines are the exact text each point refers to.


    """

    /// The plan's first heading, or a plain name.
    static func title(of plan: String) -> String {
        for line in plan.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return "Plan"
    }
}
