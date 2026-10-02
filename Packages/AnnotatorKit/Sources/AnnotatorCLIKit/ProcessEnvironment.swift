import AnnotatorIPC
import Foundation

extension CLIEnvironment {
    /// The real process: its arguments, streams and environment.
    public static func process() -> CLIEnvironment {
        let variables = ProcessInfo.processInfo.environment
        return CLIEnvironment(
            arguments: CommandLine.arguments,
            variables: variables,
            readStandardInput: { FileHandle.standardInput.readDataToEndOfFile() },
            standardInputIsTerminal: isatty(STDIN_FILENO) != 0,
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            socketPath: AnnotatorPaths.socketPath(environment: variables),
            toolPath: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0],
            launchApp: { AppLauncher.launch(variables: variables) }
        )
    }
}

/// Starts the app when the tool finds nobody listening.
enum AppLauncher {
    static func launch(variables: [String: String]) -> Bool {
        // An explicit choice wins, then the bundle this tool ships in, then a
        // development build next to it, then whatever copy the system knows.
        if let custom = variables["ANNOTATOR_APP"], !custom.isEmpty {
            return custom.hasSuffix(".app") ? open(["-g", custom]) : spawn(custom)
        }
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        if let range = executable.range(of: ".app/Contents/") {
            return open(["-g", String(executable[..<range.lowerBound]) + ".app"])
        }
        let sibling = ((executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent("AnnotatorApp")
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return spawn(sibling)
        }
        return open(["-g", "-b", AnnotatorPaths.bundleIdentifier])
    }

    private static func open(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs an unbundled build and leaves it running.
    private static func spawn(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // The app must not hold this tool's pipes open, or whoever reads them
        // would wait for the app to quit.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
