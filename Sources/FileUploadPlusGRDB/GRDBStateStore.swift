//  GRDBStateStore.swift
//  FileUploadPlusGRDB
//
//  GRDB-based state store with type-safe queries, reactive observation,
//  and database migration support. Optional alternative to raw SQLite.
//
//  Usage:
//    //    let store = try GRDBStateStore(path: "/path/to/upload.db")
//
//  Requires: https://github.com/groue/GRDB.swift
//  Add to Package.swift deps:
//    .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
#if canImport(GRDB)
import GRDB

public final class GRDBStateStore: StateStoreProtocol {
    private let dbQueue: DatabaseQueue

    public var count: Int {
        (try? dbQueue.read { try UploadStateRecord.fetchCount($0) }) ?? 0
    }

    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create") { db in
            try db.create(table: "upload_states") { t in
                t.column("task_id", .text).primaryKey()
                t.column("state_data", .blob).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(index: "idx_upload_states_updated_at",
                          on: "upload_states", columns: ["updated_at"])
        }
        try migrator.migrate(dbQueue)
    }

    public func save(state: UploadState) throws {
        let record = try UploadStateRecord.from(state)
        try dbQueue.write { try record.save($0) }
    }

    public func load(taskId: String) throws -> UploadState? {
        try dbQueue.read { db in
            try UploadStateRecord
                .filter(Column("task_id") == taskId)
                .fetchOne(db)
                .map { try $0.toState() }
        }
    }

    public func delete(taskId: String) throws {
        try dbQueue.write { db in
            try UploadStateRecord
                .filter(Column("task_id") == taskId)
                .deleteAll(db)
        }
    }

    public func loadAllTaskIds() throws -> [String] {
        try dbQueue.read { db in
            try UploadStateRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map(\.taskId)
        }
    }

    public func saveBatch(states: [UploadState]) throws {
        let records = try states.map { try UploadStateRecord.from($0) }
        try dbQueue.write { db in
            for record in records { try record.save(db) }
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { try UploadStateRecord.deleteAll($0) }
    }

    // MARK: GRDB-specific: Reactive Observation

    /// Observe upload state changes reactively (Combine / AsyncSequence).
    public func observeState(taskId: String) -> ValueObservation<UploadStateRecord?> {
        ValueObservation.tracking { db in
            try UploadStateRecord
                .filter(Column("task_id") == taskId)
                .fetchOne(db)
        }
    }

    /// Observe all active task IDs reactively.
    public func observeAllTaskIds() -> ValueObservation<[String]> {
        ValueObservation.tracking { db in
            try UploadStateRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map(\.taskId)
        }
    }
}

// MARK: - GRDB Record Model

struct UploadStateRecord: Codable, FetchableRecord, PersistableRecord {
    var taskId: String
    var stateData: Data
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case stateData = "state_data"
        case updatedAt = "updated_at"
    }

    static let databaseTableName = "upload_states"

    static func from(_ state: UploadState) throws -> UploadStateRecord {
        let data = try JSONEncoder().encode(state)
        return UploadStateRecord(
            taskId: state.taskId,
            stateData: data,
            updatedAt: Int64(state.lastModified.timeIntervalSince1970)
        )
    }

    func toState() throws -> UploadState {
        try JSONDecoder().decode(UploadState.self, from: stateData)
    }
}

#endif
