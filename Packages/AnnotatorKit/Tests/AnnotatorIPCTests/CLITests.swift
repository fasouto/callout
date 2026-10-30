import AnnotatorCore
import ClaudeCodeAdapter
import Foundation
import Testing
@testable import AnnotatorCLIKit
@testable import AnnotatorIPC

/// Runs the tool against a stand-in for the app and records what it prints.
/// Sendable by hand: the one thing in it that changes, the stand-in app, is set once per test.
private final class Run: @unchecked Sendable {
    let path = temporarySocketPath()
    let out = Locked<[String]>([])
    let err = Locked<[String]>([])
    let received = Locked<[ClientMessage]>([])
    private var server: SocketServer?

    /// Starts a stand-in app that answers each message with `respond`.
    func startApp(_ respond: @escaping @Sendable (ClientMessage, SocketConnection) -> Void) throws {
        let server = SocketServer(path: path)
        try server.start { [received] message, connection in
            received.update { $0.append(message) }
            respond(message, connection)
        }
        self.server = server
    }

    func stopApp() {
        server?.stop()
        server = nil
    }

    func annotator(
        _ arguments: String...,
        stdin: String? = nil,
        directory: String = NSTemporaryDirectory(),
        launchApp: @escaping () -> Bool = { false },
        launchTimeout: TimeInterval = 0.5
    ) -> Int32 {
        AnnotatorCLI.run(CLIEnvironment(
            arguments: ["annotator"] + arguments,
            currentDirectory: directory,
            readStandardInput: { Data((stdin ?? "").utf8) },
            standardInputIsTerminal: stdin == nil,
            out: { [out] line in out.update { $0.append(line) } },
            err: { [err] line in err.update { $0.append(line) } },
            socketPath: path,
            launchApp: launchApp,
            launchTimeout: launchTimeout
        ))
    }

    var reviewRequest: ReviewRequest? {
        for case .review(let request) in received.get() { return request }
        return nil
    }

    deinit { stopApp() }
}

private func temporaryFile(_ name: String, _ contents: String) throws -> String {
    let directory = NSTemporaryDirectory() + "annotator-cli-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = directory + "/" + name
    try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

/// An app that accepts every review and answers it at once.
private func answering(with make: @escaping @Sendable (ReviewRequest) -> ReviewResult) -> @Sendable (ClientMessage, SocketConnection) -> Void {
    { message, connection in
        guard case .review(let request) = message else { return }
        connection.send(.accepted(id: request.id))
        connection.send(.result(make(request)))
    }
}

@Suite("annotator review")
struct ReviewCommandTests {
    @Test func printsTheFeedback() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "## Feedback on Plan\n\n### General\nSimplify.\n") })

        #expect(run.annotator("review", "-", stdin: "# Plan\n") == 0)
        #expect(run.out.get() == ["## Feedback on Plan\n\n### General\nSimplify.\n"])
        // The id is announced before the wait, so a stopped process still leaves a trace of it.
        let id = try #require(run.reviewRequest?.id)
        #expect(run.err.get() == ["annotator: review \(id.uuidString) is open in Annotator"])
    }

    @Test func standardInputBecomesAMarkdownRequest() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })

        #expect(run.annotator("review", "--title", "My plan", "--session", "s-1", stdin: "# Plan\n", directory: "/work/app") == 0)
        let request = try #require(run.reviewRequest)
        #expect(request.content == .text("# Plan\n", format: .markdown))
        #expect(request.origin == .agentRequest)
        #expect(request.reply == .stdout)
        #expect(request.modes == [.feedback, .applyEdits])
        #expect(request.metadata.title == "My plan")
        #expect(request.metadata.sessionId == "s-1")
        #expect(request.metadata.projectPath == "/work/app")
        #expect(run.out.get() == ["Approved. No changes requested."])
    }

    @Test func textFilesAreSentAsText() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        let markdown = try temporaryFile("post.md", "# Post\n")
        let plain = try temporaryFile("notes.txt", "notes")

        #expect(run.annotator("review", markdown) == 0)
        var request = try #require(run.reviewRequest)
        #expect(request.content == .text("# Post\n", format: .markdown))
        #expect(request.metadata.title == "post.md")
        #expect(request.metadata.filePath?.hasSuffix("/post.md") == true)
        #expect(run.out.get() == ["The review was cancelled. No feedback was given."])

        run.received.set([])
        #expect(run.annotator("review", plain, "--origin", "file-drop") == 0)
        request = try #require(run.reviewRequest)
        #expect(request.content == .text("notes", format: .plain))
        #expect(request.origin == .fileDrop)
    }

    @Test func relativePathsResolveAgainstTheWorkingDirectory() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        let path = try temporaryFile("cv.md", "CV")
        let url = URL(fileURLWithPath: path)

        #expect(run.annotator("review", "cv.md", directory: url.deletingLastPathComponent().path) == 0)
        #expect(run.reviewRequest?.content == .text("CV", format: .markdown))
    }

    @Test func pdfsAreSentByPathAndOnlyTakeFeedback() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "## Feedback on cv.pdf\n") })
        let path = try temporaryFile("cv.pdf", "%PDF-1.4")

        #expect(run.annotator("review", path, "--modes", "feedback,apply-edits") == 0)
        let request = try #require(run.reviewRequest)
        guard case .file(let sent) = request.content else {
            Issue.record("expected file content")
            return
        }
        #expect(sent.hasSuffix("/cv.pdf") && sent.hasPrefix("/"))
        #expect(request.modes == [.feedback])
        #expect(request.metadata.title == "cv.pdf")
    }

    @Test func appliedEditsArePrintedAsTheText() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, editedText: "Fixed text.\n") })
        #expect(run.annotator("review", "-", stdin: "Fxied text.\n") == 0)
        #expect(run.out.get() == ["Fixed text.\n"])
    }

    @Test func jsonPrintsTheRawResult() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "fb") })
        #expect(run.annotator("review", "-", "--json", stdin: "x") == 0)
        let data = Data(try #require(run.out.get().first).utf8)
        let result = try JSONDecoder().decode(ReviewResult.self, from: data)
        #expect(result.decision == .feedback && result.feedback == "fb")
        #expect(result.id == run.reviewRequest?.id)
    }

    @Test func clipboardRepliesOnlyConfirm() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "fb") })
        #expect(run.annotator("review", "-", "--reply", "clipboard", stdin: "x") == 0)
        #expect(run.reviewRequest?.reply == .clipboard)
        #expect(run.out.get() == ["The response was copied to the clipboard."])
    }

    // MARK: The fallback rule

    @Test func unreachableAppExitsCleanly() {
        let run = Run()
        let started = Date()
        #expect(run.annotator("review", "-", stdin: "x") == 0)
        #expect(run.out.get() == ["Annotator could not be reached, so no review was done."])
        // Nothing to launch, so there is nothing to wait for.
        #expect(Date().timeIntervalSince(started) < 0.4)
    }

    @Test func appThatNeverStartsIsGivenUpOn() {
        let run = Run()
        let started = Date()
        #expect(run.annotator("review", "-", stdin: "x", launchApp: { true }, launchTimeout: 0.4) == 0)
        #expect(run.out.get() == ["Annotator could not be reached, so no review was done."])
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.4 && elapsed < 2)
    }

    @Test func aSocketThisProcessMayNotUseIsSaidSoAtOnce() throws {
        // What a sandbox does to the tool: the app is listening, and the
        // connection is refused to this process. A socket nobody may use stands in for it.
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: run.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: run.path) }

        let launches = Locked(0)
        let started = Date()
        let launch: @Sendable () -> Bool = {
            launches.update { $0 += 1 }
            return true
        }
        #expect(run.annotator("review", "-", stdin: "x", launchApp: launch, launchTimeout: 3) == ExitCode.notPermitted)
        #expect(run.annotator("result", launchApp: launch, launchTimeout: 3) == ExitCode.notPermitted)

        // No waiting for an app that is already there, and no second copy started.
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(launches.get() == 0)
        #expect(run.out.get().isEmpty)
        let said = run.err.get()
        #expect(said.count == 2)
        #expect(said.first?.contains("a sandbox blocks its socket") == true)
        #expect(said.first?.contains("sandbox.network.allowUnixSockets") == true)
        #expect(said.first?.hasSuffix(run.path) == true)
    }

    @Test func appIsLaunchedWhenItIsNotRunning() throws {
        let run = Run()
        let launches = Locked(0)
        let code = run.annotator("review", "-", stdin: "x", launchApp: {
            launches.update { $0 += 1 }
            // The app takes a moment to come up.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                try? run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "late but here") })
            }
            return true
        }, launchTimeout: 3)

        #expect(code == 0)
        #expect(launches.get() == 1)
        #expect(run.out.get() == ["late but here"])
    }

    @Test func runningAppIsNotLaunchedAgain() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        let launches = Locked(0)
        #expect(run.annotator("review", "-", stdin: "x", launchApp: { launches.update { $0 += 1 }; return true }) == 0)
        #expect(launches.get() == 0)
    }

    @Test func appCrashingMidReviewExitsCleanly() throws {
        let run = Run()
        try run.startApp { message, connection in
            guard case .review(let request) = message else { return }
            connection.send(.accepted(id: request.id))
            // The user is annotating... and the app dies.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { connection.close() }
        }
        #expect(run.annotator("review", "-", stdin: "x") == 0)
        #expect(run.out.get() == ["Annotator closed before the review was finished, so no feedback was given."])
    }

    @Test func appThatRefusesTheRequestExitsCleanly() throws {
        let run = Run()
        try run.startApp { _, connection in connection.send(.error("no")) }
        #expect(run.annotator("review", "-", stdin: "x") == 0)
        #expect(run.out.get() == ["Annotator did not accept the review, so none was done."])
    }

    @Test func fallbackInJSONIsACancelledResult() throws {
        let run = Run()
        #expect(run.annotator("review", "-", "--json", stdin: "x") == 0)
        let result = try JSONDecoder().decode(ReviewResult.self, from: Data(try #require(run.out.get().first).utf8))
        #expect(result.decision == .cancel)
        #expect(run.err.get() == ["annotator: Annotator could not be reached, so no review was done."])
    }

    @Test func aFileThatCannotBeReadIsSaidInOneLine() {
        // The command was understood, so the usage text would only bury the message.
        let run = Run()
        let code = AnnotatorCLI.run(CLIEnvironment(
            arguments: ["annotator", "review", "/nonexistent/file.md"],
            standardInputIsTerminal: false,
            out: { line in run.out.update { $0.append(line) } },
            err: { line in run.err.update { $0.append(line) } },
            socketPath: run.path
        ))
        #expect(code == ExitCode.noInput)
        #expect(run.err.get() == ["annotator: /nonexistent/file.md does not exist or cannot be read."])
        #expect(run.out.get().isEmpty)
    }

    @Test func nothingToReviewOpensNoWindow() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        let empty = try temporaryFile("empty.md", "")
        let blank = try temporaryFile("blank.txt", "  \n\n\t\n")
        let folder = (empty as NSString).deletingLastPathComponent

        #expect(run.annotator("review", empty) == ExitCode.noInput)
        #expect(run.annotator("review", blank) == ExitCode.noInput)
        #expect(run.annotator("review", "-", stdin: "") == ExitCode.noInput)
        #expect(run.annotator("review", "-", stdin: " \n") == ExitCode.noInput)
        #expect(run.annotator("review", folder) == ExitCode.noInput)
        #expect(run.received.get().isEmpty)
        #expect(run.err.get() == [
            "annotator: \(empty) is empty, so there is nothing to review.",
            "annotator: \(blank) is empty, so there is nothing to review.",
            "annotator: Standard input is empty, so there is nothing to review.",
            "annotator: Standard input is empty, so there is nothing to review.",
            "annotator: \(folder) is a folder. Give a file to review.",
        ])
    }

    // MARK: Usage errors

    @Test func badInvocationsExplainThemselves() {
        let cases: [([String], String)] = [
            (["review", "-", "--origin", "nowhere"], "Unknown origin"),
            (["review", "-", "--reply", "hook-decision"], "--reply takes"),
            (["review", "-", "--modes", "feedback,destroy"], "Unknown mode"),
            (["review", "-", "--title"], "needs a value"),
            (["review", "-", "--frobnicate"], "Unknown option"),
            (["review"], "Give a file"),
            (["frobnicate"], "Unknown command"),
            ([], "Usage:"),
        ]
        for (arguments, expected) in cases {
            let run = Run()
            let code = AnnotatorCLI.run(CLIEnvironment(
                arguments: ["annotator"] + arguments,
                standardInputIsTerminal: arguments == ["review"],
                out: { line in run.out.update { $0.append(line) } },
                err: { line in run.err.update { $0.append(line) } },
                socketPath: run.path
            ))
            #expect(code == ExitCode.usage, "\(arguments)")
            #expect(run.err.get().joined().contains(expected), "\(arguments): \(run.err.get())")
            #expect(run.out.get().isEmpty)
        }
    }

    @Test func helpAndVersion() {
        let run = Run()
        #expect(run.annotator("--help") == 0)
        #expect(run.out.get().first?.contains("annotator review") == true)
        #expect(run.annotator("--version") == 0)
        #expect(run.out.get().last == "annotator \(AnnotatorCLI.version)")
    }
}

@Suite("annotator result")
struct ResultCommandTests {
    private func app(finished: ReviewResult?, open: UUID? = nil) -> @Sendable (ClientMessage, SocketConnection) -> Void {
        { message, connection in
            guard case .resultQuery(let id, _) = message else { return }
            if let finished, id == nil || id == finished.id {
                connection.send(.result(finished))
            } else if let open, id == open {
                connection.send(.pending(id: open))
            } else {
                connection.send(.unknown)
            }
        }
    }

    @Test func printsAFinishedReview() throws {
        let run = Run()
        let result = ReviewResult(id: UUID(), decision: .feedback, feedback: "the feedback")
        try run.startApp(app(finished: result))

        #expect(run.annotator("result", result.id.uuidString) == 0)
        #expect(run.out.get() == ["the feedback"])
        #expect(run.received.get() == [.resultQuery(id: result.id, sessionId: nil)])
    }

    @Test func asksBySessionOrForTheLatest() throws {
        let run = Run()
        try run.startApp(app(finished: ReviewResult(id: UUID(), decision: .approve)))

        #expect(run.annotator("result", "--session", "s-1") == 0)
        #expect(run.annotator("result") == 0)
        #expect(run.received.get() == [.resultQuery(id: nil, sessionId: "s-1"), .resultQuery(id: nil, sessionId: nil)])
    }

    @Test func openAndUnknownReviewsAreReported() throws {
        let run = Run()
        let open = UUID()
        try run.startApp(app(finished: nil, open: open))

        #expect(run.annotator("result", open.uuidString) == ExitCode.nothingFound)
        #expect(run.annotator("result", UUID().uuidString) == ExitCode.nothingFound)
        #expect(run.out.get() == ["That review is still open in Annotator.", "There is no finished review to show."])
    }

    @Test func unreachableAppIsReported() {
        let run = Run()
        #expect(run.annotator("result") == ExitCode.nothingFound)
        #expect(run.out.get() == ["Annotator could not be reached."])
    }

    @Test func somethingThatIsNotAnIdIsAUsageError() {
        let run = Run()
        #expect(run.annotator("result", "latest") == ExitCode.usage)
    }
}

@Suite("annotator hook")
struct HookCommandTests {
    private let hookInput = """
    {"session_id":"s-1","transcript_path":"/t.jsonl","cwd":"/work/app","permission_mode":"plan",
     "hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode",
     "tool_input":{"plan":"# Add caching\\n\\n1. Use Redis\\n","planFilePath":"/plans/add-caching.md"}}
    """

    private func decision(_ run: Run) throws -> [String: Any] {
        #expect(run.out.get().count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(try #require(run.out.get().first).utf8)) as? [String: Any]
        let specific = try #require(object?["hookSpecificOutput"] as? [String: Any])
        return try #require(specific["decision"] as? [String: Any])
    }

    @Test func planIsSentForReview() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        #expect(run.annotator("hook", stdin: hookInput) == 0)

        let request = try #require(run.reviewRequest)
        #expect(request.content == .text("# Add caching\n\n1. Use Redis\n", format: .markdown))
        #expect(request.origin == .planHook)
        #expect(request.reply == .hookDecision)
        #expect(request.modes == [.feedback, .approve])
        #expect(request.metadata.title == "Add caching")
        #expect(request.metadata.sessionId == "s-1")
    }

    @Test func approvalPrintsAllow() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        #expect(run.annotator("hook", stdin: hookInput) == 0)
        #expect(try decision(run)["behavior"] as? String == "allow")
        // Nothing but the decision may reach Claude Code.
        #expect(run.err.get().isEmpty)
    }

    @Test func feedbackPrintsDenyWithTheFeedback() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "## Feedback on Add caching\n\n### General\nNo Redis.\n") })
        #expect(run.annotator("hook", stdin: hookInput) == 0)
        let decision = try decision(run)
        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String)?.contains("### General\nNo Redis.") == true)
    }

    // Every way of not getting an answer ends the same: no output, exit 0, and
    // Claude Code shows its own dialog.

    @Test func cancelPrintsNothing() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        #expect(run.annotator("hook", stdin: hookInput) == 0)
        #expect(run.out.get().isEmpty && run.err.get().isEmpty)
    }

    @Test func unreachableAppPrintsNothing() {
        let run = Run()
        #expect(run.annotator("hook", stdin: hookInput) == 0)
        #expect(run.out.get().isEmpty && run.err.get().isEmpty)
    }

    @Test func appCrashingMidReviewPrintsNothing() throws {
        let run = Run()
        try run.startApp { message, connection in
            guard case .review(let request) = message else { return }
            connection.send(.accepted(id: request.id))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { connection.close() }
        }
        #expect(run.annotator("hook", stdin: hookInput) == 0)
        #expect(run.out.get().isEmpty && run.err.get().isEmpty)
    }

    @Test func inputThatIsNotAPlanPrintsNothingAndOpensNothing() throws {
        let run = Run()
        try run.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        let inputs = [
            "",
            "not json",
            #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            ##"{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"# P"}}"##,
            #"{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{}}"#,
        ]
        for input in inputs {
            #expect(run.annotator("hook", stdin: input) == 0)
        }
        #expect(run.out.get().isEmpty && run.err.get().isEmpty)
        #expect(run.received.get().isEmpty)
    }
}

@Suite("annotator install")
struct InstallCommandTests {
    @Test func installsAndRemovesTheHookWithTheToolsOwnPath() throws {
        let settings = try temporaryFile("settings.json", "{\n  \"model\": \"opus\"\n}\n")
        let run = Run()
        func annotator(_ arguments: String...) -> Int32 {
            AnnotatorCLI.run(CLIEnvironment(
                arguments: ["annotator"] + arguments,
                out: { line in run.out.update { $0.append(line) } },
                err: { line in run.err.update { $0.append(line) } },
                socketPath: run.path,
                toolPath: "/Applications/Annotator.app/Contents/Helpers/annotator"
            ))
        }

        #expect(annotator("install", "--settings", settings) == 0)
        let installed = try String(contentsOfFile: settings, encoding: .utf8)
        #expect(installed.contains("\"command\": \"/Applications/Annotator.app/Contents/Helpers/annotator\""))
        #expect(run.out.get().first == "Added the plan hook to \(settings).")
        #expect(run.out.get().contains { $0.hasPrefix("The previous file is saved as ") })

        #expect(annotator("install", "--settings", settings) == 0)
        #expect(run.out.get().last == "The plan hook is already in \(settings). Nothing changed.")

        #expect(annotator("uninstall", "--settings", settings) == 0)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
        #expect(annotator("uninstall", "--settings", settings) == 0)
        #expect(run.out.get().last == "There is no plan hook in \(settings). Nothing changed.")
    }

    @Test func refusesToTouchABrokenFile() throws {
        let settings = try temporaryFile("settings.json", "{ broken")
        let run = Run()
        let code = AnnotatorCLI.run(CLIEnvironment(
            arguments: ["annotator", "install", "--settings", settings],
            out: { line in run.out.update { $0.append(line) } },
            err: { line in run.err.update { $0.append(line) } },
            socketPath: run.path
        ))
        #expect(code == ExitCode.failure)
        #expect(run.err.get() == ["annotator: \(settings) is not valid JSON, so it was left untouched."])
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{ broken")
    }
}

@Suite("annotator last-reply")
struct LastReplyCommandTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A home folder holding one session's transcript for the project at /work/app.
    private func home(session: String) throws -> String {
        let home = NSTemporaryDirectory() + "annotator-home-\(UUID().uuidString.prefix(8))"
        let folder = "\(home)/.claude/projects/-work-app"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let transcript = [
            line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "Write a haiku"]]),
            line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "An old silent pond"]]]]),
            line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "<command-name>/annotate-last</command-name>"]]),
        ].joined(separator: "\n")
        try Data(transcript.utf8).write(to: URL(fileURLWithPath: "\(folder)/\(session).jsonl"))
        return home
    }

    private func run(_ run: Run, _ arguments: [String], home: String, variables: [String: String] = [:]) -> Int32 {
        AnnotatorCLI.run(CLIEnvironment(
            arguments: ["annotator"] + arguments,
            variables: variables,
            currentDirectory: "/work/app",
            homeDirectory: home,
            out: { line in run.out.update { $0.append(line) } },
            err: { line in run.err.update { $0.append(line) } },
            socketPath: run.path
        ))
    }

    @Test func sendsTheLastReplyForFeedback() throws {
        let app = Run()
        try app.startApp(answering { ReviewResult(id: $0.id, decision: .feedback, feedback: "## Feedback on Claude's reply\n") })
        let home = try home(session: "s-1")

        #expect(run(app, ["last-reply", "--session", "s-1"], home: home) == 0)
        let request = try #require(app.reviewRequest)
        #expect(request.content == .text("An old silent pond", format: .markdown))
        #expect(request.origin == .lastReply)
        #expect(request.modes == [.feedback])
        #expect(request.metadata.sessionId == "s-1")
        #expect(request.metadata.title == "Claude's reply to “Write a haiku”")
        #expect(app.out.get() == ["## Feedback on Claude's reply\n"])
    }

    /// A home folder whose session has three replies, then the command.
    private func homeWithThreeReplies() throws -> String {
        let home = NSTemporaryDirectory() + "annotator-home-\(UUID().uuidString.prefix(8))"
        let folder = "\(home)/.claude/projects/-work-app"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var lines: [String] = []
        for (question, answer) in [("One?", "First."), ("Two?", "Second."), ("Three?", "Third.")] {
            lines.append(line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": question]]))
            lines.append(line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": answer]]]]))
        }
        lines.append(line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "<command-name>/annotate-last</command-name><command-args>2</command-args>"]]))
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: "\(folder)/s-3.jsonl"))
        return home
    }

    @Test func aNumberSendsAnEarlierReply() throws {
        let app = Run()
        try app.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        let home = try homeWithThreeReplies()

        #expect(run(app, ["last-reply", "2", "--session", "s-3"], home: home) == 0)
        let request = try #require(app.reviewRequest)
        #expect(request.content == .text("Second.", format: .markdown))
        #expect(request.metadata.title == "Claude's reply to “Two?”")

        app.received.set([])
        #expect(run(app, ["last-reply", "--session", "s-3", "3"], home: home) == 0)
        #expect(app.reviewRequest?.content == .text("First.", format: .markdown))
    }

    @Test func aNumberPastTheStartIsSaidAndNothingIsOpened() throws {
        let app = Run()
        try app.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        let home = try homeWithThreeReplies()

        #expect(run(app, ["last-reply", "4", "--session", "s-3"], home: home) == 0)
        #expect(app.out.get() == ["This session has 3 replies to review, so there is no reply 4 back."])
        #expect(app.received.get().isEmpty)
    }

    @Test(arguments: ["0", "two", "-1", "1.5"])
    func aNumberThatIsNotAReplyCountIsAUsageError(argument: String) throws {
        let app = Run()
        let home = try homeWithThreeReplies()

        #expect(run(app, ["last-reply", argument, "--session", "s-3"], home: home) == 64)
        #expect(app.err.get().first?.hasPrefix("annotator: \"\(argument)\" is not a number of replies back: 1 is the last reply, 2 the one before it.") == true)
        #expect(run(app, ["last-reply", "1", "2", "--session", "s-3"], home: home) == 64)
    }

    @Test func theMessagesTheToolPrintsAreTheOnesTheTranscriptReaderIgnores() throws {
        var printed: [String] = []

        let cancelled = Run()
        try cancelled.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        #expect(cancelled.annotator("review", "-", stdin: "x") == 0)
        printed += cancelled.out.get()

        let unreachable = Run()
        #expect(unreachable.annotator("review", "-", stdin: "x") == 0)
        printed += unreachable.out.get()

        let crashed = Run()
        try crashed.startApp { message, connection in
            guard case .review(let request) = message else { return }
            connection.send(.accepted(id: request.id))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { connection.close() }
        }
        #expect(crashed.annotator("review", "-", stdin: "x") == 0)
        printed += crashed.out.get()
        #expect(printed.count == 3)

        for output in printed {
            let transcript = [
                line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "Write a haiku"]]),
                line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "An old silent pond"]]]]),
                line(["type": "user", "isSidechain": false, "origin": ["kind": "task-notification"], "message": ["role": "user", "content": "<task-notification>done</task-notification>"]]),
                line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": output]]]]),
                line(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "text", "text": "You cancelled the review."]]]]),
                line(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "<command-name>/annotate-last</command-name>"]]),
            ].joined(separator: "\n")
            let path = NSTemporaryDirectory() + "annotator-tie-\(UUID().uuidString.prefix(8)).jsonl"
            try Data(transcript.utf8).write(to: URL(fileURLWithPath: path))
            #expect(Transcript.replies(inTranscriptAt: path).map(\.text) == ["An old silent pond"], "\(output)")
        }
    }

    @Test func sessionComesFromClaudeCodesEnvironment() throws {
        let app = Run()
        try app.startApp(answering { ReviewResult(id: $0.id, decision: .cancel) })
        let home = try home(session: "from-env")

        #expect(run(app, ["last-reply"], home: home, variables: ["CLAUDE_CODE_SESSION_ID": "from-env"]) == 0)
        #expect(app.reviewRequest?.metadata.sessionId == "from-env")
    }

    @Test func missingTranscriptOrReplyIsSaidInOneLine() throws {
        let app = Run()
        try app.startApp(answering { ReviewResult(id: $0.id, decision: .approve) })
        let home = try home(session: "s-1")

        #expect(run(app, ["last-reply", "--session", "unknown"], home: home) == 0)
        #expect(app.out.get() == ["The transcript of this session was not found, so there is no reply to review."])

        let empty = "\(home)/empty.jsonl"
        try Data().write(to: URL(fileURLWithPath: empty))
        #expect(run(app, ["last-reply", "--transcript", empty], home: home) == 0)
        #expect(app.out.get().last == "No earlier reply was found in this session, so there is nothing to review.")
        #expect(app.received.get().isEmpty)
    }

    @Test func unreachableAppExitsCleanly() throws {
        let app = Run()
        let home = try home(session: "s-1")
        #expect(run(app, ["last-reply", "--session", "s-1"], home: home) == 0)
        #expect(app.out.get() == ["Annotator could not be reached, so no review was done."])
    }
}
