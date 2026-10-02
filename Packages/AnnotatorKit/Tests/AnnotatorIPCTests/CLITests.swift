import AnnotatorCore
import Foundation
import Testing
@testable import AnnotatorCLIKit
@testable import AnnotatorIPC

/// Runs the tool against a stand-in for the app and records what it prints.
private final class Run {
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

    // MARK: Usage errors

    @Test func badInvocationsExplainThemselves() {
        let cases: [([String], String)] = [
            (["review", "/nonexistent/file.md"], "does not exist"),
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
