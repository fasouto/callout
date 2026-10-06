import AnnotatorCore
import AnnotatorIPC
import AnnotatorStore
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
    private let store: Store?
    private let coordinator: ReviewCoordinator
    private lazy var capture = CaptureController(coordinator: coordinator)
    private lazy var settings = SettingsWindow(
        store: store,
        showOnboarding: { [weak self] in self?.capture.showOnboarding() },
        showWelcome: { [weak self] in self?.showWelcome() }
    )
    private lazy var history = HistoryWindow(store: store)
    private let welcomeFinish = WelcomeFinish()
    private let dockPresence = DockPresence()

    override init() {
        // Without its database the app still reviews; it only forgets.
        store = try? Store(path: Store.defaultPath)
        coordinator = ReviewCoordinator(store: store)
        super.init()
    }

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
        dockPresence.start()
        // "Annotate with Annotator" in other apps' Services menus.
        NSApp.servicesProvider = capture
        capture.startHotkey()
        statusItem = StatusItemController(actions: .init(
            markUpSelection: { [weak self] in self?.capture.captureSelection() },
            reviewClipboard: { [weak self] in self?.capture.reviewClipboard() },
            openFile: { [weak self] url in self?.capture.review(file: url, origin: .fileDrop) },
            showHistory: { [weak self] in self?.history.show() },
            showSettings: { [weak self] in self?.settings.show() }
        ))

        // Development aid: `AnnotatorApp --review <file>` opens that file at launch.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--review"), arguments.indices.contains(flag + 1) {
            capture.review(file: URL(fileURLWithPath: arguments[flag + 1]), origin: .fileDrop)
        } else if !Welcome.hasBeenShown {
            // The first launch opens a practice review that teaches the marks.
            showWelcome()
        }
    }

    // The app's own menu bar, shown while a window is open.

    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show()
    }

    @objc func showSettings(_ sender: Any?) {
        settings.show()
    }

    @objc func showHistory(_ sender: Any?) {
        history.show()
    }

    private func showWelcome() {
        Welcome.hasBeenShown = true
        coordinator.openWelcome { [weak self] result in
            guard let self, result.decision != .cancel, let feedback = result.feedback else { return }
            self.welcomeFinish.show(feedback: feedback) { [weak self] in self?.capture.showOnboarding() }
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
