//  DataProvider.swift
//  FileUploadPlusCore

import Foundation

// MARK: - Protocol

public protocol DataProvider: AnyObject {
    func readData(offset: UInt64, size: UInt64) -> Data?
    var totalSize: UInt64? { get }
    func close()
}

// MARK: - File Data Provider

public final class FileDataProvider: DataProvider {
    private let fileURL: URL
    private let fileHandle: FileHandle?
    private let ioLock = NSLock()
    public private(set) var totalSize: UInt64?

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileNotFound
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.totalSize = attrs[.size] as? UInt64
        self.fileHandle = try FileHandle(forReadingFrom: fileURL)
    }

    public func readData(offset: UInt64, size: UInt64) -> Data? {
        ioLock.lock(); defer { ioLock.unlock() }
        guard let handle = fileHandle else { return nil }
        handle.seek(toFileOffset: offset)
        let data = handle.readData(ofLength: Int(size))
        return data.isEmpty ? nil : data
    }

    public func close() {
        ioLock.lock(); defer { ioLock.unlock() }
        try? fileHandle?.close()
    }
}

// MARK: - Streaming Data Provider

public final class StreamingDataProvider: DataProvider {
    public let fileURL: URL
    private var fileHandle: FileHandle?
    private var writeOffset: UInt64 = 0
    private let lock = NSLock()
    public private(set) var totalSize: UInt64?

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        self.fileHandle = try FileHandle(forUpdating: fileURL)
    }

    public func append(data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle = fileHandle else { throw UploadError.fileAccessDenied }
        handle.seek(toFileOffset: writeOffset)
        handle.write(data)
        writeOffset += UInt64(data.count)
    }

    public func finishWriting() {
        lock.lock(); defer { lock.unlock() }
        totalSize = writeOffset
    }

    public func readData(offset: UInt64, size: UInt64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let handle = fileHandle else { return nil }
        // Use writeOffset when totalSize hasn't been finalized yet (streaming).
        let effectiveTotal = totalSize ?? writeOffset
        let available = effectiveTotal - offset
        guard available > 0 else { return nil }
        handle.seek(toFileOffset: offset)
        return handle.readData(ofLength: Int(min(size, available)))
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }

    public var currentWriteSize: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return writeOffset
    }
}
