//  APMExports.swift
//  FileUploadPlusAPM
//
//  Application Performance Monitoring integration.
//  Export upload metrics to Sentry, Datadog, or custom APM backends.
//  Tracks spans, errors, bandwidth, and chunk-level timing.

import Foundation
#if canImport(FileUploadPlusCore)
@preconcurrency import FileUploadPlusCore
#endif
// MARK: - APM Span

public struct APMSpan: Sendable {
    public let traceId: String
    public let name: String
    public let startTime: Date
    public let endTime: Date?
    public let tags: [String: String]
    public let error: Error?

    public var durationMs: Double {
        (endTime ?? Date()).timeIntervalSince(startTime) * 1000
    }

    public init(traceId: String = UUID().uuidString, name: String,
                startTime: Date = Date(), endTime: Date? = nil,
                tags: [String: String] = [:], error: Error? = nil) {
        self.traceId = traceId; self.name = name; self.startTime = startTime
        self.endTime = endTime; self.tags = tags; self.error = error
    }
}

// MARK: - APM Exporter Protocol

public protocol APMExporter: AnyObject, Sendable {
    /// Export a completed span to the APM backend.
    func export(span: APMSpan)
    /// Record a metric value with tags.
    func recordMetric(name: String, value: Double, tags: [String: String])
    /// Flush any buffered data before app termination.
    func flush()
}

// MARK: - Console APM (Debug)

public final class ConsoleAPMExporter: APMExporter, @unchecked Sendable {
    private let logger: LogService?

    public init(logger: LogService? = nil) { self.logger = logger }

    public func export(span: APMSpan) {
        let status = span.error == nil ? "ok" : "error"
        logger?.info("[APM] span=\(span.name) trace=\(span.traceId.prefix(8)) duration=\(String(format: "%.1f", span.durationMs))ms status=\(status)")
    }

    public func recordMetric(name: String, value: Double, tags: [String: String]) {
        logger?.debug("[APM] metric=\(name) value=\(String(format: "%.2f", value)) tags=\(tags)")
    }

    public func flush() {}
}

// MARK: - Sentry-compatible Exporter

/// Formats spans into Sentry envelope format for forwarding to Sentry relay or SDK.
public final class SentryAPMExporter: APMExporter, @unchecked Sendable {
    private let dsn: String
    private let session: URLSession
    private let logger: LogService?
    private var buffer: [APMSpan] = []
    private let bufferLock = NSLock()
    private let maxBufferSize = 50
    private let flushInterval: TimeInterval = 5

    private var flushTimer: Timer?

    public init(dsn: String, logger: LogService? = nil) {
        self.dsn = dsn
        self.logger = logger
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Content-Type": "application/x-sentry-envelope"]
        self.session = URLSession(configuration: config)
    }

    public func export(span: APMSpan) {
        bufferLock.lock()
        buffer.append(span)
        let shouldFlush = buffer.count >= maxBufferSize
        bufferLock.unlock()
        if shouldFlush { sendBatch() }
    }

    public func recordMetric(name: String, value: Double, tags: [String: String]) {
        logger?.debug("[Sentry] metric=\(name) value=\(String(format: "%.2f", value)) tags=\(tags)")
    }

    public func flush() { sendBatch() }

    private func sendBatch() {
        bufferLock.lock()
        guard !buffer.isEmpty else { bufferLock.unlock(); return }
        let batch = buffer
        buffer.removeAll()
        bufferLock.unlock()

        let envelope = formatEnvelope(spans: batch)
        guard let url = sentryEnvelopeURL(),
              let body = envelope.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body

        let task = session.dataTask(with: request) { [weak self] _, _, error in
            if let error = error {
                self?.logger?.warn("Sentry flush failed: \(error.localizedDescription)")
            } else {
                self?.logger?.debug("Sentry flushed \(batch.count) spans")
            }
        }
        task.resume()
    }

    private func formatEnvelope(spans: [APMSpan]) -> String {
        // Sentry envelope format: header\nitem-header\nitem-body\n
        let header = #"{"sent_at":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        let items = spans.map { span in
            let itemHeader = #"{"type":"transaction","content_type":"application/json"}"#
            let body = """
            {"transaction":"\(span.name)","trace_id":"\(span.traceId)","start_timestamp":\(span.startTime.timeIntervalSince1970),"timestamp":\(span.endTime?.timeIntervalSince1970 ?? Date().timeIntervalSince1970),"tags":\(formatJSON(span.tags)),"contexts":{"trace":{"status":"\(span.error == nil ? "ok" : "internal_error")"}}}
            """
            return "\(itemHeader)\n\(body)"
        }
        return "\(header)\n\(items.joined(separator: "\n"))"
    }

    private func sentryEnvelopeURL() -> URL? {
        guard let projectId = dsn.components(separatedBy: "/").last,
              let host = dsn.components(separatedBy: "@").last?.components(separatedBy: "/").first else {
            return nil
        }
        return URL(string: "https://\(host)/api/\(projectId)/envelope/")
    }

    private func formatJSON(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Upload APM Bridge

/// Automatically records upload spans, chunk metrics, and errors from the upload flow.
public final class UploadAPMBridge {
    private let exporter: APMExporter
    private var activeSpans: [String: APMSpan] = [:]
    private let lock = NSLock()

    public init(exporter: APMExporter) { self.exporter = exporter }

    public func startUpload(taskId: String, fileName: String, fileSize: UInt64) {
        let span = APMSpan(traceId: taskId, name: "upload.\(fileName)",
                           tags: ["file_size": "\(fileSize)", "task_id": taskId])
        lock.lock(); activeSpans[taskId] = span; lock.unlock()
    }

    public func recordChunk(taskId: String, index: Int, bytes: Int, durationMs: Double) {
        exporter.recordMetric(name: "upload.chunk.bytes", value: Double(bytes),
                              tags: ["task_id": taskId, "index": "\(index)"])
        exporter.recordMetric(name: "upload.chunk.duration_ms", value: durationMs,
                              tags: ["task_id": taskId, "index": "\(index)"])
    }

    public func recordBandwidth(taskId: String, bytesPerSecond: Double) {
        exporter.recordMetric(name: "upload.bandwidth", value: bytesPerSecond, tags: ["task_id": taskId])
    }

    public func completeUpload(taskId: String, error: Error? = nil) {
        lock.lock()
        guard let span = activeSpans.removeValue(forKey: taskId) else { lock.unlock(); return }
        lock.unlock()
        let ended = APMSpan(traceId: span.traceId, name: span.name,
                            startTime: span.startTime, endTime: Date(),
                            tags: span.tags, error: error)
        exporter.export(span: ended)
    }

    public func flush() { exporter.flush() }
}
