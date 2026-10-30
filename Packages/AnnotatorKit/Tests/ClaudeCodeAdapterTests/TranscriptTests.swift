import Foundation
import Testing
@testable import ClaudeCodeAdapter

/// Builds transcript lines shaped like the ones Claude Code writes.
enum Line {
    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func prompt(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": text]])
    }

    static func promptWithImage(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [
            ["type": "text", "text": text], ["type": "image", "source": ["type": "base64"]],
        ]]])
    }

    static func command(_ name: String, arguments: String = "") -> String {
        prompt("<command-message>\(name)</command-message>\n<command-name>/\(name)</command-name>\n<command-args>\(arguments)</command-args>")
    }

    /// What Claude Code writes when a background task finishes.
    static func notification() -> String {
        json(["type": "user", "isSidechain": false, "origin": ["kind": "task-notification"], "message": ["role": "user", "content": [
            ["type": "text", "text": "<task-notification>\n<status>completed</status>\n</task-notification>"],
        ]]])
    }

    static func meta(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "isMeta": true, "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    static func assistant(_ text: String, sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func thinking() -> String {
        json(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hmm"]]]])
    }

    static func toolUse() -> String {
        json(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
        ]]])
    }

    static func toolResult(_ text: String = "file.txt") -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": text],
        ]]])
    }

    /// A tool result whose content is a list of text blocks.
    static func toolResultBlocks(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": [["type": "text", "text": text]]],
        ]]])
    }

    static func other(_ type: String) -> String {
        json(["type": type, "sessionId": "s"])
    }
}

@Suite("Transcript: replies")
struct RepliesTests {
    private func replies(_ lines: String...) -> [Reply] {
        Transcript.replies(in: lines.joined(separator: "\n"))
    }

    private func reply(_ lines: String...) -> String? {
        Transcript.replies(in: lines.joined(separator: "\n")).last?.text
    }

    @Test func theReplyBeforeTheCommandIsTheOneToReview() {
        #expect(reply(
            Line.other("permission-mode"),
            Line.prompt("Write me a cover letter"),
            Line.thinking(),
            Line.assistant("Dear hiring manager,\n\nI am writing to apply."),
            Line.other("file-history-snapshot"),
            Line.command("annotate-last"),
            Line.meta("The user wants to correct your previous reply..."),
            Line.assistant("Opening your reply in Annotator."),
            Line.toolUse()
        ) == "Dear hiring manager,\n\nI am writing to apply.")
    }

    @Test func onlyTheFinalMessageOfATurnIsTaken() {
        #expect(reply(
            Line.prompt("Fix the bug"),
            Line.assistant("Let me look at the code."),
            Line.toolUse(),
            Line.toolResult(),
            Line.assistant("Found it."),
            Line.toolUse(),
            Line.toolResult(),
            Line.assistant("The bug was an off-by-one."),
            Line.assistant("I fixed it in `loop.py`."),
            Line.command("annotate-last")
        ) == "The bug was an off-by-one.\n\nI fixed it in `loop.py`.")
    }

    @Test func aTurnThatEndedOnAToolCallIsTakenWhole() {
        #expect(reply(
            Line.prompt("Fix the bug"),
            Line.assistant("Looking."),
            Line.toolUse(),
            Line.toolResult(),
            Line.assistant("Trying a fix."),
            Line.toolUse(),
            Line.command("annotate-last")
        ) == "Looking.\n\nTrying a fix.")
    }

    @Test func otherCommandsAndUnansweredPromptsAreSteppedOver() {
        #expect(reply(
            Line.prompt("Summarise the design"),
            Line.assistant("The design has three parts."),
            Line.command("model"),
            Line.prompt("<local-command-stdout>Set model to opus</local-command-stdout>"),
            Line.promptWithImage("and look at this"),
            Line.command("annotate-last")
        ) == "The design has three parts.")
    }

    @Test func earlierTurnsAreNotIncluded() {
        #expect(reply(
            Line.prompt("First question"),
            Line.assistant("First answer."),
            Line.prompt("Second question"),
            Line.assistant("Second answer."),
            Line.command("annotate-last")
        ) == "Second answer.")
    }

    @Test func subagentAndInjectedMessagesAreIgnored() {
        #expect(reply(
            Line.prompt("Research this"),
            Line.assistant("Subagent chatter.", sidechain: true),
            Line.assistant("Here is what I found."),
            Line.meta("Caveat: generated by a local command"),
            Line.command("annotate-last")
        ) == "Here is what I found.")
    }

    @Test func theLatestInvocationIsTheBoundary() {
        // The command was used once already; its own turn is now the reply to review.
        #expect(reply(
            Line.prompt("Draft a message"),
            Line.assistant("First draft."),
            Line.command("annotate-last"),
            Line.toolUse(),
            Line.toolResult("## Feedback on Claude's reply\n\n### General\nShorter."),
            Line.assistant("Second draft, with your corrections."),
            Line.command("annotate-last")
        ) == "Second draft, with your corrections.")
    }

    @Test func withoutTheCommandTheCurrentTurnIsLeftOut() {
        // Claude ran the tool itself in answer to "let me correct that".
        #expect(reply(
            Line.prompt("Explain the trade-offs"),
            Line.assistant("There are two trade-offs."),
            Line.prompt("let me correct that"),
            Line.assistant("Opening it."),
            Line.toolUse()
        ) == "There are two trade-offs.")
    }

    @Test func nothingToReview() {
        #expect(reply(Line.command("annotate-last")) == nil)
        #expect(reply(Line.prompt("hello"), Line.command("annotate-last")) == nil)
        #expect(reply() == nil)
    }

    // MARK: Counting back

    @Test func repliesComeInOrderAndEarlierOnesAreReachable() {
        let found = replies(
            Line.prompt("First question"),
            Line.assistant("First answer."),
            Line.prompt("Second question"),
            Line.assistant("Second answer."),
            Line.prompt("Third question"),
            Line.assistant("Third answer."),
            Line.command("annotate-last", arguments: "2")
        )
        #expect(found.map(\.text) == ["First answer.", "Second answer.", "Third answer."])
    }

    @Test func anAnnotateLastTurnThatOnlyStartedABackgroundReviewIsNotCounted() {
        #expect(replies(
            Line.prompt("Draft a message"),
            Line.assistant("The draft."),
            Line.command("annotate-last"),
            Line.toolUse(),
            Line.toolResult("Command running in background with ID: abc"),
            Line.assistant("My last reply is open in Annotator."),
            Line.command("annotate-last", arguments: "2")
        ).map(\.text) == ["The draft."])
    }

    @Test(arguments: [ReviewOutcome.cancelled, ReviewOutcome.closed, ReviewOutcome.unreachable])
    func aNotificationTurnAfterAReviewWithoutFeedbackIsNotCounted(output: String) {
        #expect(replies(
            Line.prompt("Draft a message"),
            Line.assistant("The draft."),
            Line.command("annotate-last"),
            Line.assistant("My last reply is open in Annotator."),
            Line.notification(),
            Line.toolUse(),
            Line.toolResult(output),
            Line.assistant("You cancelled the review."),
            Line.command("annotate-last")
        ).map(\.text) == ["The draft."])
    }

    @Test func aReviewsOutputInTextBlocksIsRecognisedToo() {
        #expect(replies(
            Line.prompt("Draft a message"),
            Line.assistant("The draft."),
            Line.notification(),
            Line.toolUse(),
            Line.toolResultBlocks(ReviewOutcome.cancelled),
            Line.assistant("You cancelled the review."),
            Line.command("annotate-last")
        ).map(\.text) == ["The draft."])
    }

    @Test func aNotificationTurnAfterFeedbackCameBackIsCounted() {
        #expect(replies(
            Line.prompt("Draft a message"),
            Line.assistant("The draft."),
            Line.command("annotate-last"),
            Line.assistant("My last reply is open in Annotator."),
            Line.notification(),
            Line.toolUse(),
            Line.toolResult("## Feedback on Claude's reply\n\n### General\nShorter."),
            Line.assistant("Here is the shorter draft."),
            Line.command("annotate-last")
        ).map(\.text) == ["The draft.", "Here is the shorter draft."])
    }

    @Test func aNotificationTurnForAnUnrelatedTaskIsCounted() {
        #expect(replies(
            Line.prompt("Run the build"),
            Line.assistant("Started it."),
            Line.notification(),
            Line.toolUse(),
            Line.toolResult("Build succeeded"),
            Line.assistant("The build passed."),
            Line.command("annotate-last")
        ).map(\.text) == ["Started it.", "The build passed."])
    }

    @Test func aNotificationIsRecognisedByItsTextAlone() {
        let bare = #"{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#
        #expect(replies(
            Line.prompt("Run the build"),
            Line.assistant("Started it."),
            bare,
            Line.assistant("The build passed."),
            Line.command("annotate-last")
        ).map(\.text) == ["Started it.", "The build passed."])
    }

    // MARK: Questions

    @Test func aPromptIsTheQuestionItsReplyAnswers() {
        #expect(replies(
            Line.prompt("\n  Why is the   build slow?\nAlso the tests."),
            Line.assistant("Because of the cache."),
            Line.command("annotate-last")
        ).map(\.question) == ["Why is the build slow?"])
    }

    @Test func aLongPromptIsCutAtAWord() throws {
        let long = "Please explain how the review window decides which of the many marks a person made should be kept"
        let question = try #require(replies(Line.prompt(long), Line.assistant("A."), Line.command("annotate-last")).first?.question)
        #expect(question == "Please explain how the review window decides which of the…")
        #expect(question.count <= 60)
    }

    @Test func imageTokensAreLeftOutOfTheQuestion() {
        #expect(replies(
            Line.promptWithImage("[Image #2] what is wrong with this?"),
            Line.assistant("The margin."),
            Line.command("annotate-last")
        ).map(\.question) == ["what is wrong with this?"])
    }

    @Test func aCommandsQuestionIsItsNameAndArguments() {
        #expect(replies(
            Line.command("review-document", arguments: "cv.md"),
            Line.assistant("Opened."),
            Line.command("explain"),
            Line.assistant("Here."),
            Line.command("annotate-last")
        ).map(\.question) == ["/review-document cv.md", "/explain"])
    }

    @Test func aNotificationHasNoQuestion() {
        #expect(replies(
            Line.prompt("Run the build"),
            Line.assistant("Started it."),
            Line.notification(),
            Line.assistant("The build passed."),
            Line.command("annotate-last")
        ).map(\.question) == ["Run the build", nil])
    }

    /// Opt-in check against a transcript written by the installed Claude Code:
    /// set ANNOTATOR_REAL_TRANSCRIPT to its path.
    @Test func readsATranscriptFromTheInstalledClaudeCode() throws {
        guard let path = ProcessInfo.processInfo.environment["ANNOTATOR_REAL_TRANSCRIPT"] else { return }
        let replies = Transcript.replies(inTranscriptAt: path)
        #expect(!replies.isEmpty)
        for (index, reply) in replies.enumerated().reversed() {
            let first = reply.text.prefix(80).replacing("\n", with: " ")
            print("\(replies.count - index) back: \(reply.question.map { "“\($0)”" } ?? "(a background task)") -> \(first)")
        }
    }

    @Test func damagedLinesAreSkipped() {
        #expect(reply(
            Line.prompt("Question"),
            "{ this is not json",
            "",
            #"{"type":"assistant","message":"not an object"}"#,
            Line.assistant("Answer."),
            #"{"type":"assistant","message":{"content":[{"type":"text"}]}}"#,
            Line.command("annotate-last")
        ) == "Answer.")
    }
}

@Suite("Transcript: locating")
struct TranscriptLocatorTests {
    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "annotator-home-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ path: String, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }

    @Test func projectFolderNameReplacesEverythingButLettersAndDigits() {
        #expect(Transcript.projectName(for: "/Users/fabio/projects/annotator") == "-Users-fabio-projects-annotator")
        #expect(Transcript.projectName(for: "/work/my app_v2.1") == "-work-my-app-v2-1")
        #expect(Transcript.projectName(for: "/work/ñandú") == "-work--and-")
    }

    @Test func findsTheSessionInTheProjectOfTheWorkingDirectory() throws {
        let home = try makeHome()
        let expected = "\(home)/.claude/projects/-work-app/abc.jsonl"
        try write(expected)
        try write("\(home)/.claude/projects/-work-app/other.jsonl")
        #expect(Transcript.locate(sessionID: "abc", workingDirectory: "/work/app", variables: [:], home: home) == expected)
    }

    @Test func findsASessionThatMovedToAnotherDirectory() throws {
        let home = try makeHome()
        let expected = "\(home)/.claude/projects/-work-elsewhere/abc.jsonl"
        try write(expected)
        try write("\(home)/.claude/projects/-work-app/other.jsonl")
        #expect(Transcript.locate(sessionID: "abc", workingDirectory: "/work/app", variables: [:], home: home) == expected)
    }

    @Test func aKnownSessionThatIsMissingIsNotGuessed() throws {
        let home = try makeHome()
        try write("\(home)/.claude/projects/-work-app/other.jsonl")
        #expect(Transcript.locate(sessionID: "abc", workingDirectory: "/work/app", variables: [:], home: home) == nil)
    }

    @Test func withoutASessionTheNewestTranscriptOfTheProjectIsUsed() throws {
        let home = try makeHome()
        try write("\(home)/.claude/projects/-work-app/old.jsonl", age: 3600)
        try write("\(home)/.claude/projects/-work-app/new.jsonl", age: 5)
        try write("\(home)/.claude/projects/-work-other/newest.jsonl")
        #expect(Transcript.locate(sessionID: nil, workingDirectory: "/work/app", variables: [:], home: home)
            == "\(home)/.claude/projects/-work-app/new.jsonl")
        #expect(Transcript.locate(sessionID: nil, workingDirectory: "/work/none", variables: [:], home: home) == nil)
    }

    @Test func configDirectoryCanBeMoved() throws {
        let home = try makeHome()
        let config = "\(home)/custom-config"
        try write("\(config)/projects/-work-app/abc.jsonl")
        #expect(Transcript.locate(sessionID: "abc", workingDirectory: "/work/app", variables: ["CLAUDE_CONFIG_DIR": config], home: home)
            == "\(config)/projects/-work-app/abc.jsonl")
    }
}
