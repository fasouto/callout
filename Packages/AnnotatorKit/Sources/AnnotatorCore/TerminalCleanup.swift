import Foundation

/// Turns text copied out of a terminal back into the text that was meant: the
/// frames and bullets a terminal interface draws are removed, and lines that
/// were only broken because the window ended are joined again.
public enum TerminalCleanup {
    /// Bundle identifiers of the terminals whose selections get cleaned.
    public static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    ]

    public static func isTerminal(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(terminalApps.contains) ?? false
    }

    public static func clean(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripChrome(String($0)) }
            .compactMap { $0 }

        lines = dedent(lines)
        lines = rejoin(lines)

        // No blank lines at the ends, and never more than one in a row.
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    // MARK: - Interface characters

    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        // Box drawing and block elements.
        (0x2500...0x259F).contains(scalar.value)
    }

    /// Markers a terminal interface puts in front of a line: a message bullet,
    /// a result elbow, a prompt arrow.
    private static let leadingMarkers: [String] = ["⏺", "⎿", "❯", "●"]

    /// A line without its frame and markers, or nil when nothing but frame is left.
    private static func stripChrome(_ line: String) -> String? {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        guard !text.isEmpty else { return "" }

        // Only frame characters and spaces: an empty row inside a box is a blank
        // line of its text, anything else is a rule or the box's edge.
        if text.unicodeScalars.allSatisfy({ isBoxDrawing($0) || $0 == " " }) {
            let sides: Set<Unicode.Scalar> = ["│", "┃", "║", " "]
            return text.unicodeScalars.allSatisfy(sides.contains) ? "" : nil
        }

        // The sides of a box: "│ text │".
        let indent = text.prefix { $0 == " " }
        var body = text.dropFirst(indent.count)
        if let first = body.unicodeScalars.first, isBoxDrawing(first) {
            body = body.dropFirst()
            if body.first == " " { body = body.dropFirst() }
            if let last = body.unicodeScalars.last, isBoxDrawing(last) {
                body = body.dropLast()
                while body.last == " " { body = body.dropLast() }
            }
            text = indent + body
        }

        // A marker keeps its indentation, so the text still lines up with what follows it.
        let leading = text.prefix { $0 == " " }
        let rest = text.dropFirst(leading.count)
        for marker in leadingMarkers where rest.hasPrefix(marker) {
            let after = rest.dropFirst(marker.count)
            let gap = after.prefix { $0 == " " }
            text = leading + String(repeating: " ", count: marker.count + gap.count) + after.dropFirst(gap.count)
            break
        }
        return String(text)
    }

    /// Removes the indentation every line shares.
    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count }
        guard let common = indents.min(), common > 0 else {
            return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : $0 }
        }
        return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(common)) }
    }

    // MARK: - Hard wraps

    /// Joins lines the terminal broke at its right edge. A line was broken there
    /// if the first word of the next line would not have fitted on it.
    private static func rejoin(_ lines: [String]) -> [String] {
        let width = lines.map(\.count).max() ?? 0
        // Short text was never near the edge; leave its line breaks alone.
        guard width >= 40 else { return lines }

        var result: [String] = []
        var inCode = false
        // The line as it was in the terminal; `result.last` grows as lines are joined to it.
        var physical: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            defer {
                if isFence { inCode.toggle() }
                physical = line
            }

            if let physical, let joined = result.last, !inCode, !isFence, continues(physical, with: line, width: width) {
                result[result.count - 1] = joined + " " + trimmed
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func continues(_ previous: String, with next: String, width: Int) -> Bool {
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        let previousTrimmed = previous.trimmingCharacters(in: .whitespaces)
        guard !nextTrimmed.isEmpty, !previousTrimmed.isEmpty else { return false }
        // These lines are whole by nature, or start something new.
        if startsBlock(nextTrimmed) || isStandalone(previousTrimmed) { return false }

        // Would the next line's first word have fitted on the previous line?
        let firstWord = nextTrimmed.prefix { $0 != " " }
        return previous.count + 1 + firstWord.count > width
    }

    /// Whether a line begins a list item, heading, quote, table row or code fence.
    private static func startsBlock(_ line: String) -> Bool {
        line.wholeMatch(of: /(?:[-*+•]|\d{1,3}[.)])\s.*|\#{1,6}\s.*|>.*|\|.*|```.*|~~~.*/) != nil
    }

    /// Whether a line is never continued: a heading, a table row, a fence.
    private static func isStandalone(_ line: String) -> Bool {
        line.wholeMatch(of: /\#{1,6}\s.*|\|.*|```.*|~~~.*/) != nil
    }
}
