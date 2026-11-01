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

    public struct ToolInput: Decodable, Equatable, Sendable {
        /// Claude Code injects the plan's markdown and its file path for `ExitPlanMode`.
        public var plan: String?
        public var planFilePath: String?
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
    public static func output(for result: ReviewResult) -> String? {
        let decision: [String: Any]
        switch result.decision {
        case .cancel:
            return nil
        case .approve:
            decision = [
                "behavior": "allow",
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
