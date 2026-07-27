//  ChunkCoordinator.swift
//  FileUploadPlusEngine
//
//  Lightweight offset tracker for streaming/chunked uploads.
//  NOT thread-safe on its own — caller (UploadTask.syncQueue) serializes access.
//
//  Offsets:
//    writeOffset     — how much data has been written (file size for non-streaming)
//    dispatchOffset  — next chunk position to dispatch
//    readOffset      — completed & confirmed position (for resume)

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
final class ChunkCoordinator {
    private let chunkSize: UInt64
    private var writeOffset: UInt64 = 0
    private var readOffset: UInt64 = 0
    private var dispatchOffset: UInt64 = 0
    private(set) var isWritingFinished: Bool

    init(chunkSize: UInt64, initialReadOffset: UInt64 = 0, initialWriteOffset: UInt64 = 0) {
        self.chunkSize = chunkSize
        self.readOffset = initialReadOffset
        self.dispatchOffset = initialReadOffset
        self.writeOffset = initialWriteOffset
        // Non-streaming uploads start with all data already "written".
        self.isWritingFinished = initialWriteOffset > 0
    }

    func updateWriteOffset(_ newOffset: UInt64) {
        if newOffset > writeOffset { writeOffset = newOffset }
    }

    func finishWriting() {
        isWritingFinished = true
    }

    /// Next chunk to dispatch. Uses dispatchOffset so each call returns the next
    /// pending chunk — never the same one twice.
    func nextChunk() -> (offset: UInt64, size: UInt64)? {
        let available = writeOffset - dispatchOffset
        guard available > 0 else { return nil }
        let size = min(available, chunkSize)
        return (dispatchOffset, size)
    }

    /// Mark a chunk as dispatched (advances dispatchOffset to the next gap).
    func markDispatched(offset: UInt64, size: UInt64) {
        if offset == dispatchOffset { dispatchOffset += size }
    }

    /// Mark a chunk as uploaded successfully.
    func confirmChunk(offset: UInt64, size: UInt64) {
        if offset == readOffset { readOffset += size }
    }

    func resetReadOffset(to offset: UInt64) {
        if offset < readOffset { readOffset = offset }
    }

    func resetDispatchOffset(to offset: UInt64) {
        if offset < dispatchOffset { dispatchOffset = offset }
    }

    var totalUploadedBytes: UInt64 { readOffset }

    var isAllUploaded: Bool {
        isWritingFinished && readOffset >= writeOffset
    }

    var currentWriteOffset: UInt64 { writeOffset }
}
