import CalloutCore
import AppKit
import SwiftUI
import Testing
@testable import CalloutUI

/// One step of the demo: what is done to the review, what the viewer is told about it,
/// and how long the frame it leaves holds.
private struct Step {
    enum Action {
        case rest
        case select(String)
        case press(letter: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
        case typeInField(String)
        case typeOnSelection(String)
        case finishWriting
    }

    let action: Action
    var caption: Caption?
    var hold: Double
    /// Seconds each typed character stays on screen.
    var perCharacter = 0.09

    init(_ action: Action, caption: Caption? = nil, hold: Double) {
        self.action = action
        self.caption = caption
        self.hold = hold
    }
}

private struct Caption {
    let keys: String
    let label: String
}

private let demoFolder = ProcessInfo.processInfo.environment["CALLOUT_DEMO_DIR"]

private let captionSeconds = 1.3

private let storyboard: [Step] = [
    Step(.rest, hold: 1.5),

    Step(.select("leverage"), hold: 0.7),
    Step(.press(letter: "r", keyCode: 15, modifiers: .option), caption: Caption(keys: "⌥R", label: "Replace"), hold: 0.5),
    Step(.typeInField("use"), hold: 0.6),
    Step(.finishWriting, hold: 0.8),

    Step(.select("very robust "), hold: 0.7),
    Step(.press(letter: "d", keyCode: 2, modifiers: .option), caption: Caption(keys: "⌥D", label: "Delete"), hold: 1.2),

    Step(.select("token bucket"), hold: 0.7),
    Step(.typeOnSelection("Why not a sliding window?"), caption: Caption(keys: "Type", label: "Comment"), hold: 0.6),
    Step(.finishWriting, hold: 0.8),

    Step(.select("Return 429 with a Retry-After header"), hold: 0.7),
    Step(.press(letter: "k", keyCode: 40, modifiers: .option), caption: Caption(keys: "⌥K", label: "Keep"), hold: 1.2),

    Step(.press(letter: "o", keyCode: 31, modifiers: .command), caption: Caption(keys: "⌘O", label: "Overall comment"), hold: 0.6),
    Step(.typeInField("Too complex, simplify."), hold: 0.6),
    Step(.finishWriting, hold: 2.2),
]

extension OnTheMainThread {
    /// Replays `storyboard` on the real review window and writes the frames for
    /// `scripts/make-demo.sh` into `CALLOUT_DEMO_DIR`: numbered PNGs and `frames.txt`,
    /// which says how long each one is shown. Does nothing when the variable is unset.
    @MainActor
    @Suite("Demo video")
    struct DemoVideoTests {
        @Test(.enabled(if: demoFolder != nil)) func recordsTheDemoFrames() async throws {
            let directory = URL(fileURLWithPath: try #require(demoFolder))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            _ = NSApplication.shared
            let request = ReviewRequest(
                content: .text(ReviewWindowTests.source, format: .markdown), origin: .planHook,
                metadata: ReviewMetadata(title: "Plan"), reply: .stdout, modes: [.feedback, .applyEdits]
            )
            let session = ReviewSession(request: request)
            let window = SnapshotWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: ReviewView(session: session, finish: { _ in }))
            await settle(window)
            let textView = try #require(Self.findTextView(in: window.contentView))
            textView.usesVimKeys = false
            window.makeFirstResponder(textView)
            await settle(window)

            var recorder = Recorder(directory: directory)
            for step in storyboard {
                if let caption = step.caption { recorder.show(caption) }
                switch step.action {
                case .rest:
                    break
                case .select(let phrase):
                    textView.setSelectedRange((textView.string as NSString).range(of: phrase))
                case .press(let letter, let keyCode, let modifiers):
                    try Self.keyDown(letter, keyCode: keyCode, modifiers: modifiers, window: window, textView: textView)
                case .typeInField(let text):
                    await settle(window)
                    for character in text {
                        try Self.insert(String(character), in: window)
                        await settle(window)
                        try recorder.frame(of: window, seconds: step.perCharacter)
                    }
                case .typeOnSelection(let text):
                    var rest = Substring(text)
                    try Self.keyDown(String(rest.removeFirst()), keyCode: 0, modifiers: [], window: window, textView: textView)
                    await settle(window)
                    try recorder.frame(of: window, seconds: step.perCharacter)
                    for character in rest {
                        try Self.insert(String(character), in: window)
                        await settle(window)
                        try recorder.frame(of: window, seconds: step.perCharacter)
                    }
                case .finishWriting:
                    session.endEditing()
                }
                await settle(window)
                try recorder.frame(of: window, seconds: step.hold)
            }
            try recorder.finish()
            #expect(session.marks.map(\.kind) == [.replace, .delete, .comment, .keep])
            #expect(session.generalComment == "Too complex, simplify.")
        }

        private func settle(_ window: NSWindow) async {
            for _ in 0..<3 {
                spin(window)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }

        private func spin(_ window: NSWindow) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        private static func findTextView(in view: NSView?) -> AnnotationTextView? {
            guard let view else { return nil }
            if let textView = view as? AnnotationTextView { return textView }
            return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
        }

        private static func keyDown(
            _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow, textView: AnnotationTextView
        ) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            // A Command key is the window's shortcut, as ⌘O is the overall comment's button; the rest are the text view's.
            if modifiers.contains(.command) { _ = window.performKeyEquivalent(with: event) } else { textView.keyDown(with: event) }
        }

        private static func insert(_ text: String, in window: NSWindow) throws {
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}

/// Writes frames and the list of how long each shows, drawing the window on a
/// backdrop and the key caption over the first moments after a shortcut.
@MainActor
private struct Recorder {
    let directory: URL
    private var listing = "ffconcat version 1.0\n"
    private var count = 0
    private var captionLeft = 0.0
    private var caption: Caption?
    private var lastFile = ""

    private static let margin = (side: 110, top: 90, bottom: 190)

    init(directory: URL) { self.directory = directory }

    mutating func show(_ caption: Caption) {
        self.caption = caption
        captionLeft = captionSeconds
    }

    /// The window as it is now, shown for `seconds`: with the caption while it lasts, then without.
    mutating func frame(of window: NSWindow, seconds: Double) throws {
        guard let shot = window.contentView?.snapshotBitmap() else { return }
        var remaining = seconds
        if let caption, captionLeft > 0 {
            let shown = min(remaining, captionLeft)
            try write(Self.compose(shot, caption: caption), seconds: shown)
            captionLeft -= shown
            remaining -= shown
        }
        if remaining > 0.0001 { try write(Self.compose(shot, caption: nil), seconds: remaining) }
    }

    private mutating func write(_ bitmap: NSBitmapImageRep, seconds: Double) throws {
        count += 1
        lastFile = String(format: "frame-%04d.png", count)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(lastFile))
        listing += "file '\(lastFile)'\nduration \(String(format: "%.3f", seconds))\n"
    }

    /// ffmpeg ignores the last duration unless the file is named once more.
    mutating func finish() throws {
        listing += "file '\(lastFile)'\n"
        try listing.write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    }

    private static func compose(_ shot: NSBitmapImageRep, caption: Caption?) -> NSBitmapImageRep {
        let width = shot.pixelsWide + 2 * margin.side
        let height = shot.pixelsHigh + margin.top + margin.bottom
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        canvas.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let frame = NSRect(x: margin.side, y: margin.bottom, width: shot.pixelsWide, height: shot.pixelsHigh)
        let corners = NSBezierPath(roundedRect: frame, xRadius: 28, yRadius: 28)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -22)
        shadow.shadowBlurRadius = 60
        shadow.set()
        NSColor.white.setFill()
        corners.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        corners.addClip()
        shot.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        corners.lineWidth = 2
        corners.stroke()

        if let caption { draw(caption, centeredIn: NSRect(x: 0, y: 0, width: width, height: margin.bottom)) }
        return canvas
    }

    private static func draw(_ caption: Caption, centeredIn area: NSRect) {
        let keyFont = NSFont.systemFont(ofSize: 40, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 40, weight: .regular)
        let keyText = NSAttributedString(string: caption.keys, attributes: [.font: keyFont, .foregroundColor: NSColor(white: 0.15, alpha: 1)])
        let labelText = NSAttributedString(string: caption.label, attributes: [.font: labelFont, .foregroundColor: NSColor(white: 0.35, alpha: 1)])
        let capSize = NSSize(width: keyText.size().width + 48, height: 76)
        let gap = 24.0
        let total = capSize.width + gap + labelText.size().width
        let x = area.midX - total / 2
        let cap = NSRect(x: x, y: area.midY - capSize.height / 2 - 14, width: capSize.width, height: capSize.height)

        let path = NSBezierPath(roundedRect: cap, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 0
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 2
        path.stroke()
        keyText.draw(at: NSPoint(x: cap.minX + 24, y: cap.midY - keyText.size().height / 2))
        labelText.draw(at: NSPoint(x: cap.maxX + gap, y: cap.midY - labelText.size().height / 2))
    }
}
