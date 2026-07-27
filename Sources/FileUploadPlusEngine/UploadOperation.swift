//  UploadOperation.swift
//  FileUploadPlusEngine

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
final class UploadOperation: Operation, @unchecked Sendable {
    private let taskId: String
    private let chunkIndex: Int
    private let offset: UInt64
    private let size: UInt64
    private weak var task: UploadTask?
    private let retryPolicy: RetryPolicy
    private var attempt: Int = 1
    private var _isExecuting = false
    private var _isFinished = false
    private let stateLock = NSLock()

    init(task: UploadTask, chunkIndex: Int, offset: UInt64, size: UInt64) {
        self.task = task; self.taskId = task.taskId
        self.chunkIndex = chunkIndex; self.offset = offset; self.size = size
        self.retryPolicy = RetryPolicy(maxAttempts: task.config.maxRetryAttempts,
                                        baseDelay: task.config.retryBaseDelay,
                                        maxDelay: task.config.retryMaxDelay)
        super.init()
    }

    override func start() {
        stateLock.lock()
        guard !isCancelled else { stateLock.unlock(); finish(); return }
        _isExecuting = true
        stateLock.unlock()
        // KVO must be sent outside the lock — OperationQueue reads isExecuting
        // in the KVO callback, which would deadlock on stateLock.
        willChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isExecuting")
        performUpload()
    }

    private func performUpload() {
        guard let task = task else { finish(); return }

        if let cb = task.circuitBreaker, !cb.allowRequest() {
            task.handleChunkFailure(chunkIndex: chunkIndex, error: UploadError.circuitBreakerOpen)
            guard !isCancelled else { finish(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + task.config.retryMaxDelay) { [weak self] in
                guard let self = self else { return }
                if self.isCancelled { self.finish(); return }
                self.performUpload()
            }
            return
        }

        task.trafficController?.acquireSlot()

        guard let rawData = task.dataProvider?.readData(offset: offset, size: size) else {
            task.trafficController?.releaseSlot(bytes: 0)
            task.handleChunkFailure(chunkIndex: chunkIndex, error: UploadError.chunkReadFailed)
            finish(); return
        }

        let actualSize = UInt64(rawData.count)
        task.logService?.debug("Chunk \(chunkIndex): offset=\(offset) size=\(actualSize)", taskId: taskId)
        task.config.onChunkSent?(taskId, chunkIndex, offset, rawData)

        let chunkCtx = ChunkContext(taskId: taskId, chunkIndex: chunkIndex, offset: offset,
                                      data: rawData, md5: nil, uploadId: task.state.uploadId,
                                      metadata: task.state.metadata)

        Task {
            let processed: ChunkContext
            do { processed = try await (task.pipeline?.processChunk(chunkCtx) ?? chunkCtx) }
            catch {
                task.trafficController?.releaseSlot(bytes: 0)
                task.trafficController?.onChunkFailure()
                task.circuitBreaker?.recordFailure()
                task.handleChunkFailure(chunkIndex: self.chunkIndex, error: error)
                self.finish()
                return
            }

            guard !processed.skipUpload else {
                task.trafficController?.releaseSlot(bytes: 0)
                task.handleChunkSuccess(chunkIndex: self.chunkIndex, md5: processed.md5 ?? "")
                self.finish()
                return
            }

            let url: URL
            if let ub = task.urlBuilder, let uploadId = task.state.uploadId {
                url = ub.buildChunkURL(taskId: self.taskId, uploadId: uploadId, chunkIndex: self.chunkIndex)
            } else {
                url = URL(string: "https://api.example.com/upload/chunk/\(self.taskId)/\(self.chunkIndex)")!
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let md5 = processed.md5 { request.setValue(md5, forHTTPHeaderField: "Content-MD5") }
            request.setValue("bytes \(self.offset)-\(self.offset + actualSize - 1)/*", forHTTPHeaderField: "Content-Range")
            request.timeoutInterval = task.config.requestTimeout

            if let s = task.requestSigner {
                do { request = try s.sign(request: request, body: processed.data) }
                catch { task.trafficController?.releaseSlot(bytes: actualSize); finish(); return }
            }
            if let a = task.authentication { request = a.authenticate(request: request) }

            let delay = task.trafficController?.throttleDelay(for: actualSize) ?? 0
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }

            task.networkClient.uploadChunk(request: request, data: processed.data,
                                            taskId: self.taskId, chunkIndex: self.chunkIndex) { [weak self] result in
                guard let self = self, let task = self.task else { return }
                switch result {
                case .success:
                    task.metricsCollector?.recordProgress(taskId: self.taskId, uploadedBytes: task.state.uploadedBytes + actualSize)
                    task.trafficController?.releaseSlot(bytes: actualSize)
                    task.trafficController?.onChunkSuccess()
                    task.circuitBreaker?.recordSuccess()
                    task.handleChunkSuccess(chunkIndex: self.chunkIndex, md5: processed.md5 ?? "")
                    self.finish()
                case .failure(let error):
                    task.trafficController?.releaseSlot(bytes: actualSize)
                    task.circuitBreaker?.recordFailure()
                    if !self.isCancelled && self.retryPolicy.shouldRetry(attempt: self.attempt, error: error) {
                        let delay = self.retryPolicy.nextDelay(attempt: self.attempt)
                        self.attempt += 1
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self else { return }
                            if self.isCancelled { self.finish(); return }
                            self.performUpload()
                        }
                    } else {
                        task.trafficController?.onChunkFailure()
                        task.handleChunkFailure(chunkIndex: self.chunkIndex, error: error)
                        self.finish()
                    }
                }
            }
        }
    }

    private func finish() {
        stateLock.lock()
        let wasExecuting = _isExecuting
        let wasFinished = _isFinished
        _isExecuting = false
        _isFinished = true
        stateLock.unlock()
        if wasExecuting {
            willChangeValue(forKey: "isExecuting")
            didChangeValue(forKey: "isExecuting")
        }
        if !wasFinished {
            willChangeValue(forKey: "isFinished")
            didChangeValue(forKey: "isFinished")
        }
    }

    override var isAsynchronous: Bool { true }
    override var isExecuting: Bool { stateLock.withLock { _isExecuting } }
    override var isFinished: Bool { stateLock.withLock { _isFinished } }
}
