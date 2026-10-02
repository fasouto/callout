import AnnotatorCore
import AnnotatorStore
import Foundation
import Observation
import PDFKit

/// One review in progress: the document, the marks made so far, and what to
/// send back. Everything the review window shows comes from here.
@MainActor
@Observable
final class ReviewSession {
    let request: ReviewRequest
    /// The text under review, and how it is displayed. Empty for a PDF.
    let source: String
    let document: RenderedDocument
    /// The PDF under review, with the text of each page. Nil for text.
    let pdf: PDFDocument?
    let pageTexts: [String]
    /// Why the content could not be shown, if it could not.
    let loadFailure: String?
    /// What changed since the previous version of this plan, when there was one.
    let changes: PlanChanges?
    /// Which version of the plan this is, counting from 1.
    let planVersion: Int?
    /// Whether the changes since the previous version are pointed out.
    var showsChanges = true {
        didSet { if showsChanges != oldValue { marksChanged() } }
    }

    private(set) var marks: [Mark] = []
    private(set) var layout: DisplayLayout
    /// Bumped whenever the text view has to redraw.
    private(set) var revision = 0
    var generalComment = ""
    var selectedMarkID: UUID? {
        didSet {
            guard selectedMarkID != oldValue else { return }
            revision += 1
            // Writing in a different note is a different undo step.
            if coalescedEdit != selectedMarkID { coalescedEdit = nil }
        }
    }
    /// A short note for the status line, such as why an action did nothing.
    var statusMessage: String?
    /// The margin field that should have the keyboard, if any.
    private(set) var editing: EditTarget?
    /// Bumped to hand the keyboard back to the document.
    private(set) var documentFocusToken = 0
    /// Whether the document has a selection that marks can be applied to.
    var selection = SelectionState.none
    /// Bumped to give the keyboard to the overall comment.
    private(set) var overallFocusToken = 0
    /// With vim keys: whether a selection is being extended by moving (visual mode).
    var isSelectingByKeyboard = false
    /// The reusable comments on offer, loaded when the picker is first asked for.
    @ObservationIgnored var loadSnippets: () -> [Snippet] = { [] }
    /// For comments that came from a snippet, which one: the history remembers it.
    @ObservationIgnored private(set) var snippetUses: [UUID: Int64] = [:]
    /// The window's undo manager, so ⌘Z takes back marks.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// A mark that was added to be written and has nothing written yet, with the
    /// marks as they were before it.
    @ObservationIgnored private var unwritten: (id: UUID, before: Snapshot)?
    /// The mark whose edits are already covered by an undo step.
    @ObservationIgnored private var coalescedEdit: UUID?

    /// - Parameters:
    ///   - previousVersion: the plan as it was before this revision, to compare against.
    ///   - planVersion: which version this one is.
    init(request: ReviewRequest, previousVersion: String? = nil, planVersion: Int? = nil) {
        self.request = request
        self.planVersion = planVersion
        if case .text(let text, _) = request.content, let previousVersion {
            let found = PlanDiff.changes(from: previousVersion, to: text)
            changes = found.isEmpty ? nil : found
        } else {
            changes = nil
        }
        switch request.content {
        case .text(let text, let format):
            source = text
            document = MarkdownRenderer.render(text, format: format)
            pdf = nil
            pageTexts = []
            loadFailure = nil
        case .file(let path):
            source = ""
            document = RenderedDocument(plain: "")
            let loaded = PDFDocument(url: URL(fileURLWithPath: path))
            pdf = loaded
            pageTexts = (0..<(loaded?.pageCount ?? 0)).map { loaded?.page(at: $0)?.string ?? "" }
            if loaded == nil {
                loadFailure = "\(URL(fileURLWithPath: path).lastPathComponent) could not be opened as a PDF."
            } else if pageTexts.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                loadFailure = "This PDF has no text to select. It may be a scan."
            } else {
                loadFailure = nil
            }
        }
        layout = DisplayLayout(document: document, marks: [], removals: changes?.removed ?? [])
    }

    /// The changes to point out right now: none when they are hidden.
    var shownChanges: PlanChanges? {
        showsChanges ? changes : nil
    }

    var isPDF: Bool { pdf != nil }

    var title: String {
        if let title = request.metadata.title, !title.isEmpty { return title }
        if case .file(let path) = request.content { return URL(fileURLWithPath: path).lastPathComponent }
        if let path = request.metadata.filePath { return URL(fileURLWithPath: path).lastPathComponent }
        return "Text"
    }

    /// Marks in the order they appear in the document.
    var orderedMarks: [Mark] {
        marks.enumerated().sorted { lhs, rhs in
            (lhs.element.anchor.page ?? 0, lhs.element.anchor.span.start, lhs.offset)
                < (rhs.element.anchor.page ?? 0, rhs.element.anchor.span.start, rhs.offset)
        }.map(\.element)
    }

    var selectedMark: Mark? {
        marks.first { $0.id == selectedMarkID }
    }

    var allows: (feedback: Bool, applyEdits: Bool, approve: Bool) {
        (request.modes.contains(.feedback), request.modes.contains(.applyEdits), request.modes.contains(.approve))
    }

    // MARK: - Selections

    /// The source behind a selection in the view, or nil when it covers no document text.
    func sourceSpan(forView range: Range<Int>) -> TextSpan? {
        let displayed = layout.displayedRange(forView: range)
        return document.sourceSpan(forDisplayed: displayed)
    }

    func sourceOffset(forView offset: Int) -> Int? {
        document.sourceOffset(forDisplayed: layout.displayedOffset(forView: offset))
    }

    /// The mark whose text contains a view offset, edits before comments.
    func mark(atView offset: Int) -> Mark? {
        let hits = marks.filter { mark in
            if layout.ghosts.contains(where: { $0.markID == mark.id && $0.range.contains(offset) }) { return true }
            return layout.viewRanges(forSource: mark.anchor.span).contains { $0.contains(offset) }
        }
        return hits.first { $0.kind.isEdit } ?? hits.first
    }

    // MARK: - Editing marks

    /// Adds a mark over a source span. Returns nil, with a status message, when it cannot be placed.
    @discardableResult
    func addMark(_ kind: MarkKind, span: TextSpan, text: String? = nil, note: String? = nil) -> Mark? {
        place(kind, anchor: Anchor.make(in: source, span: span), text: text, note: note, undoName: kind.label)
    }

    /// Adds a mark at an anchor built elsewhere, such as on a PDF page.
    @discardableResult
    func addMark(_ kind: MarkKind, anchor: Anchor?, text: String? = nil, note: String? = nil) -> Mark? {
        place(kind, anchor: anchor, text: text, note: note, undoName: kind.label)
    }

    /// Adds a mark that still has to be written: a replacement, an insertion or a
    /// comment. The keyboard goes to its margin field, and the mark only becomes
    /// undoable once something was written; left empty, it never happened.
    @discardableResult
    func addMarkToWrite(_ kind: MarkKind, span: TextSpan) -> Mark? {
        addMarkToWrite(kind, anchor: Anchor.make(in: source, span: span))
    }

    @discardableResult
    func addMarkToWrite(_ kind: MarkKind, anchor: Anchor?) -> Mark? {
        let before = Snapshot(marks: marks, selection: selectedMarkID)
        guard let mark = place(kind, anchor: anchor, text: kind == .comment ? nil : "", note: nil, undoName: nil) else {
            return nil
        }
        unwritten = (mark.id, before)
        coalescedEdit = mark.id
        beginEditing(mark.id)
        return mark
    }

    private func place(_ kind: MarkKind, anchor: Anchor?, text: String?, note: String?, undoName: String?) -> Mark? {
        guard let anchor else {
            statusMessage = "That selection can't be marked."
            return nil
        }
        let mark = Mark(kind: kind, anchor: anchor, text: text, note: note?.nilIfBlank)
        if EditApplier.conflict(of: mark, with: marks) != nil {
            statusMessage = "That overlaps another edit. Remove it first."
            return nil
        }
        if let undoName { registerUndo(undoName) }
        marks.append(mark)
        statusMessage = nil
        selectedMarkID = mark.id
        marksChanged()
        return mark
    }

    /// Comments on text with a reusable comment.
    @discardableResult
    func addComment(from snippet: Snippet, anchor: Anchor?) -> Mark? {
        guard let mark = place(.comment, anchor: anchor, text: nil, note: snippet.text, undoName: MarkKind.comment.label) else {
            return nil
        }
        snippetUses[mark.id] = snippet.id
        return mark
    }

    // MARK: - Writing in the margin

    /// Gives the keyboard to a mark's margin field: its text for a replacement or
    /// insertion, otherwise its note.
    func beginEditing(_ id: UUID, field: MarkField? = nil) {
        guard let mark = marks.first(where: { $0.id == id }), mark.kind != .keep else { return }
        let natural: MarkField = mark.kind == .replace || mark.kind == .insert ? .text : .note
        selectedMarkID = id
        editing = EditTarget(markID: id, field: field ?? natural)
    }

    /// Gives the keyboard to the overall comment.
    func focusOverallComment() {
        if editing != nil { endEditing() }
        overallFocusToken += 1
    }

    /// Finishes writing and returns the keyboard to the document. A mark left
    /// without what makes it one is tidied away: an empty insertion or comment
    /// goes, and a replacement with nothing becomes a deletion.
    func endEditing() {
        if let id = editing?.markID, let index = marks.firstIndex(where: { $0.id == id }) {
            let mark = marks[index]
            let text = mark.text?.nilIfBlank
            var survives = true
            switch mark.kind {
            case .insert where text == nil, .comment where mark.note == nil:
                survives = false
                drop(id)
            case .replace where text == nil:
                marks[index].kind = .delete
                marks[index].text = nil
                marksChanged()
            default:
                break
            }
            if let unwritten, unwritten.id == id, survives {
                registerUndo(marks[index].kind.label, restoring: unwritten.before)
            }
        }
        unwritten = nil
        coalescedEdit = nil
        editing = nil
        documentFocusToken += 1
    }

    func update(_ id: UUID, text: String? = nil, note: String? = nil) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        // One undo step per mark being written, not one per keystroke.
        if coalescedEdit != id {
            registerUndo("Edit Note")
            coalescedEdit = id
        }
        if let text { marks[index].text = text }
        if let note { marks[index].note = note.nilIfBlank }
        marksChanged()
    }

    func remove(_ id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        if unwritten?.id == id {
            unwritten = nil
        } else {
            registerUndo("Remove Mark")
        }
        drop(id)
        if editing?.markID == id {
            editing = nil
            documentFocusToken += 1
        }
    }

    private func drop(_ id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        let position = orderedMarks.firstIndex { $0.id == id } ?? 0
        marks.remove(at: index)
        coalescedEdit = nil
        // Keep the keyboard flowing: select the neighbour.
        if selectedMarkID == id {
            let remaining = orderedMarks
            selectedMarkID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
        }
        marksChanged()
    }

    /// Selects the next or the previous mark in the document, wrapping around.
    func selectMark(offsetBy step: Int) {
        let ordered = orderedMarks
        guard !ordered.isEmpty else { return }
        guard let current = ordered.firstIndex(where: { $0.id == selectedMarkID }) else {
            selectedMarkID = step > 0 ? ordered.first?.id : ordered.last?.id
            return
        }
        selectedMarkID = ordered[(current + step + ordered.count) % ordered.count].id
    }

    // MARK: - Undo

    private struct Snapshot {
        var marks: [Mark]
        var selection: UUID?
    }

    /// Makes the change that follows undoable, by remembering the marks as they are now.
    private func registerUndo(_ name: String, restoring snapshot: Snapshot? = nil) {
        guard let undoManager else { return }
        let snapshot = snapshot ?? Snapshot(marks: marks, selection: selectedMarkID)
        let marks = snapshot.marks
        let selection = snapshot.selection
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(marks, selection: selection, name: name) }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func restore(_ marks: [Mark], selection: UUID?, name: String) {
        // Registering while undoing is what makes redo work.
        registerUndo(name)
        unwritten = nil
        coalescedEdit = nil
        editing = nil
        self.marks = marks
        selectedMarkID = marks.contains { $0.id == selection } ? selection : nil
        marksChanged()
        documentFocusToken += 1
    }

    private func marksChanged() {
        layout = DisplayLayout(document: document, marks: marks, removals: shownChanges?.removed ?? [])
        revision += 1
    }

    // MARK: - Output

    var hasFeedback: Bool {
        !marks.isEmpty || !generalComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasEdits: Bool {
        marks.contains { $0.kind.isEdit }
    }

    func feedback() -> String {
        FeedbackFormatter.format(.init(
            title: title, document: isPDF ? .pdf(pages: pageTexts) : .text(source),
            marks: marks, generalComment: generalComment
        ))
    }

    func editedText() throws -> String {
        try EditApplier.apply(marks, to: source)
    }
}

enum MarkField: Hashable {
    /// The replacement, or the text to insert.
    case text
    /// The reason or the comment.
    case note
}

struct EditTarget: Equatable {
    var markID: UUID
    var field: MarkField
}

enum SelectionState: Equatable {
    case none
    /// A caret in the document: text can be inserted there.
    case caret
    /// Selected document text: any mark applies.
    case range
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

extension MarkKind {
    var label: String {
        switch self {
        case .delete: "Delete"
        case .replace: "Replace"
        case .insert: "Insert"
        case .comment: "Comment"
        case .expand: "Expand"
        case .summarize: "Summarize"
        case .keep: "Keep"
        }
    }

    var key: String {
        switch self {
        case .delete: "D"
        case .replace: "R"
        case .insert: "I"
        case .comment: "C"
        case .expand: "X"
        case .summarize: "M"
        case .keep: "K"
        }
    }

    /// The key as shown to the user. With vim keys on, a plain K moves up, so Keep needs Shift.
    func keyLabel(vim: Bool) -> String {
        self == .keep && vim ? "⇧K" : key
    }

    var symbol: String {
        switch self {
        case .delete: "strikethrough"
        case .replace: "arrow.2.squarepath"
        case .insert: "plus"
        case .comment: "highlighter"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .summarize: "arrow.down.right.and.arrow.up.left"
        case .keep: "checkmark"
        }
    }

    /// An instruction is said by the mark itself; a note is only an addition to it.
    var isInstruction: Bool {
        self == .expand || self == .summarize
    }

    /// What the mark's margin field asks for.
    var textPrompt: String {
        self == .replace ? "Replace with" : "Text to add"
    }

    var notePrompt: String {
        switch self {
        case .comment: "Comment"
        case .expand: "What is missing (optional)"
        case .summarize: "What to keep (optional)"
        default: "Reason (optional)"
        }
    }

    init?(key: String) {
        guard let kind = MarkKind.allCases.first(where: { $0.key.lowercased() == key.lowercased() }) else { return nil }
        self = kind
    }
}
