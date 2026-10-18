import AnnotatorCore
import AnnotatorIPC
import ClaudeCodeAdapter
import Foundation

/// `annotator hook`: Claude Code's `PermissionRequest` hook for `ExitPlanMode`.
///
/// Whatever goes wrong, this prints nothing and exits 0: Claude Code then shows
/// its own plan dialog, exactly as if the hook were not installed.
struct HookCommand {
    let environment: CLIEnvironment

    func run() -> Int32 {
        guard let input = HookInput.decode(environment.readStandardInput()),
              let request = PlanHook.request(for: input),
              let client = AppConnection.open(environment) else { return ExitCode.success }
        defer { client.close() }

        do {
            try client.send(.review(request))
            guard case .accepted = try client.receive(timeout: AppConnection.acceptTimeout) else { return ExitCode.success }
            while true {
                if case .result(let result) = try client.receive(timeout: nil) {
                    if let output = PlanHook.output(for: result) { environment.out(output) }
                    return ExitCode.success
                }
            }
        } catch {
            return ExitCode.success
        }
    }
}

/// `annotator install` and `annotator uninstall`: the plan hook in
/// `~/.claude/settings.json`, for people who do not use the plugin.
struct InstallCommand {
    private let environment: CLIEnvironment
    private let removing: Bool
    private var settingsPath = SettingsInstaller.defaultSettingsPath()

    init(arguments: inout Arguments, environment: CLIEnvironment, removing: Bool) throws {
        self.environment = environment
        self.removing = removing
        while let argument = arguments.next() {
            guard argument == "--settings" else { throw UsageError("Unknown option \(argument).") }
            settingsPath = try arguments.value(for: argument)
        }
    }

    func run() -> Int32 {
        do {
            let outcome = removing
                ? try SettingsInstaller.uninstall(settingsPath: settingsPath)
                : try SettingsInstaller.install(toolPath: environment.toolPath, settingsPath: settingsPath)
            switch outcome {
            case .installed(let backup):
                environment.out("Added the plan hook to \(settingsPath).")
                if let backup { environment.out("The previous file is saved as \(backup).") }
                environment.out("Start a new Claude Code session for it to take effect.")
            case .alreadyInstalled:
                environment.out("The plan hook is already in \(settingsPath). Nothing changed.")
            case .removed(let backup):
                environment.out("Removed the plan hook from \(settingsPath).")
                if let backup { environment.out("The previous file is saved as \(backup).") }
            case .notInstalled:
                environment.out("There is no plan hook in \(settingsPath). Nothing changed.")
            }
            return ExitCode.success
        } catch SettingsInstaller.Failure.unreadable {
            environment.err("annotator: \(settingsPath) is not valid JSON, so it was left untouched.")
        } catch SettingsInstaller.Failure.readOnly {
            environment.err("annotator: \(settingsPath) is read-only, so it was left untouched.")
        } catch {
            environment.err("annotator: \(settingsPath) could not be edited safely, so it was left untouched.")
        }
        return ExitCode.failure
    }
}
