import Foundation

/// What changed between two versions of a text, described against the new one.
public struct PlanChanges: Equatable, Sendable {
    public struct Removal: Equatable, Sendable {
        /// Where in the new text the removed text used to be (UTF-16 offset).
        public var offset: Int
        public var text: String
        /// Whole lines were removed, rather than words inside a line.
        public var isWholeLine: Bool

        public init(offset: Int, text: String, isWholeLine: Bool) {
            self.offset = offset
            self.text = text
            self.isWholeLine = isWholeLine
        }
    }

    /// Spans of the new text that were not in the old one.
    public var added: [TextSpan] = []
    public var removed: [Removal] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    public init(added: [TextSpan] = [], removed: [Removal] = []) {
        self.added = added
        self.removed = removed
    }
}

/// Compares two versions line by line, then word by word inside lines that
/// were reworded, so a changed sentence shows which words changed.
public enum PlanDiff {
    public static func changes(from old: String, to new: String) -> PlanChanges {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // UTF-16 offset at which each line of the new text starts.
        var starts: [Int] = []
        var offset = 0
        for line in newLines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        let end = new.utf16.count

        var removedOld = Set<Int>()
        var insertedNew = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let index, _, _): removedOld.insert(index)
            case .insert(let index, _, _): insertedNew.insert(index)
            }
        }

        var changes = PlanChanges()
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            // A run of removed lines followed by a run of inserted ones is a rewrite.
            var removedRun: [Int] = []
            while removedOld.contains(oldIndex) {
                removedRun.append(oldIndex)
                oldIndex += 1
            }
            var insertedRun: [Int] = []
            while insertedNew.contains(newIndex) {
                insertedRun.append(newIndex)
                newIndex += 1
            }

            if removedRun.isEmpty && insertedRun.isEmpty {
                oldIndex += 1
                newIndex += 1
                continue
            }

            let paired = min(removedRun.count, insertedRun.count)
            for pair in 0..<paired {
                let before = oldLines[removedRun[pair]]
                let after = newLines[insertedRun[pair]]
                let start = starts[insertedRun[pair]]
                if let words = wordChanges(from: before, to: after, at: start) {
                    changes.added += words.added
                    changes.removed += words.removed
                } else {
                    // Too different to be the same line reworded.
                    appendLine(removed: before, at: start, to: &changes)
                    appendLine(added: after, at: start, to: &changes)
                }
            }
            for index in removedRun.dropFirst(paired) {
                // Shown where the next surviving line of the new text begins.
                let position = newIndex < starts.count ? starts[newIndex] : end
                appendLine(removed: oldLines[index], at: position, to: &changes)
            }
            for index in insertedRun.dropFirst(paired) {
                appendLine(added: newLines[index], at: starts[index], to: &changes)
            }
        }
        return changes
    }

    private static func appendLine(removed line: String, at offset: Int, to changes: inout PlanChanges) {
        guard !line.allSatisfy(\.isWhitespace) else { return }
        changes.removed.append(.init(offset: offset, text: line, isWholeLine: true))
    }

    private static func appendLine(added line: String, at offset: Int, to changes: inout PlanChanges) {
        guard !line.allSatisfy(\.isWhitespace) else { return }
        changes.added.append(TextSpan(offset, offset + line.utf16.count))
    }

    // MARK: - Words

    /// Words, and every other character on its own.
    private static func tokens(_ line: String) -> [Substring] {
        var result: [Substring] = []
        var index = line.startIndex
        while index < line.endIndex {
            if line[index].isLetter || line[index].isNumber {
                var end = index
                while end < line.endIndex, line[end].isLetter || line[end].isNumber { end = line.index(after: end) }
                result.append(line[index..<end])
                index = end
            } else {
                let next = line.index(after: index)
                result.append(line[index..<next])
                index = next
            }
        }
        return result
    }

    /// The changes between two versions of a line, or nil when they share too
    /// little for a word-by-word comparison to mean anything.
    private static func wordChanges(from before: String, to after: String, at lineStart: Int) -> PlanChanges? {
        let oldTokens = tokens(before)
        let newTokens = tokens(after)
        let difference = newTokens.difference(from: oldTokens)

        var removedAt: [Int: Substring] = [:]
        var insertedAt = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let index, let token, _): removedAt[index] = token
            case .insert(let index, _, _): insertedAt.insert(index)
            }
        }
        // Compare by words, so shared spaces and punctuation do not make two
        // unrelated lines look alike.
        let isWord: (Substring) -> Bool = { $0.first.map { $0.isLetter || $0.isNumber } ?? false }
        let oldWords = oldTokens.filter(isWord).count
        let newWords = newTokens.filter(isWord).count
        let keptWords = oldWords - removedAt.values.filter(isWord).count
        guard oldWords + newWords > 0, Double(2 * keptWords) / Double(oldWords + newWords) >= 0.5 else { return nil }

        var changes = PlanChanges()
        var offset = lineStart
        var oldIndex = 0
        var newIndex = 0
        var pendingRemoval = ""
        var pendingAddition: TextSpan?

        func flush() {
            if !pendingRemoval.allSatisfy(\.isWhitespace) {
                changes.removed.append(.init(offset: pendingAddition?.start ?? offset, text: pendingRemoval, isWholeLine: false))
            }
            if let span = pendingAddition { changes.added.append(span) }
            pendingRemoval = ""
            pendingAddition = nil
        }

        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            if let removed = removedAt[oldIndex] {
                pendingRemoval += removed
                oldIndex += 1
            } else if insertedAt.contains(newIndex) {
                let length = newTokens[newIndex].utf16.count
                pendingAddition = TextSpan(pendingAddition?.start ?? offset, offset + length)
                offset += length
                newIndex += 1
            } else {
                // A space kept between two changed words belongs to the change:
                // "very robust" is one removal, not two with a space in between.
                let kept = newIndex < newTokens.count ? newTokens[newIndex] : ""
                let hasPending = !pendingRemoval.isEmpty || pendingAddition != nil
                let changeFollows = removedAt[oldIndex + 1] != nil || insertedAt.contains(newIndex + 1)
                if hasPending, changeFollows, !kept.isEmpty, kept.allSatisfy(\.isWhitespace) {
                    if !pendingRemoval.isEmpty { pendingRemoval += kept }
                    if let span = pendingAddition { pendingAddition = TextSpan(span.start, offset + kept.utf16.count) }
                } else {
                    flush()
                }
                offset += kept.utf16.count
                oldIndex += 1
                newIndex += 1
            }
        }
        flush()
        // Additions are words: the space around them is not worth pointing at.
        changes.added = changes.added.compactMap { span in
            guard let text = after.slice(TextSpan(span.start - lineStart, span.end - lineStart)) else { return span }
            let leading = text.prefix(while: \.isWhitespace).utf16.count
            let trailing = text.reversed().prefix(while: \.isWhitespace).reduce(0) { $0 + $1.utf16.count }
            return leading + trailing >= span.length ? nil : TextSpan(span.start + leading, span.end - trailing)
        }
        return changes
    }
}
