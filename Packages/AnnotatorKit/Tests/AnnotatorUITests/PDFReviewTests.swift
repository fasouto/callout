import AnnotatorCore
import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// Writes a small PDF with real, selectable text: one array of lines per page.
/// Under the heading, the lines are `leading` points apart.
func makePDF(pages: [[String]], leading: CGFloat = 24) throws -> String {
    let path = NSTemporaryDirectory() + "annotator-\(UUID().uuidString.prefix(8)).pdf"
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try #require(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 770
        for (index, text) in lines.enumerated() {
            let font = index == 0 ? NSFont.boldSystemFont(ofSize: 22) : NSFont.systemFont(ofSize: 13)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 64, y: y)
            CTLineDraw(line, context)
            y -= index == 0 ? 40 : leading
        }
        context.endPDFPage()
    }
    context.closePDF()
    return path
}

@MainActor
@Suite("PDF review")
struct PDFReviewTests {
    private static let pages = [
        [
            "Ada Lovelace",
            "Senior engineer with a proven track record in delivery.",
            "Passionate, results-driven builder of analytical engines.",
            "Built browser automation for insurance price comparison.",
            "Mentored a team of five engineers through two product launches.",
        ],
        [
            "Experience",
            "Worked at CERN on database availability.",
            "Built browser automation for a second company.",
        ],
    ]

    private struct Harness {
        let session: ReviewSession
        let window: NSWindow
        let view: AnnotationPDFView
    }

    private func makeHarness(pages: [[String]] = Self.pages, leading: CGFloat = 24) throws -> Harness {
        _ = NSApplication.shared
        let path = try makePDF(pages: pages, leading: leading)
        let request = ReviewRequest(
            content: .file(path: path), origin: .agentRequest,
            metadata: ReviewMetadata(title: "cv.pdf"), reply: .stdout, modes: [.feedback]
        )
        let session = ReviewSession(request: request)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewView(session: session) { _ in })
        settle(window)
        let view = try #require(find(AnnotationPDFView.self, in: window.contentView))
        return Harness(session: session, window: window, view: view)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func find<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
        guard let view else { return nil }
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private func select(_ phrase: String, page index: Int, in harness: Harness) throws {
        let page = try #require(harness.session.pdf?.page(at: index))
        let range = ((page.string ?? "") as NSString).range(of: phrase)
        #expect(range.location != NSNotFound, "\(phrase) is on the page")
        harness.view.setCurrentSelection(page.selection(for: range), animate: false)
    }

    private func drag(from start: CGPoint, to end: CGPoint, in harness: Harness) throws {
        let page = try #require(harness.session.pdf?.page(at: 0))
        let window = harness.window
        let from = harness.view.convert(harness.view.convert(start, from: page), to: nil)
        let to = harness.view.convert(harness.view.convert(end, from: page), to: nil)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        let down = try mouse(.leftMouseDown, at: from)
        let moves = try (1...8).map { step in
            let t = CGFloat(step) / 8
            return try mouse(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        let up = try mouse(.leftMouseUp, at: to)
        let pressed = try #require(window.contentView?.superview?.hitTest(from))
        // Posting an event stops the run loop that is running. Posted from the test,
        // that is the loop the test runner waits in, and the process then exits
        // with status 0 before the remaining tests run.
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            for event in moves + [up] { NSApp.postEvent(event, atStart: false) }
            // PDFKit's mouseDown takes the drags from the queue and puts the release back.
            pressed.mouseDown(with: down)
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                if event.type == .leftMouseUp { pressed.mouseUp(with: event) }
            }
            CFRunLoopStop(loop)
        }
        CFRunLoopRunInMode(.defaultMode, 10, false)
    }

    /// Presses ⌥ and a mark's letter.
    private func mark(_ letter: String, keyCode: UInt16, in harness: Harness) throws {
        try press(letter, keyCode: keyCode, modifiers: .option, in: harness)
    }

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in harness: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        harness.view.keyDown(with: event)
    }

    /// Writes a page with its marks as a PNG when a snapshot folder is set.
    /// PDFKit draws the live view into layers that only exist on screen, so the
    /// page is drawn directly; this shows the marks, not the window around them.
    private func snapshot(page index: Int, of session: ReviewSession, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"],
              let page = session.pdf?.page(at: index) else { return }
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let crop = CGRect(x: 0, y: box.height - 250, width: box.width, height: 250)
        guard let context = CGContext(
            data: nil, width: Int(crop.width * scale), height: Int(crop.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: -crop.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    @Test func loadsThePagesAndTheirText() throws {
        let harness = try makeHarness()
        #expect(harness.session.isPDF)
        #expect(harness.session.loadFailure == nil)
        #expect(harness.session.pageTexts.count == 2)
        #expect(harness.session.pageTexts[0].contains("proven track record"))
        #expect(harness.session.title == "cv.pdf")
        #expect(!harness.session.allows.applyEdits)
    }

    @Test func keysMarkTheSelectionOnItsPage() throws {
        let harness = try makeHarness()
        let session = harness.session

        try select("Passionate, results-driven", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()
        try select("Worked at CERN", page: 1, in: harness)
        try mark("k", keyCode: 40, in: harness)

        #expect(session.marks.map(\.kind) == [.delete, .keep])
        #expect(session.marks[0].anchor.page == 1)
        #expect(session.marks[0].anchor.quote == "Passionate, results-driven")
        #expect(session.marks[1].anchor.page == 2)
        // The marks are drawn on their pages, and never written to the file.
        settle(harness.window)
        #expect(session.pdf?.page(at: 0)?.annotations.count == 1)
        #expect(session.pdf?.page(at: 1)?.annotations.count == 1)
    }

    @Test func feedbackMatchesTheDocumentedFormat() throws {
        let harness = try makeHarness()
        let session = harness.session

        try select("with a proven track record", page: 0, in: harness)
        try mark("r", keyCode: 15, in: harness)
        session.update(try #require(session.selectedMarkID), text: "who ships reliable systems in production")
        session.endEditing()

        try select("Passionate, results-driven", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()

        try select("Worked at CERN", page: 1, in: harness)
        try mark("c", keyCode: 8, in: harness)
        session.update(try #require(session.selectedMarkID), note: "Mention the Oracle scale and the three-state availability model.")
        session.endEditing()

        try select("Built browser automation for insurance price comparison", page: 0, in: harness)
        try mark("k", keyCode: 40, in: harness)
        session.generalComment = "Keep it to one page."

        let expected = """
        ## Feedback on cv.pdf

        Apply these changes to the source this document was generated from, then regenerate it.

        ### 1. Replace (page 1)
        > with a proven track record
        With: who ships reliable systems in production

        ### 2. Delete (page 1)
        > Passionate, results-driven

        ### 3. Comment (page 2)
        > Worked at CERN
        Mention the Oracle scale and the three-state availability model.

        ### Keep as is
        > Built browser automation for insurance price comparison

        ### General
        Keep it to one page.

        """
        #expect(session.feedback() == expected)

        try select("Mentored a team", page: 0, in: harness)
        try mark("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "and hired")
        session.endEditing()
        settle(harness.window)
        snapshot(page: 0, of: session, named: "pdf-page-marked")
    }

    /// Writes the whole window as a PNG when a snapshot folder is set. Drawn
    /// through the print path, which also draws PDFKit's pages.
    private func snapshot(_ window: NSWindow, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"],
              let content = window.contentView,
              let image = NSImage(data: content.dataWithPDF(inside: content.bounds)) else { return }
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * scale), pixelsHigh: Int(content.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        bitmap.size = content.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: content.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    @Test func theWindowLaysOutPageAndMargin() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select("with a proven track record", page: 0, in: harness)
        try mark("r", keyCode: 15, in: harness)
        session.update(try #require(session.selectedMarkID), text: "who ships reliable systems")
        session.endEditing()
        try select("Passionate, results-driven", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()
        try select("browser automation", page: 0, in: harness)
        try mark("c", keyCode: 8, in: harness)
        session.update(try #require(session.selectedMarkID), note: "Say which insurer, and how many quotes a day.")
        session.endEditing()
        try select("Mentored a team", page: 0, in: harness)
        try mark("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "and hired")
        session.endEditing()
        session.selectedMarkID = nil
        settle(harness.window)

        #expect(session.marks.count == 4)
        // The words to add are in the margin: on the page, a blue strike, a red
        // strike, a highlight and a caret.
        #expect(session.pdf?.page(at: 0)?.annotations.count == 4)
        snapshot(harness.window, named: "pdf-window")
        // A selected note has a line to its mark.
        session.selectedMarkID = session.marks.first { $0.kind == .replace }?.id
        settle(harness.window)
        snapshot(harness.window, named: "pdf-window-selected")
        snapshot(page: 0, of: session, named: "pdf-page-written")
    }

    @Test func thePageGrowsWithTheWindowUpToAComfortableSize() throws {
        let harness = try makeHarness()
        settle(harness.window)
        // At 1040 points the page, with the desk around it, fills the width beside
        // the margin. The desk is scaled with the sheet.
        let fitted = harness.view.scaleFactor
        let clip = try #require(AnnotationPDFView.clipView(in: harness.view))
        #expect(fitted < PDFPane.Coordinator.largestScale)
        #expect(abs(fitted * (595 + 72) - clip.frame.width) < 1)
        try expectNoSidewaysScroll(in: harness)

        // Nor in a narrower window, where the page is smaller.
        harness.window.setContentSize(NSSize(width: 900, height: 760))
        settle(harness.window)
        #expect(harness.view.scaleFactor < fitted)
        try expectNoSidewaysScroll(in: harness)

        // A wide window shows more desk instead of a bigger page.
        harness.window.setContentSize(NSSize(width: 2000, height: 760))
        settle(harness.window)
        #expect(abs(harness.view.scaleFactor - PDFPane.Coordinator.largestScale) < 0.01)
        try expectNoSidewaysScroll(in: harness)
    }

    /// The page is no wider than the view, so a scroll or a drag along a line
    /// cannot slide it sideways: as far right as it goes is as far left.
    private func expectNoSidewaysScroll(in harness: Harness) throws {
        let clip = try #require(AnnotationPDFView.clipView(in: harness.view))
        let document = try #require(clip.documentView)
        #expect(document.frame.width <= clip.bounds.width)
        let right = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 40, dy: 0)).minX
        let left = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: -40, dy: 0)).minX
        #expect(abs(right - left) < 0.01)
    }

    @Test func theWordsToAddAreWrittenInTheMarginNotOnThePage() throws {
        let harness = try makeHarness()
        let session = harness.session
        let long = "who has shipped reliable systems in production for a decade, at a scale of millions of people"
        try select("with a proven track record", page: 0, in: harness)
        try mark("r", keyCode: 15, in: harness)
        session.update(try #require(session.selectedMarkID), text: long)
        session.endEditing()
        try select("Mentored a team", page: 0, in: harness)
        try mark("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "and hired")
        session.endEditing()
        settle(harness.window)

        // On the page, a blue strike and a caret: nothing that runs past the line.
        let shapes = (session.pdf?.page(at: 0)?.annotations ?? []).compactMap { ($0 as? MarkAnnotation)?.shape }
        #expect(shapes == [.replace, .caret])
        // The words are whole, for the margin and for the feedback.
        #expect(session.marks.first?.text == long)
        #expect(session.feedback().contains("With: \(long)"))
    }

    @Test func insertionGoesAfterTheSelectedWords() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select("Worked at CERN", page: 1, in: harness)
        try mark("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "(2019 to 2024)")
        session.endEditing()

        let mark = try #require(session.marks.first)
        #expect(mark.kind == .insert && mark.anchor.span.isEmpty && mark.anchor.page == 2)
        #expect(session.feedback().contains("### 1. Insert after (page 2)\n> Experience Worked at CERN\nAdd: (2019 to 2024)\n")
            || session.feedback().contains("### 1. Insert after (page 2)\n> Worked at CERN\nAdd: (2019 to 2024)\n"))
    }

    @Test func typingOnASelectionWritesAComment() throws {
        let harness = try makeHarness()
        try select("Built browser automation", page: 0, in: harness)
        for key in "why?" { try press(String(key), keyCode: 0, in: harness) }
        #expect(harness.session.marks.map(\.kind) == [.comment])
        #expect(harness.session.marks.first?.note == "why?")
        #expect(harness.session.marks.first?.anchor.page == 1)
        #expect(harness.session.editing?.field == .note)
    }

    /// The page lets go of the selection when it redraws the new comment, before
    /// the comment's field has the keyboard. Keys pressed in between still count.
    @Test func keysPressedWhileTheCommentsFieldTakesTheKeyboardAreInTheComment() throws {
        let harness = try makeHarness()
        try select("Built browser automation", page: 0, in: harness)
        try press("w", keyCode: 0, in: harness)
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(harness.window.firstResponder === harness.view, "the field has not taken the keyboard yet")
        for key in "hy?" { try press(String(key), keyCode: 0, in: harness) }
        #expect(harness.session.marks.map(\.kind) == [.comment])
        #expect(harness.session.marks.first?.note == "why?")
    }

    @Test func typingOnANewSelectionAfterTheFieldHadTheKeyboardStartsANewComment() async throws {
        let harness = try makeHarness()
        try select("Built browser automation", page: 0, in: harness)
        try press("w", keyCode: 0, in: harness)
        settle(harness.window)
        try await Task.sleep(for: .milliseconds(60))
        #expect((harness.window.firstResponder as? NSTextView)?.isFieldEditor == true, "the field has the keyboard")

        harness.window.makeFirstResponder(harness.view)
        try select("Worked at CERN", page: 1, in: harness)
        for key in "ok" { try press(String(key), keyCode: 0, in: harness) }
        #expect(harness.session.marks.map(\.note) == ["w", "ok"])
    }

    @Test func wordsTypedBeforeTheReplacementsFieldHasTheKeyboardAreTheReplacement() throws {
        let harness = try makeHarness()
        try select("with a proven track record", page: 0, in: harness)
        try mark("r", keyCode: 15, in: harness)
        harness.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(harness.window.firstResponder === harness.view, "the field has not taken the keyboard yet")
        for key in "who ships" { try press(String(key), keyCode: 0, in: harness) }
        #expect(harness.session.marks.map(\.kind) == [.replace])
        #expect(harness.session.marks.first?.text == "who ships")
    }

    /// A drag that ends a little past the end of a line, level with it, selects to
    /// the end of that line, though the longer line above or below is nearer the pointer.
    @Test func draggingPastTheEndOfALineSelectsToTheEndOfThatLine() throws {
        let harness = try makeHarness(pages: [[
            "Ada Lovelace",
            "Built browser automation for insurance price comparison.",
            "Mentored a team of five engineers through two launches and a migration.",
            "Responsible for the database.",
        ]], leading: 18)
        let session = harness.session
        let page = try #require(session.pdf?.page(at: 0))
        let text = (page.string ?? "") as NSString
        func box(of phrase: String) throws -> CGRect {
            let range = text.range(of: phrase)
            try #require(range.location != NSNotFound, "\(phrase) is on the page")
            return try #require(page.selection(for: range)?.bounds(for: page))
        }
        func start(of phrase: String) throws -> CGPoint {
            let box = try box(of: phrase)
            return CGPoint(x: box.minX + 1, y: box.midY)
        }
        func pastTheEnd(of line: String) throws -> CGPoint {
            let box = try box(of: line)
            return CGPoint(x: box.maxX + 20, y: box.midY)
        }

        try drag(from: try start(of: "insurance"), to: try pastTheEnd(of: "Built browser automation for insurance price comparison."), in: harness)
        #expect(harness.view.currentSelection?.string == "insurance price comparison.", "not the longer line below")
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()

        try drag(from: try start(of: "the database"), to: try pastTheEnd(of: "Responsible for the database."), in: harness)
        #expect(harness.view.currentSelection?.string == "the database.", "not the longer line above")
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()

        #expect(session.marks.map(\.anchor.quote) == ["insurance price comparison.", "the database."])
    }

    @Test func keysNeedASelection() throws {
        let harness = try makeHarness()
        harness.view.clearSelection()
        try mark("d", keyCode: 2, in: harness)
        try mark("i", keyCode: 34, in: harness)
        #expect(harness.session.marks.isEmpty)
        #expect(harness.session.statusMessage == "Select the words the new text goes after.")
    }

    @Test func overlappingEditsOnAPageAreRefusedButNotAcrossPages() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select("Built browser automation", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        session.endEditing()
        try select("browser automation for insurance", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        #expect(session.marks.count == 1)

        // The same words on the other page are another matter.
        try select("Built browser automation", page: 1, in: harness)
        try mark("d", keyCode: 2, in: harness)
        #expect(session.marks.count == 2)
    }

    @Test func removingAndUndoingRedrawsThePage() throws {
        let harness = try makeHarness()
        let session = harness.session
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo

        try select("Passionate, results-driven", page: 0, in: harness)
        try mark("d", keyCode: 2, in: harness)
        #expect(session.editing?.field == .note)
        // Back from the reason, without one.
        session.endEditing()
        try press("\u{7F}", keyCode: KeyCode.delete, in: harness)
        settle(harness.window)
        #expect(session.marks.isEmpty)
        #expect(session.pdf?.page(at: 0)?.annotations.isEmpty == true)

        undo.undo()
        settle(harness.window)
        #expect(session.marks.count == 1)
        #expect(session.pdf?.page(at: 0)?.annotations.count == 1)
    }

    @Test func theTitleBarIsTheSameGreyAsTheDeskUnderThePages() throws {
        _ = NSApplication.shared
        let request = ReviewRequest(
            content: .file(path: try makePDF(pages: Self.pages)), origin: .agentRequest,
            metadata: ReviewMetadata(title: "cv.pdf"), reply: .stdout, modes: [.feedback]
        )
        let controller = ReviewWindowController(request: request) { _ in }
        // The title bar is see-through: what shows there is the window's own colour.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var window: CGFloat?
            var desk: CGFloat?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                window = controller.window.backgroundColor.usingColorSpace(.deviceGray)?.whiteComponent
                desk = Theme.desk.usingColorSpace(.deviceGray)?.whiteComponent
            }
            #expect(window != nil && window == desk)
        }
    }

    @Test func aFileThatIsNotAPDFSaysSo() throws {
        _ = NSApplication.shared
        let path = NSTemporaryDirectory() + "not-a-pdf-\(UUID().uuidString.prefix(8)).pdf"
        try Data("hello".utf8).write(to: URL(fileURLWithPath: path))
        let session = ReviewSession(request: ReviewRequest(content: .file(path: path), origin: .fileDrop, reply: .clipboard, modes: [.feedback]))
        #expect(session.loadFailure?.contains("could not be opened as a PDF") == true)
        #expect(!session.isPDF)
    }
}
