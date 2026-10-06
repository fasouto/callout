import AnnotatorCore
import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import AnnotatorUI

@MainActor
@Suite("Capture from other apps")
struct CaptureTests {
    private let wrapped = """
    ⏺ The plan has three parts. First we add a rate limiter in the
      middleware, then we return 429 with a Retry-After header.
    """

    @Test func terminalSelectionsAreCleanedAndKeepTheRawText() {
        let request = CaptureController.request(
            forText: wrapped, bundleIdentifier: "com.apple.Terminal", title: "Selection from Terminal", origin: .hotkey
        )
        #expect(request.content == .text(
            "The plan has three parts. First we add a rate limiter in the middleware, then we return 429 with a Retry-After header.",
            format: .markdown
        ))
        #expect(request.metadata.rawCapture == wrapped)
        #expect(request.metadata.sourceApp == "com.apple.Terminal")
        #expect(request.reply == .clipboard)
        #expect(request.modes == [.feedback, .applyEdits])
        #expect(request.origin == .hotkey)
    }

    @Test func otherAppsAreTakenAsTheyAre() {
        let request = CaptureController.request(forText: wrapped, bundleIdentifier: "com.apple.Safari", title: "Selection", origin: .service)
        #expect(request.content == .text(wrapped, format: .markdown))
        #expect(request.metadata.rawCapture == nil)
        #expect(request.origin == .service)
    }

    @Test func terminalTextThatNeedsNoCleaningHasNoRawVersion() {
        let request = CaptureController.request(forText: "ls -la", bundleIdentifier: "com.mitchellh.ghostty", title: "Selection", origin: .hotkey)
        #expect(request.content == .text("ls -la", format: .markdown))
        #expect(request.metadata.rawCapture == nil)
    }

    @Test func filesOpenByTheirKind() throws {
        let folder = NSTemporaryDirectory() + "annotator-files-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ contents: String) throws -> URL {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        let markdown = try #require(CaptureController.request(forFile: try file("post.md", "# Post"), origin: .fileDrop))
        #expect(markdown.content == .text("# Post", format: .markdown))
        #expect(markdown.modes == [.feedback, .applyEdits])
        #expect(markdown.metadata.title == "post.md")
        #expect(markdown.reply == .clipboard)

        let plain = try #require(CaptureController.request(forFile: try file("notes.txt", "# not a heading"), origin: .share))
        #expect(plain.content == .text("# not a heading", format: .plain))
        #expect(plain.origin == .share)

        let pdf = try #require(CaptureController.request(forFile: try file("cv.pdf", "%PDF"), origin: .fileDrop))
        #expect(pdf.content == .file(path: "\(folder)/cv.pdf"))
        #expect(pdf.modes == [.feedback])

        #expect(CaptureController.request(forFile: try file("photo.png", "x"), origin: .fileDrop) == nil)
        #expect(CaptureController.request(forFile: URL(fileURLWithPath: "\(folder)/missing.md"), origin: .fileDrop) == nil)
        #expect(!CaptureController.canOpen(URL(fileURLWithPath: "/tmp/a.docx")))
        #expect(CaptureController.canOpen(URL(fileURLWithPath: "/tmp/A.PDF")))
    }

    @Test func clipboardIsPutBackExactly() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("annotator-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("what the user had copied", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        pasteboard.writeObjects([item])

        let saved = SavedPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("the selection Annotator copied", forType: .string)
        saved.restore(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.private")) == Data([1, 2, 3]))
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    @Test func anEmptyClipboardIsPutBackEmpty() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("annotator-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let saved = SavedPasteboard(pasteboard)
        pasteboard.setString("copied", forType: .string)
        saved.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func shortcutsAreWrittenTheWayMenusWriteThem() {
        #expect(Hotkey.default.display == "⌥⌘A")
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey | cmdKey), key: "K").display == "⌃⇧⌘K")
    }

    @Test func aShortcutNeedsAModifierOtherThanShift() throws {
        func event(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
        }
        #expect(Hotkey(event: try event("a", 0, [])) == nil)
        #expect(Hotkey(event: try event("A", 0, [.shift])) == nil)
        let hotkey = try #require(Hotkey(event: try event("m", 46, [.command, .option])))
        #expect(hotkey.display == "⌥⌘M")
        #expect(hotkey.keyCode == 46)
        #expect(Hotkey(event: try event(" ", UInt16(kVK_Space), [.control]))?.display == "⌃Space")
    }

    @Test func aReviewOfATerminalCaptureCanShowTheTextAsCopied() throws {
        _ = NSApplication.shared
        let request = CaptureController.request(forText: wrapped, bundleIdentifier: "com.apple.Terminal", title: "Selection", origin: .hotkey)
        let controller = ReviewWindowController(request: request) { _ in }
        #expect(!controller.isShowingRawCapture)
        #expect(controller.session.source.hasPrefix("The plan has three parts."))

        controller.switchCapture()
        #expect(controller.isShowingRawCapture)
        #expect(controller.session.source == wrapped)

        controller.switchCapture()
        #expect(!controller.isShowingRawCapture)
        #expect(controller.session.source.hasSuffix("with a Retry-After header."))
        // The request, and so the answer, is still the same review.
        #expect(controller.session.request.id == request.id)
    }

    // MARK: Windows

    private func snapshot(_ view: some View, size: NSSize, named name: String) {
        _ = NSApplication.shared
        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"] else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        // In light, and in dark as <name>-dark.png.
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
        }
    }

    @Test func onboardingAndSettingsLayOut() {
        let onboarding = OnboardingView(hotkey: "⌥⌘A") {}
        snapshot(onboarding, size: NSSize(width: 480, height: 420), named: "onboarding")
        // Still waiting after Settings was opened: the switch is probably an earlier copy's.
        snapshot(OnboardingView(hotkey: "⌥⌘A", looksStale: true) {}, size: NSSize(width: 480, height: 420), named: "onboarding-stale")
        let settings = SettingsView {}
        snapshot(settings, size: NSSize(width: 500, height: 330), named: "settings")
    }
}
