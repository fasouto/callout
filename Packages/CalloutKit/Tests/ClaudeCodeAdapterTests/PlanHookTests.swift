import CalloutCore
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

    private func hookInput(_ plan: String? = "# Refactor auth\n\n1. Extract the token store\n") throws -> HookInput {
        try #require(HookInput.decode(planHookInput(plan: plan)))
    }

    @Test func approvalAllowsAndSwitchesToAcceptEdits() throws {
        let output = PlanHook.output(for: ReviewResult(id: UUID(), decision: .approve), input: try hookInput())
        let decision = try decision(output)
        #expect(decision["behavior"] as? String == "allow")
        let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
        #expect(updatedInput["plan"] as? String == "# Refactor auth\n\n1. Extract the token store\n")
        #expect(updatedInput["planFilePath"] as? String == "/Users/me/.claude/plans/refactor-auth.md")
        let updates = try #require(decision["updatedPermissions"] as? [[String: String]])
        #expect(updates == [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
        // One line, so nothing else on standard output can be mistaken for it.
        #expect(output?.contains("\n") == false)
    }

    @Test func approvalHandsBackEveryFieldOfTheToolInput() throws {
        let raw = Data("""
        {"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"# P","planFilePath":"/p.md","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}],"count":3,"ratio":0.5,"flag":true,"none":null}}
        """.utf8)
        let input = try #require(HookInput.decode(raw))
        let output = try #require(PlanHook.output(for: ReviewResult(id: UUID(), decision: .approve), input: input))
        let updated = try #require(decision(output)["updatedInput"] as? NSDictionary)
        let expected: NSDictionary = [
            "plan": "# P", "planFilePath": "/p.md", "count": 3, "ratio": 0.5, "flag": true, "none": NSNull(),
            "allowedPrompts": [["tool": "Bash", "prompt": "run tests"]],
        ]
        #expect(updated == expected)
    }

    @Test func feedbackDeniesWithTheFeedbackAsTheMessage() throws {
        let feedback = "## Feedback on Refactor auth\n\n### 1. Delete\n> Extract the token store\nReason: out of scope\n"
        let decision = try decision(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback, feedback: feedback), input: try hookInput()))
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(message.hasPrefix("The user reviewed this plan in Callout and wants changes."))
        #expect(message.hasSuffix("### 1. Delete\n> Extract the token store\nReason: out of scope"))
        #expect(decision["updatedPermissions"] == nil)
    }

    @Test func cancelAndEmptyFeedbackPrintNothing() throws {
        let input = try hookInput()
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .cancel), input: input) == nil)
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback, feedback: " \n"), input: input) == nil)
        #expect(PlanHook.output(for: ReviewResult(id: UUID(), decision: .feedback), input: input) == nil)
    }

    @Test func sessionComesFromTheEnvironment() {
        #expect(ClaudeCode.sessionID(in: ["CLAUDE_CODE_SESSION_ID": "abc"]) == "abc")
        #expect(ClaudeCode.sessionID(in: ["CLAUDE_CODE_SESSION_ID": ""]) == nil)
        #expect(ClaudeCode.sessionID(in: [:]) == nil)
    }
}

@Suite("Settings installer")
struct SettingsInstallerTests {
    private let tool = "/Applications/Callout.app/Contents/Helpers/callout"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func settingsFile(_ contents: String?) throws -> String {
        let directory = NSTemporaryDirectory() + "callout-settings-\(UUID().uuidString.prefix(8))"
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
                    "command": "/Applications/Callout.app/Contents/Helpers/callout",
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
        #expect(backup.contains(".callout-backup-"))
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

    @Test func settingsLinkedFromElsewhereAreEditedWhereTheyLive() throws {
        // Settings kept in a dotfiles folder, with a link in ~/.claude.
        let real = try settingsFile(existing)
        let link = (real as NSString).deletingLastPathComponent + "/linked.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        guard case .installed(let backup?) = try SettingsInstaller.install(toolPath: tool, settingsPath: link, now: date) else {
            Issue.record("expected an install with a backup")
            return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(try planHooks(real).count == 1)
        #expect(try read(backup) == existing)
        #expect(try FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? Int == 0o644)

        _ = try SettingsInstaller.uninstall(settingsPath: link, now: date)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(try read(real) == existing)
    }

    @Test func aReadOnlyFileIsLeftAlone() throws {
        let path = try settingsFile(existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        #expect(throws: SettingsInstaller.Failure.readOnly(path)) {
            try SettingsInstaller.install(toolPath: tool, settingsPath: path, now: date)
        }
        #expect(try read(path) == existing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent) == ["settings.json"])
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
              { "matcher": "ExitPlanMode", "hooks": [{ "type": "command", "command": "plcallout" }] },
              { "matcher": "ExitPlanMode", "hooks": [{ "type": "command", "command": "/old/place/callout", "args": ["hook"] }] },
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "check" }] }
            ]
          }
        }
        """)
        _ = try SettingsInstaller.uninstall(settingsPath: path, now: date)
        let requests = try planHooks(path)
        #expect(requests.count == 2)
        #expect(requests.map { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String } == ["plcallout", "check"])
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
