//  FileUploadManager.swift
//  FileUploadPlusEngine

import Foundation
import Network

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
public final class FileUploadManager {
    public let config: UploadConfiguration
    private let stateStore: UploadStateStore
    private let networkClient: NetworkClient
    private let encryption: Encryption?
    private let authentication: Authentication?
    private let integrityChecker: IntegrityChecker?
    private var tasks: [String: UploadTask] = [:]
    private let tasksLock = NSLock()
    private var reachabilityMonitor: NWPathMonitor?

    public init(config: UploadConfiguration = UploadConfiguration(),
                encryption: Encryption? = nil, authentication: Authentication? = nil,
                integrityChecker: IntegrityChecker? = nil,
                mockProtocolClasses: [AnyClass]? = nil) throws {
        self.config = config; self.encryption = encryption
        self.authentication = authentication; self.integrityChecker = integrityChecker
        self.stateStore = try UploadStateStore(directory: config.stateStoreDirectory)
        self.networkClient = NetworkClient(config: config, mockProtocolClasses: mockProtocolClasses)
        networkClient.logService = config.logService
        if config.autoResumeOnNetworkReachability { setupReachability() }
        try recoverUnfinishedTasks()
    }

    private func setupReachability() {
        reachabilityMonitor = NWPathMonitor()
        reachabilityMonitor?.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                self?.resumeAllPausedTasks()
            }
        }
        reachabilityMonitor?.start(queue: DispatchQueue.global(qos: .background))
    }

    private func recoverUnfinishedTasks() throws {
        let ids = try stateStore.loadAllTaskIds()
        for tid in ids {
            guard let s = try stateStore.load(taskId: tid),
                  s.status == .uploading || s.status == .paused else { continue }
            let t = try UploadTask(taskId: tid, fileURL: URL(fileURLWithPath: s.filePath), state: s,
                                    config: config, networkClient: networkClient, stateStore: stateStore,
                                    encryption: encryption, authentication: authentication,
                                    integrityChecker: integrityChecker)
            tasksLock.withLock { tasks[tid] = t }
            if s.status == .uploading { t.start() }
        }
    }

    private func resumeAllPausedTasks() {
        tasksLock.lock()
        let paused = tasks.values.filter { $0.safeIsPaused }
        tasksLock.unlock()
        for t in paused { t.start() }
    }

    public func uploadFile(at fileURL: URL, taskId: String? = nil,
                           metadata: [String: String] = [:], validate: Bool = true,
                           completion: ((Error?) -> Void)? = nil) throws -> UploadTask {
        if validate, !config.validators.isEmpty {
            var errors: [String] = []
            for v in config.validators {
                let r = v.validate(fileURL: fileURL, metadata: metadata)
                if !r.isValid { errors.append(contentsOf: r.errors) }
            }
            if !errors.isEmpty { throw UploadError.validationFailed(errors) }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw UploadError.fileNotFound }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fs = attrs[.size] as? UInt64, fs > 0 else { throw UploadError.invalidFileSize }

        let tid = taskId ?? UUID().uuidString
        guard tasksLock.withLock({ tasks[tid] }) == nil else { throw UploadError.uploadAlreadyExists }

        let cs = adaptiveChunkSize(for: fs)
        let tc = Int((fs + cs - 1) / cs)
        var chunks: [ChunkState] = []
        for i in 0..<tc {
            let o = UInt64(i) * cs
            chunks.append(ChunkState(index: i, offset: o, size: min(cs, fs - o)))
        }
        let state = UploadState(taskId: tid, filePath: fileURL.path, totalChunks: tc, chunks: chunks, metadata: metadata)
        state.fileSize = fs
        try stateStore.save(state: state)

        let task = try UploadTask(taskId: tid, fileURL: fileURL, state: state, config: config,
                                   networkClient: networkClient, stateStore: stateStore,
                                   encryption: encryption, authentication: authentication,
                                   integrityChecker: integrityChecker)
        task.onComplete = completion
        tasksLock.withLock { tasks[tid] = task }

        let ctx = UploadContext(taskId: tid, fileURL: fileURL, metadata: metadata)
        ctx.fileSize = fs
        Task {
            if try await config.pipeline?.executePreUpload(context: ctx) ?? true {
                task.startWithFileSize(ctx.fileSize != fs ? ctx.fileSize : nil)
            } else { completion?(UploadError.validationFailed(["Pipeline rejected"])) }
        }
        config.metricsCollector?.recordStart(taskId: tid, fileSize: fs)
        return task
    }

    private func adaptiveChunkSize(for fileSize: UInt64) -> UInt64 {
        guard config.adaptiveChunkSizing else { return config.chunkSize }
        let ideal = fileSize / 150
        return min(max(ideal, config.minChunkSize), config.maxChunkSize)
    }

    public func createStreamingUpload(taskId: String? = nil, metadata: [String: String] = [:]) throws -> StreamingUploadHandle {
        let tid = taskId ?? UUID().uuidString
        guard tasksLock.withLock({ tasks[tid] }) == nil else { throw UploadError.uploadAlreadyExists }
        let d = config.stateStoreDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = d.appendingPathComponent("stream_\(tid).tmp")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let state = UploadState(taskId: tid, filePath: url.path, totalChunks: 0, chunks: [], metadata: metadata)
        try stateStore.save(state: state)
        let p = try StreamingDataProvider(fileURL: url)
        let task = try UploadTask(taskId: tid, fileURL: url, state: state, config: config,
                                   networkClient: networkClient, stateStore: stateStore,
                                   encryption: encryption, authentication: authentication,
                                   integrityChecker: integrityChecker)
        task.setStreamingProvider(p)
        tasksLock.withLock { tasks[tid] = task }
        task.start()
        config.metricsCollector?.recordStart(taskId: tid, fileSize: 0)
        return StreamingUploadHandle(task: task, provider: p, logService: config.logService)
    }

    public func pause(taskId: String) throws {
        guard let t = tasksLock.withLock({ tasks[taskId] }) else { throw UploadError.uploadNotFound }
        t.pause()
    }

    public func resume(taskId: String) throws {
        guard let t = tasksLock.withLock({ tasks[taskId] }) else { throw UploadError.uploadNotFound }
        t.start()
    }

    public func cancel(taskId: String, cleanupServer: Bool = true) throws {
        guard let t = tasksLock.withLock({ tasks[taskId] }) else { throw UploadError.uploadNotFound }
        t.cancel(cleanupServer: cleanupServer)
        tasksLock.withLock { _ = tasks.removeValue(forKey: taskId) }
        config.metricsCollector?.cleanup(taskId: taskId)
    }

    public func getTask(taskId: String) -> UploadTask? { tasksLock.withLock { tasks[taskId] } }
    public var allTasks: [UploadTask] { tasksLock.withLock { Array(tasks.values) } }
    public func pauseAll() {
        tasksLock.lock(); let snapshot = Array(tasks.values); tasksLock.unlock()
        for t in snapshot { t.pause() }
    }
    public func resumeAll() {
        tasksLock.lock(); let snapshot = Array(tasks.values); tasksLock.unlock()
        for t in snapshot where t.safeIsPaused { t.start() }
    }
    public func cancelAll() {
        tasksLock.lock(); let snapshot = Array(tasks.values); tasks.removeAll(); tasksLock.unlock()
        for t in snapshot { t.cancel(cleanupServer: true) }
    }
    deinit { reachabilityMonitor?.cancel() }
}
