//  UploadTask.swift
//  FileUploadPlusEngine

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
public final class UploadTask {
    public let taskId: String
    internal let config: UploadConfiguration
    internal let networkClient: NetworkClient
    internal let stateStore: UploadStateStore
    internal let encryption: Encryption?
    internal let authentication: Authentication?
    internal let integrityChecker: IntegrityChecker?
    internal var state: UploadState
    internal let coordinator: ChunkCoordinator
    internal var dataProvider: DataProvider?
    internal let operationQueue = OperationQueue()
    /// Single serial queue protects ALL mutable state: isRunning, state, dataProvider.
    private let syncQueue = DispatchQueue(label: "com.upload.task.sync")
    private var isRunning = false

    // --- Batched persistence: avoid SQLite write on every single chunk ---
    private var unsavedChunkCount = 0
    private var maxUnsavedChunks: Int { config.maxUnsavedChunks }

    internal weak var urlBuilder: URLBuilder? { config.urlBuilder }
    internal weak var requestSigner: RequestSigner? { config.requestSigner }
    internal weak var logService: LogService? { config.logService }
    internal weak var pipeline: PipelineStageExecutor? { config.pipeline }
    internal weak var trafficController: TrafficControlProtocol? { config.trafficController }
    internal weak var metricsCollector: MetricsCollectorProtocol? { config.metricsCollector }
    internal weak var circuitBreaker: CircuitBreakerProtocol? { config.circuitBreaker }

    public weak var progressDelegate: UploadProgressDelegate?
    public var onProgress: ((Double) -> Void)?
    public var onComplete: ((Error?) -> Void)?
    public var onChunkComplete: ((Int, Int) -> Void)?
    public var onStateChanged: ((UploadState.UploadStatus) -> Void)?

    init(taskId: String, fileURL: URL, state: UploadState, config: UploadConfiguration,
         networkClient: NetworkClient, stateStore: UploadStateStore,
         encryption: Encryption?, authentication: Authentication?, integrityChecker: IntegrityChecker?) throws {
        self.taskId = taskId; self.config = config
        self.networkClient = networkClient; self.stateStore = stateStore
        self.encryption = encryption; self.authentication = authentication
        self.integrityChecker = integrityChecker; self.state = state

        let completedBytes = state.resumeOffset
        let actualChunkSize = state.chunks.first?.size ?? config.chunkSize
        self.coordinator = ChunkCoordinator(chunkSize: actualChunkSize,
                                             initialReadOffset: completedBytes,
                                             initialWriteOffset: state.fileSize ?? 0)
        if let fs = state.fileSize { coordinator.updateWriteOffset(fs) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.dataProvider = try FileDataProvider(fileURL: fileURL)
        }
        operationQueue.maxConcurrentOperationCount = config.trafficController?.maxConcurrentChunks ?? config.maxConcurrentUploads
        operationQueue.qualityOfService = .userInitiated
    }

    internal func setStreamingProvider(_ provider: StreamingDataProvider) { self.dataProvider = provider }

    /// Thread-safe status query for external callers.
    internal var safeStatus: UploadState.UploadStatus {
        syncQueue.sync { state.status }
    }

    public var safeIsPaused: Bool {
        syncQueue.sync { state.status == .paused }
    }

    // MARK: - Persistence (called within syncQueue)

    /// Lightweight: mark dirty, only persist every N chunks to reduce SQLite write amplification.
    /// For hot-path use (handleChunkSuccess).
    private func maybeSaveState() {
        state.lastModified = Date()
        unsavedChunkCount += 1
        if unsavedChunkCount >= maxUnsavedChunks {
            try? stateStore.save(state: state)
            unsavedChunkCount = 0
        }
    }

    /// Force immediate persistence. Use at lifecycle boundaries (pause/cancel/complete/fail).
    private func flushState() {
        state.lastModified = Date()
        unsavedChunkCount = 0
        try? stateStore.save(state: state)
    }

    // MARK: - Public API

    public func start() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.state.status != .completed, !self.isRunning else { return }
            self.isRunning = true
            self.state.status = .uploading
            self.coordinator.resetDispatchOffset(to: self.coordinator.totalUploadedBytes)
            self.flushState()
            let needsInit = self.state.uploadId == nil && self.config.negotiateUploadId && self.config.urlBuilder != nil
            if needsInit { self.initUploadWithServer() } else { self.scheduleUpload() }
        }
    }

    internal func startWithFileSize(_ fileSize: UInt64?) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            if let fs = fileSize { self.state.fileSize = fs; self.coordinator.updateWriteOffset(fs) }
            guard self.state.status != .completed, !self.isRunning else { return }
            self.isRunning = true
            self.state.status = .uploading
            self.coordinator.resetDispatchOffset(to: self.coordinator.totalUploadedBytes)
            self.flushState()
            let needsInit = self.state.uploadId == nil && self.config.negotiateUploadId && self.config.urlBuilder != nil
            if needsInit { self.initUploadWithServer() } else { self.scheduleUpload() }
        }
    }

    public func pause() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.state.status = .paused
            self.operationQueue.cancelAllOperations()
            self.flushState()
        }
    }

    public func cancel(cleanupServer: Bool = true) {
        syncQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.isRunning = false
            self.state.status = .failed
            self.operationQueue.cancelAllOperations()
            self.flushState()
            // Wait for in-flight ops on a background thread so syncQueue is never
            // blocked for network-timeout durations.
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                self.operationQueue.waitUntilAllOperationsAreFinished()
                self.syncQueue.async { [weak self] in
                    guard let self = self, !self.isRunning else { return }
                    if cleanupServer, let uid = self.state.uploadId, let ub = self.config.urlBuilder {
                        self.networkClient.abortUpload(url: ub.buildAbortURL(taskId: self.taskId, uploadId: uid),
                                                       uploadId: uid, auth: self.authentication, signer: self.requestSigner) { _ in }
                    }
                    try? self.stateStore.delete(taskId: self.taskId)
                    self.dataProvider?.close()
                    self.dataProvider = nil
                }
            }
        }
    }

    public func append(data: Data) throws {
        try syncQueue.sync {
            guard let p = dataProvider as? StreamingDataProvider else {
                throw UploadError.internalError("Not streaming")
            }
            try p.append(data: data)
            coordinator.updateWriteOffset(p.currentWriteSize)
            state.fileSize = nil
            scheduleUpload()
        }
    }

    public func finishWriting() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard let p = self.dataProvider as? StreamingDataProvider else { return }
            p.finishWriting()
            self.coordinator.finishWriting()
            if let t = p.totalSize { self.state.fileSize = t }
            self.flushState()
            self.scheduleUpload()
            self.checkAndCompleteIfDone()
        }
    }

    // MARK: - Safe callback dispatch (must NOT be called from within syncQueue)

    /// All user callbacks are dispatched off syncQueue to prevent re-entrant
    /// syncQueue.sync deadlocks (e.g. user calls safeStatus inside onComplete).
    private func emitCompletion(_ error: Error?) {
        let cb = onComplete
        let dg = progressDelegate
        let tid = taskId
        guard cb != nil || dg != nil else { return }
        DispatchQueue.main.async {
            cb?(error)
            dg?.uploadTask(tid, didCompleteWithError: error)
        }
    }

    // MARK: - Internal

    private func initUploadWithServer() {
        guard let ub = config.urlBuilder else { scheduleUpload(); return }
        let url = ub.buildInitURL(taskId: taskId, metadata: state.metadata)
        let body: [String: Any] = [
            "taskId": taskId, "fileName": URL(fileURLWithPath: state.filePath).lastPathComponent,
            "fileSize": state.fileSize ?? 0, "chunkSize": config.chunkSize,
            "totalChunks": state.totalChunks, "metadata": state.metadata
        ]
        networkClient.initUpload(url: url, body: body, auth: authentication, signer: requestSigner) { [weak self] r in
            guard let self = self else { return }
            self.syncQueue.async {
                switch r {
                case .success(let uploadId):
                    self.state.uploadId = uploadId; self.flushState(); self.scheduleUpload()
                case .failure(let e):
                    let rp = RetryPolicy(maxAttempts: self.config.maxRetryAttempts,
                                         baseDelay: self.config.retryBaseDelay,
                                         maxDelay: self.config.retryMaxDelay)
                    if rp.shouldRetry(attempt: 1, error: e) {
                        let delay = rp.nextDelay(attempt: 1)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.syncQueue.async { self?.initUploadWithServer() }
                        }
                    } else {
                        self.state.status = .failed
                        self.flushState()
                        self.emitCompletion(e)
                    }
                }
            }
        }
    }

    internal func scheduleUpload() {
        // Must be called within syncQueue.
        guard isRunning else { return }
        while let chunk = coordinator.nextChunk() {
            // Check if this chunk is already tracked (pre-created by FileUploadManager
            // for non-streaming uploads, or added by a previous scheduleUpload call).
            if let i = state.chunks.firstIndex(where: { $0.offset == chunk.offset }) {
                switch state.chunks[i].status {
                case .completed, .uploading:
                    // Already handled; advance past it.
                    coordinator.markDispatched(offset: chunk.offset, size: chunk.size)
                    continue
                case .failed, .pending:
                    // Ready to (re)dispatch using the existing entry.
                    state.chunks[i].status = .pending
                    state.chunks[i].retryCount = 0
                    operationQueue.addOperation(UploadOperation(task: self, chunkIndex: i, offset: chunk.offset, size: chunk.size))
                }
            } else {
                // New chunk not tracked yet (streaming upload).
                let ci = state.chunks.count
                state.chunks.append(ChunkState(index: ci, offset: chunk.offset, size: chunk.size))
                maybeSaveState()
                operationQueue.addOperation(UploadOperation(task: self, chunkIndex: ci, offset: chunk.offset, size: chunk.size))
            }
            coordinator.markDispatched(offset: chunk.offset, size: chunk.size)
        }
        if coordinator.isAllUploaded { completeUpload() }
    }

    /// Check whether all dispatched chunks are completed AND writing is finished,
    /// triggering final completion. Handles out-of-order chunk completions correctly
    /// by checking per-chunk status rather than relying on coordinator byte offsets.
    private func checkAndCompleteIfDone() {
        guard !state.chunks.isEmpty else { return }
        guard state.chunks.allSatisfy({ $0.status == .completed }) else { return }
        guard coordinator.isWritingFinished else { return }
        completeUpload()
    }

    internal func handleChunkSuccess(chunkIndex: Int, md5: String) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard chunkIndex < self.state.chunks.count else { return }
            self.state.chunks[chunkIndex].status = .completed
            self.state.chunks[chunkIndex].md5 = md5
            let sz = self.state.chunks[chunkIndex].size
            self.state.uploadedBytes += sz
            self.coordinator.confirmChunk(offset: self.state.chunks[chunkIndex].offset, size: sz)
            self.maybeSaveState()
            self.checkAndCompleteIfDone()
            let denominator = self.state.fileSize ?? self.coordinator.currentWriteOffset
            let p = denominator > 0 ? Double(self.state.uploadedBytes) / Double(denominator) : 0
            DispatchQueue.main.async {
                self.onProgress?(p); self.onChunkComplete?(chunkIndex, self.state.chunks.count)
                self.progressDelegate?.uploadTask(self.taskId, didUpdateProgress: p)
            }
            self.scheduleUpload()
        }
    }

    internal func handleChunkFailure(chunkIndex: Int, error: Error) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            guard chunkIndex < self.state.chunks.count else { return }
            self.state.chunks[chunkIndex].status = .failed
            self.state.chunks[chunkIndex].retryCount += 1
            self.flushState()
            if !((error as? UploadError)?.isRetryable ?? false) {
                self.state.status = .failed
                self.emitCompletion(error)
            }
        }
    }

    private func completeUpload() {
        guard let uid = state.uploadId else { finishUploadSuccess(); return }
        let url = config.urlBuilder?.buildCompleteURL(taskId: taskId, uploadId: uid)
            ?? URL(string: "https://api.example.com/upload/complete/\(taskId)")!
        networkClient.completeUpload(url: url, uploadId: uid, chunks: state.chunks,
                                      auth: authentication, signer: requestSigner) { [weak self] r in
            guard let self = self else { return }
            self.syncQueue.async {
                switch r {
                case .success: self.finishUploadSuccess()
                case .failure(let e):
                    let rp = RetryPolicy(maxAttempts: self.config.maxRetryAttempts,
                                         baseDelay: self.config.retryBaseDelay,
                                         maxDelay: self.config.retryMaxDelay)
                    if rp.shouldRetry(attempt: 1, error: e) {
                        let delay = rp.nextDelay(attempt: 1)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.syncQueue.async { self?.completeUpload() }
                        }
                    } else {
                        self.state.status = .failed; self.flushState()
                        self.dataProvider?.close(); self.dataProvider = nil
                        self.emitCompletion(e)
                    }
                }
            }
        }
    }

    private func finishUploadSuccess() {
        state.status = .completed; flushState()
        dataProvider?.close(); dataProvider = nil
        try? stateStore.delete(taskId: taskId)
        Task { await pipeline?.executePostUpload(context: UploadContext(taskId: taskId, fileURL: URL(fileURLWithPath: state.filePath), metadata: state.metadata), error: nil) }
        emitCompletion(nil)
    }
}
