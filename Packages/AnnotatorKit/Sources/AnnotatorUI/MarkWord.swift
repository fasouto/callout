import AnnotatorCore
import SwiftUI

/// A mark's name, drawn the way the mark looks on the page, with the letter
/// that makes it in bold: Delete struck in red, Replace and Insert in blue ink,
/// the notes under the highlighter, Keep underlined in green.
struct MarkWord: View {
    let kind: MarkKind
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 2) {
            if kind == .keep, Keymap.usesVimKeys {
                // With vim keys a plain K moves up, so Keep takes Shift.
                Text("⇧")
                    .font(.system(size: size - 1.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            word
        }
        .accessibilityLabel(kind.label)
    }

    @ViewBuilder private var word: some View {
        let text = Self.keyed(kind.label, key: kind.key).font(.system(size: size))
        switch kind {
        case .delete:
            text.strikethrough(color: Color(nsColor: Theme.pen))
        case .replace, .insert:
            text.italic().foregroundStyle(Color(nsColor: Theme.ink))
        case .comment, .expand, .summarize:
            text
                .padding(.horizontal, 3)
                .background(Color(nsColor: Theme.highlighter).opacity(0.4), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .keep:
            text.underline(color: Color(nsColor: Theme.keep))
        }
    }

    /// The word for saved comments, with its key in bold like the marks'.
    static func savedComments(size: CGFloat = 12.5) -> some View {
        keyed("Saved…", key: "S")
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Saved comments")
    }

    /// The word with its key letter in bold. The letter is looked up in the
    /// word, so Expand shows its x and Summarize its m.
    static func keyed(_ word: String, key: String) -> Text {
        guard let parts = split(word, key: key) else { return Text(word).fontWeight(.medium) }
        return Text(parts.before).fontWeight(.medium)
            + Text(parts.key).fontWeight(.heavy)
            + Text(parts.after).fontWeight(.medium)
    }

    static func split(_ word: String, key: String) -> (before: Substring, key: Substring, after: Substring)? {
        guard let index = word.firstIndex(where: { $0.lowercased() == key.lowercased() }) else { return nil }
        let next = word.index(after: index)
        return (word[..<index], word[index..<next], word[next...])
    }
}

extension View {
    /// A thin bar in the mark's colour down the leading edge, in place of an icon:
    /// the colour is the one the mark has on the page.
    func markColourBar(_ kind: MarkKind) -> some View {
        padding(.leading, 9)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(kind.tint)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
    }
}
