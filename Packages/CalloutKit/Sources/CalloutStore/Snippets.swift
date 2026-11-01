import Foundation
import GRDB

/// Where a reusable comment applies.
public enum SnippetContext: String, CaseIterable, Sendable, Identifiable {
    case plans
    case documents
    case gitlab
    case blog

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plans: "Plans"
        case .documents: "Documents"
        case .gitlab: "GitLab"
        case .blog: "Blog"
        }
    }
}

/// A comment to reuse, such as "Too complex, simplify."
public struct Snippet: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var context: SnippetContext
    public var text: String
    public var position: Int

    /// What Expand used to ask for, as a comment. A migration adds it to plans,
    /// in new databases too.
    static let sayMore = "Say more about this."

    /// What Claude's replies were most often told in the history, most first.
    /// A migration puts them first in plans, in new databases too.
    static let mostWritten = [
        "Do it.",
        "Why? Explain the reason.",
        "I don't understand this. Explain it simply.",
        "Are you sure? Check it.",
        "Give me options and your pick.",
    ]

    /// What the snippet table was first filled with; comments added since come
    /// with migrations of their own. All of it can be changed in Settings.
    static let starters: [(SnippetContext, [String])] = [
        (.plans, [
            "Too complex, simplify.",
            "Reuse existing code instead of writing new code.",
            "No tests for this.",
            "Out of scope: leave it out.",
        ]),
        (.documents, [
            "Too generic: say something specific.",
            "Shorter.",
            "Give a concrete example or a number.",
        ]),
        (.gitlab, [
            "Why? Explain the reason.",
            "Nitpick, not blocking.",
        ]),
        (.blog, [
            "Reads like marketing: say it plainly.",
            "Cut this.",
        ]),
    ]
}

extension Store {
    /// Every snippet, in the order of the contexts and then their own order.
    public func snippets() throws -> [Snippet] {
        try read { db in
            let all = try Row.fetchAll(db, sql: "SELECT * FROM snippet ORDER BY position, id").compactMap(Self.snippet)
            return SnippetContext.allCases.flatMap { context in all.filter { $0.context == context } }
        }
    }

    @discardableResult
    public func addSnippet(_ text: String, context: SnippetContext) throws -> Snippet {
        try write { db in
            let position = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM snippet WHERE context = ?", arguments: [context.rawValue]
            ) ?? 0
            try db.execute(
                sql: "INSERT INTO snippet (context, text, position) VALUES (?, ?, ?)",
                arguments: [context.rawValue, text, position]
            )
            return Snippet(id: db.lastInsertedRowID, context: context, text: text, position: position)
        }
    }

    public func updateSnippet(_ id: Int64, text: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE snippet SET text = ? WHERE id = ?", arguments: [text, id])
        }
    }

    public func deleteSnippet(_ id: Int64) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM snippet WHERE id = ?", arguments: [id])
        }
    }

    private static func snippet(_ row: Row) -> Snippet? {
        guard let context = SnippetContext(rawValue: row["context"]) else { return nil }
        return Snippet(id: row["id"], context: context, text: row["text"], position: row["position"])
    }
}
