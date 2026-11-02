import CalloutCore
import AppKit
import SwiftUI
import ObjectiveC
import Testing
@testable import CalloutUI

/// One step of the demo: what is done to the review, what the viewer is told about it,
/// and how long the frame it leaves holds.
private struct Step {
    enum Action {
        case rest
        case drag(String)
        /// Moves onto a button of the bar above the selection and clicks it with real mouse events.
        case clickBar(MarkKind)
        /// A bare click just after the phrase, leaving a caret there.
        case click(after: String)
        case press(letter: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
        case typeInField(String)
        case typeOnSelection(String)
        case finishWriting
        case pointAtSendFeedback
    }

    let action: Action
    var caption: Caption?
    var hold: Double
    /// Seconds each typed character stays on screen.
    var perCharacter = 0.075

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
    Step(.rest, hold: 1.3),

    Step(.drag("leverage"), hold: 0.7),
    Step(.press(letter: "r", keyCode: 15, modifiers: .option), caption: Caption(keys: "⌥R", label: "Replace"), hold: 0.5),
    Step(.typeInField("use"), hold: 0.6),
    Step(.finishWriting, hold: 0.8),

    Step(.drag("robust, battle-tested "), hold: 0.7),
    Step(.clickBar(.delete), hold: 1.0),

    Step(.drag("token bucket"), hold: 0.7),
    Step(.typeOnSelection("Why not a sliding window?"), caption: Caption(keys: "Type", label: "Comment"), hold: 0.6),
    Step(.finishWriting, hold: 0.8),

    Step(.drag("Return 429 Too Many Requests with a Retry-After header"), hold: 0.7),
    Step(.press(letter: "k", keyCode: 40, modifiers: .option), caption: Caption(keys: "⌥K", label: "Keep"), hold: 1.0),

    Step(.click(after: "Websockets"), hold: 0.5),
    Step(.typeOnSelection(" and server-sent events"), caption: Caption(keys: "Type", label: "Add words"), hold: 0.6),
    Step(.finishWriting, hold: 0.4),
    Step(.click(after: "for now."), hold: 0.6),

    Step(.press(letter: "o", keyCode: 31, modifiers: .command), caption: Caption(keys: "⌘O", label: "Overall comment"), hold: 0.6),
    Step(.typeInField("Ship the 429 first; the alerts can wait."), hold: 0.6),
    Step(.finishWriting, hold: 0.4),
    Step(.pointAtSendFeedback, hold: 1.8),
]

private let fps = 30.0

/// Long enough to need a few kinds of mark, short enough to fit the window without scrolling.
private let demoPlan = """
# Plan: rate limiting for the public API

The public API has no limits today, so one client can use up the database pool and slow every other customer down. This plan adds a limit for each API key.

1. Add a `RateLimiter` middleware in front of every route
   - a token bucket per API key, kept in Redis so every worker shares it
   - 100 requests a minute by default, set per plan
2. Return `429 Too Many Requests` with a `Retry-After` header
3. Log each rejected request, and alert when one key is rejected more than 1,000 times an hour

We will leverage a robust, battle-tested library for the bucket instead of writing our own.

> Websockets are out of scope for now.
"""

private let windowSize = NSSize(width: 820, height: 620)

private enum Shape { case arrow, iBeam }

private struct Pointer {
    /// In window coordinates, points, y up.
    var position: NSPoint
    var shape: Shape
    var visible = true
}

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
                content: .text(demoPlan, format: .markdown), origin: .planHook,
                metadata: ReviewMetadata(title: "Plan"), reply: .stdout, modes: [.feedback, .applyEdits]
            )
            let session = ReviewSession(request: request)
            let window = SnapshotWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.drawsAsKey = true
            Self.reportApplicationAsActive()
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: ReviewView(session: session, finish: { _ in }))
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            await settle(window)
            let textView = try #require(Self.findTextView(in: window.contentView))
            textView.usesVimKeys = false
            window.makeFirstResponder(textView)
            await settle(window)

            var recorder = Recorder(directory: directory)
            recorder.pointer = Pointer(position: NSPoint(x: windowSize.width - 120, y: windowSize.height * 0.55), shape: .arrow)
            let sendFeedback = try #require(Self.sendFeedbackFrame(in: window))
            for step in storyboard {
                if let caption = step.caption { recorder.show(caption) }
                switch step.action {
                case .rest:
                    break
                case .drag(let phrase):
                    await settle(window)
                    try drag(over: (textView.string as NSString).range(of: phrase), textView: textView, window: window, recorder: &recorder)
                case .clickBar(let kind):
                    await settle(window)
                    try clickBar(kind, textView: textView, window: window, recorder: &recorder)
                case .click(after: let phrase):
                    await settle(window)
                    let end = (textView.string as NSString).range(of: phrase)
                    let rect = window.convertFromScreen(textView.firstRect(
                        forCharacterRange: NSRange(location: end.location + end.length - 1, length: 1), actualRange: nil
                    ))
                    try glide(to: NSPoint(x: rect.maxX, y: rect.midY), textView: textView, window: window, recorder: &recorder)
                    window.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: end.location + end.length, length: 0))
                case .pointAtSendFeedback:
                    await settle(window)
                    try glide(to: NSPoint(x: sendFeedback.midX, y: sendFeedback.midY), textView: textView, window: window, recorder: &recorder)
                case .press(let letter, let keyCode, let modifiers):
                    recorder.pointer?.visible = false
                    try Self.keyDown(letter, keyCode: keyCode, modifiers: modifiers, window: window, textView: textView)
                case .typeInField(let text):
                    recorder.pointer?.visible = false
                    await settle(window)
                    for character in text {
                        try Self.insert(String(character), in: window)
                        await settle(window)
                        try recorder.frame(of: window, seconds: step.perCharacter)
                    }
                case .typeOnSelection(let text):
                    recorder.pointer?.visible = false
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
                    // Return ends words typed in the page and a note in the margin; Esc leaves the overall comment.
                    if window.firstResponder === textView {
                        try Self.keyDown("\r", keyCode: 36, modifiers: [], window: window, textView: textView)
                    } else {
                        session.endEditing()
                    }
                }
                await settle(window)
                try recorder.frame(of: window, seconds: step.hold)
            }
            try recorder.finish()
            #expect(session.marks.map(\.kind) == [.replace, .delete, .comment, .keep, .insert])
            #expect(session.generalComment == "Ship the 429 first; the alerts can wait.")
            let sent = try session.editedText()
            #expect(sent.contains("We will use a library for the bucket instead of writing our own."))
            #expect(sent.contains("Websockets and server-sent events are out of scope for now."))
        }

        /// Glides to the first character, presses, and drags to the last while the selection
        /// grows with the pointer along the characters' real positions.
        private func drag(over range: NSRange, textView: AnnotationTextView, window: NSWindow, recorder: inout Recorder) throws {
            func rect(_ index: Int) -> NSRect {
                window.convertFromScreen(textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil))
            }
            recorder.barAllowed = false
            let start = rect(range.location)
            try glide(to: NSPoint(x: start.minX, y: start.midY), textView: textView, window: window, recorder: &recorder)
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))

            let frames = max(8, Int(min(1.0, 0.3 + Double(range.length) * 0.03) * fps))
            for k in 1...frames {
                let reached = max(1, Int((Double(range.length) * Self.ease(Double(k) / Double(frames))).rounded(.up)))
                textView.setSelectedRange(NSRange(location: range.location, length: reached))
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let end = rect(range.location + reached - 1)
                recorder.pointer?.position = NSPoint(x: end.maxX, y: end.midY)
                try recorder.frame(of: window, seconds: 1 / fps)
            }
            recorder.barAllowed = true
        }

        /// Glides onto the bar's button and presses it with the mouse events a click sends.
        private func clickBar(_ kind: MarkKind, textView: NSView, window: NSWindow, recorder: inout Recorder) throws {
            let panel = try #require(window.childWindows?.first { $0.isVisible })
            let bar = try #require(panel.contentView?.snapshotBitmap())
            let button = try #require(Self.centre(ofRedIn: bar, panel: panel))
            let target = window.convertFromScreen(NSRect(origin: button, size: .zero)).origin
            try glide(to: target, textView: textView, window: window, recorder: &recorder)
            try recorder.frame(of: window, seconds: 0.5)
            let spot = panel.convertPoint(fromScreen: window.convertToScreen(NSRect(origin: target, size: .zero)).origin)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                panel.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        /// Where the Strike it out button is, on screen. An off-screen panel has no accessibility
        /// tree to ask, and the strike glyph is the only red in the bar.
        private static func centre(ofRedIn bar: NSBitmapImageRep, panel: NSWindow) -> NSPoint? {
            var xs = [Int](), ys = [Int]()
            for y in 0..<bar.pixelsHigh {
                for x in 0..<bar.pixelsWide {
                    guard let c = bar.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8,
                          c.redComponent > 0.8, c.greenComponent < 0.4, c.blueComponent < 0.4 else { continue }
                    xs.append(x); ys.append(y)
                }
            }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
            let inPanel = NSPoint(x: Double(x0 + x1) / 4, y: Double(bar.pixelsHigh) / 2 - Double(y0 + y1) / 4)
            return NSPoint(x: panel.frame.minX + inPanel.x, y: panel.frame.minY + inPanel.y)
        }

        private func glide(to target: NSPoint, textView: NSView, window: NSWindow, recorder: inout Recorder) throws {
            guard var pointer = recorder.pointer, let shot = recorder.snapshot(of: window) else { return }
            let from = pointer.position
            let text = textView.convert(textView.bounds, to: nil)
            let bar = window.childWindows?.first(where: \.isVisible).map { window.convertFromScreen($0.frame) } ?? .zero
            let distance = hypot(target.x - from.x, target.y - from.y)
            let frames = Int((0.3 + min(0.2, distance / 2500)) * fps)
            pointer.visible = true
            for k in 1...frames {
                let t = Self.ease(Double(k) / Double(frames))
                pointer.position = NSPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
                pointer.shape = text.contains(pointer.position) && !bar.contains(pointer.position) ? .iBeam : .arrow
                recorder.pointer = pointer
                try recorder.frame(shot, seconds: 1 / fps)
            }
        }

        private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

        /// Where the Send Feedback button shows. SwiftUI's buttons are not views, but each answer
        /// has a view behind it that catches its Return chord, and Send Feedback is the last.
        private static func sendFeedbackFrame(in window: NSWindow) -> NSRect? {
            func chordViews(_ view: NSView) -> [NSView] {
                (String(describing: type(of: view)).hasSuffix("KeyView") ? [view] : []) + view.subviews.flatMap(chordViews)
            }
            guard let content = window.contentView, let view = chordViews(content).last else { return nil }
            return view.convert(view.bounds, to: nil)
        }

        /// AppKit draws a selection in the key colour only for an active application, and a
        /// test process never is. Only this test process asks.
        private static func reportApplicationAsActive() {
            guard let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) else { return }
            let always: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(always))
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
    var pointer: Pointer?
    /// False while a drag is still going, since the app shows its bar once the mouse is up.
    var barAllowed = false
    private var listing = "ffconcat version 1.0\n"
    private var count = 0
    private var held: (file: String, picture: Data, seconds: Double)?
    private var captionLeft = 0.0
    private var caption: Caption?

    private static let margin = (side: 64, top: 56, bottom: 150)

    init(directory: URL) { self.directory = directory }

    mutating func show(_ caption: Caption) {
        self.caption = caption
        captionLeft = captionSeconds
    }

    /// The window as it is now, shown for `seconds`: with the caption while it lasts, then without.
    mutating func frame(of window: NSWindow, seconds: Double) throws {
        guard let shot = snapshot(of: window) else { return }
        try frame(shot, seconds: seconds)
    }

    /// The window's content with the app's bar of marks drawn over it, which lives in a panel of its own.
    func snapshot(of window: NSWindow) -> NSBitmapImageRep? {
        guard let shot = window.contentView?.snapshotBitmap() else { return nil }
        guard barAllowed, let panel = window.childWindows?.first(where: \.isVisible),
              let bar = panel.contentView?.snapshotBitmap() else { return shot }
        let spot = window.convertFromScreen(panel.frame)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: shot) else { return shot }
        NSGraphicsContext.current = context
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 18
        shadow.set()
        // The rep's size is in points, and the panel's corners are transparent in the real thing.
        NSBezierPath(roundedRect: spot, xRadius: spot.height / 2, yRadius: spot.height / 2).addClip()
        bar.draw(in: spot)
        return shot
    }

    mutating func frame(_ shot: NSBitmapImageRep, seconds: Double) throws {
        var remaining = seconds
        if let caption, captionLeft > 0.001 {
            let shown = min(remaining, captionLeft)
            try write(Self.compose(shot, pointer: pointer, caption: caption), seconds: shown)
            captionLeft -= shown
            remaining -= shown
        }
        if remaining > 0.001 { try write(Self.compose(shot, pointer: pointer, caption: nil), seconds: remaining) }
    }

    /// A picture the same as the one before only extends how long that one shows.
    private mutating func write(_ bitmap: NSBitmapImageRep, seconds: Double) throws {
        let picture = try #require(bitmap.representation(using: .png, properties: [:]))
        if var current = held, current.picture == picture {
            current.seconds += seconds
            held = current
            return
        }
        try flush()
        count += 1
        let file = String(format: "frame-%04d.png", count)
        try picture.write(to: directory.appendingPathComponent(file))
        held = (file, picture, seconds)
    }

    private mutating func flush() throws {
        guard let held else { return }
        listing += "file '\(held.file)'\nduration \(String(format: "%.3f", held.seconds))\n"
    }

    /// ffmpeg ignores the last duration unless the file is named once more.
    mutating func finish() throws {
        try flush()
        listing += "file '\(held?.file ?? "")'\n"
        try listing.write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    }

    private static func compose(_ shot: NSBitmapImageRep, pointer: Pointer?, caption: Caption?) -> NSBitmapImageRep {
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

        if let pointer, pointer.visible { draw(pointer, over: frame) }
        if let caption { draw(caption, centeredIn: NSRect(x: 0, y: 0, width: width, height: margin.bottom)) }
        return canvas
    }

    /// The system's own cursor, at its size in points on a two-pixel-a-point picture.
    private static func draw(_ pointer: Pointer, over frame: NSRect) {
        let cursor = pointer.shape == .arrow ? NSCursor.arrow : NSCursor.iBeam
        let image = cursor.image
        let scale = 2.0
        let hotSpot = cursor.hotSpot
        let tip = NSPoint(x: frame.minX + pointer.position.x * scale, y: frame.minY + pointer.position.y * scale)
        image.draw(in: NSRect(
            x: tip.x - hotSpot.x * scale, y: tip.y + hotSpot.y * scale - image.size.height * scale,
            width: image.size.width * scale, height: image.size.height * scale
        ))
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
