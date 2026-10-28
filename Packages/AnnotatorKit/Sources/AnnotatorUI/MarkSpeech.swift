import AnnotatorCore
import AppKit

extension Mark {
    /// What VoiceOver says about the mark: what was done, to which words.
    var spokenDescription: String {
        let quote = Self.spoken(anchor.quote)
        let text = text?.nilIfBlank.map(Self.spoken)
        let note = note.map(Self.spoken)
        let page = anchor.page.map { ", page \($0)" } ?? ""
        let place = anchor.pointPlace.map { " \(Self.spoken($0))" } ?? ""
        let said: String
        switch kind {
        case .delete:
            said = "Struck out: \(quote)"
        case .replace:
            said = text.map { "Replaced: \(quote), with: \($0)" } ?? "Replacing: \(quote)"
        case .insert:
            said = text.map { "Added\(place): \($0)" } ?? "Adding text\(place)"
        case .comment where anchor.isPoint:
            said = note.map { "Comment\(place): \($0)" } ?? "Comment\(place)"
        case .comment:
            said = note.map { "Comment on \(quote): \($0)" } ?? "Comment on: \(quote)"
        case .expand:
            said = "Asked for more on: \(quote)" + (note.map { ". \($0)" } ?? "")
        case .summarize:
            said = "Asked to shorten: \(quote)" + (note.map { ". \($0)" } ?? "")
        case .keep:
            said = "Keep as is: \(quote)"
        }
        return said + page
    }

    /// Text as it is read aloud: on one line, and not too long to listen to.
    private static func spoken(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }
}

extension Anchor {
    /// Where a point is, in a few words of its own line: after the ones before
    /// it, or at the start of a line, before the ones after it.
    var pointPlace: String? {
        let lineBefore = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let before = lineBefore.split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " ")
        if !before.isEmpty { return "after \(before)" }
        let lineAfter = suffix.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let after = lineAfter.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
        return after.isEmpty ? nil : "before \(after)"
    }
}

/// Speaks to VoiceOver users about something that happened without moving
/// their cursor, such as a mark being made.
@MainActor
enum Announcer {
    static func post(_ message: String) {
        // Nothing to speak to before the app is up. With no window open, the app itself speaks.
        guard let app = NSApp else { return }
        let element: Any = app.keyWindow ?? app.mainWindow ?? app
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
