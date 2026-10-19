import Foundation

/// How wide a table's text is on the page, near enough to choose its layout
/// before it is set in type: in points of the page's table type, a character
/// at a time. The page measures the text itself once it is set.
public enum TableMeasure {
    /// A character of a cell: the serif a size under the body's, or code.
    static let cellCharacter = 7.6
    /// A character of a column's name: the small sans of the header.
    static let nameCharacter = 6.5
    /// Between two columns, on the page too.
    public static let gap = 24.0
    /// What the last column needs at least when its cells wrap, on the page too.
    public static let wrappingColumn = 160.0
    /// The widest a table in columns can be: the page's measure, less a
    /// little for the guesswork. A narrower window sets it in smaller type.
    static let budget = 600.0
    /// The most lines a column's name wraps over.
    static let nameLines = 3

    static func cell(_ text: String) -> Double {
        Double(text.count) * cellCharacter
    }

    static func name(_ text: String) -> Double {
        Double(text.count) * nameCharacter
    }

    /// The widths of a name's words.
    static func words(of name: String) -> [Double] {
        name.split(whereSeparator: \.isWhitespace).map { self.name(String($0)) }
    }

    /// The narrowest a name can be set, broken between words into at most `lines` lines.
    static func narrowest(_ words: [Double], lines: Int) -> Double {
        guard let widest = words.max() else { return 0 }
        guard words.count > lines else { return widest }
        // Every width a line can have: a run of words with the spaces between them.
        let space = nameCharacter
        let words = words.prefix(40)
        var candidates: [Double] = []
        for start in words.indices {
            var width = -space
            for end in start..<words.endIndex {
                width += space + words[end]
                if width >= widest { candidates.append(width) }
            }
        }
        for width in candidates.sorted() where lineCount(words, space: space, width: width) <= lines {
            return width
        }
        return words.reduce(-space) { $0 + space + $1 }
    }

    /// How many lines words take, each line filled before the next is begun.
    private static func lineCount(_ words: ArraySlice<Double>, space: Double, width: Double) -> Int {
        var count = 0
        var used = 0.0
        for word in words {
            if count > 0, used + space + word <= width + 0.01 {
                used += space + word
            } else {
                count += 1
                used = word
            }
        }
        return count
    }

    /// Whether a column holds numbers: some, and nothing but numbers and the
    /// dashes and blanks that stand for none.
    static func holdsNumbers(_ cells: [String]) -> Bool {
        var found = false
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespaces)
            if ["", "-", "–", "—", "n/a", "N/A", "?"].contains(text) { continue }
            guard isNumber(text) else { return false }
            found = true
        }
        return found
    }

    /// A number as tables hold them: 488, 96.5%, $3.00, 1,024, −2, ~2 s, 200K, 1 MB.
    static func isNumber(_ text: String) -> Bool {
        var rest = Substring(text).unicodeScalars[...]
        func dropOne(of characters: String) {
            if let first = rest.first, characters.unicodeScalars.contains(first) { rest.removeFirst() }
        }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

        dropOne(of: "~≈<>≤≥±+−-")
        dropOne(of: "$€£¥")
        guard let first = rest.first, isDigit(first) else { return false }
        while let next = rest.first, isDigit(next) || ",. \u{2009}\u{202F}".unicodeScalars.contains(next) {
            rest.removeFirst()
        }
        // A unit after it, short: %, K, MB, ms, ×.
        var unit = 0
        while let next = rest.first, next == "%" || next == "×" || next == "µ" || CharacterSet.letters.contains(next) {
            rest.removeFirst()
            unit += 1
        }
        return rest.isEmpty && unit <= 3
    }
}
