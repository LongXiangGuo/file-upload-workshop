//  MetricsExports.swift
//  FileUploadPlusMetrics

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Bandwidth Tracker

public final class BandwidthTracker {
    private struct Sample { let bytes: UInt64; let timestamp: Date }
    private var samples: [Sample] = []; private let window: TimeInterval; private let maxSamples: Int; private let lock = NSLock()
    public init(windowDuration: TimeInterval = 5.0, maxSamples: Int = 50) { self.window = windowDuration; self.maxSamples = maxSamples }

    public func record(bytes: UInt64) {
        lock.lock(); samples.append(Sample(bytes: bytes, timestamp: Date())); prune(); lock.unlock()
    }
    public var currentBandwidth: Double {
        lock.lock(); defer { lock.unlock() }; prune()
        guard let f = samples.first, let l = samples.last, samples.count > 1 else { return 0 }
        let d = l.timestamp.timeIntervalSince(f.timestamp)
        return d > 0 ? Double(samples.reduce(0) { $0 + $1.bytes }) / d : 0
    }
    private func prune() {
        let c = Date().addingTimeInterval(-window)
        while let f = samples.first, f.timestamp < c { samples.removeFirst() }
        while samples.count > maxSamples { samples.removeFirst() }
    }
    public func reset() { lock.lock(); samples.removeAll(); lock.unlock() }
}

// MARK: - Traffic Controller

public final class TrafficController: TrafficControlProtocol {
    public var maxConcurrentChunks: Int { didSet { adjust() } }
    public var maxBytesPerSecond: UInt64?
    private let tracker = BandwidthTracker(); private let lock = NSLock()
    private var active = 0; private var sema: DispatchSemaphore

    public init(maxConcurrentChunks: Int = 3, maxBytesPerSecond: UInt64? = nil) {
        self.maxConcurrentChunks = maxConcurrentChunks; self.maxBytesPerSecond = maxBytesPerSecond
        self.sema = DispatchSemaphore(value: maxConcurrentChunks)
    }

    public func acquireSlot() { sema.wait(); lock.lock(); active += 1; lock.unlock() }
    public func releaseSlot(bytes: UInt64) { lock.lock(); active -= 1; lock.unlock(); sema.signal(); tracker.record(bytes: bytes) }
    public func throttleDelay(for bytes: UInt64) -> TimeInterval {
        guard let limit = maxBytesPerSecond else { return 0 }
        let bw = tracker.currentBandwidth; guard bw > Double(limit) else { return 0 }
        return Swift.max(0, Double(bytes)/Double(limit) - Double(bytes)/Swift.max(bw, 1))
    }
    public func onChunkSuccess() {
        lock.lock(); if maxConcurrentChunks < 8 { maxConcurrentChunks = min(8, maxConcurrentChunks + 1); sema.signal() }; lock.unlock()
    }
    public func onChunkFailure() { lock.lock(); maxConcurrentChunks = max(1, maxConcurrentChunks/2); lock.unlock() }
    public var currentBandwidth: Double { tracker.currentBandwidth }
    private func adjust() { let d = maxConcurrentChunks - active; if d > 0 { for _ in 0..<d { sema.signal() } } }
}

// MARK: - Circuit Breaker

public final class CircuitBreaker: CircuitBreakerProtocol {
    public enum State: String { case closed, open, halfOpen }
    public let name: String; public private(set) var state = State.closed
    private let ft: Int; private let rt: TimeInterval; private let hm: Int
    private var fc = 0; private var oa: Date?; private var hr = 0; private let lock = NSLock()

    public init(name: String = "default", failureThreshold: Int = 5, recoveryTimeout: TimeInterval = 30, halfOpenMaxRequests: Int = 3) {
        self.name = name; self.ft = failureThreshold; self.rt = recoveryTimeout; self.hm = halfOpenMaxRequests
    }

    public func allowRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed: return true
        case .open:
            guard let o = oa, Date().timeIntervalSince(o) >= rt else { return false }
            state = .halfOpen; hr = 0; return true
        case .halfOpen:
            guard hr < hm else { return false }; hr += 1; return true
        }
    }

    public func recordSuccess() {
        lock.lock(); fc = 0
        if state == .halfOpen { state = .closed; hr = 0 }; lock.unlock()
    }

    public func recordFailure() {
        lock.lock(); fc += 1
        if state == .halfOpen || (state == .closed && fc >= ft) { state = .open; oa = Date() }; lock.unlock()
    }

    public func reset() { lock.lock(); state = .closed; fc = 0; hr = 0; oa = nil; lock.unlock() }
}

// MARK: - Upload Statistics

public struct UploadStatistics {
    public let taskId: String; public var fileSize: UInt64; public var uploadedBytes: UInt64
    public var startTime: Date; public var endTime: Date?; public var isComplete: Bool; public var error: String?
    public var duration: TimeInterval { (endTime ?? Date()).timeIntervalSince(startTime) }
    public var averageSpeed: Double { duration > 0 ? Double(uploadedBytes) / duration : 0 }
    public var progress: Double { fileSize > 0 ? Double(uploadedBytes) / Double(fileSize) : 0 }
    public var eta: TimeInterval {
        guard averageSpeed > 0, uploadedBytes < fileSize else { return 0 }
        return Double(fileSize - uploadedBytes) / averageSpeed
    }
    public var formattedSpeed: String {
        let b = averageSpeed
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b/1_000_000) }
        if b >= 1_000 { return String(format: "%.1f KB/s", b/1_000) }
        return String(format: "%.0f B/s", b)
    }
    public var formattedETA: String {
        let e = eta
        if e < 60 { return "\(Int(e))s" }
        return String(format: "%.1fm", e/60)
    }
}

// MARK: - Metrics Collector

public final class UploadMetricsCollector: MetricsCollectorProtocol {
    private var stats: [String: UploadStatistics] = [:]; private let tracker = BandwidthTracker()
    private let lock = NSLock()
    public var onStatsUpdated: ((UploadStatistics) -> Void)?

    public init() {}

    public func recordStart(taskId: String, fileSize: UInt64) {
        lock.lock(); stats[taskId] = UploadStatistics(taskId: taskId, fileSize: fileSize, uploadedBytes: 0, startTime: Date(), endTime: nil, isComplete: false); lock.unlock()
    }
    public func recordProgress(taskId: String, uploadedBytes: UInt64) {
        lock.lock(); stats[taskId]?.uploadedBytes = uploadedBytes
        if let s = stats[taskId] { onStatsUpdated?(s) }; lock.unlock()
    }
    public func recordCompletion(taskId: String) {
        lock.lock(); stats[taskId]?.isComplete = true; stats[taskId]?.endTime = Date()
        if let s = stats[taskId] { onStatsUpdated?(s) }; lock.unlock()
    }
    public func recordFailure(taskId: String, error: Error) {
        lock.lock(); stats[taskId]?.error = error.localizedDescription; stats[taskId]?.endTime = Date(); lock.unlock()
    }
    public func getStats(taskId: String) -> Any? { lock.lock(); defer { lock.unlock() }; return stats[taskId] }
    public func getAllStats() -> [Any] { lock.lock(); defer { lock.unlock() }; return Array(stats.values) }
    public func cleanup(taskId: String) { lock.lock(); stats.removeValue(forKey: taskId); lock.unlock() }
    public var currentBandwidth: Double { tracker.currentBandwidth }
}

// MARK: - Chunk Timer

public final class ChunkTimer {
    private var starts: [Int: Date] = [:]; private var durations: [Int: TimeInterval] = [:]; private let lock = NSLock()
    public func start(_ i: Int) { lock.lock(); starts[i] = Date(); lock.unlock() }
    public func end(_ i: Int) { lock.lock(); if let s = starts[i] { durations[i] = Date().timeIntervalSince(s) }; lock.unlock() }
    public var avg: TimeInterval { lock.lock(); defer { lock.unlock() }; guard !durations.isEmpty else { return 0 }; return durations.values.reduce(0,+)/Double(durations.count) }
}
