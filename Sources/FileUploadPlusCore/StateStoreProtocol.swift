//  StateStoreProtocol.swift
//  FileUploadPlusCore
//
//  Protocol abstraction for upload state persistence.
//  Default: SQLite (zero-dependency). Optional: GRDB, CoreData, SwiftData, custom.

import Foundation

// MARK: - State Store Protocol

public protocol StateStoreProtocol: AnyObject {
    /// Save an upload state record.
    func save(state: UploadState) throws

    /// Load an upload state by task ID, or nil if not found.
    func load(taskId: String) throws -> UploadState?

    /// Delete a state record.
    func delete(taskId: String) throws

    /// Get all task IDs ordered by last modified (most recent first).
    func loadAllTaskIds() throws -> [String]

    /// Batch save for performance.
    func saveBatch(states: [UploadState]) throws

    /// Delete all records (cleanup).
    func deleteAll() throws

    /// Number of persisted records.
    var count: Int { get }
}

// Default implementations for optional methods
public extension StateStoreProtocol {
    func saveBatch(states: [UploadState]) throws {
        for state in states { try save(state: state) }
    }

    func deleteAll() throws {
        let ids = try loadAllTaskIds()
        for id in ids { try delete(taskId: id) }
    }
}

// MARK: - State Store Factory

/// Creates the appropriate state store based on configuration.
public enum StateStoreFactory {
    /// Create the default SQLite store.
    public static func makeSQLite(directory: URL? = nil) throws -> StateStoreProtocol {
        try UploadStateStore(directory: directory)
    }

    /// Allows injection of custom store (e.g. GRDB, in-memory for testing).
    public static func makeCustom(_ store: StateStoreProtocol) -> StateStoreProtocol {
        store
    }
}

// MARK: - In-Memory Store (for testing / previews)

public final class InMemoryStateStore: StateStoreProtocol {
    private var storage: [String: UploadState] = [:]
    private let lock = NSLock()

    public init() {}

    public var count: Int { lock.withLock { storage.count } }

    public func save(state: UploadState) throws {
        lock.withLock { storage[state.taskId] = state }
    }

    public func load(taskId: String) throws -> UploadState? {
        return lock.withLock { storage[taskId] }
    }

    public func delete(taskId: String) throws {
        return lock.withLock { storage.removeValue(forKey: taskId) }
    }

    public func loadAllTaskIds() throws -> [String] {
        lock.withLock {
            storage.values
                .sorted { $0.lastModified > $1.lastModified }
                .map(\.taskId)
        }
    }

    public func deleteAll() throws {
        lock.withLock { storage.removeAll() }
    }
}
