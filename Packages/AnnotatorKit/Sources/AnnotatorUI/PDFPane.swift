import AnnotatorCore
import AppKit
import PDFKit
import SwiftUI

/// The PDF view with the same keys as the text page: letters mark the selection.
final class AnnotationPDFView: PDFView {
    var onCommand: ((Keymap.Command) -> Void)?
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
        let isPlain = modifiers.isEmpty || modifiers == .shift

        let vim = usesVimKeys ?? Keymap.usesVimKeys
        if vim, vimKeyDown(characters, keyCode: event.keyCode, modifiers: modifiers) { return }

        if isPlain, let command = Keymap.command(for: characters, vim: vim) {
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
            super.keyDown(with: event)
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
/// of a keep, or the caret where text is to be added. Never saved to the file.
final class MarkAnnotation: PDFAnnotation {
    enum Shape {
        case strike
        case highlight
        case keep
        case caret
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
        shouldPrint = false
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
            // Multiplied over the page, as a highlighter is.
            context.setBlendMode(.multiply)
            context.setFillColor(Theme.highlighter.withAlphaComponent(isSelected ? 0.75 : 0.45).cgColor)
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
            context.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.45))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.strokePath()
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
            view.autoScales = true
            view.pageShadowsEnabled = true
            view.backgroundColor = .underPageBackgroundColor
            view.setAccessibilityLabel("Document")

            view.onCommand = { [weak self] command in
                switch command {
                case .mark(let kind): self?.perform(kind)
                case .snippets: self?.pickSnippet()
                case .overall: self?.session.focusOverallComment()
                }
            }
            view.onDeleteKey = { [weak self] in
                guard let self else { return }
                // ⌫ strikes out the selected text, or takes the strike back from text
                // that is already struck; with nothing selected it removes the selected mark.
                if let selected = self.currentSelection() {
                    let span = TextSpan(selected.range.location, NSMaxRange(selected.range))
                    let struck = self.session.marks.first {
                        $0.kind == .delete && $0.anchor.page == selected.index + 1 && $0.anchor.span == span
                    }
                    if let struck { self.session.remove(struck.id) } else { self.perform(.delete) }
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
            // The page scrolls inside the PDF view's own scroll view.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let clip = AnnotationPDFView.clipView(in: view) else { return }
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(self.viewChanged), name: NSView.boundsDidChangeNotification, object: clip)
                view.window?.makeFirstResponder(view)
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
            switch mark.kind {
            case .delete, .replace:
                return rects.map { (.strike, $0) }
            case .comment, .expand, .summarize:
                return rects.map { (.highlight, $0) }
            case .keep:
                return rects.map { (.keep, $0) }
            case .insert:
                guard let rect = rects.first else { return [] }
                let width = max(6, rect.height * 0.62)
                return [(.caret, CGRect(x: rect.minX - width / 2, y: rect.minY - rect.height * 0.36, width: width, height: rect.height * 0.6))]
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

        func perform(_ kind: MarkKind) {
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
            case .delete, .keep, .expand, .summarize:
                session.addMark(kind, anchor: Anchor.make(inPage: text, page: page, span: span))
            case .replace, .comment:
                session.addMarkToWrite(kind, anchor: Anchor.make(inPage: text, page: page, span: span))
            }
        }
    }
}
