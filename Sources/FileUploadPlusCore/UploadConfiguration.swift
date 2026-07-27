//  UploadConfiguration.swift
//  FileUploadPlusCore

import Foundation

public struct UploadConfiguration {
    public var chunkSize: UInt64 = 2 * 1024 * 1024
    public var maxConcurrentUploads: Int = 3
    public var maxRetryAttempts: Int = 5
    public var retryBaseDelay: TimeInterval = 1.0
    public var retryMaxDelay: TimeInterval = 60.0
    public var requestTimeout: TimeInterval = 60.0
    public var backgroundSessionIdentifier: String = "com.upload.background"
    public var enableBackgroundUpload: Bool = true
    public var allowsCellularAccess: Bool = true
    public var autoResumeOnNetworkReachability: Bool = true
    public var stateStoreDirectory: URL?

    // Pluggable components (set these before creating manager)
    public var urlBuilder: URLBuilder?
    public var requestSigner: RequestSigner?
    public var logService: LogService?
    public var validators: [FileValidator] = []
    public var pipeline: (any PipelineStageExecutor)?
    public var trafficController: TrafficControlProtocol?
    public var metricsCollector: MetricsCollectorProtocol?
    public var circuitBreaker: CircuitBreakerProtocol?

    // Dynamic chunk sizing
    public var adaptiveChunkSizing: Bool = false
    public var minChunkSize: UInt64 = 256 * 1024
    public var maxChunkSize: UInt64 = 10 * 1024 * 1024

    // Persistence batching: persist state every N chunks instead of every chunk.
    // Reduces SQLite write amplification. 0 = persist every chunk (legacy behavior).
    public var maxUnsavedChunks: Int = 20

    // Server negotiation
    public var negotiateUploadId: Bool = true

    // Called with (taskId, chunkIndex, offset, rawData) before each chunk is sent.
    // Useful for saving uploaded data in a mock server for integrity verification.
    public var onChunkSent: ((String, Int, UInt64, Data) -> Void)?

    public init() {}
}

// Lightweight protocol declarations (full definitions in respective modules)
// These allow Core to reference these concepts without circular deps.

public protocol URLBuilder: AnyObject {
    func buildInitURL(taskId: String, metadata: [String: String]) -> URL
    func buildChunkURL(taskId: String, uploadId: String, chunkIndex: Int) -> URL
    func buildCompleteURL(taskId: String, uploadId: String) -> URL
    func buildAbortURL(taskId: String, uploadId: String) -> URL
}

public protocol RequestSigner: AnyObject {
    var name: String { get }
    func sign(request: URLRequest, body: Data?) throws -> URLRequest
}

public protocol FileValidator: AnyObject {
    var name: String { get }
    func validate(fileURL: URL, metadata: [String: String]) -> ValidationResult
}

public protocol LogService: AnyObject {
    var minimumLevel: LogLevel { get set }
    func log(_ entry: LogEntry)
}

public protocol Encryption: AnyObject {
    func encrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data
    func decrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data
}

public protocol Authentication: AnyObject {
    func authenticate(request: URLRequest) -> URLRequest
    func refreshCredentials(completion: @escaping (Bool) -> Void)
    var isExpired: Bool { get }
}

public protocol IntegrityChecker: AnyObject {
    func checksum(data: Data) -> String
    func verifyFile(at url: URL, expectedChecksum: String) -> Bool
}

/// Unidirectional pipeline interface to avoid circular dependency.
public protocol PipelineStageExecutor: AnyObject {
    func executePreUpload(context: UploadContext) async throws -> Bool
    func processChunk(_ chunk: ChunkContext) async throws -> ChunkContext
    func executePostUpload(context: UploadContext, error: Error?) async
}

/// Unidirectional traffic control interface.
public protocol TrafficControlProtocol: AnyObject {
    func acquireSlot()
    func releaseSlot(bytes: UInt64)
    func throttleDelay(for bytes: UInt64) -> TimeInterval
    func onChunkSuccess()
    func onChunkFailure()
    var maxConcurrentChunks: Int { get set }
    var currentBandwidth: Double { get }
}

/// Unidirectional metrics collector interface.
public protocol MetricsCollectorProtocol: AnyObject {
    func recordStart(taskId: String, fileSize: UInt64)
    func recordProgress(taskId: String, uploadedBytes: UInt64)
    func recordCompletion(taskId: String)
    func recordFailure(taskId: String, error: Error)
    func getStats(taskId: String) -> Any?
    func getAllStats() -> [Any]
    func cleanup(taskId: String)
    var currentBandwidth: Double { get }
}

/// Unidirectional circuit breaker interface.
public protocol CircuitBreakerProtocol: AnyObject {
    func allowRequest() -> Bool
    func recordSuccess()
    func recordFailure()
    func reset()
}

// MARK: - Validation Result

public struct ValidationResult {
    public let isValid: Bool
    public let errors: [String]
    public init(isValid: Bool, errors: [String] = []) {
        self.isValid = isValid
        self.errors = errors
    }
    public static let valid = ValidationResult(isValid: true)
    public static func invalid(_ reason: String) -> ValidationResult {
        ValidationResult(isValid: false, errors: [reason])
    }
}

// MARK: - Log Types

public enum LogLevel: Int, Comparable, Codable {
    case debug = 0, info, warn, error, fatal
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEntry {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]
    public let file: String
    public let line: Int
    public let taskId: String?

    public var formatted: String {
        let meta = metadata.isEmpty ? "" : " " + metadata.map { "\($0)=\($1)" }.joined(separator: " ")
        let tid = taskId.map { "[\($0.prefix(8))] " } ?? ""
        return "[\(level.name)] \(tid)\(category): \(message)\(meta)"
    }

    public init(level: LogLevel, category: String, message: String,
                metadata: [String: String] = [:], file: String = #file,
                line: Int = #line, taskId: String? = nil) {
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.file = file
        self.line = line
        self.taskId = taskId
    }
}

public extension LogLevel {
    var name: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
}

// Default log extension
public extension LogService {
    func debug(_ message: String, category: String = "Upload", metadata: [String: String] = [:],
               file: String = #file, line: Int = #line, taskId: String? = nil) {
        guard minimumLevel <= .debug else { return }
        log(LogEntry(level: .debug, category: category, message: message,
                      metadata: metadata, file: file, line: line, taskId: taskId))
    }
    func info(_ message: String, category: String = "Upload", metadata: [String: String] = [:],
              file: String = #file, line: Int = #line, taskId: String? = nil) {
        guard minimumLevel <= .info else { return }
        log(LogEntry(level: .info, category: category, message: message,
                      metadata: metadata, file: file, line: line, taskId: taskId))
    }
    func warn(_ message: String, category: String = "Upload", metadata: [String: String] = [:],
              file: String = #file, line: Int = #line, taskId: String? = nil) {
        guard minimumLevel <= .warn else { return }
        log(LogEntry(level: .warn, category: category, message: message,
                      metadata: metadata, file: file, line: line, taskId: taskId))
    }
    func error(_ message: String, category: String = "Upload", metadata: [String: String] = [:],
               file: String = #file, line: Int = #line, taskId: String? = nil) {
        guard minimumLevel <= .error else { return }
        log(LogEntry(level: .error, category: category, message: message,
                      metadata: metadata, file: file, line: line, taskId: taskId))
    }
}
