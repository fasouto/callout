import Foundation
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
