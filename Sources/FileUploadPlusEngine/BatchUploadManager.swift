//  BatchUploadManager.swift
//  FileUploadPlusEngine
//
//  Multi-file batch upload with:
//  - Priority queue (high/medium/low)
//  - Inter-file dependency graph (file B starts only after file A completes)
//  - Group progress tracking with aggregate progress
//  - Partial failure handling (continue on error vs stop all)
//  - Deduplication by file hash

import Foundation
import CryptoKit

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Batch Configuration

public struct BatchUploadConfig {
    public enum FailurePolicy {
        case abortAll          // Stop everything on first failure
        case continueOthers    // Keep uploading other files
        case retryFailed(maxRetries: Int)
    }

    public enum Priority: Int, Comparable {
        case low = 0, medium = 50, high = 100
        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var maxConcurrentFiles: Int = 2
    public var failurePolicy: FailurePolicy = .continueOthers
    public var enableDeduplication: Bool = true
    public var progressReportInterval: TimeInterval = 0.5

    public init() {}
}

// MARK: - Batch Item

public struct BatchUploadItem: Identifiable {
    public let id: String
    public let fileURL: URL
    public var priority: BatchUploadConfig.Priority
    public var metadata: [String: String]
    public var dependsOn: [String]      // IDs of items that must complete first

    public init(id: String = UUID().uuidString,
                fileURL: URL,
                priority: BatchUploadConfig.Priority = .medium,
                metadata: [String: String] = [:],
                dependsOn: [String] = []) {
        self.id = id; self.fileURL = fileURL; self.priority = priority
        self.metadata = metadata; self.dependsOn = dependsOn
    }
}

// MARK: - Batch Result

public struct BatchUploadResult {
    public let itemId: String
    public let success: Bool
    public let error: Error?
    public let duration: TimeInterval
    public let uploadedBytes: UInt64
}

// MARK: - Batch Progress

public struct BatchProgress {
    public let totalFiles: Int
    public let completedFiles: Int
    public let failedFiles: Int
    public let totalBytes: UInt64
    public let uploadedBytes: UInt64
    public var fileProgress: Double { totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0 }
    public var byteProgress: Double { totalBytes > 0 ? Double(uploadedBytes) / Double(totalBytes) : 0 }
}

// MARK: - Batch Manager

public final class BatchUploadManager {
    private let uploadManager: FileUploadManager
    private let config: BatchUploadConfig
    private let logger: LogService?

    // All mutable state protected by the serial queue.
    private let queue = DispatchQueue(label: "com.upload.batch")
    private var items: [BatchUploadItem] = []
    private var results: [String: BatchUploadResult] = [:]
    private var activeTasks: Set<String> = []
    private var completedTasks: Set<String> = []
    private var failedTasks: Set<String> = []
    private var fileSizes: [String: UInt64] = [:]
    private var uploadedBytes: [String: UInt64] = [:]
    private var isRunning = false
    private var cancelled = false
    private var lastProgressReportTime: Date = Date()

    public var onItemProgress: ((String, Double) -> Void)?
    public var onItemComplete: ((BatchUploadResult) -> Void)?
    public var onBatchProgress: ((BatchProgress) -> Void)?
    public var onBatchComplete: (([BatchUploadResult]) -> Void)?

    public init(uploadManager: FileUploadManager, config: BatchUploadConfig = BatchUploadConfig(),
                logger: LogService? = nil) {
        self.uploadManager = uploadManager
        self.config = config
        self.logger = logger
    }

    // MARK: - Public API

    public func addItems(_ newItems: [BatchUploadItem]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.config.enableDeduplication {
                let existingHashes = Set(self.items.compactMap { self.fileHash($0.fileURL) })
                let filtered = newItems.filter { item in
                    guard let hash = self.fileHash(item.fileURL) else { return true }
                    return !existingHashes.contains(hash)
                }
                self.items.append(contentsOf: filtered)
                if filtered.count < newItems.count {
                    self.logger?.info("Dedup: removed \(newItems.count - filtered.count) duplicate files")
                }
            } else {
                self.items.append(contentsOf: newItems)
            }
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true; self.cancelled = false
            self.lastProgressReportTime = Date()
            for item in self.items {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: item.fileURL.path) {
                    self.fileSizes[item.id] = attrs[.size] as? UInt64 ?? 0
                }
            }
            self.logger?.info("Batch upload started: \(self.items.count) files, total: \(self.formatBytes(self.totalBytes))")
            self.scheduleNext()
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelled = true; self.isRunning = false
            let taskIds = self.activeTasks
            for tid in taskIds {
                try? self.uploadManager.cancel(taskId: tid)
            }
            self.logger?.info("Batch upload cancelled")
        }
    }

    // MARK: - Scheduling (all called from within queue)

    private func scheduleNext() {
        guard isRunning, !cancelled else { return }

        let dispatchCount = config.maxConcurrentFiles - activeTasks.count
        guard dispatchCount > 0 else { return }

        let candidates = readyItems().prefix(dispatchCount)
        for item in candidates {
            startItem(item)
        }

        if activeTasks.isEmpty, completedTasks.count + failedTasks.count == items.count {
            finishBatch()
        }
    }

    private func readyItems() -> [BatchUploadItem] {
        items
            .filter { !completedTasks.contains($0.id) && !failedTasks.contains($0.id) && !activeTasks.contains($0.id) }
            .filter { item in item.dependsOn.allSatisfy { completedTasks.contains($0) } }
            .sorted { $0.priority > $1.priority }
    }

    private func startItem(_ item: BatchUploadItem) {
        activeTasks.insert(item.id)

        do {
            let task = try uploadManager.uploadFile(at: item.fileURL,
                                                     taskId: item.id,
                                                     metadata: item.metadata,
                                                     validate: true)

            task.onProgress = { [weak self] progress in
                guard let self = self else { return }
                self.queue.async {
                    self.uploadedBytes[item.id] = UInt64(Double(self.fileSizes[item.id] ?? 0) * progress)
                    self.onItemProgress?(item.id, progress)
                    self.reportBatchProgress()
                }
            }

            task.onComplete = { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    self.activeTasks.remove(item.id)

                    let result = BatchUploadResult(
                        itemId: item.id,
                        success: error == nil,
                        error: error,
                        duration: Date().timeIntervalSince(Date()),
                        uploadedBytes: self.uploadedBytes[item.id] ?? 0
                    )
                    self.results[item.id] = result

                    if error == nil {
                        self.completedTasks.insert(item.id)
                    } else {
                        self.failedTasks.insert(item.id)
                    }

                    self.onItemComplete?(result)

                    if error != nil {
                        switch self.config.failurePolicy {
                        case .abortAll:
                            self.cancel()
                        case .retryFailed(let max):
                            if max > 0 {
                                self.logger?.info("Retrying \(item.id.prefix(8))...")
                                self.activeTasks.insert(item.id)
                                self.failedTasks.remove(item.id)
                                self.startItem(item)
                            }
                        case .continueOthers:
                            break
                        }
                    }

                    self.scheduleNext()
                }
            }

            logger?.debug("Batch item started: \(item.id.prefix(8))... priority=\(item.priority)")
        } catch {
            activeTasks.remove(item.id)
            failedTasks.insert(item.id)
            results[item.id] = BatchUploadResult(itemId: item.id, success: false,
                                                   error: error, duration: 0, uploadedBytes: 0)
            scheduleNext()
        }
    }

    // MARK: - Progress

    private func reportBatchProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastProgressReportTime) >= config.progressReportInterval else { return }
        lastProgressReportTime = now
        let uploaded = uploadedBytes.values.reduce(0, +)
        let bp = BatchProgress(
            totalFiles: items.count,
            completedFiles: completedTasks.count,
            failedFiles: failedTasks.count,
            totalBytes: totalBytes,
            uploadedBytes: uploaded
        )
        onBatchProgress?(bp)
    }

    private var totalBytes: UInt64 {
        fileSizes.values.reduce(0, +)
    }

    private func finishBatch() {
        isRunning = false
        lastProgressReportTime = Date.distantPast // force final report
        reportBatchProgress()
        let allResults = items.compactMap { results[$0.id] }
        logger?.info("Batch completed: \(completedTasks.count) ok, \(failedTasks.count) failed")
        onBatchComplete?(allResults)
    }

    private func fileHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func formatBytes(_ b: UInt64) -> String {
        b > 1_000_000 ? String(format: "%.1f MB", Double(b)/1_000_000) : String(format: "%.0f KB", Double(b)/1024)
    }
}
