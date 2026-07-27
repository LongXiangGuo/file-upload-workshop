//  StreamingUploadHandle.swift
//  FileUploadPlusEngine

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
public final class StreamingUploadHandle {
    private let task: UploadTask
    private let provider: StreamingDataProvider
    private weak var logService: LogService?

    init(task: UploadTask, provider: StreamingDataProvider, logService: LogService?) {
        self.task = task; self.provider = provider; self.logService = logService
    }

    public func append(data: Data) throws { try task.append(data: data) }

    public func finish() {
        logService?.debug("Streaming finish, total written: \(provider.currentWriteSize)", taskId: taskId)
        task.finishWriting()
    }

    public var taskId: String { task.taskId }
    public var bytesWritten: UInt64 { provider.currentWriteSize }

    public var onProgress: ((Double) -> Void)? {
        get { task.onProgress }
        set { task.onProgress = newValue }
    }

    public var onComplete: ((Error?) -> Void)? {
        get { task.onComplete }
        set { task.onComplete = newValue }
    }
}
