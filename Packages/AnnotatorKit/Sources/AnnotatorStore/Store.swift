import AnnotatorCore
import Foundation
import GRDB

/// The app's database: plan versions per session, the history of reviews, and
/// reusable comments. One SQLite file in Application Support.
public final class Store: Sendable {
    private let database: DatabaseQueue

    /// Opens the database at `path`, creating it and its folder when missing.
    public init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: path)
        try Self.migrator.migrate(database)
    }

    /// A database that lives in memory, for tests.
    public init() throws {
        database = try DatabaseQueue()
        try Self.migrator.migrate(database)
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Annotator/annotator.sqlite"
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1: plan versions") { db in
            try db.create(table: "plan_version") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("sessionId", .text).notNull().indexed()
                table.column("version", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.uniqueKey(["sessionId", "version"])
            }
        }
        return migrator
    }

    func read<T>(_ work: (Database) throws -> T) throws -> T {
        try database.read(work)
    }

    func write<T>(_ work: (Database) throws -> T) throws -> T {
        try database.write(work)
    }
}

// MARK: - Plan versions

public struct PlanVersion: Equatable, Sendable {
    public var sessionId: String
    /// 1 for the first plan of a session, counting up with each revision.
    public var version: Int
    public var content: String
    public var createdAt: Date
}

extension Store {
    /// Records a plan that arrived for a session, and returns the version before
    /// it, if the session had one. A plan identical to the latest version is not
    /// recorded again: Claude Code re-asks for approval of an unchanged plan.
    @discardableResult
    public func recordPlan(_ content: String, sessionId: String, at date: Date = Date()) throws -> (previous: PlanVersion?, version: Int) {
        try write { db in
            let latest = try Self.latestPlan(db, sessionId: sessionId)
            if let latest, latest.content == content {
                let before = try Self.plan(db, sessionId: sessionId, version: latest.version - 1)
                return (before, latest.version)
            }
            let version = (latest?.version ?? 0) + 1
            try db.execute(
                sql: "INSERT INTO plan_version (sessionId, version, content, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [sessionId, version, content, date]
            )
            return (latest, version)
        }
    }

    public func planVersions(sessionId: String) throws -> [PlanVersion] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plan_version WHERE sessionId = ? ORDER BY version", arguments: [sessionId])
                .map(Self.planVersion)
        }
    }

    private static func latestPlan(_ db: Database, sessionId: String) throws -> PlanVersion? {
        try Row.fetchOne(db, sql: "SELECT * FROM plan_version WHERE sessionId = ? ORDER BY version DESC LIMIT 1", arguments: [sessionId])
            .map(planVersion)
    }

    private static func plan(_ db: Database, sessionId: String, version: Int) throws -> PlanVersion? {
        try Row.fetchOne(db, sql: "SELECT * FROM plan_version WHERE sessionId = ? AND version = ?", arguments: [sessionId, version])
            .map(planVersion)
    }

    private static func planVersion(_ row: Row) -> PlanVersion {
        PlanVersion(sessionId: row["sessionId"], version: row["version"], content: row["content"], createdAt: row["createdAt"])
    }
}
