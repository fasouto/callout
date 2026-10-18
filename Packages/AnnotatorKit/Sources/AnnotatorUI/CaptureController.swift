import AnnotatorCore
import AppKit

/// The ways text and files get into the app from outside Claude Code: the
/// hotkey, the Services menu, files dropped on the menu-bar icon or shared.
/// Every one of them answers to the clipboard.
@MainActor
final class CaptureController: NSObject {
    private let coordinator: ReviewCoordinator
    private lazy var onboarding = AccessibilityOnboarding()

    init(coordinator: ReviewCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: Hotkey

    func startHotkey() {
        HotkeyCenter.shared.onPress = { [weak self] in self?.captureSelection() }
        HotkeyCenter.shared.register(Hotkey.stored)
    }

    func showOnboarding() {
        onboarding.show()
    }

    func captureSelection() {
        let app = NSWorkspace.shared.frontmostApplication
        guard SelectionCapture.isAllowed else {
            onboarding.show()
            return
        }
        Task {
            guard let text = await SelectionCapture.capture()?.nilIfBlank else {
                Toast.show("Nothing is selected in \(app?.localizedName ?? "the app in front")", symbol: "text.cursor")
                return
            }
            review(text: text, from: app, origin: .hotkey)
        }
    }

    // MARK: Text

    func reviewClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.nilIfBlank else {
            Toast.show("The clipboard has no text", symbol: "clipboard")
            return
        }
        open(Self.request(forText: text, bundleIdentifier: nil, title: "Clipboard", origin: .hotkey))
    }

    func review(text: String, from app: NSRunningApplication?, origin: ReviewOrigin) {
        let name = app?.localizedName
        open(Self.request(
            forText: text, bundleIdentifier: app?.bundleIdentifier,
            title: name.map { "Selection from \($0)" } ?? "Selection", origin: origin
        ))
    }

    /// The request for captured text. Text from a terminal is cleaned up, and
    /// the capture as it was copied is kept so the review can show it instead.
    static func request(forText text: String, bundleIdentifier: String?, title: String, origin: ReviewOrigin) -> ReviewRequest {
        var content = text
        var raw: String?
        if TerminalCleanup.isTerminal(bundleIdentifier: bundleIdentifier) {
            let cleaned = TerminalCleanup.clean(text)
            if cleaned != text, !cleaned.isEmpty {
                content = cleaned
                raw = text
            }
        }
        return ReviewRequest(
            content: .text(content, format: .markdown),
            origin: origin,
            metadata: ReviewMetadata(sourceApp: bundleIdentifier, title: title, rawCapture: raw),
            reply: .clipboard,
            modes: [.feedback, .applyEdits]
        )
    }

    // MARK: Files

    static let textExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text"]

    static func canOpen(_ url: URL) -> Bool {
        let type = url.pathExtension.lowercased()
        return type == "pdf" || textExtensions.contains(type)
    }

    /// Opens a `.md`, `.txt` or `.pdf` file for review.
    func review(file url: URL, origin: ReviewOrigin) {
        guard let request = Self.request(forFile: url, origin: origin) else {
            let name = url.lastPathComponent
            let message = !Self.canOpen(url) ? "Annotator opens .md, .txt and .pdf files"
                : Self.isBlankText(url) ? "\(name) is empty" : "\(name) could not be read"
            Toast.show(message, symbol: "doc.questionmark")
            return
        }
        open(request)
    }

    static func request(forFile url: URL, origin: ReviewOrigin) -> ReviewRequest? {
        let type = url.pathExtension.lowercased()
        let metadata = ReviewMetadata(title: url.lastPathComponent, filePath: url.path)
        if type == "pdf" {
            guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return ReviewRequest(content: .file(path: url.path), origin: origin, metadata: metadata, reply: .clipboard, modes: [.feedback])
        }
        guard textExtensions.contains(type), let text = try? String(contentsOf: url, encoding: .utf8),
              text.nilIfBlank != nil else { return nil }
        return ReviewRequest(
            content: .text(text, format: type.hasPrefix("m") ? .markdown : .plain),
            origin: origin, metadata: metadata, reply: .clipboard, modes: [.feedback, .applyEdits]
        )
    }

    /// A text file that reads, but holds nothing a review could show.
    private static func isBlankText(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8)).map { $0.nilIfBlank == nil } ?? false
    }

    /// Handles `annotator://open?path=…`, which the Share extension sends, and plain file URLs.
    func open(url: URL) {
        if url.isFileURL {
            review(file: url, origin: .fileDrop)
        } else if url.scheme == "annotator", url.host == "open",
                  let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
            review(file: URL(fileURLWithPath: path), origin: .share)
        }
    }

    private func open(_ request: ReviewRequest) {
        coordinator.open(request)
    }

    // MARK: Services menu

    /// "Annotate with Annotator" in other apps' Services menus.
    @objc func annotateSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string)?.nilIfBlank else {
            error.pointee = "There is no text to annotate."
            return
        }
        review(text: text, from: NSWorkspace.shared.frontmostApplication, origin: .service)
    }
}
