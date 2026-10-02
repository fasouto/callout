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
    private lazy var capture = CaptureController(coordinator: coordinator)
    private lazy var settings = SettingsWindow(showOnboarding: { [weak self] in self?.capture.showOnboarding() })
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
        // "Annotate with Annotator" in other apps' Services menus.
        NSApp.servicesProvider = capture
        capture.startHotkey()
        statusItem = StatusItemController(actions: .init(
            markUpSelection: { [weak self] in self?.capture.captureSelection() },
            reviewClipboard: { [weak self] in self?.capture.reviewClipboard() },
            openFile: { [weak self] url in self?.capture.review(file: url, origin: .fileDrop) },
            showSettings: { [weak self] in self?.settings.show() }
        ))

        // Development aid: `AnnotatorApp --review <file>` opens that file at launch.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--review"), arguments.indices.contains(flag + 1) {
            capture.review(file: URL(fileURLWithPath: arguments[flag + 1]), origin: .fileDrop)
        }
    }

    /// Files opened with the app, and `annotator://` links from the Share extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { capture.open(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyCenter.shared.unregister()
        ipc?.stop()
    }
}
