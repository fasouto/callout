import Foundation

/// Adds the plan hook to a Claude Code `settings.json`, and takes it out again,
/// for people who do not use the plugin. The file is edited in place: its key
/// order, spacing and everything unrelated stay as they are.
public enum SettingsInstaller {
    public enum Outcome: Equatable {
        case installed(backup: String?)
        case alreadyInstalled
        case removed(backup: String?)
        case notInstalled
    }

    public enum Failure: Error, Equatable {
        /// The file is not a JSON object, so it is left alone.
        case unreadable(String)
        /// The edit did not produce what was intended; nothing was written.
        case editFailed
        /// The file is read-only, so it is left alone.
        case readOnly(String)
    }

    public static func defaultSettingsPath() -> String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    /// The hook entry, as Claude Code's settings describe it.
    static func entry(toolPath: String) -> [String: Any] {
        [
            "matcher": "ExitPlanMode",
            "hooks": [
                ["type": "command", "command": toolPath, "args": ["hook"], "timeout": hookTimeout] as [String: Any],
            ],
        ]
    }

    /// Seconds. A review can stay open for a long time; when the hook is
    /// cancelled at this limit Claude Code shows its own dialog.
    public static let hookTimeout = 86_400

    // MARK: - Install

    public static func install(toolPath: String, settingsPath given: String, now: Date = Date()) throws -> Outcome {
        let settingsPath = resolved(given)
        let manager = FileManager.default
        guard manager.fileExists(atPath: settingsPath) else {
            let fresh: [String: Any] = ["hooks": ["PermissionRequest": [entry(toolPath: toolPath)]]]
            try manager.createDirectory(
                atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try write(try serialize(fresh, indent: "") + "\n", to: settingsPath)
            return .installed(backup: nil)
        }

        let text = try read(settingsPath)
        let settings = try parse(text, path: settingsPath)
        if !ownEntries(in: settings).isEmpty { return .alreadyInstalled }
        try requireWritable(settingsPath)

        var expected = settings
        var hooks = expected["hooks"] as? [String: Any] ?? [:]
        var requests = hooks["PermissionRequest"] as? [Any] ?? []
        requests.append(entry(toolPath: toolPath))
        hooks["PermissionRequest"] = requests
        expected["hooks"] = hooks

        let edited = try insert(entry(toolPath: toolPath), into: text)
        // The text edit is only kept when it means exactly what was intended.
        guard let reparsed = try? parse(edited, path: settingsPath),
              NSDictionary(dictionary: reparsed).isEqual(to: expected) else { throw Failure.editFailed }

        let backup = try makeBackup(of: settingsPath, now: now)
        try write(edited, to: settingsPath)
        return .installed(backup: backup)
    }

    private static func insert(_ entry: [String: Any], into text: String) throws -> String {
        var json = JSONText(text)
        guard let root = json.rootObject() else { throw Failure.editFailed }

        if let hooks = json.member("hooks", of: root) {
            guard let hooksObject = json.object(at: hooks.value) else { throw Failure.editFailed }
            if let requests = json.member("PermissionRequest", of: hooksObject) {
                guard let array = json.array(at: requests.value) else { throw Failure.editFailed }
                let indent = array.childIndent ?? requests.indent + json.indentUnit
                try json.append(try serialize(entry, indent: indent, unit: json.indentUnit), to: array, indent: indent, closingIndent: requests.indent)
            } else {
                let indent = hooksObject.childIndent ?? hooks.indent + json.indentUnit
                let value = try serialize([entry], indent: indent, unit: json.indentUnit)
                try json.append("\"PermissionRequest\": \(value)", to: hooksObject, indent: indent, closingIndent: hooks.indent)
            }
        } else {
            let indent = root.childIndent ?? json.indentUnit
            let value = try serialize(["PermissionRequest": [entry]], indent: indent, unit: json.indentUnit)
            try json.append("\"hooks\": \(value)", to: root, indent: indent, closingIndent: "")
        }
        return json.text
    }

    // MARK: - Uninstall

    public static func uninstall(settingsPath given: String, now: Date = Date()) throws -> Outcome {
        let settingsPath = resolved(given)
        guard FileManager.default.fileExists(atPath: settingsPath) else { return .notInstalled }
        let text = try read(settingsPath)
        let settings = try parse(text, path: settingsPath)
        let own = ownEntries(in: settings)
        guard !own.isEmpty else { return .notInstalled }
        try requireWritable(settingsPath)

        var expected = settings
        var hooks = expected["hooks"] as? [String: Any] ?? [:]
        var requests = hooks["PermissionRequest"] as? [Any] ?? []
        for index in own.reversed() { requests.remove(at: index) }
        if requests.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = requests }
        if hooks.isEmpty { expected["hooks"] = nil } else { expected["hooks"] = hooks }

        var json = JSONText(text)
        guard let root = json.rootObject(), let hooksMember = json.member("hooks", of: root),
              let hooksObject = json.object(at: hooksMember.value),
              let requestsMember = json.member("PermissionRequest", of: hooksObject),
              let array = json.array(at: requestsMember.value) else { throw Failure.editFailed }

        // Remove the smallest thing that leaves no empty shell behind.
        if requests.isEmpty, hooks.isEmpty {
            json.remove(hooksMember, from: root)
        } else if requests.isEmpty {
            json.remove(requestsMember, from: hooksObject)
        } else {
            for index in own.reversed() { json.remove(elementAt: index, from: json.array(at: requestsMember.value) ?? array) }
        }
        guard let reparsed = try? parse(json.text, path: settingsPath),
              NSDictionary(dictionary: reparsed).isEqual(to: expected) else { throw Failure.editFailed }

        let backup = try makeBackup(of: settingsPath, now: now)
        try write(json.text, to: settingsPath)
        return .removed(backup: backup)
    }

    /// Indexes of this tool's entries in `hooks.PermissionRequest`.
    static func ownEntries(in settings: [String: Any]) -> [Int] {
        let requests = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] ?? []
        return requests.indices.filter { index in
            guard let group = requests[index] as? [String: Any], group["matcher"] as? String == "ExitPlanMode",
                  let handlers = group["hooks"] as? [[String: Any]] else { return false }
            return handlers.contains { handler in
                let command = handler["command"] as? String ?? ""
                let arguments = handler["args"] as? [String] ?? []
                let name = (command as NSString).lastPathComponent
                return (name == "callout" && arguments == ["hook"]) || command.hasSuffix("callout hook")
            }
        }
    }

    // MARK: - Files

    /// The file itself: settings kept in a dotfiles folder and linked into
    /// place are edited where they live, and the link stays a link.
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteURL.resolvingSymlinksInPath().path
    }

    /// A file the user made read-only is theirs to unlock.
    private static func requireWritable(_ path: String) throws {
        guard FileManager.default.isWritableFile(atPath: path) else { throw Failure.readOnly(path) }
    }

    private static func read(_ path: String) throws -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw Failure.unreadable(path) }
        return text
    }

    private static func parse(_ text: String, path: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure.unreadable(path)
        }
        return object
    }

    private static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func makeBackup(of path: String, now: Date) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = "\(path).callout-backup-\(formatter.string(from: now))"
        if FileManager.default.fileExists(atPath: backup) { try FileManager.default.removeItem(atPath: backup) }
        try FileManager.default.copyItem(atPath: path, toPath: backup)
        return backup
    }

    /// Pretty JSON whose continuation lines sit at `indent`, nested with `unit`.
    private static func serialize(_ value: Any, indent: String, unit: String = "  ") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.editFailed }
        let lines = text.replacingOccurrences(of: "\" : ", with: "\": ").components(separatedBy: "\n")
        return lines.enumerated()
            .map { offset, line -> String in
                // The serializer nests with two spaces; use the file's own unit instead.
                let depth = line.prefix { $0 == " " }.count / 2
                let content = line.drop { $0 == " " }
                return (offset == 0 ? "" : indent) + String(repeating: unit, count: depth) + content
            }
            .joined(separator: "\n")
    }
}
