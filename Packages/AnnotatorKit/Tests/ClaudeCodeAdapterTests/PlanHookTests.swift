import AnnotatorCore
import Foundation
import Testing
@testable import ClaudeCodeAdapter

/// A `PermissionRequest` hook input as Claude Code documents it for `ExitPlanMode`.
func planHookInput(plan: String? = "# Refactor auth\n\n1. Extract the token store\n", tool: String = "ExitPlanMode") -> Data {
    var toolInput: [String: Any] = ["planFilePath": "/Users/me/.claude/plans/refactor-auth.md"]
    if let plan { toolInput["plan"] = plan }
    let input: [String: Any] = [
        "session_id": "00893aaf-19fa-41d2-8238-13269b9b3ca0",
        "transcript_path": "/Users/me/.claude/projects/-work-app/00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
        "cwd": "/work/app",
        "permission_mode": "plan",
        "hook_event_name": "PermissionRequest",
        "tool_name": tool,
        "tool_input": toolInput,
        "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
    ]
    return try! JSONSerialization.data(withJSONObject: input)
}

@Suite("Plan hook")
struct PlanHookTests {
    @Test func planBecomesAReviewRequest() throws {
        let input = try #require(HookInput.decode(planHookInput()))
        let request = try #require(PlanHook.request(for: input))

        #expect(request.content == .text("# Refactor auth\n\n1. Extract the token store\n", format: .markdown))
        #expect(request.origin == .planHook)
        #expect(request.reply == .hookDecision)
        #expect(request.modes == [.feedback, .approve])
        #expect(request.metadata.title == "Refactor auth")
        #expect(request.metadata.projectPath == "/work/app")
        #expect(request.metadata.sessionId == "00893aaf-19fa-41d2-8238-13269b9b3ca0")
        #expect(request.metadata.filePath == "/Users/me/.claude/plans/refactor-auth.md")
    }

    @Test func otherToolsAndEmptyPlansAreNotReviewed() throws {
        #expect(PlanHook.request(for: try #require(HookInput.decode(planHookInput(tool: "Bash")))) == nil)
        #expect(PlanHook.request(for: try #require(HookInput.decode(planHookInput(plan: nil)))) == nil)
        #expect(PlanHook.request(for: try #require(HookInput.decode(planHookInput(plan: "  \n")))) == nil)
        #expect(HookInput.decode(Data("not json".utf8)) == nil)
        #expect(HookInput.decode(Data("{}".utf8)) == nil)
    }

    @Test func titleIsTheFirstHeading() {
        #expect(PlanHook.title(of: "Intro line\n\n## Add caching\n\n# Later") == "Add caching")
        #expect(PlanHook.title(of: "No headings here") == "Plan")
        #expect(PlanHook.title(of: "#\n### Real title ") == "Real title")
    }

    private func decision(_ output: String?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(try #require(output).utf8)) as? [String: Any]
        let specific = try #require(object?["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        return try #require(specific["decision"] as? [String: Any])
    }

    @Test func approvalAllowsAndSwitchesToAcceptEdits() throws {
        let output = PlanHook.output(for: ReviewResult(id: UUID(), decision: .approve))
        let decision = try decision(output)
        #expect(decision["behavior"] as? String == "allow")
        let updates = try #require(decision["updatedPermissions"] as? [[String: String]])
        #expect(updates == [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
        // One line, so nothing else on standard output can be mistaken for it.
        #expect(output?.contains("\n") == false)
    }

    @Test func feedbackDeniesWithTheFeedbackAsTheMessage() throws {
        let feedback = "## Feedback on Refactor auth\n\n### 1. Delete\n> Extract the token store\nReason: out of scope\n"
        let decision = try decision(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback, feedback: feedback)))
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(message.hasPrefix("The user reviewed this plan in Annotator and wants changes."))
        #expect(message.hasSuffix("### 1. Delete\n> Extract the token store\nReason: out of scope"))
        #expect(decision["updatedPermissions"] == nil)
    }

    @Test func cancelAndEmptyFeedbackPrintNothing() {
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .cancel)) == nil)
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback, feedback: " \n")) == nil)
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback)) == nil)
    }

    @Test func sessionComesFromTheEnvironment() {
        #expect(ClaudeCode.sessionID(in: ["CLAUDE_CODE_SESSION_ID": "abc"]) == "abc")
        #expect(ClaudeCode.sessionID(in: ["CLAUDE_CODE_SESSION_ID": ""]) == nil)
        #expect(ClaudeCode.sessionID(in: [:]) == nil)
    }
}

@Suite("Settings installer")
struct SettingsInstallerTests {
    private let tool = "/Applications/Annotator.app/Contents/Helpers/annotator"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func settingsFile(_ contents: String?) throws -> String {
        let directory = NSTemporaryDirectory() + "annotator-settings-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/settings.json"
        if let contents { try Data(contents.utf8).write(to: URL(fileURLWithPath: path)) }
        return path
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func parsed(_ path: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(try read(path).utf8)) as? NSDictionary)
    }

    private func planHooks(_ path: String) throws -> [[String: Any]] {
        let hooks = try parsed(path)["hooks"] as? [String: Any]
        return hooks?["PermissionRequest"] as? [[String: Any]] ?? []
    }

    // A file in the user's own order and style, which must survive untouched.
    private let existing = """
    {
      "includeCoAuthoredBy": false,
      "permissions": {
        "allow": ["Bash(npm test)", "Read(~/notes/**)"],
        "deny": []
      },
      "model": "opus",
      "env": { "A": "x, y", "B": "{not json}" }
    }

    """

    @Test func addsTheHookAndLeavesEverythingElseAsItWas() throws {
        let path = try settingsFile(existing)
        let outcome = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)

        let expected = """
        {
          "includeCoAuthoredBy": false,
          "permissions": {
            "allow": ["Bash(npm test)", "Read(~/notes/**)"],
            "deny": []
          },
          "model": "opus",
          "env": { "A": "x, y", "B": "{not json}" },
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  {
                    "args": [
                      "hook"
                    ],
                    "command": "/Applications/Annotator.app/Contents/Helpers/annotator",
                    "timeout": 86400,
                    "type": "command"
                  }
                ],
                "matcher": "ExitPlanMode"
              }
            ]
          }
        }

        """
        #expect(try read(path) == expected)

        guard case .installed(let backup?) = outcome else {
            Issue.record("expected a backup, got \(outcome)")
            return
        }
        #expect(backup.contains(".annotator-backup-"))
        #expect(try read(backup) == existing)
    }

    @Test func installingTwiceChangesNothing() throws {
        let path = try settingsFile(existing)
        _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        let once = try read(path)
        #expect(try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date) == .alreadyInstalled)
        #expect(try read(path) == once)
    }

    @Test func uninstallRestoresTheOriginalText() throws {
        let path = try settingsFile(existing)
        _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        guard case .removed = try SettingsInstaller.uninstall(settingsPath: path, now: date) else {
            Issue.record("expected removal")
            return
        }
        #expect(try read(path) == existing)
        #expect(try SettingsInstaller.uninstall(settingsPath: path, now: date) == .notInstalled)
    }

    @Test func joinsHooksThatAreAlreadyThere() throws {
        let withHooks = """
        {
            "hooks": {
                "PostToolUse": [
                    { "matcher": "Edit", "hooks": [{ "type": "command", "command": "fmt" }] }
                ],
                "PermissionRequest": [
                    { "matcher": "Bash", "hooks": [{ "type": "command", "command": "check" }] }
                ]
            },
            "model": "opus"
        }
        """
        let path = try settingsFile(withHooks)
        _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)

        let text = try read(path)
        // The other hooks keep their exact text, and the file's four-space style is followed.
        #expect(text.contains(#"{ "matcher": "Edit", "hooks": [{ "type": "command", "command": "fmt" }] }"#))
        #expect(text.contains("{ \"matcher\": \"Bash\", \"hooks\": [{ \"type\": \"command\", \"command\": \"check\" }] },\n            {\n                \"hooks\": ["))
        let requests = try planHooks(path)
        #expect(requests.count == 2)
        #expect(requests[0]["matcher"] as? String == "Bash")
        #expect(requests[1]["matcher"] as? String == "ExitPlanMode")

        _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
        #expect(try read(path) == withHooks)
    }

    @Test func addsTheEventToExistingHooks() throws {
        let original = "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
        let path = try settingsFile(original)
        _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        #expect(try read(path).hasPrefix("{\n  \"hooks\": {\n    \"Stop\": [],\n    \"PermissionRequest\": [\n      {\n"))
        #expect(try planHooks(path).count == 1)

        _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
        #expect(try read(path) == original)
    }

    @Test func handlesEmptyAndCompactFiles() throws {
        for original in ["{}", "{}\n", "{\"model\":\"opus\"}", "{\"hooks\":{}}", "{\"hooks\":{\"PermissionRequest\":[]}}"] {
            let path = try settingsFile(original)
            _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
            #expect(try planHooks(path).count == 1, "\(original)")
            #expect(try parsed(path).count >= 1)

            _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
            #expect(try planHooks(path).isEmpty, "\(original)")
            #expect(try parsed(path)["model"] as? String == (original.contains("opus") ? "opus" : nil))
        }
    }

    @Test func createsTheFileWhenThereIsNone() throws {
        let path = try settingsFile(nil)
        #expect(try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date) == .installed(backup: nil))
        let requests = try planHooks(path)
        #expect(requests.count == 1)
        let handler = try #require((requests[0]["hooks"] as? [[String: Any]])?.first)
        #expect(handler["command"] as? String == tool)
        #expect(handler["args"] as? [String] == ["hook"])
        #expect(handler["timeout"] as? Int == 86_400)
        #expect(try SettingsInstaller.uninstall(settingsPath: path + ".missing", now: date) == .notInstalled)
    }

    @Test func aBrokenFileIsLeftAlone() throws {
        let broken = "{ \"model\": \"opus\", // my comment\n}"
        let path = try settingsFile(broken)
        #expect(throws: SettingsInstaller.Failure.unreadable(path)) {
            try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        }
        #expect(try read(path) == broken)
        #expect(try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent) == ["settings.json"])
    }

    @Test func removesOnlyItsOwnEntry() throws {
        let path = try settingsFile("""
        {
          "hooks": {
            "PermissionRequest": [
              { "matcher": "ExitPlanMode", "hooks": [{ "type": "command", "command": "plannotator" }] },
              { "matcher": "ExitPlanMode", "hooks": [{ "type": "command", "command": "/old/place/annotator", "args": ["hook"] }] },
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "check" }] }
            ]
          }
        }
        """)
        _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
        let requests = try planHooks(path)
        #expect(requests.count == 2)
        #expect(requests.map { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String } == ["plannotator", "check"])
    }

    @Test func textWithBracesAndEscapesInStringsIsNotMisread() throws {
        let tricky = """
        {
          "env": { "PROMPT": "say \\"}\\" and \\\\", "LIST": "[1, 2" },
          "hooks": {}
        }
        """
        let path = try settingsFile(tricky)
        _ = try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        #expect(try planHooks(path).count == 1)
        #expect((try parsed(path)["env"] as? [String: String])?["PROMPT"] == "say \"}\" and \\")
        _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
        #expect((try parsed(path)["env"] as? [String: String])?["LIST"] == "[1, 2")
        #expect(try planHooks(path).isEmpty)
    }
}
