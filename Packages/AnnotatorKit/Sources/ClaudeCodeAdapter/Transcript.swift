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

    // MARK: - Reading the last reply

    public static func lastReply(inTranscriptAt path: String, command: String = "annotate-last") -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return lastReply(in: text, command: command)
    }

    /// Claude's last finished reply: the text it ended a turn with, before the
    /// command that asked for this review.
    static func lastReply(in transcript: String, command: String = "annotate-last") -> String? {
        let entries = transcript.split(whereSeparator: \.isNewline).flatMap { parse(line: String($0)) }

        // Everything from the command on belongs to the turn that is running now.
        var boundary = entries.count
        if let invoked = entries.lastIndex(where: { if case .command(let name) = $0 { return name.contains(command) } else { return false } }) {
            boundary = invoked
        } else if let prompt = entries.lastIndex(of: .prompt) {
            boundary = prompt
        }

        // Walk back to the turn before it, past prompts that got no reply.
        var turn: [Entry] = []
        for entry in entries[..<boundary].reversed() {
            if entry == .prompt {
                if turn.contains(where: \.isText) { break }
                turn.removeAll()
            } else {
                turn.insert(entry, at: 0)
            }
        }

        // The reply is what came after the last tool call; a turn that ended on
        // a tool call is taken whole.
        let final = turn.split(separator: .toolUse, omittingEmptySubsequences: false).last.map(Array.init) ?? []
        let chosen = final.contains(where: \.isText) ? final : turn
        let texts = chosen.compactMap { entry -> String? in
            if case .text(let text) = entry { return text } else { return nil }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private enum Entry: Equatable {
        /// Something the user typed.
        case prompt
        /// A slash command the user ran.
        case command(String)
        /// Text Claude wrote.
        case text(String)
        case toolUse

        var isText: Bool {
            if case .text = self { return true } else { return false }
        }
    }

    private static func parse(line: String) -> [Entry] {
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
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    return .toolUse
                default:
                    return nil
                }
            }
        case "user":
            // Injected context and compaction summaries are not the user speaking.
            if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return [] }
            if let text = content as? String { return userEntry(text) }
            let blocks = content as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return [] }
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return blocks.isEmpty ? [] : userEntry(text)
        default:
            return []
        }
    }

    private static func userEntry(_ text: String) -> [Entry] {
        if let name = text.firstMatch(of: /<command-name>\s*\/?([^<]*?)\s*<\/command-name>/) {
            return [.command(String(name.1))]
        }
        // Output of a local command, echoed into the conversation.
        if text.hasPrefix("<local-command-") || text.hasPrefix("<command-") { return [] }
        return [.prompt]
    }
}
