import AnnotatorCore
import SwiftUI

/// The margin of the page: one note per mark, each beside the line it refers to.
struct MarginNotes: View {
    @Bindable var session: ReviewSession
    let model: MarginModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MarginLayout(spacing: 6) {
            if session.marks.isEmpty {
                MarginGuide()
                    .layoutValue(key: AnchorKey.self, value: model.firstLine - MarginNote.firstLineCentre)
            } else {
                ForEach(session.orderedMarks) { mark in
                    MarginNote(session: session, mark: mark)
                        .layoutValue(key: AnchorKey.self, value: (model.anchors[mark.id] ?? 0) - MarginNote.topPadding - MarginNote.firstLineCentre)
                }
            }
        }
        // Notes glide to their new place when the text reflows. Not in a window
        // that is not on screen, where nothing would drive the animation.
        .animation(model.animates && !reduceMotion ? .snappy(duration: 0.2) : nil, value: model.anchors)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The distance from the top of the page at which a note wants to start.
private struct AnchorKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Places each note at its anchor, or right below the note above when that one is in the way.
private struct MarginLayout: Layout {
    var spacing: CGFloat

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        // Notes of marks scrolled out above the view sit above it, not piled at its top.
        var cursor = -CGFloat.greatestFiniteMagnitude
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let top = max(subview[AnchorKey.self], cursor)
            frames.append(CGRect(x: 0, y: top, width: width, height: size.height))
            cursor = top + size.height + spacing
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Theme.marginWidth
        return CGSize(width: width, height: max(0, frames(width: width, subviews: subviews).last?.maxY ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

// MARK: - A note

private struct MarginNote: View {
    static let topPadding: CGFloat = 5
    /// Half the height of a note's first line: notes are centred on the line they refer to.
    static let firstLineCentre: CGFloat = 8

    let session: ReviewSession
    let mark: Mark

    /// The field that has the keyboard, if one of this note's does.
    @State private var focus: MarkField?
    /// The note as it is being written. A note that is only spaces is stored
    /// as no note, and the spaces must not vanish from under the caret.
    @State private var draftNote: String?

    private var text: Binding<String> {
        Binding(get: { mark.text ?? "" }, set: { session.update(mark.id, text: $0) })
    }

    private var note: Binding<String> {
        Binding(
            get: { draftNote ?? mark.note ?? "" },
            set: { value in
                draftNote = value
                session.update(mark.id, note: value)
            }
        )
    }

    private var isSelected: Bool { session.selectedMarkID == mark.id }
    private var hasText: Bool { mark.kind == .replace || mark.kind == .insert }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSelected {
                editor
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .markColourBar(mark.kind)
        .padding(.vertical, Self.topPadding)
        .padding(.horizontal, 8)
        .background(mark.kind.tint.opacity(isSelected ? 0.11 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedMarkID = mark.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // What the note says when it is not being written.
    @ViewBuilder private var summary: some View {
        if hasText, let text = mark.text?.nilIfBlank {
            Text(text)
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(Color(nsColor: Theme.ink))
                .lineLimit(3)
        }
        if mark.kind.isInstruction {
            // The instruction is the message; it is always said.
            Text(mark.kind.label)
                .font(.system(size: 12.5, weight: .medium))
        }
        if let note = mark.note {
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(mark.kind.isInstruction ? .secondary : .primary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        } else if !mark.kind.isInstruction, !hasText || mark.text?.nilIfBlank == nil {
            Text(mark.kind.label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var editor: some View {
        if hasText {
            field(.text, prompt: mark.kind.textPrompt, text: text, font: Theme.serif(13, italic: true), color: Theme.ink)
        }
        if mark.kind.isInstruction {
            Text(mark.kind.label)
                .font(.system(size: 12.5, weight: .medium))
        }
        if mark.kind == .keep {
            Text("Keep")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        } else {
            field(.note, prompt: mark.kind.notePrompt, text: note, font: .systemFont(ofSize: 12.5), color: .labelColor)
        }
        HStack(spacing: 10) {
            if focus != nil {
                Text("↩ done")
            } else if mark.kind != .keep {
                Text("↩ write   ⌘⌫ remove")
            } else {
                Text("⌘⌫ remove")
            }
            Spacer(minLength: 0)
            Button {
                session.remove(mark.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this mark")
            .accessibilityLabel("Remove this mark")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.top, 1)
    }

    private func field(_ which: MarkField, prompt: String, text: Binding<String>, font: NSFont, color: NSColor) -> some View {
        NoteField(
            placeholder: prompt, text: text, font: font, color: color,
            wantsFocus: session.editing == EditTarget(markID: mark.id, field: which),
            onFocusChange: { focused in
                if focused {
                    focus = which
                } else if focus == which {
                    focus = nil
                    draftNote = nil
                }
            },
            onCommit: { session.endEditing() },
            onCancel: { session.endEditing() }
        )
    }

    private var accessibilityLabel: String {
        let quote = mark.anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [mark.kind.label]
        if !quote.isEmpty { parts.append(quote) }
        if let text = mark.text?.nilIfBlank { parts.append("with \(text)") }
        if let note = mark.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The empty margin

/// Shown before the first mark: what the keys do.
private struct MarginGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(Keymap.usesVimKeys
                ? "Press v and move to select, then press a key. Press i to type."
                : "Select text, then press a key. Or just type to add text where the caret is.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(MarkKind.allCases, id: \.self) { kind in
                    GridRow {
                        KeyCap(kind.keyLabel(vim: Keymap.usesVimKeys))
                        HStack(spacing: 7) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(kind.tint)
                                .frame(width: 14)
                            Text(kind.hint)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    KeyCap("S")
                    HStack(spacing: 7) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text("Use a saved comment")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 16)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

extension MarkKind {
    /// What the mark means, in the words of the person marking.
    var hint: String {
        switch self {
        case .delete: "Strike it out"
        case .replace: "Replace it"
        case .insert: "Add text here"
        case .comment: "Comment on it"
        case .expand: "Ask for more here"
        case .summarize: "Ask for it shorter"
        case .keep: "Keep it as it is"
        }
    }
}
