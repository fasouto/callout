import AnnotatorCore
import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
@testable import AnnotatorUI

/// Writes a small PDF with real, selectable text: one array of lines per page.
func makePDF(pages: [[String]]) throws -> String {
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
            y -= index == 0 ? 40 : 24
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

    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let path = try makePDF(pages: Self.pages)
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
        harness.view.setCurrentSelection(try #require(page.selection(for: range)), animate: false)
    }

    private func press(_ characters: String, keyCode: UInt16, in harness: Harness) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
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
        try press("d", keyCode: 2, in: harness)
        try select("Worked at CERN", page: 1, in: harness)
        try press("k", keyCode: 40, in: harness)

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
        try press("r", keyCode: 15, in: harness)
        session.update(try #require(session.selectedMarkID), text: "who ships reliable systems in production")
        session.endEditing()

        try select("Passionate, results-driven", page: 0, in: harness)
        try press("d", keyCode: 2, in: harness)

        try select("Worked at CERN", page: 1, in: harness)
        try press("c", keyCode: 8, in: harness)
        session.update(try #require(session.selectedMarkID), note: "Mention the Oracle scale and the three-state availability model.")
        session.endEditing()

        try select("Built browser automation for insurance price comparison", page: 0, in: harness)
        try press("k", keyCode: 40, in: harness)
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
        try press("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "and hired")
        session.endEditing()
        settle(harness.window)
        snapshot(page: 0, of: session, named: "pdf-page-marked")
    }

    @Test func insertionGoesAfterTheSelectedWords() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select("Worked at CERN", page: 1, in: harness)
        try press("i", keyCode: 34, in: harness)
        session.update(try #require(session.selectedMarkID), text: "(2019 to 2024)")
        session.endEditing()

        let mark = try #require(session.marks.first)
        #expect(mark.kind == .insert && mark.anchor.span.isEmpty && mark.anchor.page == 2)
        #expect(session.feedback().contains("### 1. Insert after (page 2)\n> Experience Worked at CERN\nAdd: (2019 to 2024)\n")
            || session.feedback().contains("### 1. Insert after (page 2)\n> Worked at CERN\nAdd: (2019 to 2024)\n"))
    }

    @Test func keysNeedASelection() throws {
        let harness = try makeHarness()
        harness.view.clearSelection()
        try press("d", keyCode: 2, in: harness)
        try press("i", keyCode: 34, in: harness)
        #expect(harness.session.marks.isEmpty)
        #expect(harness.session.statusMessage == "Select the words the new text goes after.")
    }

    @Test func overlappingEditsOnAPageAreRefusedButNotAcrossPages() throws {
        let harness = try makeHarness()
        let session = harness.session
        try select("Built browser automation", page: 0, in: harness)
        try press("d", keyCode: 2, in: harness)
        try select("browser automation for insurance", page: 0, in: harness)
        try press("d", keyCode: 2, in: harness)
        #expect(session.marks.count == 1)

        // The same words on the other page are another matter.
        try select("Built browser automation", page: 1, in: harness)
        try press("d", keyCode: 2, in: harness)
        #expect(session.marks.count == 2)
    }

    @Test func removingAndUndoingRedrawsThePage() throws {
        let harness = try makeHarness()
        let session = harness.session
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo

        try select("Passionate, results-driven", page: 0, in: harness)
        try press("d", keyCode: 2, in: harness)
        try press("\u{7F}", keyCode: KeyCode.delete, in: harness)
        settle(harness.window)
        #expect(session.marks.isEmpty)
        #expect(session.pdf?.page(at: 0)?.annotations.isEmpty == true)

        undo.undo()
        settle(harness.window)
        #expect(session.marks.count == 1)
        #expect(session.pdf?.page(at: 0)?.annotations.count == 1)
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
