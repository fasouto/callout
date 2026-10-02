import AnnotatorCore
import AnnotatorIPC
import AppKit

/// The app's entry point, shared by the app bundle and the unbundled development build.
@MainActor
public enum AnnotatorApplication {
    private static let delegate = AppDelegate()

    public static func run() {
        let application = NSApplication.shared
        application.delegate = delegate
        // A menu-bar app: no Dock icon, and windows only when there is something to review.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = ReviewCoordinator()
    private var statusItem: StatusItemController?
    private var ipc: IPCService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ipc = IPCService(coordinator: coordinator)
        do {
            try ipc.start()
            self.ipc = ipc
        } catch SocketError.alreadyRunning {
            // One copy of the app serves every request.
            NSApp.terminate(nil)
            return
        } catch {
            // Without the socket the app still works from its own menu.
            NSLog("Annotator: could not listen for requests: \(error)")
        }

        NSApp.mainMenu = MainMenu.make()
        statusItem = StatusItemController(reviewClipboard: { [weak self] in self?.reviewClipboard() })

        // Development aid: `AnnotatorApp --review <file>` opens that text file at launch.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--review"), arguments.indices.contains(flag + 1) {
            reviewFile(at: arguments[flag + 1])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipc?.stop()
    }

    private func reviewClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.nilIfBlank else {
            Toast.show("The clipboard has no text")
            return
        }
        coordinator.open(ReviewRequest(
            content: .text(text, format: .markdown),
            origin: .hotkey,
            metadata: ReviewMetadata(title: "Clipboard"),
            reply: .clipboard,
            modes: [.feedback, .applyEdits]
        ))
    }

    private func reviewFile(at path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            Toast.show("Could not read \(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        let isMarkdown = ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        coordinator.open(ReviewRequest(
            content: .text(text, format: isMarkdown ? .markdown : .plain),
            origin: .fileDrop,
            metadata: ReviewMetadata(filePath: path),
            reply: .clipboard,
            modes: [.feedback, .applyEdits]
        ))
    }
}
