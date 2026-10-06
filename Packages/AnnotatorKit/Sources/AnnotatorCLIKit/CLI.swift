import AnnotatorCore
import AnnotatorIPC
import Foundation

/// Everything the tool touches from outside, so tests can stand in for it.
public struct CLIEnvironment {
    public var arguments: [String]
    public var variables: [String: String]
    public var currentDirectory: String
    public var homeDirectory: String
    public var readStandardInput: () -> Data
    public var standardInputIsTerminal: Bool
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var socketPath: String
    /// Absolute path of the tool itself, for writing into settings.
    public var toolPath: String
    /// Starts the app. Returns false when there is nothing to start.
    public var launchApp: () -> Bool
    /// How long to wait for a freshly launched app to answer.
    public var launchTimeout: TimeInterval

    public init(
        arguments: [String],
        variables: [String: String] = [:],
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        homeDirectory: String = NSHomeDirectory(),
        readStandardInput: @escaping () -> Data = { Data() },
        standardInputIsTerminal: Bool = false,
        out: @escaping (String) -> Void,
        err: @escaping (String) -> Void,
        socketPath: String,
        toolPath: String = "/usr/local/bin/annotator",
        launchApp: @escaping () -> Bool = { false },
        launchTimeout: TimeInterval = 5
    ) {
        self.arguments = arguments
        self.variables = variables
        self.currentDirectory = currentDirectory
        self.homeDirectory = homeDirectory
        self.readStandardInput = readStandardInput
        self.standardInputIsTerminal = standardInputIsTerminal
        self.out = out
        self.err = err
        self.socketPath = socketPath
        self.toolPath = toolPath
        self.launchApp = launchApp
        self.launchTimeout = launchTimeout
    }
}

public enum ExitCode {
    public static let success: Int32 = 0
    /// A finished review was asked for and there is none.
    public static let nothingFound: Int32 = 1
    public static let failure: Int32 = 1
    /// The command line could not be understood.
    public static let usage: Int32 = 64
    /// What was to be reviewed could not be read.
    public static let noInput: Int32 = 66
}

public enum AnnotatorCLI {
    public static let version = "0.1.0"

    static let usage = """
    Usage:
      annotator review [file | -] [options]   Open a review and wait for the response
      annotator result [id] [--session <id>]  Print a finished review again
      annotator last-reply [--session <id>]   Review Claude's last reply in a Claude Code session
      annotator hook                          Claude Code plan hook (reads the hook JSON on standard input)
      annotator install [--settings <file>]   Add the plan hook to ~/.claude/settings.json
      annotator uninstall [--settings <file>] Remove it again

    Options for review:
      --title <text>            Title shown in the window
      --origin <origin>         plan-hook, last-reply, agent-request (default), hotkey, service, file-drop, share
      --reply stdout|clipboard  Where the response goes (default: stdout)
      --format markdown|plain   How to read standard input (default: markdown)
      --modes <list>            Comma-separated: feedback, apply-edits, approve
      --session <id>            Session the review belongs to
      --json                    Print the raw result

    A file ending in .pdf is opened as a PDF; any other file is read as text.
    If the app cannot be reached, the tool says so and exits successfully.
    Exit status: 0 done, or no review; 1 no finished review to print, or
    settings left untouched; 64 the command line is wrong; 66 the file cannot be read.
    """

    public static func run(_ environment: CLIEnvironment) -> Int32 {
        var arguments = Arguments(Array(environment.arguments.dropFirst()))
        guard let command = arguments.next() else {
            environment.err(usage)
            return ExitCode.usage
        }
        do {
            switch command {
            case "review":
                return try ReviewCommand(arguments: &arguments, environment: environment).run()
            case "result":
                return try ResultCommand(arguments: &arguments, environment: environment).run()
            case "last-reply":
                return try LastReplyCommand(arguments: &arguments, environment: environment).run()
            case "hook":
                return HookCommand(environment: environment).run()
            case "install":
                return try InstallCommand(arguments: &arguments, environment: environment, removing: false).run()
            case "uninstall":
                return try InstallCommand(arguments: &arguments, environment: environment, removing: true).run()
            case "--version", "version":
                environment.out("annotator \(version)")
                return ExitCode.success
            case "--help", "-h", "help":
                environment.out(usage)
                return ExitCode.success
            default:
                throw UsageError("Unknown command \"\(command)\".")
            }
        } catch let error as UsageError {
            environment.err("annotator: \(error.message)\n\n\(usage)")
            return ExitCode.usage
        } catch let error as InputError {
            // The command was understood: the usage would only bury what went wrong.
            environment.err("annotator: \(error.message)")
            return ExitCode.noInput
        } catch {
            environment.err("annotator: \(error.localizedDescription)")
            return ExitCode.usage
        }
    }
}

struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// The file or the text to review could not be read.
struct InputError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A cursor over the command line.
struct Arguments {
    private var remaining: [String]

    init(_ arguments: [String]) {
        remaining = arguments
    }

    mutating func next() -> String? {
        remaining.isEmpty ? nil : remaining.removeFirst()
    }

    /// The value that follows an option.
    mutating func value(for option: String) throws -> String {
        guard let value = next() else { throw UsageError("\(option) needs a value.") }
        return value
    }
}

// MARK: - Reaching the app

enum AppConnection {
    /// Connects to the app, starting it when it is not running. Nil when it stays unreachable.
    static func open(_ environment: CLIEnvironment) -> SocketClient? {
        if let client = try? SocketClient(path: environment.socketPath) { return client }
        guard environment.launchApp() else { return nil }

        let deadline = Date().addingTimeInterval(environment.launchTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let client = try? SocketClient(path: environment.socketPath) { return client }
        }
        return nil
    }

    static let acceptTimeout: TimeInterval = 5
}

enum Output {
    /// What a result looks like on standard output.
    static func text(for result: ReviewResult, json: Bool) -> String {
        if json, let data = try? JSONEncoder().encode(result), let text = String(data: data, encoding: .utf8) {
            return text
        }
        switch result.decision {
        case .cancel:
            return "The review was cancelled. No feedback was given."
        case .approve:
            return "Approved. No changes requested."
        case .feedback:
            return result.editedText ?? result.feedback ?? "No changes requested."
        }
    }
}
