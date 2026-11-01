import AppKit

/// What a typesetter does to text before it is printed, limited to what keeps
/// every character where it is: the page shows the text, the marks point into
/// the source, and both must count the same.
enum Typography {
    /// Sets straight quotes as curly ones and a spaced hyphen as an en dash.
    /// Code is left as it was written.
    static func setPunctuation(in text: NSMutableAttributedString) {
        let string = text.string as NSString
        guard string.length > 0 else { return }
        var replacements: [(Int, String)] = []
        for index in 0..<string.length {
            let character = string.character(at: index)
            guard character == 0x22 || character == 0x27 || character == 0x2D else { continue }
            if isCode(at: index, in: text) { continue }
            let before = index > 0 ? string.character(at: index - 1) : nil
            let after = index + 1 < string.length ? string.character(at: index + 1) : nil
            switch character {
            case 0x22: // "
                replacements.append((index, opens(after: before) ? "\u{201C}" : "\u{201D}"))
            case 0x27: // '
                replacements.append((index, opens(after: before) ? "\u{2018}" : "\u{2019}"))
            default: // - with a space on each side, between words
                if before == 0x20, after == 0x20, !startsLine(index, in: string) { replacements.append((index, "\u{2013}")) }
            }
        }
        for (index, replacement) in replacements {
            text.replaceCharacters(in: NSRange(location: index, length: 1), with: replacement)
        }
    }

    /// Whether only spaces come before this place on its line. A hyphen there
    /// starts a list item in plain text, and stays a hyphen.
    private static func startsLine(_ index: Int, in string: NSString) -> Bool {
        var look = index - 1
        while look >= 0 {
            let character = string.character(at: look)
            if character == 0x0A || character == 0x0D || character == 0x2028 { return true }
            if character != 0x20, character != 0x09 { return false }
            look -= 1
        }
        return true
    }

    /// A quote opens at the start of a line, after a space, or after an opening bracket or dash.
    private static func opens(after previous: unichar?) -> Bool {
        guard let previous, let scalar = Unicode.Scalar(previous) else { return true }
        let character = Character(scalar)
        return character.isWhitespace || "([{\u{2014}\u{2013}\u{201C}\u{2018}".contains(character)
    }

    private static func isCode(at index: Int, in text: NSAttributedString) -> Bool {
        if let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont,
           font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return true
        }
        if case .panel = text.attribute(.calloutBlock, at: index, effectiveRange: nil) as? BlockDecoration { return true }
        return false
    }
}
