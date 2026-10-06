import AnnotatorCore
import AnnotatorIPC
import AnnotatorStore
import AppKit
import CoreServices

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

/// What the app does when a person opens it, from Finder, Spotlight or
/// Launchpad. A menu-bar app that answered only with its icon would look as
/// if nothing had happened, so it shows the history of reviews.
enum Opening {
    /// Whether a launch was a person opening the app: not the command-line
    /// tool or a script starting it for a review, not a start at login, and
    /// not a launch to open a file, a link or a Services request.
    static func isByHand(arguments: [String], isDefaultLaunch: Bool, atLogin: Bool) -> Bool {
        isDefaultLaunch && !atLogin && !arguments.contains("--background") && !arguments.contains("--review")
    }

    /// A window the app already has, on screen or minimized: opening the app
    /// again brings that back instead.
    @MainActor static func hasWindow(_ windows: [NSWindow]) -> Bool {
        windows.contains { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
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
        } else if Opening.isByHand(
            arguments: arguments,
            isDefaultLaunch: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true,
            atLogin: Self.wasLaunchedAtLogin
        ) {
            history.show()
        }
    }

    /// macOS says so in the event that launched the app.
    private static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Opened again while it is running. AppKit brings back a window that is
    /// open or minimized; with none, the history is the window there is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Opening.hasWindow(sender.windows) else { return true }
        history.show()
        return false
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

    @objc func showPracticeReview(_ sender: Any?) {
        showWelcome()
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
