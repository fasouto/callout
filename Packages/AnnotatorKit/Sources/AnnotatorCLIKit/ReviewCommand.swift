import AnnotatorCore
import AnnotatorIPC
import ClaudeCodeAdapter
import Foundation

/// `annotator review`: sends a request, blocks until the user responds, prints the result.
struct ReviewCommand {
    private let environment: CLIEnvironment
    private var file: String?
    private var title: String?
    private var origin = ReviewOrigin.agentRequest
    private var reply = ReplyChannel.stdout
    private var format: TextFormat?
    private var modes: [ReviewMode]?
    private var session: String?
    private var json = false

    init(arguments: inout Arguments, environment: CLIEnvironment) throws {
        self.environment = environment
        while let argument = arguments.next() {
            switch argument {
            case "--title":
                title = try arguments.value(for: argument)
            case "--origin":
                let value = try arguments.value(for: argument)
                guard let origin = ReviewOrigin(rawValue: value) else { throw UsageError("Unknown origin \"\(value)\".") }
                self.origin = origin
            case "--reply":
                let value = try arguments.value(for: argument)
                guard let reply = ReplyChannel(rawValue: value), reply != .hookDecision else {
                    throw UsageError("--reply takes stdout or clipboard.")
                }
                self.reply = reply
            case "--format":
                let value = try arguments.value(for: argument)
                guard let format = TextFormat(rawValue: value) else { throw UsageError("--format takes markdown or plain.") }
                self.format = format
            case "--modes":
                let value = try arguments.value(for: argument)
                modes = try value.split(separator: ",").map { name in
                    guard let mode = ReviewMode(rawValue: String(name)) else { throw UsageError("Unknown mode \"\(name)\".") }
                    return mode
                }
            case "--session":
                session = try arguments.value(for: argument)
            case "--json":
                json = true
            default:
                if argument.hasPrefix("--") { throw UsageError("Unknown option \(argument).") }
                guard file == nil else { throw UsageError("Only one file can be reviewed at a time.") }
                file = argument
            }
        }
    }

    func run() throws -> Int32 {
        ReviewExchange(environment: environment, json: json).run(try makeRequest())
    }

    // MARK: - Request

    private func makeRequest() throws -> ReviewRequest {
        var metadata = ReviewMetadata(
            projectPath: environment.currentDirectory,
            sessionId: session ?? ClaudeCode.sessionID(in: environment.variables),
            title: title
        )
        let content: ReviewContent

        if let file, file != "-" {
            let url = URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: environment.currentDirectory)).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw InputError("\(file) does not exist or cannot be read.")
            }
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                throw InputError("\(file) is a folder. Give a file to review.")
            }
            metadata.title = title ?? url.lastPathComponent
            if url.pathExtension.lowercased() == "pdf" {
                content = .file(path: url.path)
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw InputError("\(file) is not UTF-8 text.")
                }
                guard !text.isBlank else { throw InputError("\(file) is empty, so there is nothing to review.") }
                metadata.filePath = url.path
                let isMarkdown = ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
                content = .text(text, format: format ?? (isMarkdown ? .markdown : .plain))
            }
        } else {
            guard file == "-" || !environment.standardInputIsTerminal else {
                throw UsageError("Give a file to review, or pipe text in.")
            }
            guard let text = String(data: environment.readStandardInput(), encoding: .utf8) else {
                throw InputError("Standard input is not UTF-8 text.")
            }
            guard !text.isBlank else { throw InputError("Standard input is empty, so there is nothing to review.") }
            content = .text(text, format: format ?? .markdown)
        }

        var allowed = modes ?? [.feedback, .applyEdits]
        if case .file = content {
            // A PDF has no source here to edit.
            allowed.removeAll { $0 == .applyEdits }
            if allowed.isEmpty { allowed = [.feedback] }
        }
        return ReviewRequest(content: content, origin: origin, metadata: metadata, reply: reply, modes: allowed)
    }
}

/// Sends a request to the app and waits for the response, with the fallback rule:
/// whenever there is no response to give, say so in one line and exit successfully.
struct ReviewExchange {
    let environment: CLIEnvironment
    var json = false

    func run(_ request: ReviewRequest) -> Int32 {
        guard let client = AppConnection.open(environment) else {
            // Kept out is not the same as nobody home: the caller can do something about it.
            if AppConnection.isBlocked(environment) { return AppConnection.sayBlocked(environment) }
            return finishWithout(request, "Annotator could not be reached, so no review was done.")
        }
        defer { client.close() }

        do {
            try client.send(.review(request))
            guard case .accepted = try client.receive(timeout: AppConnection.acceptTimeout) else {
                return finishWithout(request, "Annotator did not accept the review, so none was done.")
            }
            // On standard error, so it is on record even if this process is stopped before the result.
            environment.err("annotator: review \(request.id.uuidString) is open in Annotator")

            while true {
                if case .result(let result) = try client.receive(timeout: nil) {
                    if request.reply == .clipboard, !json, result.decision == .feedback {
                        environment.out("The response was copied to the clipboard.")
                    } else {
                        environment.out(Output.text(for: result, json: json))
                    }
                    return ExitCode.success
                }
            }
        } catch {
            // The app quit or crashed mid-review. The caller carries on as if there had been none.
            return finishWithout(request, "Annotator closed before the review was finished, so no feedback was given.")
        }
    }

    private func finishWithout(_ request: ReviewRequest, _ message: String) -> Int32 {
        if json {
            environment.err("annotator: \(message)")
            environment.out(Output.text(for: ReviewResult(id: request.id, decision: .cancel), json: true))
        } else {
            environment.out(message)
        }
        return ExitCode.success
    }
}

/// `annotator last-reply`: opens Claude's last reply in this session for review.
struct LastReplyCommand {
    private let environment: CLIEnvironment
    private var session: String?
    private var transcript: String?
    private var json = false

    init(arguments: inout Arguments, environment: CLIEnvironment) throws {
        self.environment = environment
        while let argument = arguments.next() {
            switch argument {
            case "--session":
                session = try arguments.value(for: argument)
            case "--transcript":
                transcript = try arguments.value(for: argument)
            case "--json":
                json = true
            default:
                throw UsageError("Unknown option \(argument).")
            }
        }
    }

    func run() -> Int32 {
        let session = session ?? ClaudeCode.sessionID(in: environment.variables)
        let path = transcript ?? Transcript.locate(
            sessionID: session, workingDirectory: environment.currentDirectory, variables: environment.variables,
            home: environment.homeDirectory
        )
        guard let path else {
            environment.out("The transcript of this session was not found, so there is no reply to review.")
            return ExitCode.success
        }
        guard let reply = Transcript.lastReply(inTranscriptAt: path) else {
            environment.out("No earlier reply was found in this session, so there is nothing to review.")
            return ExitCode.success
        }
        let request = ReviewRequest(
            content: .text(reply, format: .markdown),
            origin: .lastReply,
            metadata: ReviewMetadata(projectPath: environment.currentDirectory, sessionId: session, title: "Claude's reply"),
            reply: .stdout,
            modes: [.feedback]
        )
        return ReviewExchange(environment: environment, json: json).run(request)
    }
}

/// `annotator result`: prints a review that already finished.
struct ResultCommand {
    private let environment: CLIEnvironment
    private var id: UUID?
    private var session: String?
    private var json = false

    init(arguments: inout Arguments, environment: CLIEnvironment) throws {
        self.environment = environment
        while let argument = arguments.next() {
            switch argument {
            case "--session":
                session = try arguments.value(for: argument)
            case "--json":
                json = true
            default:
                guard !argument.hasPrefix("--"), let id = UUID(uuidString: argument), self.id == nil else {
                    throw UsageError("\"\(argument)\" is not a review id.")
                }
                self.id = id
            }
        }
    }

    func run() throws -> Int32 {
        guard let client = AppConnection.open(environment) else {
            if AppConnection.isBlocked(environment) { return AppConnection.sayBlocked(environment) }
            environment.out("Annotator could not be reached.")
            return ExitCode.nothingFound
        }
        defer { client.close() }

        do {
            // Without an id, the review of the session this runs in is the one meant.
            let session = session ?? (id == nil ? ClaudeCode.sessionID(in: environment.variables) : nil)
            try client.send(.resultQuery(id: id, sessionId: session))
            switch try client.receive(timeout: AppConnection.acceptTimeout) {
            case .result(let result):
                environment.out(Output.text(for: result, json: json))
                return ExitCode.success
            case .pending:
                environment.out("That review is still open in Annotator.")
            default:
                environment.out("There is no finished review to show.")
            }
        } catch {
            environment.out("Annotator did not answer.")
        }
        return ExitCode.nothingFound
    }
}

private extension String {
    /// Nothing but spaces and line breaks: a review of it would be an empty page.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
