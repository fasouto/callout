import AnnotatorCore
import AppKit
import PDFKit
import SwiftUI

/// The PDF view with the same keys as the text page: ⌥ and a letter marks the
/// selection, and typing on it comments on it.
final class AnnotationPDFView: PDFView {
    var onCommand: ((Keymap.Command) -> Void)?
    /// Text typed on a selection, which is a comment on it.
    var onTypeOnSelection: ((String) -> Void)?
    /// Overrides the setting for this view. Nil follows Settings.
    var usesVimKeys: Bool?
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onTabKey: ((_ forward: Bool) -> Void)?
    var onCancelKey: (() -> Void)?
    /// Called when the mouse is released, at a point in view coordinates.
    var onMouseUp: ((NSPoint) -> Void)?
    private var awaitsSecondG = false

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""

        let vim = usesVimKeys ?? Keymap.usesVimKeys
        if vim, vimKeyDown(characters, keyCode: event.keyCode, modifiers: modifiers) { return }

        if let command = Keymap.command(for: characters, modifiers: modifiers, vim: vim) {
            onCommand?(command)
            return
        }
        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            onDeleteKey?()
        case KeyCode.escape:
            onCancelKey?()
        case KeyCode.return, KeyCode.enter:
            onReturnKey?()
        case KeyCode.tab where modifiers.isEmpty || modifiers == .shift:
            onTabKey?(modifiers.isEmpty)
        default:
            if !vim, currentSelection?.string?.isEmpty == false, let text = Keymap.typedText(of: event) {
                onTypeOnSelection?(text)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// A page has no caret to move, so vim's keys scroll it. Text is still selected with the mouse.
    private func vimKeyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == .control, characters == "r" {
            undoManager?.redo()
            return true
        }
        if keyCode == KeyCode.escape {
            clearSelection()
            return true
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        defer { if characters != "g" { awaitsSecondG = false } }
        switch characters {
        case "j": scroll(by: 48)
        case "k": scroll(by: -48)
        case "G": goToLastPage(nil)
        case "g":
            if awaitsSecondG { goToFirstPage(nil) }
            awaitsSecondG.toggle()
        case "u": undoManager?.undo()
        case "n": onTabKey?(true)
        case "N": onTabKey?(false)
        default: return false
        }
        return true
    }

    private func scroll(by distance: CGFloat) {
        guard let clip = Self.clipView(in: self), let document = clip.documentView else { return }
        var origin = clip.bounds.origin
        // Down the page is towards smaller y unless the document view is flipped.
        origin.y += document.isFlipped ? distance : -distance
        origin.y = min(max(origin.y, 0), max(0, document.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    static func clipView(in view: NSView) -> NSClipView? {
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView { return scroll.contentView }
            if let found = clipView(in: subview) { return found }
        }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A review opens ready for the keyboard: no click needed before the first key.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// A mark drawn on a PDF page: the pen stroke, the highlighter, the underline
/// of a keep, the caret where text is to be added, and the words written in
/// above the line. Drawn over the page, never saved to the file.
final class MarkAnnotation: PDFAnnotation {
    enum Shape {
        case strike
        case highlight
        case keep
        case caret
        /// Replacement or added words, written in blue ink in the space above the line.
        case writing(String, fontSize: CGFloat)
    }

    let markID: UUID
    private let shape: Shape
    private let isSelected: Bool

    init(markID: UUID, shape: Shape, bounds: CGRect, isSelected: Bool) {
        self.markID = markID
        self.shape = shape
        self.isSelected = isSelected
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
    }

    /// Where words written above a line go, and how big they are: about two
    /// thirds of the line's height, starting at `x`, sitting just above the line
    /// and kept on the page.
    static func writing(_ text: String, above line: CGRect, at x: CGFloat, on page: CGRect) -> (Shape, CGRect) {
        let fontSize = min(14, max(7, line.height * 0.62))
        let font = Theme.serif(fontSize, italic: true)
        let width = min(writingLine(text, font: font, maxWidth: .greatestFiniteMagnitude).width, page.width - 48)
        let height = font.ascender - font.descender + 2
        let left = min(max(x, page.minX + 24), page.maxX - 24 - width)
        let rect = CGRect(x: left - 1, y: line.maxY + 1 + font.descender, width: width + 2, height: height)
        return (.writing(text, fontSize: fontSize), rect)
    }

    /// The words as one line of type, cut short with an ellipsis if they would not fit.
    private static func writingLine(_ text: String, font: NSFont, maxWidth: CGFloat, halo: Bool = false) -> (line: CTLine, width: CGFloat) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.ink]
        if halo {
            // A stroke only, in the page's white: keeps the ink legible over the line above.
            attributes[.strokeColor] = NSColor.white
            attributes[.strokeWidth] = 32
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > maxWidth else { return (line, width) }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let cut = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
        return (cut, maxWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rect = bounds
        context.saveGState()
        switch shape {
        case .strike:
            if isSelected {
                context.setFillColor(Theme.pen.withAlphaComponent(0.14).cgColor)
                context.fill(rect)
            }
            context.setStrokeColor(Theme.pen.cgColor)
            context.setLineWidth(max(1.2, rect.height * 0.1))
            context.setLineCap(.round)
            // Through the middle of the lowercase letters rather than the middle of the line box.
            let y = rect.minY + rect.height * 0.42
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        case .highlight:
            // On screen the mark is drawn over the text rather than blended into
            // the page, so it stays light enough for the words to keep their ink.
            context.setBlendMode(.multiply)
            context.setFillColor(Theme.highlighter.withAlphaComponent(isSelected ? 0.5 : 0.34).cgColor)
            context.fill(rect.insetBy(dx: -1, dy: -0.5))
        case .keep:
            context.setBlendMode(.multiply)
            context.setFillColor(Theme.keep.withAlphaComponent(isSelected ? 0.34 : 0.14).cgColor)
            context.fill(rect)
            context.setBlendMode(.normal)
            context.setFillColor(Theme.keep.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY - 0.5, width: rect.width, height: max(1.2, rect.height * 0.09)))
        case .caret:
            if isSelected {
                context.setFillColor(Theme.ink.withAlphaComponent(0.16).cgColor)
                context.fill(rect)
            }
            context.setStrokeColor(Theme.ink.cgColor)
            context.setLineWidth(max(1.2, rect.height * 0.1))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            // The proofreader's caret, pointing up into the line from below it.
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.strokePath()
        case let .writing(text, fontSize):
            let font = Theme.serif(fontSize, italic: true)
            let origin = CGPoint(x: rect.minX + 1, y: rect.minY + 1 - font.descender)
            context.textMatrix = .identity
            for halo in [true, false] {
                let line = Self.writingLine(text, font: font, maxWidth: rect.width - 2, halo: halo).line
                context.textPosition = origin
                CTLineDraw(line, context)
            }
        }
        context.restoreGState()
    }
}

/// The annotation surface for a PDF. Its notes live in a margin beside it,
/// which follows the page as it scrolls.
struct PDFPane: NSViewRepresentable {
    let session: ReviewSession
    let margin: MarginModel
    /// Read by the parent so SwiftUI calls `updateNSView` when the session changes.
    let revision: Int
    let focusToken: Int
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, margin: margin, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> AnnotationPDFView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: AnnotationPDFView, context: Context) {
        context.coordinator.refresh(revision: revision)
        context.coordinator.focusDocument(token: focusToken)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let session: ReviewSession
        private let margin: MarginModel
        private let onCancel: () -> Void
        private var view: AnnotationPDFView!
        private var shownRevision = -1
        private var shownSelection: UUID?
        private var shownFocusToken = 0
        private var annotations: [MarkAnnotation] = []
        private lazy var toolbar = SelectionToolbar(
            perform: { [weak self] kind in self?.perform(kind) },
            pickSnippet: { [weak self] in self?.pickSnippet() }
        )
        private let snippetPicker = SnippetPickerPopover()

        init(session: ReviewSession, margin: MarginModel, onCancel: @escaping () -> Void) {
            self.session = session
            self.margin = margin
            self.onCancel = onCancel
        }

        func makeView() -> AnnotationPDFView {
            let view = AnnotationPDFView()
            self.view = view
            view.document = session.pdf
            view.displayMode = .singlePageContinuous
            view.displaysPageBreaks = true
            // A sheet on the desk: room around every page, so its edges show.
            view.pageBreakMargins = NSEdgeInsets(top: 24, left: 36, bottom: 24, right: 36)
            view.autoScales = false
            view.pageShadowsEnabled = true
            view.backgroundColor = Theme.desk
            view.setAccessibilityLabel("Document")

            view.onCommand = { [weak self] command in
                switch command {
                case .mark(let kind): self?.perform(kind)
                case .snippets: self?.pickSnippet()
                case .overall: self?.session.focusOverallComment()
                }
            }
            view.onTypeOnSelection = { [weak self] text in self?.comment(typing: text) }
            view.onDeleteKey = { [weak self] in
                guard let self else { return }
                // ⌫ strikes out the selected text, or takes the strike back from text
                // that is already struck; with nothing selected it removes the selected mark.
                if let selected = self.currentSelection() {
                    let span = TextSpan(selected.range.location, NSMaxRange(selected.range))
                    let struck = self.session.marks.first {
                        $0.kind == .delete && $0.anchor.page == selected.index + 1 && $0.anchor.span == span
                    }
                    if let struck { self.session.remove(struck.id) } else { self.perform(.delete, writingNote: false) }
                } else if let id = self.session.selectedMarkID {
                    self.session.remove(id)
                }
            }
            view.onReturnKey = { [weak self] in
                guard let self, let id = self.session.selectedMarkID else { return }
                self.session.beginEditing(id)
            }
            view.onTabKey = { [weak self] forward in self?.session.selectMark(offsetBy: forward ? 1 : -1) }
            view.onCancelKey = { [weak self] in self?.onCancel() }
            view.onMouseUp = { [weak self] point in self?.mouseUp(at: point) }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(viewChanged), name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(viewChanged), name: .PDFViewVisiblePagesChanged, object: view)
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            view.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: view)
            // The page scrolls inside the PDF view's own scroll view.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let clip = AnnotationPDFView.clipView(in: view) else { return }
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(self.viewChanged), name: NSView.boundsDidChangeNotification, object: clip)
                // A scroller that comes or goes changes the width the page has.
                clip.postsFrameChangedNotifications = true
                center.addObserver(self, selector: #selector(self.frameChanged), name: NSView.frameDidChangeNotification, object: clip)
                view.window?.makeFirstResponder(view)
                self.fitPage()
                self.updateAnchors()
            }
            refresh(revision: session.revision)
            return view
        }

        // MARK: Drawing

        func refresh(revision: Int) {
            guard revision != shownRevision else { return }
            shownRevision = revision

            for annotation in annotations { annotation.page?.removeAnnotation(annotation) }
            annotations = []
            for mark in session.marks {
                guard let page = page(of: mark) else { continue }
                let selected = mark.id == session.selectedMarkID
                for (shape, rect) in shapes(for: mark, on: page) {
                    let annotation = MarkAnnotation(markID: mark.id, shape: shape, bounds: rect, isSelected: selected)
                    page.addAnnotation(annotation)
                    annotations.append(annotation)
                }
            }
            view.setNeedsDisplay(view.bounds)
            view.clearSelection()
            toolbar.hide()
            updateAnchors()

            if session.selectedMarkID != shownSelection {
                shownSelection = session.selectedMarkID
                if let mark = session.selectedMark { reveal(mark) }
            }
        }

        func focusDocument(token: Int) {
            guard token != shownFocusToken else { return }
            shownFocusToken = token
            view.window?.makeFirstResponder(view)
        }

        private func page(of mark: Mark) -> PDFPage? {
            guard let number = mark.anchor.page else { return nil }
            return session.pdf?.page(at: number - 1)
        }

        /// The rectangles of a mark's text, one per line, in page coordinates.
        private func lineRects(for mark: Mark, on page: PDFPage) -> [CGRect] {
            let span = mark.anchor.span
            if span.isEmpty {
                // An insertion sits after the character before it.
                guard span.start > 0, let before = page.selection(for: NSRange(location: span.start - 1, length: 1)) else { return [] }
                let rect = before.bounds(for: page)
                return [CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)]
            }
            guard let selection = page.selection(for: NSRange(location: span.start, length: span.length)) else { return [] }
            return selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        }

        private func shapes(for mark: Mark, on page: PDFPage) -> [(MarkAnnotation.Shape, CGRect)] {
            let rects = lineRects(for: mark, on: page)
            let sheet = page.bounds(for: .mediaBox)
            let text = mark.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch mark.kind {
            case .delete:
                return rects.map { (.strike, $0) }
            case .replace:
                // Struck out, with the new words written above the first line.
                var shapes = rects.map { (MarkAnnotation.Shape.strike, $0) }
                if let first = rects.first, !text.isEmpty {
                    shapes.append(MarkAnnotation.writing(text, above: first, at: first.minX, on: sheet))
                }
                return shapes
            case .comment, .expand, .summarize:
                return rects.map { (.highlight, $0) }
            case .keep:
                return rects.map { (.keep, $0) }
            case .insert:
                guard let rect = rects.first else { return [] }
                let width = max(7, rect.height * 0.7)
                var shapes: [(MarkAnnotation.Shape, CGRect)] = [
                    (.caret, CGRect(x: rect.minX - width / 2, y: rect.minY - rect.height * 0.38, width: width, height: rect.height * 0.62)),
                ]
                if !text.isEmpty {
                    shapes.append(MarkAnnotation.writing(text, above: rect, at: rect.minX - width / 2, on: sheet))
                }
                return shapes
            }
        }

        /// Tells the margin where each mark is on screen, measured from the top of the view.
        private func updateAnchors() {
            // Notes follow the page as it scrolls; easing them would make them lag behind it.
            if margin.animates { margin.animates = false }
            var anchors: [UUID: CGFloat] = [:]
            for mark in session.marks {
                guard let page = page(of: mark), let rect = lineRects(for: mark, on: page).first else { continue }
                let inView = view.convert(rect, from: page)
                anchors[mark.id] = view.bounds.height - inView.midY
            }
            if margin.anchors != anchors { margin.anchors = anchors }
            if margin.firstLine != 36 { margin.firstLine = 36 }
        }

        private func reveal(_ mark: Mark) {
            guard let page = page(of: mark), let rect = lineRects(for: mark, on: page).first else { return }
            let visible = view.convert(view.bounds, to: page)
            if !visible.contains(rect) {
                view.go(to: rect.insetBy(dx: 0, dy: -80), on: page)
            }
            updateAnchors()
        }

        @objc private func viewChanged() {
            toolbar.hide()
            updateAnchors()
        }

        @objc private func frameChanged() {
            fitPage()
            viewChanged()
        }

        /// The largest the page is drawn: a typical document's text then reads
        /// about the size of the text page's. Wider windows show more desk.
        static let largestScale: CGFloat = 1.5

        /// The page takes the width it is given, up to the largest scale.
        func fitPage() {
            guard let scale = Self.fittingScale(for: view), abs(view.scaleFactor - scale) > 0.0001 else { return }
            view.scaleFactor = scale
        }

        /// The scale at which the widest page, with the desk around it, fills the
        /// visible width, but no more than the largest scale. Worked out here rather
        /// than asked of PDFKit, whose answer lags behind the page margins. PDFKit
        /// scales the desk with the sheet, so the margins count as part of the
        /// width: counted apart, the page came out wider than the view and slid
        /// sideways under the pointer.
        static func fittingScale(for view: PDFView) -> CGFloat? {
            guard let document = view.document, document.pageCount > 0 else { return nil }
            let visible = AnnotationPDFView.clipView(in: view)?.frame.width ?? view.bounds.width
            let margins = view.pageBreakMargins
            let widest = (0..<document.pageCount).compactMap { document.page(at: $0) }.map { page in
                let box = page.bounds(for: view.displayBox)
                return page.rotation % 180 == 0 ? box.width : box.height
            }.max() ?? 0
            let width = widest + margins.left + margins.right
            guard widest > 0, visible > 1 else { return nil }
            // Half a point to spare, so rounding never leaves the page a hair too wide.
            return min((visible - 0.5) / width, largestScale)
        }

        // MARK: Selection

        @objc private func selectionChanged() {
            if NSEvent.pressedMouseButtons == 0 { selectionSettled() }
        }

        private func mouseUp(at point: NSPoint) {
            if let selection = view.currentSelection, !(selection.string ?? "").isEmpty {
                selectionSettled()
                return
            }
            // A click on a mark selects it; a click elsewhere lets go of it.
            if session.editing != nil { session.endEditing() }
            var hit: UUID?
            if let page = view.page(for: point, nearest: false) {
                let onPage = view.convert(point, to: page)
                hit = annotations.first { $0.page == page && $0.bounds.insetBy(dx: -2, dy: -3).contains(onPage) }?.markID
            }
            shownSelection = hit
            session.selectedMarkID = hit
            session.selection = .none
        }

        private func selectionSettled() {
            guard let selected = currentSelection() else {
                toolbar.hide()
                session.selection = .none
                return
            }
            session.selection = .range
            toolbar.show(above: view.convert(selected.firstLine, from: selected.page), in: view)
        }

        /// The selection as a range of one page's text. A selection that runs over
        /// several pages is cut to the part on its first page.
        private func currentSelection() -> (page: PDFPage, index: Int, range: NSRange, firstLine: CGRect)? {
            guard let selection = view.currentSelection, let page = selection.pages.first,
                  let document = session.pdf, selection.numberOfTextRanges(on: page) > 0 else { return nil }
            let range = selection.range(at: 0, on: page)
            guard range.length > 0 else { return nil }
            let firstLine = selection.selectionsByLine().first { $0.pages.first == page }?.bounds(for: page) ?? selection.bounds(for: page)
            return (page, document.index(for: page), range, firstLine)
        }

        // MARK: Actions

        /// Comments on the selection with a reusable comment chosen from the picker.
        func pickSnippet() {
            toolbar.hide()
            guard let selected = currentSelection(), session.pageTexts.indices.contains(selected.index) else {
                session.statusMessage = "Select some text of the document first."
                NSSound.beep()
                return
            }
            let anchor = Anchor.make(
                inPage: session.pageTexts[selected.index], page: selected.index + 1,
                span: TextSpan(selected.range.location, NSMaxRange(selected.range))
            )
            snippetPicker.show(
                snippets: session.loadSnippets(), preferred: .preferred(for: session.request),
                relativeTo: view.convert(selected.firstLine, from: selected.page), of: view
            ) { [weak self] snippet in
                guard let self else { return }
                if let snippet { self.session.addComment(from: snippet, anchor: anchor) }
                self.view.window?.makeFirstResponder(self.view)
            }
        }

        /// Words typed on a selection are a comment on it.
        func comment(typing text: String) {
            toolbar.hide()
            let anchor = currentSelection().flatMap { selected in
                session.pageTexts.indices.contains(selected.index)
                    ? Anchor.make(inPage: session.pageTexts[selected.index], page: selected.index + 1,
                                  span: TextSpan(selected.range.location, NSMaxRange(selected.range)))
                    : nil
            }
            session.comment(typing: text, anchor: anchor)
        }

        /// - Parameter writingNote: whether the keyboard goes to the new mark's
        ///   note. Not for ⌫, which strikes as an editor deletes.
        func perform(_ kind: MarkKind, writingNote: Bool = true) {
            toolbar.hide()
            guard let selected = currentSelection(), session.pageTexts.indices.contains(selected.index) else {
                session.statusMessage = kind == .insert
                    ? "Select the words the new text goes after."
                    : "Select some text of the document first."
                NSSound.beep()
                return
            }
            let text = session.pageTexts[selected.index]
            let page = selected.index + 1
            let span = TextSpan(selected.range.location, NSMaxRange(selected.range))

            switch kind {
            case .insert:
                session.addMarkToWrite(.insert, anchor: Anchor.make(inPage: text, page: page, span: TextSpan(span.end, span.end)))
            case .delete where writingNote:
                // Ready for the reason, as a comment is; ↩ or Esc goes on without one.
                session.addMarkToWrite(kind, anchor: Anchor.make(inPage: text, page: page, span: span))
            case .delete, .keep, .expand, .summarize:
                session.addMark(kind, anchor: Anchor.make(inPage: text, page: page, span: span))
            case .replace, .comment:
                session.addMarkToWrite(kind, anchor: Anchor.make(inPage: text, page: page, span: span))
            }
        }
    }
}
