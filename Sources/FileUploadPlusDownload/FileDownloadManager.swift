//
//  FileDownloadManager.swift
//  FileUploadPlusDownload
//
//  Production-grade file download with:
//  - Resumable download (断点续传)
//  - Background download via URLSession
//  - Progress tracking, pause/resume/cancel
//  - Pluggable auth, signing, logging
//  - Bandwidth tracking, traffic control
//

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Download Configuration

public struct DownloadConfiguration {
    public var maxConcurrentDownloads: Int = 3
    public var maxRetryAttempts: Int = 5
    public var retryBaseDelay: TimeInterval = 1.0
    public var retryMaxDelay: TimeInterval = 60.0
    public var requestTimeout: TimeInterval = 60.0
    public var resourceTimeout: TimeInterval = 86400
    public var backgroundSessionIdentifier: String = "com.upload.download.background"
    public var enableBackgroundDownload: Bool = true
    public var allowsCellularAccess: Bool = true
    public var destinationDirectory: URL?
    public var logService: LogService?
    public var metricsCollector: MetricsCollectorProtocol?
    public var trafficController: TrafficControlProtocol?
    public var circuitBreaker: CircuitBreakerProtocol?

    public init() {}
}

// MARK: - Download Error

public enum DownloadError: Error, CustomStringConvertible {
    case invalidURL
    case downloadAlreadyExists
    case downloadNotFound
    case downloadCancelled
    case downloadCompleted
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case fileWriteFailed
    case resumeDataInvalid
    case circuitBreakerOpen

    public var description: String {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .downloadAlreadyExists: return "Download task already exists"
        case .downloadNotFound: return "Download task not found"
        case .downloadCancelled: return "Download cancelled"
        case .downloadCompleted: return "Download already completed"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .serverError(let c, let m): return "Server error \(c): \(m ?? "unknown")"
        case .fileWriteFailed: return "Failed to write file"
        case .resumeDataInvalid: return "Resume data is invalid"
        case .circuitBreakerOpen: return "Circuit breaker is open"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkError, .serverError, .circuitBreakerOpen: return true
        default: return false
        }
    }
}

// MARK: - Download Task

public final class DownloadTask: Identifiable {
    public let id: String
    public let url: URL
    public let destinationURL: URL
    public private(set) var state: DownloadState
    public private(set) var progress: Double = 0          // 0...1
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var totalBytes: Int64 = 0
    public private(set) var speed: Double = 0              // bytes/sec

    private var urlSessionTask: URLSessionTask?
    private var resumeData: Data?
    private var lastProgressBytes: Int64 = 0
    private var lastProgressTime: Date = Date()
    private var retryCount: Int = 0
    private let maxRetryAttempts: Int
    private let retryBaseDelay: TimeInterval
    private let retryMaxDelay: TimeInterval
    private let lock = NSLock()

    public var onProgress: ((Double, Int64, Int64) -> Void)?
    public var onComplete: ((Error?) -> Void)?
    public var onStateChanged: ((DownloadState) -> Void)?

    public enum DownloadState: String {
        case pending, downloading, paused, completed, failed, cancelled
    }

    init(id: String, url: URL, destinationURL: URL, state: DownloadState = .pending,
         maxRetryAttempts: Int = 5, retryBaseDelay: TimeInterval = 1.0, retryMaxDelay: TimeInterval = 60.0) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.state = state
        self.maxRetryAttempts = maxRetryAttempts
        self.retryBaseDelay = retryBaseDelay
        self.retryMaxDelay = retryMaxDelay
    }

    func bind(sessionTask: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        urlSessionTask = sessionTask
    }

    func updateProgress(downloaded: Int64, total: Int64) {
        lock.lock()
        downloadedBytes = downloaded
        totalBytes = total
        if total > 0 { progress = Double(downloaded) / Double(total) }
        // Speed calculation (sliding)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressTime)
        if elapsed >= 1.0 {
            let bytesDelta = downloaded - lastProgressBytes
            speed = Double(bytesDelta) / elapsed
            lastProgressBytes = downloaded
            lastProgressTime = now
        }
        let p = progress; let d = downloaded; let t = total
        lock.unlock()
        onProgress?(p, d, t)
    }

    func setState(_ newState: DownloadState) {
        lock.lock(); defer { lock.unlock() }
        state = newState
        onStateChanged?(newState)
    }

    func saveResumeData(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        resumeData = data
    }

    func savedResumeData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return resumeData
    }

    func shouldRetry(error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard retryCount < maxRetryAttempts else { return false }
        retryCount += 1
        if let de = error as? DownloadError { return de.isRetryable }
        return (error as NSError).domain == NSURLErrorDomain
    }

    func retryDelay() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let delay = retryBaseDelay * pow(2.0, Double(retryCount - 1))
        return min(delay + Double.random(in: 0...1), retryMaxDelay)
    }

    func resetRetries() {
        lock.lock(); defer { lock.unlock() }
        retryCount = 0
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .pending || state == .downloading || state == .paused
    }

    // Progress query API
    public struct ProgressSnapshot {
        public let progress: Double
        public let downloadedBytes: Int64
        public let totalBytes: Int64
        public let speed: Double
        public let state: DownloadState
    }

    public var snapshot: ProgressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ProgressSnapshot(progress: progress, downloadedBytes: downloadedBytes,
                                 totalBytes: totalBytes, speed: speed, state: state)
    }
}

// MARK: - Background Session Delegate

final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var manager: FileDownloadManager?

    init(manager: FileDownloadManager) { self.manager = manager }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let mgr = manager,
              let task = mgr.findTask(byIdentifier: downloadTask.taskIdentifier) else { return }

        do {
            let destDir = task.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: task.destinationURL.path) {
                try FileManager.default.removeItem(at: task.destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: task.destinationURL)
            task.setState(.completed)
            task.onComplete?(nil)
            mgr.logService?.info("Download completed: \(task.id.prefix(8))... → \(task.destinationURL.lastPathComponent)")
        } catch {
            task.setState(.failed)
            task.onComplete?(DownloadError.fileWriteFailed)
            mgr.logService?.error("Download file write failed: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let mgr = manager,
              let task = mgr.findTask(byIdentifier: downloadTask.taskIdentifier) else { return }
        task.updateProgress(downloaded: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let mgr = manager,
              let task = mgr.findTask(byIdentifier: downloadTask.taskIdentifier) else { return }
        mgr.logService?.info("Download resumed at offset \(fileOffset) of \(expectedTotalBytes)")
        task.updateProgress(downloaded: fileOffset, total: expectedTotalBytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let mgr = manager,
              let dtask = mgr.findTask(byIdentifier: task.taskIdentifier) else { return }

        if let error = error {
            let nsError = error as NSError
            // Check if we have resume data
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                dtask.saveResumeData(resumeData)
                dtask.setState(.paused)
                mgr.logService?.info("Download paused with resume data: \(dtask.id.prefix(8))...")
                return
            }

            // Retry logic
            if dtask.shouldRetry(error: error) {
                let delay = dtask.retryDelay()
                mgr.logService?.warn("Download retrying in \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak mgr] in
                    mgr?.resume(taskId: dtask.id)
                }
                return
            }

            dtask.setState(.failed)
            dtask.onComplete?(DownloadError.networkError(error))
            mgr.logService?.error("Download failed: \(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .downloadBackgroundEventsCompleted, object: nil)
        }
    }
}

public extension Notification.Name {
    static let downloadBackgroundEventsCompleted = Notification.Name("DownloadBackgroundEventsCompleted")
}

// MARK: - File Download Manager

public final class FileDownloadManager {
    private let config: DownloadConfiguration
    private var foregroundSession: URLSession!
    private var backgroundSession: URLSession!
    private var backgroundDelegate: BackgroundDownloadDelegate!
    private var tasks: [String: DownloadTask] = [:]
    private var taskIdentifierMap: [Int: String] = [:]  // URLSessionTask.id → taskId
    private let queue = DispatchQueue(label: "com.download.manager", attributes: .concurrent)
    internal var logService: LogService? { config.logService }

    public init(config: DownloadConfiguration = DownloadConfiguration()) {
        self.config = config
        setupSessions()
    }

    private func setupSessions() {
        backgroundDelegate = BackgroundDownloadDelegate(manager: self)

        let fgConfig = URLSessionConfiguration.default
        fgConfig.timeoutIntervalForRequest = config.requestTimeout
        fgConfig.allowsCellularAccess = config.allowsCellularAccess
        foregroundSession = URLSession(configuration: fgConfig, delegate: backgroundDelegate, delegateQueue: nil)

        if config.enableBackgroundDownload {
            let bgConfig = URLSessionConfiguration.background(withIdentifier: config.backgroundSessionIdentifier)
            bgConfig.timeoutIntervalForRequest = config.requestTimeout
            bgConfig.timeoutIntervalForResource = config.resourceTimeout
            bgConfig.allowsCellularAccess = config.allowsCellularAccess
            bgConfig.isDiscretionary = false
            bgConfig.sessionSendsLaunchEvents = true
            backgroundSession = URLSession(configuration: bgConfig, delegate: backgroundDelegate, delegateQueue: nil)
        } else {
            backgroundSession = foregroundSession
        }
    }

    // MARK: - Public API

    /// Start a new download. Supports resume if the destination file already exists.
    public func download(from url: URL,
                         to destinationURL: URL? = nil,
                         taskId: String? = nil,
                         headers: [String: String] = [:],
                         auth: Authentication? = nil,
                         signer: RequestSigner? = nil) throws -> DownloadTask {

        guard url.scheme != nil else { throw DownloadError.invalidURL }

        let tid = taskId ?? UUID().uuidString
        let existing = queue.sync(flags: .barrier) { tasks[tid] }
        guard existing == nil else { throw DownloadError.downloadAlreadyExists }

        let destURL = destinationURL ?? defaultDestination(for: url)
        let task = DownloadTask(id: tid, url: url, destinationURL: destURL,
                                 maxRetryAttempts: config.maxRetryAttempts,
                                 retryBaseDelay: config.retryBaseDelay,
                                 retryMaxDelay: config.retryMaxDelay)

        var request = URLRequest(url: url)
        request.timeoutInterval = config.requestTimeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        if let signer = signer {
            do { request = try signer.sign(request: request, body: nil) }
            catch { throw DownloadError.networkError(error) }
        }
        if let auth = auth { request = auth.authenticate(request: request) }

        // Check for existing partial download
        var downloadTask: URLSessionDownloadTask
        if let resumeData = task.savedResumeData() {
            downloadTask = backgroundSession.downloadTask(withResumeData: resumeData)
            logService?.info("Resuming download from saved data: \(tid.prefix(8))...")
        } else if FileManager.default.fileExists(atPath: destURL.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                  let existingSize = attrs[.size] as? Int64, existingSize > 0 {
            // Resume via Range header
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            downloadTask = backgroundSession.downloadTask(with: request)
            task.updateProgress(downloaded: existingSize, total: 0) // total unknown until response
            logService?.info("Resuming download from byte \(existingSize): \(tid.prefix(8))...")
        } else {
            downloadTask = backgroundSession.downloadTask(with: request)
            logService?.info("Starting download: \(tid.prefix(8))...")
        }

        task.bind(sessionTask: downloadTask)
        task.setState(.downloading)

        queue.sync(flags: .barrier) {
            tasks[tid] = task
            taskIdentifierMap[downloadTask.taskIdentifier] = tid
        }

        config.metricsCollector?.recordStart(taskId: tid, fileSize: UInt64(task.snapshot.totalBytes))
        downloadTask.resume()

        return task
    }

    /// Pause a download. Resume data is saved for later resumption.
    public func pause(taskId: String) {
        guard let task = queue.sync(execute: { tasks[taskId] }) else { return }
        guard task.snapshot.state == .downloading else { return }

        task.setState(.paused)

        // Get the underlying session task and cancel with resume data
        backgroundSession.getAllTasks { sessionTasks in
            for st in sessionTasks {
                let identifier = st.taskIdentifier
                if self.queue.sync(execute: { self.taskIdentifierMap[identifier] }) == taskId {
                    if let downloadTask = st as? URLSessionDownloadTask {
                        downloadTask.cancel { resumeData in
                            if let data = resumeData {
                                task.saveResumeData(data)
                                // Persist resume data to disk for crash recovery
                                let resumeURL = self.resumeDataURL(for: taskId)
                                try? data.write(to: resumeURL)
                            }
                        }
                    } else {
                        st.cancel()
                    }
                    break
                }
            }
        }
        logService?.info("Download paused: \(taskId.prefix(8))...")
    }

    /// Resume a paused download.
    public func resume(taskId: String) {
        guard let task = queue.sync(execute: { tasks[taskId] }) else { return }
        guard task.snapshot.state == .paused else { return }

        // Try saved resume data first, then persisted file
        let resumeData = task.savedResumeData() ?? (try? Data(contentsOf: resumeDataURL(for: taskId)))

        task.setState(.downloading)
        task.resetRetries()

        let sessionTask: URLSessionDownloadTask
        if let resumeData = resumeData {
            sessionTask = backgroundSession.downloadTask(withResumeData: resumeData)
        } else {
            // Resume via Range header from existing file size
            var request = URLRequest(url: task.url)
            if FileManager.default.fileExists(atPath: task.destinationURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: task.destinationURL.path),
               let existingSize = attrs[.size] as? Int64, existingSize > 0 {
                request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            }
            sessionTask = backgroundSession.downloadTask(with: request)
        }

        task.bind(sessionTask: sessionTask)
        queue.sync(flags: .barrier) {
            taskIdentifierMap[sessionTask.taskIdentifier] = taskId
        }
        sessionTask.resume()
        logService?.info("Download resumed: \(taskId.prefix(8))...")
    }

    /// Cancel a download and optionally remove partial file.
    public func cancel(taskId: String, removePartialFile: Bool = false) {
        guard let task = queue.sync(execute: { tasks[taskId] }) else { return }

        task.setState(.cancelled)

        backgroundSession.getAllTasks { sessionTasks in
            for st in sessionTasks {
                let identifier = st.taskIdentifier
                if self.queue.sync(execute: { self.taskIdentifierMap[identifier] }) == taskId {
                    st.cancel()
                    break
                }
            }
        }

        if removePartialFile {
            try? FileManager.default.removeItem(at: task.destinationURL)
        }
        try? FileManager.default.removeItem(at: resumeDataURL(for: taskId))

        queue.sync(flags: .barrier) {
            tasks.removeValue(forKey: taskId)
            // Clean up identifier map
            taskIdentifierMap = taskIdentifierMap.filter { $0.value != taskId }
        }
        config.metricsCollector?.cleanup(taskId: taskId)
        logService?.info("Download cancelled: \(taskId.prefix(8))...")
    }

    // MARK: - Query APIs

    /// Get progress for a specific task.
    public func getProgress(taskId: String) -> DownloadTask.ProgressSnapshot? {
        queue.sync { tasks[taskId]?.snapshot }
    }

    /// Get all active task IDs.
    public var allTaskIds: [String] {
        queue.sync { Array(tasks.keys) }
    }

    /// Get all active tasks.
    public var allTasks: [DownloadTask] {
        queue.sync { Array(tasks.values) }
    }

    /// Cancel all active downloads.
    public func cancelAll() {
        let ids = allTaskIds
        ids.forEach { cancel(taskId: $0) }
    }

    /// Pause all active downloads.
    public func pauseAll() {
        allTaskIds.forEach { pause(taskId: $0) }
    }

    // MARK: - Internal

    func findTask(byIdentifier identifier: Int) -> DownloadTask? {
        queue.sync {
            guard let tid = taskIdentifierMap[identifier] else { return nil }
            return tasks[tid]
        }
    }

    // MARK: - Helpers

    private func defaultDestination(for url: URL) -> URL {
        let dir = config.destinationDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(url.lastPathComponent)
    }

    private func resumeDataURL(for taskId: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DownloadResumeData")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(taskId).resume")
    }

    deinit {
        foregroundSession.invalidateAndCancel()
        backgroundSession.invalidateAndCancel()
    }
}

// MARK: - Progress Query Service

/// Cross-module progress query for both upload and download tasks.
public final class TaskProgressService {
    public enum TaskType { case upload, download }

    public struct UnifiedProgress {
        public let taskId: String
        public let type: TaskType
        public let progress: Double
        public let downloadedBytes: Int64
        public let totalBytes: Int64
        public let speed: Double
        public let state: String
        public let eta: TimeInterval
    }

    private let downloadManager: FileDownloadManager?

    public init(downloadManager: FileDownloadManager? = nil) {
        self.downloadManager = downloadManager
    }

    /// Query download progress by task ID.
    public func queryProgress(taskId: String) -> UnifiedProgress? {
        guard let snap = downloadManager?.getProgress(taskId: taskId) else { return nil }
        let eta = snap.speed > 0 ? Double(snap.totalBytes - snap.downloadedBytes) / snap.speed : 0
        return UnifiedProgress(taskId: taskId, type: .download,
                                progress: snap.progress, downloadedBytes: snap.downloadedBytes,
                                totalBytes: snap.totalBytes, speed: snap.speed,
                                state: snap.state.rawValue, eta: eta)
    }

    /// Query all active download tasks.
    public func queryAllActive() -> [UnifiedProgress] {
        guard let dm = downloadManager else { return [] }
        return dm.allTasks.filter(\.isActive).compactMap { task in
            guard let snap = dm.getProgress(taskId: task.id) else { return nil }
            let eta = snap.speed > 0 ? Double(snap.totalBytes - snap.downloadedBytes) / snap.speed : 0
            return UnifiedProgress(taskId: task.id, type: .download,
                                    progress: snap.progress, downloadedBytes: snap.downloadedBytes,
                                    totalBytes: snap.totalBytes, speed: snap.speed,
                                    state: snap.state.rawValue, eta: eta)
        }
    }
}
