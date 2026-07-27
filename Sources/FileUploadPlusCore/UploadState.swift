//  UploadState.swift
//  FileUploadPlusCore

import Foundation

// MARK: - Chunk Models

public enum ChunkStatus: String, Codable {
    case pending, uploading, completed, failed
}

public struct ChunkState: Codable {
    public let index: Int
    public let offset: UInt64
    public let size: UInt64
    public var md5: String?
    public var status: ChunkStatus = .pending
    public var retryCount: Int = 0

    public init(index: Int, offset: UInt64, size: UInt64) {
        self.index = index; self.offset = offset; self.size = size
    }
}

// MARK: - Upload State

public final class UploadState: Codable {
    public let taskId: String
    public let filePath: String
    public var fileSize: UInt64?
    public var totalChunks: Int
    public var chunks: [ChunkState]
    public var uploadId: String?
    public var status: UploadStatus
    public var metadata: [String: String]
    public var uploadedBytes: UInt64 = 0
    public var createdAt: Date
    public var lastModified: Date

    public enum UploadStatus: String, Codable {
        case pending, uploading, paused, completed, failed
    }

    public init(taskId: String, filePath: String, totalChunks: Int,
                chunks: [ChunkState], metadata: [String: String] = [:]) {
        self.taskId = taskId
        self.filePath = filePath
        self.totalChunks = totalChunks
        self.chunks = chunks
        self.metadata = metadata
        self.status = .pending
        self.createdAt = Date()
        self.lastModified = Date()
    }

    public var resumeOffset: UInt64 {
        chunks.filter { $0.status == .completed }.reduce(0) { max($0, $1.offset + $1.size) }
    }
}

// MARK: - Upload Context (for pipeline)

public class UploadContext {
    public let taskId: String
    public let fileURL: URL
    public var metadata: [String: String]
    public var fileSize: UInt64?
    public var mimeType: String?
    public var uploadId: String?
    public var userInfo: [String: Any] = [:]

    public init(taskId: String, fileURL: URL, metadata: [String: String] = [:]) {
        self.taskId = taskId; self.fileURL = fileURL; self.metadata = metadata
    }
}

public struct ChunkContext {
    public let taskId: String
    public let chunkIndex: Int
    public let offset: UInt64
    public var data: Data
    public var md5: String?
    public let uploadId: String?
    public var metadata: [String: String]
    public var skipUpload: Bool = false

    public init(taskId: String, chunkIndex: Int, offset: UInt64, data: Data,
                md5: String?, uploadId: String?, metadata: [String: String]) {
        self.taskId = taskId; self.chunkIndex = chunkIndex; self.offset = offset
        self.data = data; self.md5 = md5; self.uploadId = uploadId
        self.metadata = metadata
    }
}

// MARK: - Progress Delegate

public protocol UploadProgressDelegate: AnyObject {
    func uploadTask(_ taskId: String, didUpdateProgress progress: Double)
    func uploadTask(_ taskId: String, didCompleteWithError error: Error?)
    func uploadTask(_ taskId: String, didFinishChunk index: Int, total: Int)
}
