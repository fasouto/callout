import Foundation

/// Reads Claude Code's session transcripts. Their format is not documented, so
/// everything here is tolerant: a line that is not understood is skipped.
public enum Transcript {
    // MARK: - Finding the transcript

    /// The transcript of a session.
    ///
    /// Transcripts live at `<config>/projects/<project>/<session>.jsonl`, where
    /// `<project>` is the working directory with every non-alphanumeric character
    /// replaced by a dash. The session may have moved to another directory since
    /// it started, so every project is searched when the obvious place has nothing.
    public static func locate(
        sessionID: String?, workingDirectory: String, variables: [String: String], home: String = NSHomeDirectory()
    ) -> String? {
        let config = variables["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        let projects = config + "/projects"
        let project = projects + "/" + projectName(for: workingDirectory)
        let manager = FileManager.default

        if let sessionID, !sessionID.isEmpty {
            let direct = "\(project)/\(sessionID).jsonl"
            if manager.fileExists(atPath: direct) { return direct }
            let folders = (try? manager.contentsOfDirectory(atPath: projects)) ?? []
            return folders.sorted().lazy
                .map { "\(projects)/\($0)/\(sessionID).jsonl" }
                .first { manager.fileExists(atPath: $0) }
        }

        // Without a session id, the transcript written to most recently in this project.
        let files = ((try? manager.contentsOfDirectory(atPath: project)) ?? []).filter { $0.hasSuffix(".jsonl") }
        return files
            .map { "\(project)/\($0)" }
            .max { modified($0) < modified($1) }
    }

    static func projectName(for directory: String) -> String {
        String(directory.unicodeScalars.map { scalar in
            let isAlphanumeric = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - Reading the replies

    /// Claude's finished replies before the command that asked for this review,
    /// oldest first, without the replies that only talk about running a review.
    public static func replies(inTranscriptAt path: String, command: String = "annotate-last") -> [Reply] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return replies(in: text, command: command)
    }

    static func replies(in transcript: String, command: String = "annotate-last") -> [Reply] {
        let turns = turns(in: transcript)

        // Everything from the command on belongs to the turn that is running now.
        let boundary = turns.lastIndex { $0.opener.isCommand(command) }
            ?? turns.lastIndex { $0.opener.isPrompt }
            ?? turns.count

        return turns[..<boundary].compactMap { turn in
            // A turn with no text, such as an unanswered prompt or /model, is not a reply.
            guard !turn.isChatter(command: command), let text = turn.reply else { return nil }
            return Reply(question: turn.opener.question, text: text)
        }
    }

    /// What started a turn.
    enum Opener: Equatable {
        /// Something the user typed.
        case prompt(String)
        /// A slash command the user ran.
        case command(name: String, arguments: String)
        /// A background task finished and told Claude.
        case notification

        var isPrompt: Bool {
            if case .prompt = self { return true } else { return false }
        }

        func isCommand(_ wanted: String) -> Bool {
            if case .command(let name, _) = self { return name.contains(wanted) } else { return false }
        }

        /// What the user said that a reply answers, short enough for a title.
        var question: String? {
            switch self {
            case .prompt(let text):
                let lines = text.split(whereSeparator: \.isNewline).map {
                    String($0).replacing(/\[Image #\d+\]/, with: "").collapsingWhitespace
                }
                return lines.first { !$0.isEmpty }.map(\.cutForTitle)
            case .command(let name, let arguments):
                return "/\(name) \(arguments)".collapsingWhitespace.cutForTitle
            case .notification:
                return nil
            }
        }
    }

    /// What Claude and the tools wrote after an opener.
    enum Entry: Equatable {
        case text(String)
        case toolUse
        case toolResult(String)
    }

    /// An opener and everything written until the next one.
    struct Turn: Equatable {
        var opener: Opener
        var entries: [Entry] = []

        /// The text after the last tool call; a turn that ended on a tool call
        /// is taken whole. Nil when Claude wrote no text.
        var reply: String? {
            let final = entries.split(separator: .toolUse, omittingEmptySubsequences: false).last.map(Array.init) ?? []
            let chosen = final.contains(where: \.isText) ? final : entries
            let texts = chosen.compactMap { entry -> String? in
                if case .text(let text) = entry { return text } else { return nil }
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        }

        private var toolResults: [String] {
            entries.compactMap { entry in
                if case .toolResult(let text) = entry { return text } else { return nil }
            }
        }

        /// A review the command started in the background leaves its turn with one
        /// line, unless a tool result in it carries the feedback (an older, foreground
        /// run), which makes the turn a real answer. A turn that a finished task
        /// opened is noise only when its results say the review had no feedback.
        func isChatter(command: String) -> Bool {
            switch opener {
            case .prompt:
                return false
            case .command:
                guard opener.isCommand(command) else { return false }
                // The tool says the review is open before the feedback, on another stream.
                return !toolResults.contains { $0.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("## Feedback") } }
            case .notification:
                return toolResults.contains { result in ReviewOutcome.withoutFeedback.contains { result.contains($0) } }
            }
        }
    }

    static func turns(in transcript: String) -> [Turn] {
        var turns: [Turn] = []
        for line in transcript.split(whereSeparator: \.isNewline) {
            for event in parse(line: String(line)) {
                switch event {
                case .opener(let opener):
                    turns.append(Turn(opener: opener))
                case .entry(let entry):
                    // Before the first opener there is no turn to belong to.
                    if !turns.isEmpty { turns[turns.count - 1].entries.append(entry) }
                }
            }
        }
        return turns
    }

    private enum Event {
        case opener(Opener)
        case entry(Entry)
    }

    private static func parse(line: String) -> [Event] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return [] }
        let content = message["content"]

        switch object["type"] as? String {
        case "assistant":
            let blocks = content as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .entry(.text(text))
                case "tool_use":
                    return .entry(.toolUse)
                default:
                    return nil
                }
            }
        case "user":
            let blocks = content as? [[String: Any]] ?? []
            let text = content as? String ?? blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let origin = (object["origin"] as? [String: Any])?["kind"] as? String

            // A notification may be marked as injected context, and is still the start of a turn.
            if origin == "task-notification" || text.hasPrefix("<task-notification>") { return [.opener(.notification)] }
            // Injected context and compaction summaries are not the user speaking.
            if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return [] }

            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty { return results.map { .entry(.toolResult(resultText($0["content"]))) } }
            if content is String || !blocks.isEmpty { return userOpener(text).map { [.opener($0)] } ?? [] }
            return []
        default:
            return []
        }
    }

    /// A tool result's content is a string, or text blocks.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func userOpener(_ text: String) -> Opener? {
        if let name = text.firstMatch(of: /<command-name>\s*\/?([^<]*?)\s*<\/command-name>/) {
            let arguments = text.firstMatch(of: /<command-args>(.*?)<\/command-args>/.dotMatchesNewlines())
            return .command(name: String(name.1), arguments: arguments.map { String($0.1).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "")
        }
        // Output of a local command, echoed into the conversation.
        if text.hasPrefix("<local-command-") || text.hasPrefix("<command-") { return nil }
        return .prompt(text)
    }
}

extension Transcript.Entry {
    fileprivate var isText: Bool {
        if case .text = self { return true } else { return false }
    }
}

/// One of Claude's finished replies.
public struct Reply: Equatable, Sendable {
    /// What the user said that this reply answers, short enough for a title; nil when a background task started the turn.
    public var question: String?
    public var text: String

    public init(question: String?, text: String) {
        self.question = question
        self.text = text
    }
}

private extension String {
    var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// At most 60 characters, cut at a word.
    var cutForTitle: String {
        let limit = 60
        guard count > limit else { return self }
        let room = prefix(limit - 1)
        // Cut mid-word only when there is no word break to cut at.
        if !self[room.endIndex].isWhitespace, let space = room.lastIndex(of: " ") {
            return String(room[..<space]) + "…"
        }
        return String(room) + "…"
    }
}
