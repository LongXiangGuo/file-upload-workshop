//  UploadStateStore.swift
//  FileUploadPlusCore

import Foundation
import SQLite3

/// SQLite-backed state persistence for resumable uploads.
public final class UploadStateStore: StateStoreProtocol {
    private let dbQueue: DispatchQueue
    private var db: OpaquePointer?

    public init(directory: URL? = nil) throws {
        self.dbQueue = DispatchQueue(label: "com.upload.statestore")
        let storeDir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UploadStates")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let dbPath = storeDir.appendingPathComponent("upload_state.db").path
        try openDatabase(path: dbPath)
        try createTable()
    }

    private func openDatabase(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw UploadError.internalError("Cannot open database")
        }
        self.db = db
        _ = executeRaw("PRAGMA journal_mode=WAL;")
    }

    private func createTable() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS upload_states (
                task_id TEXT PRIMARY KEY,
                state_data BLOB,
                updated_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_updated_at ON upload_states(updated_at);
        """)
    }

    private func execute(_ sql: String) throws {
        guard let db = db else { throw UploadError.internalError("DB not initialized") }
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw UploadError.internalError("SQL error: \(error)")
        }
    }

    private func executeRaw(_ sql: String) -> Int32 {
        guard let db = db else { return -1 }
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    public func save(state: UploadState) throws {
        try dbQueue.sync {
            let data = try JSONEncoder().encode(state)
            let sql = "INSERT OR REPLACE INTO upload_states (task_id, state_data, updated_at) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw UploadError.internalError("Prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (state.taskId as NSString).utf8String, -1, nil)
            sqlite3_bind_blob(stmt, 2, (data as NSData).bytes, Int32(data.count), nil)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw UploadError.internalError("Save failed")
            }
        }
    }

    public func load(taskId: String) throws -> UploadState? {
        try dbQueue.sync {
            let sql = "SELECT state_data FROM upload_states WHERE task_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw UploadError.internalError("Prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (taskId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let blob = sqlite3_column_blob(stmt, 0)
            let length = Int(sqlite3_column_bytes(stmt, 0))
            return try JSONDecoder().decode(UploadState.self, from: Data(bytes: blob!, count: length))
        }
    }

    public func delete(taskId: String) throws {
        try dbQueue.sync {
            let sql = "DELETE FROM upload_states WHERE task_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw UploadError.internalError("Prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (taskId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    public func loadAllTaskIds() throws -> [String] {
        try dbQueue.sync {
            let sql = "SELECT task_id FROM upload_states ORDER BY updated_at DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw UploadError.internalError("Prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0) { ids.append(String(cString: text)) }
            }
            return ids
        }
    }

    public var count: Int {
        dbQueue.sync {
            let sql = "SELECT COUNT(*) FROM upload_states;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }
}
