import AnnotatorCore
import CryptoKit
import Foundation
import GRDB

/// A finished review as the history lists it.
public struct ReviewSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var origin: ReviewOrigin
    public var decision: ReviewDecision
    public var projectPath: String?
    public var markCount: Int
}

/// A finished review with everything that was said in it.
public struct ReviewDetail: Equatable, Sendable {
    public var summary: ReviewSummary
    public var contentText: String?
    public var filePath: String?
    public var feedback: String?
    public var editedText: String?
    public var generalComment: String
    public var marks: [Mark]
}

extension Store {
    /// Saves a finished review: what was reviewed, every mark, and what went back.
    /// - Parameter snippets: for marks whose comment came from a snippet, which one.
    public func saveReview(
        _ request: ReviewRequest, result: ReviewResult, marks: [Mark], generalComment: String,
        snippets: [UUID: Int64] = [:], at date: Date = Date()
    ) throws {
        var contentKind = "text"
        var contentText: String?
        var filePath = request.metadata.filePath
        var fileHash: String?
        switch request.content {
        case .text(let text, _):
            contentText = text
        case .file(let path):
            contentKind = "pdf"
            filePath = path
            fileHash = Self.hash(ofFileAt: path)
        }
        let title = request.metadata.title ?? filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Text"

        try write { db in
            try db.execute(sql: "DELETE FROM review WHERE id = ?", arguments: [request.id.uuidString])
            try db.execute(
                sql: """
                INSERT INTO review (id, createdAt, origin, sourceApp, projectPath, sessionId, title, contentKind,
                                    contentText, filePath, fileHash, decision, feedback, editedText, generalComment)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    request.id.uuidString, date, request.origin.rawValue, request.metadata.sourceApp,
                    request.metadata.projectPath, request.metadata.sessionId, title, contentKind,
                    contentText, filePath, fileHash, result.decision.rawValue, result.feedback, result.editedText,
                    generalComment,
                ]
            )
            for (ordinal, mark) in marks.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO mark (id, reviewId, ordinal, kind, page, start, end, quote, prefix, suffix, text, note, snippetId)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        mark.id.uuidString, request.id.uuidString, ordinal, mark.kind.rawValue, mark.anchor.page,
                        mark.anchor.span.start, mark.anchor.span.end, mark.anchor.quote, mark.anchor.prefix,
                        mark.anchor.suffix, mark.text, mark.note, snippets[mark.id],
                    ]
                )
            }
        }
    }

    /// Finished reviews, newest first. A query searches titles, content, feedback and overall comments.
    public func history(matching query: String = "", limit: Int = 200) throws -> [ReviewSummary] {
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return try read { db in
            let counts = "(SELECT COUNT(*) FROM mark WHERE mark.reviewId = review.id) AS markCount"
            if terms.isEmpty {
                return try Row.fetchAll(
                    db, sql: "SELECT review.*, \(counts) FROM review ORDER BY createdAt DESC LIMIT ?", arguments: [limit]
                ).compactMap(Self.summary)
            }
            // Every word must be there; the last one may still be being typed.
            let pattern = terms.enumerated().map { index, term in
                "\"\(term)\"" + (index == terms.count - 1 ? "*" : "")
            }.joined(separator: " ")
            return try Row.fetchAll(
                db,
                sql: """
                SELECT review.*, \(counts) FROM review
                JOIN review_search ON review_search.rowid = review.rowid
                WHERE review_search MATCH ? ORDER BY createdAt DESC LIMIT ?
                """,
                arguments: [pattern, limit]
            ).compactMap(Self.summary)
        }
    }

    public func review(_ id: UUID) throws -> ReviewDetail? {
        try read { db in
            let counts = "(SELECT COUNT(*) FROM mark WHERE mark.reviewId = review.id) AS markCount"
            guard let row = try Row.fetchOne(db, sql: "SELECT review.*, \(counts) FROM review WHERE id = ?", arguments: [id.uuidString]),
                  let summary = Self.summary(row) else { return nil }
            let marks = try Row.fetchAll(db, sql: "SELECT * FROM mark WHERE reviewId = ? ORDER BY ordinal", arguments: [id.uuidString])
                .compactMap(Self.mark)
            return ReviewDetail(
                summary: summary, contentText: row["contentText"], filePath: row["filePath"], feedback: row["feedback"],
                editedText: row["editedText"], generalComment: row["generalComment"], marks: marks
            )
        }
    }

    /// What a finished review was answered with: the review with this id, else
    /// the latest of this session, else the latest of all.
    public func result(id: UUID? = nil, sessionId: String? = nil) throws -> ReviewResult? {
        try read { db in
            let columns = "SELECT id, decision, feedback, editedText FROM review"
            let row: Row?
            if let id {
                row = try Row.fetchOne(db, sql: "\(columns) WHERE id = ?", arguments: [id.uuidString])
            } else if let sessionId {
                row = try Row.fetchOne(db, sql: "\(columns) WHERE sessionId = ? ORDER BY createdAt DESC LIMIT 1", arguments: [sessionId])
            } else {
                row = try Row.fetchOne(db, sql: "\(columns) ORDER BY createdAt DESC LIMIT 1")
            }
            guard let row, let id = UUID(uuidString: row["id"]), let decision = ReviewDecision(rawValue: row["decision"]) else { return nil }
            return ReviewResult(id: id, decision: decision, feedback: row["feedback"], editedText: row["editedText"])
        }
    }

    public func deleteReview(_ id: UUID) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM review WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// How often each note was written on a kind of mark: the raw material for
    /// noticing a correction that keeps coming back.
    public func repeatedNotes(minimum: Int = 2) throws -> [(kind: MarkKind, note: String, count: Int)] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT kind, note, COUNT(*) AS uses FROM mark
                WHERE note IS NOT NULL AND note <> ''
                GROUP BY kind, note HAVING uses >= ? ORDER BY uses DESC, note
                """,
                arguments: [minimum]
            ).compactMap { row in
                guard let kind = MarkKind(rawValue: row["kind"]) else { return nil }
                return (kind, row["note"], row["uses"])
            }
        }
    }

    private static func summary(_ row: Row) -> ReviewSummary? {
        guard let id = UUID(uuidString: row["id"]), let origin = ReviewOrigin(rawValue: row["origin"]),
              let decision = ReviewDecision(rawValue: row["decision"]) else { return nil }
        return ReviewSummary(
            id: id, createdAt: row["createdAt"], title: row["title"], origin: origin, decision: decision,
            projectPath: row["projectPath"], markCount: row["markCount"]
        )
    }

    private static func mark(_ row: Row) -> Mark? {
        guard let id = UUID(uuidString: row["id"]), let kind = MarkKind(rawValue: row["kind"]) else { return nil }
        let anchor = Anchor(
            page: row["page"], span: TextSpan(row["start"], row["end"]),
            quote: row["quote"], prefix: row["prefix"], suffix: row["suffix"]
        )
        return Mark(id: id, kind: kind, anchor: anchor, text: row["text"], note: row["note"])
    }

    private static func hash(ofFileAt path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
