import Foundation

/// JSON as text, with just enough structure to add or remove one member or
/// element without rewriting the rest. Offsets are into the UTF-8 bytes.
struct JSONText {
    private var bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    struct Container {
        /// From the opening bracket to after the closing one.
        var range: Range<Int>
        /// Ranges of the members (key through value) or elements.
        var children: [Range<Int>]
        /// Whitespace before the first child, when it starts its own line.
        var childIndent: String?
    }

    struct Member {
        /// From the key's opening quote to the end of the value.
        var range: Range<Int>
        var value: Range<Int>
        /// Whitespace at the start of the member's line.
        var indent: String
    }

    /// One level of indentation as the file uses it, two spaces when it cannot be told.
    var indentUnit: String {
        guard let root = rootObject(), let indent = root.childIndent, !indent.isEmpty else { return "  " }
        return indent
    }

    // MARK: - Reading

    func rootObject() -> Container? {
        object(at: skipWhitespace(from: 0)..<bytes.count)
    }

    func object(at range: Range<Int>) -> Container? {
        container(at: range, open: UInt8(ascii: "{"), close: UInt8(ascii: "}"), keyed: true)
    }

    func array(at range: Range<Int>) -> Container? {
        container(at: range, open: UInt8(ascii: "["), close: UInt8(ascii: "]"), keyed: false)
    }

    func member(_ key: String, of object: Container) -> Member? {
        for child in object.children {
            guard let keyEnd = stringEnd(from: child.lowerBound),
                  let name = try? JSONSerialization.jsonObject(
                      with: Data(bytes[child.lowerBound..<keyEnd]), options: .fragmentsAllowed
                  ) as? String, name == key else { continue }
            let colon = skipWhitespace(from: keyEnd)
            let valueStart = skipWhitespace(from: colon + 1)
            return Member(range: child, value: valueStart..<child.upperBound, indent: lineIndent(at: child.lowerBound))
        }
        return nil
    }

    private func container(at range: Range<Int>, open: UInt8, close: UInt8, keyed: Bool) -> Container? {
        var index = range.lowerBound
        guard index < bytes.count, bytes[index] == open else { return nil }
        index += 1
        var children: [Range<Int>] = []
        var childIndent: String?

        while true {
            index = skipWhitespace(from: index)
            guard index < bytes.count else { return nil }
            if bytes[index] == close { return Container(range: range.lowerBound..<(index + 1), children: children, childIndent: childIndent) }

            let start = index
            if children.isEmpty, startsLine(start) { childIndent = lineIndent(at: start) }
            if keyed {
                guard let keyEnd = stringEnd(from: index) else { return nil }
                index = skipWhitespace(from: keyEnd)
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index = skipWhitespace(from: index + 1)
            }
            guard let valueEnd = valueEnd(from: index) else { return nil }
            children.append(start..<valueEnd)

            index = skipWhitespace(from: valueEnd)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1 }
        }
    }

    private func valueEnd(from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(from: start)
        case UInt8(ascii: "{"):
            return object(at: start..<bytes.count)?.range.upperBound
        case UInt8(ascii: "["):
            return array(at: start..<bytes.count)?.range.upperBound
        default:
            // A number, true, false or null runs to the next delimiter.
            var index = start
            let delimiters = Set(",]} \t\r\n".utf8)
            while index < bytes.count, !delimiters.contains(bytes[index]) { index += 1 }
            return index > start ? index : nil
        }
    }

    /// The offset after the closing quote of the string starting at `start`.
    private func stringEnd(from start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                index += 2
            } else if bytes[index] == UInt8(ascii: "\"") {
                return index + 1
            } else {
                index += 1
            }
        }
        return nil
    }

    private func skipWhitespace(from start: Int) -> Int {
        var index = start
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func lineStart(of offset: Int) -> Int {
        var index = offset
        while index > 0, bytes[index - 1] != 0x0A { index -= 1 }
        return index
    }

    private func startsLine(_ offset: Int) -> Bool {
        bytes[lineStart(of: offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private func lineIndent(at offset: Int) -> String {
        let start = lineStart(of: offset)
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    // MARK: - Editing

    /// Adds a member or element at the end of a container, on its own line.
    mutating func append(_ item: String, to container: Container, indent: String, closingIndent: String) throws {
        if let last = container.children.last {
            bytes.insert(contentsOf: Array(",\n\(indent)\(item)".utf8), at: last.upperBound)
        } else {
            // An empty container: open it up over three lines.
            let inside = (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
            bytes.replaceSubrange(inside, with: Array("\n\(indent)\(item)\n\(closingIndent)".utf8))
        }
    }

    mutating func remove(_ member: Member, from container: Container) {
        guard let index = container.children.firstIndex(of: member.range) else { return }
        remove(elementAt: index, from: container)
    }

    /// Removes a child together with the comma and the whitespace that belong to it.
    mutating func remove(elementAt index: Int, from container: Container) {
        guard container.children.indices.contains(index) else { return }
        let child = container.children[index]

        if container.children.count == 1 {
            // The only child: the container closes right after its opening bracket.
            bytes.removeSubrange((container.range.lowerBound + 1)..<(container.range.upperBound - 1))
        } else if index > 0 {
            // Take the comma before it, back to the end of the previous child.
            bytes.removeSubrange(container.children[index - 1].upperBound..<child.upperBound)
        } else {
            // The first child: take the comma after it, up to the next child.
            bytes.removeSubrange(child.lowerBound..<container.children[1].lowerBound)
        }
    }
}
