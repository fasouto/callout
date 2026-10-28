import AnnotatorCore
import Foundation
import GRDB
import Testing
@testable import AnnotatorStore

@Suite("Plan versions")
struct PlanVersionTests {
    @Test func theFirstPlanOfASessionHasNoPrevious() throws {
        let store = try Store()
        let recorded = try store.recordPlan("# Plan A", sessionId: "s-1")
        #expect(recorded.previous == nil)
        #expect(recorded.version == 1)
    }

    @Test func aRevisedPlanGetsTheVersionBeforeIt() throws {
        let store = try Store()
        try store.recordPlan("# Plan A", sessionId: "s-1")
        let second = try store.recordPlan("# Plan B", sessionId: "s-1")
        #expect(second.previous?.content == "# Plan A")
        #expect(second.version == 2)

        let third = try store.recordPlan("# Plan C", sessionId: "s-1")
        #expect(third.previous?.content == "# Plan B")
        #expect(third.version == 3)
        #expect(try store.planVersions(sessionId: "s-1").map(\.content) == ["# Plan A", "# Plan B", "# Plan C"])
    }

    @Test func sessionsDoNotSeeEachOther() throws {
        let store = try Store()
        try store.recordPlan("# Plan A", sessionId: "s-1")
        let other = try store.recordPlan("# Plan X", sessionId: "s-2")
        #expect(other.previous == nil)
        #expect(other.version == 1)
    }

    @Test func theSamePlanAgainIsNotANewVersion() throws {
        let store = try Store()
        try store.recordPlan("# Plan A", sessionId: "s-1")
        try store.recordPlan("# Plan B", sessionId: "s-1")
        // Claude Code asks again for a plan that did not change, after the terminal dialog was dismissed.
        let again = try store.recordPlan("# Plan B", sessionId: "s-1")
        #expect(again.version == 2)
        #expect(again.previous?.content == "# Plan A")
        #expect(try store.planVersions(sessionId: "s-1").count == 2)
    }

    @Test func versionsSurviveReopeningTheFile() throws {
        let path = NSTemporaryDirectory() + "annotator-store-\(UUID().uuidString.prefix(8))/annotator.sqlite"
        do {
            let store = try Store(path: path)
            try store.recordPlan("# Plan A", sessionId: "s-1")
        }
        let reopened = try Store(path: path)
        #expect(try reopened.recordPlan("# Plan B", sessionId: "s-1").previous?.content == "# Plan A")
    }
}

@Suite("Snippets")
struct SnippetTests {
    @Test func aNewDatabaseStartsWithSnippetsInEveryContext() throws {
        let snippets = try Store().snippets()
        #expect(Set(snippets.map(\.context)) == Set(SnippetContext.allCases))
        #expect(snippets.first?.text == "Too complex, simplify.")
        #expect(snippets.first?.context == .plans)
        // Grouped by context, in the contexts' own order.
        #expect(snippets.map(\.context).reduce(into: [SnippetContext]()) { if $0.last != $1 { $0.append($1) } } == SnippetContext.allCases)
    }

    private func sayMoreCount(_ store: Store) throws -> Int {
        try store.snippets().filter { $0.text == "Say more about this." }.count
    }

    private func storeAtV2(_ path: String) throws -> DatabaseQueue {
        let database = try DatabaseQueue(path: path)
        try Store.migrator.migrate(database, upTo: "v2: history and snippets")
        return database
    }

    private func temporaryPath() -> String {
        NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
    }

    @Test func aNewDatabaseHasSayMoreOnceAtTheEndOfPlans() throws {
        let store = try Store()
        let plans = try store.snippets().filter { $0.context == .plans }
        #expect(plans.last?.text == "Say more about this.")
        #expect(try sayMoreCount(store) == 1)
    }

    @Test func aDatabaseFromBeforeGetsSayMoreOnceAtTheEndOfPlans() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try storeAtV2(path)
        let before = try old.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM snippet WHERE text = 'Say more about this.'") }
        #expect(before == 0)
        try old.write { try $0.execute(sql: "INSERT INTO snippet (context, text, position) VALUES ('plans', 'Mine.', 4)") }
        try old.close()

        let store = try Store(path: path)
        let plans = try store.snippets().filter { $0.context == .plans }.map(\.text)
        #expect(plans.last == "Say more about this.")
        #expect(plans.suffix(2) == ["Mine.", "Say more about this."])
        #expect(try sayMoreCount(store) == 1)

        let again = try Store(path: path)
        #expect(try sayMoreCount(again) == 1)
        #expect(try again.snippets().count == store.snippets().count)
    }

    @Test func aDatabaseThatHasTheTextAlreadyGetsNoDuplicate() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try storeAtV2(path)
        try old.write { try $0.execute(sql: "INSERT INTO snippet (context, text, position) VALUES ('documents', 'Say more about this.', 9)") }
        try old.close()

        let store = try Store(path: path)
        #expect(try sayMoreCount(store) == 1)
        #expect(try store.snippets().first { $0.text == "Say more about this." }?.context == .documents)
    }

    @Test func snippetsCanBeAddedChangedAndRemoved() throws {
        let store = try Store()
        let added = try store.addSnippet("Name the trade-off.", context: .plans)
        #expect(try store.snippets().last { $0.context == .plans } == added)

        try store.updateSnippet(added.id, text: "Name the trade-off you chose.")
        #expect(try store.snippets().first { $0.id == added.id }?.text == "Name the trade-off you chose.")

        try store.deleteSnippet(added.id)
        #expect(try store.snippets().contains { $0.id == added.id } == false)
    }
}

@Suite("History")
struct HistoryTests {
    private func mark(_ kind: MarkKind, _ quote: String, in text: String, note: String? = nil, replacement: String? = nil) -> Mark {
        let range = (text as NSString).range(of: quote)
        let anchor = Anchor.make(in: text, span: TextSpan(range.location, NSMaxRange(range)))!
        return Mark(kind: kind, anchor: anchor, text: replacement, note: note)
    }

    private func save(
        _ store: Store, title: String, text: String, marks: [Mark], general: String = "",
        origin: ReviewOrigin = .planHook, at date: Date = Date(), snippets: [UUID: Int64] = [:]
    ) throws -> ReviewRequest {
        let request = ReviewRequest(
            content: .text(text, format: .markdown), origin: origin,
            metadata: ReviewMetadata(projectPath: "/work/app", sessionId: "s-1", title: title),
            reply: .hookDecision, modes: [.feedback, .approve]
        )
        let feedback = FeedbackFormatter.format(.init(title: title, document: .text(text), marks: marks, generalComment: general))
        try store.saveReview(
            request, result: ReviewResult(id: request.id, decision: .feedback, feedback: feedback),
            marks: marks, generalComment: general, snippets: snippets, at: date
        )
        return request
    }

    @Test func aReviewIsKeptWithItsMarksAndItsFeedback() throws {
        let store = try Store()
        let text = "We will leverage a very robust approach here."
        let marks = [
            mark(.replace, "leverage", in: text, replacement: "use"),
            mark(.delete, "very robust ", in: text, note: "filler"),
        ]
        let request = try save(store, title: "Plan: rate limiting", text: text, marks: marks, general: "Too complex, simplify.")

        let detail = try #require(try store.review(request.id))
        #expect(detail.summary.title == "Plan: rate limiting")
        #expect(detail.summary.origin == .planHook)
        #expect(detail.summary.decision == .feedback)
        #expect(detail.summary.markCount == 2)
        #expect(detail.summary.projectPath == "/work/app")
        #expect(detail.contentText == text)
        #expect(detail.generalComment == "Too complex, simplify.")
        #expect(detail.marks == marks)
        #expect(detail.feedback?.contains("### 1. Replace\n> leverage\nWith: use") == true)
    }

    @Test func aCommentOnNoWordsIsKeptWithItsEmptyQuote() throws {
        let store = try Store()
        let text = "We will leverage a very robust approach here."
        let point = NSMaxRange((text as NSString).range(of: "robust"))
        let comment = Mark(kind: .comment, anchor: Anchor.make(in: text, span: TextSpan(point, point))!, note: "Says who?")
        let request = try save(store, title: "Plan", text: text, marks: [comment])

        let detail = try #require(try store.review(request.id))
        #expect(detail.marks == [comment])
        #expect(detail.marks.first?.anchor.quote == "")
        #expect(detail.feedback?.contains("### 1. Comment after\n> We will leverage a very robust\nSays who?") == true)
    }

    @Test func historyIsNewestFirstAndSearchable() throws {
        let store = try Store()
        let now = Date()
        _ = try save(store, title: "Plan: rate limiting", text: "Add a token bucket per API key.", marks: [], general: "Fine.", at: now.addingTimeInterval(-300))
        _ = try save(store, title: "Cover letter", text: "Dear hiring manager, I am passionate.", marks: [], general: "Too generic.", origin: .agentRequest, at: now.addingTimeInterval(-200))
        _ = try save(store, title: "Plan: caching", text: "Put Redis in front of Postgres.", marks: [], general: "", at: now.addingTimeInterval(-100))

        #expect(try store.history().map(\.title) == ["Plan: caching", "Cover letter", "Plan: rate limiting"])
        #expect(try store.history(matching: "plan").map(\.title) == ["Plan: caching", "Plan: rate limiting"])
        // Content, feedback and the overall comment are searched too.
        #expect(try store.history(matching: "redis").map(\.title) == ["Plan: caching"])
        #expect(try store.history(matching: "generic").map(\.title) == ["Cover letter"])
        // Every word must match; the last one may be unfinished.
        #expect(try store.history(matching: "token buck").map(\.title) == ["Plan: rate limiting"])
        #expect(try store.history(matching: "token redis").isEmpty)
        // Punctuation in what is typed is not search syntax.
        #expect(try store.history(matching: "\"plan: (").count == 2)
        #expect(try store.history(matching: "nothing-like-this").isEmpty)
    }

    @Test func deletingAReviewTakesItsMarksAndItsSearchEntry() throws {
        let store = try Store()
        let text = "Use Redis here."
        let request = try save(store, title: "Plan", text: text, marks: [mark(.delete, "Redis", in: text)])
        try store.deleteReview(request.id)
        #expect(try store.review(request.id) == nil)
        #expect(try store.history(matching: "redis").isEmpty)
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mark") } == 0)
    }

    @Test func savingTheSameReviewTwiceKeepsOne() throws {
        let store = try Store()
        let request = try save(store, title: "Plan", text: "Text.", marks: [])
        try store.saveReview(request, result: ReviewResult(id: request.id, decision: .approve), marks: [], generalComment: "")
        #expect(try store.history().count == 1)
        #expect(try store.review(request.id)?.summary.decision == .approve)
    }

    @Test func aPDFIsKeptByPathAndHash() throws {
        let store = try Store()
        let path = NSTemporaryDirectory() + "annotator-history-\(UUID().uuidString.prefix(8)).pdf"
        try Data("%PDF-1.4 pretend".utf8).write(to: URL(fileURLWithPath: path))
        let request = ReviewRequest(content: .file(path: path), origin: .agentRequest, reply: .stdout, modes: [.feedback])
        try store.saveReview(request, result: ReviewResult(id: request.id, decision: .feedback, feedback: "## Feedback"), marks: [], generalComment: "")

        let detail = try #require(try store.review(request.id))
        #expect(detail.filePath == path)
        #expect(detail.contentText == nil)
        #expect(detail.summary.title == URL(fileURLWithPath: path).lastPathComponent)
        let hash = try store.read { try String.fetchOne($0, sql: "SELECT fileHash FROM review") }
        #expect(hash?.count == 64)
    }

    @Test func repeatedCorrectionsCanBeCounted() throws {
        let store = try Store()
        let text = "One very long sentence. Another very long sentence."
        for index in 0..<3 {
            _ = try save(store, title: "Plan \(index)", text: text, marks: [
                mark(.comment, "One very long sentence", in: text, note: "Too complex, simplify."),
                mark(.delete, "Another", in: text, note: index == 0 ? "filler" : nil),
            ], snippets: [:])
        }
        let repeated = try store.repeatedNotes()
        #expect(repeated.count == 1)
        #expect(repeated.first?.kind == .comment)
        #expect(repeated.first?.note == "Too complex, simplify.")
        #expect(repeated.first?.count == 3)
    }

    @Test func anExpandMarkFromBeforeStillLoadsAndFormats() throws {
        let store = try Store()
        let text = "We add a cache here."
        let request = try save(store, title: "Plan", text: text, marks: [mark(.expand, "We add a cache", in: text)])
        let detail = try #require(try store.review(request.id))
        #expect(detail.marks.map(\.kind) == [.expand])
        #expect(detail.feedback?.contains("### 1. Expand\n> We add a cache") == true)
    }

    @Test func aMarkRemembersTheSnippetItCameFrom() throws {
        let store = try Store()
        let snippet = try #require(try store.snippets().first)
        let text = "A long plan."
        let comment = mark(.comment, "long plan", in: text, note: snippet.text)
        _ = try save(store, title: "Plan", text: text, marks: [comment], snippets: [comment.id: snippet.id])
        let stored = try store.read { try Int64.fetchOne($0, sql: "SELECT snippetId FROM mark") }
        #expect(stored == snippet.id)
    }
}
