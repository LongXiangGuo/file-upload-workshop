//
//  ContentView.swift
//  FileUploadPlus
//
//  Comprehensive demo showcasing all upload scenarios.
//

import SwiftUI
import Foundation
import Combine
import CryptoKit

// MARK: - Local Demo Server (URLProtocol)

final class DemoURLProtocol: URLProtocol {
    static let demoHost = "localhost"
    static let demoPort = 9999
    static var demoBase: String { "http://\(demoHost):\(demoPort)" }

    // MARK: - Logger (set from app to capture all protocol logs)
    static weak var logger: LogService?

    // MARK: - File storage for integrity verification

    private static var storageLock = NSLock()
    private static var storedUploads: [String: (savedURL: URL, fileHandle: FileHandle, chunkCount: Int, totalBytes: UInt64)] = [:]

    private static func log(_ message: String, level: LogLevel = .debug) {
        if let logger {
            logger.log(LogEntry(level: level, category: "DemoURLProtocol", message: message))
        } else {
            print("[DemoURLProtocol] \(message)")
        }
    }

    static func saveChunk(taskId: String, chunkIndex: Int, offset: UInt64, data: Data) {
        storageLock.lock()
        var stored = storedUploads[taskId]
        if stored == nil {
            let u = FileManager.default.temporaryDirectory
                .appendingPathComponent("uploaded_\(taskId.prefix(8)).data")
            FileManager.default.createFile(atPath: u.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: u) {
                stored = (savedURL: u, fileHandle: h, chunkCount: 0, totalBytes: 0)
                storedUploads[taskId] = stored
            }
        }
        guard let entry = stored else { storageLock.unlock(); return }
        do {
            try entry.fileHandle.seek(toOffset: offset)
            try entry.fileHandle.write(contentsOf: data)
            storedUploads[taskId]?.chunkCount += 1
            storedUploads[taskId]?.totalBytes += UInt64(data.count)
            let total = storedUploads[taskId]?.totalBytes ?? 0
            log("Chunk saved: idx=\(chunkIndex) offset=\(offset) size=\(data.count) total=\(total)")
        } catch {
            log("Write error at \(offset): \(error)", level: .error)
        }
        storageLock.unlock()
    }

    static func sha256OfFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = CryptoKit.SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verify the uploaded file against the original, then clean up.
    static func verifyUpload(taskId: String, against originalURL: URL) {
        storageLock.lock()
        let saved = storedUploads[taskId]
        storageLock.unlock()
        guard let saved else {
            log("No saved file found", level: .warn)
            return
        }
        log("Chunks saved: \(saved.chunkCount), total bytes written: \(saved.totalBytes)", level: .info)
        guard let origHash = sha256OfFile(at: originalURL),
              let savedHash = sha256OfFile(at: saved.savedURL) else {
            log("Failed to compute hash", level: .error)
            return
        }
        let origSize = (try? Data(contentsOf: originalURL).count) ?? 0
        let savedSize = (try? Data(contentsOf: saved.savedURL).count) ?? 0
        if origHash == savedHash, origSize == savedSize {
            log("PASSED — \(ByteCountFormatter.string(fromByteCount: Int64(savedSize), countStyle: .file))", level: .info)
            log("SHA256: \(origHash.prefix(32))", level: .info)
        } else {
            log("FAILED! Original: size=\(origSize) hash=\(origHash.prefix(32))", level: .error)
            log("FAILED! Uploaded: size=\(savedSize) hash=\(savedHash.prefix(32))", level: .error)
        }
        storageLock.lock()
        storedUploads.removeValue(forKey: taskId)
        storageLock.unlock()
        try? FileManager.default.removeItem(at: saved.savedURL)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == demoHost && request.url?.port == demoPort
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client = client else { return }
        let method = request.httpMethod ?? "?"
        let path = url.path
        Self.log("\(method) \(path)")

        // --- Read request body (httpBody for dataTask, httpBodyStream for uploadTask) ---
        let bodyData: Data = {
            if let b = request.httpBody, !b.isEmpty { return b }
            if let s = request.httpBodyStream {
                s.open(); defer { s.close() }
                var d = Data(); var buf = [UInt8](repeating: 0, count: 65536)
                while true { let n = s.read(&buf, maxLength: buf.count); if n > 0 { d.append(buf, count: n) } else { break } }
                return d
            }
            return Data()
        }()

        // --- Init: create temp file if not already created by saveChunk ---
        if method == "POST", path.hasSuffix("/init"), !bodyData.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let tid = json["taskId"] as? String {
                Self.storageLock.lock()
                if Self.storedUploads[tid] == nil {
                    let u = FileManager.default.temporaryDirectory
                        .appendingPathComponent("uploaded_\(tid.prefix(8)).data")
                    FileManager.default.createFile(atPath: u.path, contents: nil)
                    if let h = try? FileHandle(forWritingTo: u) {
                        Self.storedUploads[tid] = (savedURL: u, fileHandle: h, chunkCount: 0, totalBytes: 0)
                    }
                }
                Self.storageLock.unlock()
            }
        }

        // --- Complete: close file ---
        if method == "POST", path.hasSuffix("/complete") {
            let parts = path.split(separator: "/")
            if parts.count >= 3 {
                let tid = String(parts[2])
                Self.storageLock.lock()
                if let entry = Self.storedUploads[tid] {
                    try? entry.fileHandle.synchronize()
                    try? entry.fileHandle.close()
                    Self.log("Complete: chunks=\(entry.chunkCount) bytes=\(entry.totalBytes)", level: .info)
                }
                Self.storageLock.unlock()
            }
        }

        let delay = Double.random(in: 0.15...0.5)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let (status, body): (Int, Data) = self.mockResponse(url: url)
            guard let resp = HTTPURLResponse(
                url: url, statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else { return }
            client.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    private func mockResponse(url: URL) -> (Int, Data) {
        let path = url.path
        let uploadId = "demo-upload-\(UUID().uuidString.prefix(8))"

        if path.hasSuffix("/init") {
            let json = #"{"uploadId":"\#(uploadId)","status":"ok"}"#
            return (200, Data(json.utf8))
        } else if path.contains("/chunk/") {
            let md5 = Data(repeating: 0, count: 16).map { String(format: "%02x", $0) }.joined()
            let json = #"{"status":"ok","md5":"\#(md5)"}"#
            return (200, Data(json.utf8))
        } else if path.hasSuffix("/complete") {
            let json = #"{"status":"ok","message":"upload complete"}"#
            return (200, Data(json.utf8))
        } else if path.hasSuffix("/abort") {
            return (200, Data(#"{"status":"ok"}"#.utf8))
        }
        return (404, Data(#"{"error":"not found"}"#.utf8))
    }
}

// MARK: - Demo URL Builder

final class DemoURLBuilder: URLBuilder {
    func buildInitURL(taskId: String, metadata: [String: String]) -> URL {
        URL(string: "\(DemoURLProtocol.demoBase)/uploads/\(taskId)/init")!
    }
    func buildChunkURL(taskId: String, uploadId: String, chunkIndex: Int) -> URL {
        URL(string: "\(DemoURLProtocol.demoBase)/uploads/\(taskId)/chunk/\(chunkIndex)")!
    }
    func buildCompleteURL(taskId: String, uploadId: String) -> URL {
        URL(string: "\(DemoURLProtocol.demoBase)/uploads/\(taskId)/complete")!
    }
    func buildAbortURL(taskId: String, uploadId: String) -> URL {
        URL(string: "\(DemoURLProtocol.demoBase)/uploads/\(taskId)/abort")!
    }
}

// MARK: - Demo UI

struct ContentView: View {
    @StateObject private var demo = UploadDemoViewModel()

    var body: some View {
        NavigationView {
            List {
                // Status Section
                Section("Upload Engine Status") {
                    HStack {
                        Text("Network")
                        Spacer()
                        Circle()
                            .fill(demo.isReachable ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(demo.isReachable ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let bw = demo.currentBandwidth {
                        HStack {
                            Text("Bandwidth")
                            Spacer()
                            Text(bw).font(.caption).foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Active Tasks")
                        Spacer()
                        Text("\(demo.activeTaskCount)").font(.caption).foregroundColor(.secondary)
                    }

                    if let cb = demo.circuitBreakerState {
                        HStack {
                            Text("Circuit Breaker")
                            Spacer()
                            Text(cb).font(.caption).foregroundColor(cb == "open" ? .red : .green)
                        }
                    }
                }

                // Upload Demos
                Section("Upload Demos") {
                    // Demo 1: Standard file upload
                    Button("1. Upload 10MB Test File") {
                        demo.runStandardUpload()
                    }
                    .disabled(demo.isUploading || !demo.isReady)

                    // Demo 2: Image upload with compression
                    Button("2. Upload Image (with compression)") {
                        demo.runImageUpload()
                    }
                    .disabled(demo.isUploading || !demo.isReady)

                    // Demo 3: Streaming upload
                    Button("3. Simulate Streaming Upload") {
                        demo.runStreamingUpload()
                    }
                    .disabled(demo.isUploading || !demo.isReady)

                    // Demo 4: Pause/Resume test
                    Button("4. Upload with Pause/Resume") {
                        demo.runPauseResumeTest()
                    }
                    .disabled(demo.isUploading || !demo.isReady)

                    // Demo 5: Cancel and cleanup
                    Button("5. Upload then Cancel") {
                        demo.runCancelTest()
                    }
                    .disabled(demo.isUploading || !demo.isReady)
                }

                // Progress
                if let progress = demo.currentProgress {
                    Section("Current Progress") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            HStack {
                                Text("\(Int(progress * 100))%")
                                    .font(.headline)
                                Spacer()
                                if let speed = demo.currentSpeed {
                                    Text(speed).font(.caption).foregroundColor(.secondary)
                                }
                                if let eta = demo.currentETA {
                                    Text("ETA: \(eta)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            if let tid = demo.currentTaskId {
                                Text("Task: \(tid.prefix(12))...")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Logs
                Section("Log Output") {
                    ScrollView {
                        Text(demo.logText)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 250)

                    Button("Clear Logs") { demo.logText = "" }
                }

                // Quick Actions
                Section("Quick Actions") {
                    if demo.pausedTaskCount > 0 {
                        Button("Start All", role: .none) { demo.resumeAll() }
                            .disabled(demo.pausedTaskCount == 0)
                    }
                    if demo.activeTaskCount > demo.pausedTaskCount {
                        Button("Pause All", role: .none) { demo.pauseAll() }
                            .disabled(demo.activeTaskCount == 0)
                    }
                    Button("Cancel All", role: .destructive) { demo.cancelAll() }
                        .disabled(demo.activeTaskCount == 0)
                }

                // Validation Test
                Section("Validation Test") {
                    Button("Test File Rejected (too large)") {
                        demo.testValidationRejection()
                    }
                    Button("Test File Rejected (bad extension)") {
                        demo.testExtensionRejection()
                    }
                }
            }
            .navigationTitle("FileUploadPlus Demo")
        }
    }
}

// MARK: - Demo ViewModel

class UploadDemoViewModel: ObservableObject {
    @Published var logText = ""
    @Published var isUploading = false
    @Published var currentProgress: Double?
    @Published var currentSpeed: String?
    @Published var currentETA: String?
    @Published var currentTaskId: String?
    @Published var isReachable = true
    @Published var currentBandwidth: String?
    @Published var activeTaskCount = 0
    @Published var pausedTaskCount = 0
    @Published var circuitBreakerState: String?
    @Published var isReady = false

    private var manager: FileUploadManager!
    private var currentTask: UploadTask?
    private var usedConfig: UploadConfiguration!
    private var statusTimer: AnyCancellable?
    private let logBuffer = NSMutableAttributedString()
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    init() {
        appendLog("[Demo] Starting FileUploadPlus (local mock server)...", color: .systemBlue)
        setupManager()
        statusTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    private func setupManager() {
        // UI log bridge — all library logs appear in the demo's log panel
        let uiLog = CallbackLogService(minimumLevel: .debug) { [weak self] entry in
            self?.appendLog(entry.formatted, color: .label)
        }

        // Log service: UI + console + file
        let consoleLog = ConsoleLogService(minimumLevel: .debug)
        let fileLog = FileLogService(minimumLevel: .info, maxFileSize: 10 * 1024 * 1024)
        var logServices: [LogService] = [uiLog, consoleLog]
        if let fl = fileLog { logServices.append(fl) }
        let compositeLog = CompositeLogService(services: logServices)

        // Bind DemoURLProtocol logs into the same pipeline
        DemoURLProtocol.logger = compositeLog

        var config = UploadConfiguration()
        config.chunkSize = 1 * 1024 * 1024 // 1MB chunks
        config.maxConcurrentUploads = 3
        config.maxRetryAttempts = 3
        config.retryBaseDelay = 0.5
        config.retryMaxDelay = 10
        config.requestTimeout = 30
        config.backgroundSessionIdentifier = "com.demo.upload"
        config.enableBackgroundUpload = true
        config.adaptiveChunkSizing = true

        // Pluggable logging
        config.logService = compositeLog

        // Use local mock server (no external network needed)
        config.urlBuilder = DemoURLBuilder()
        config.requestSigner = nil

        // File validators (defense in depth)
        config.validators = [
            FileSizeValidator(minBytes: 1, maxBytes: 100 * 1024 * 1024),     // 100MB max
            FileTypeValidator(allowedExtensions: Set(["jpg", "jpeg", "png", "pdf", "mp4", "mov", "data", "tmp"]),
                              allowedMIMETypes: Set(["image/jpeg", "image/png", "application/pdf", "video/mp4"])),
            FileNameValidator(maxNameLength: 255,
                              blockedExtensions: Set(["exe", "sh", "php", "dmg"])),
        ]

        // Upload pipeline stages
        let pipeline = UploadPipeline(logger: compositeLog)
        pipeline.addStage(FileValidationStage(validators: config.validators, logger: compositeLog))
        pipeline.addStage(ImageCompressionStage(compressionQuality: 0.8, maxDimension: 2048))
        pipeline.addStage(ChecksumStage(checker: SHA256IntegrityChecker()))

        // Metrics + Notification
        let notification = NotificationStage()
        notification.onStart = { [weak self] ctx in
            self?.appendLog("[Notification] Upload started: \(ctx.taskId.prefix(8))...", color: .systemBlue)
        }
        notification.onComplete = { [weak self] ctx, error in
            if let error = error {
                self?.appendLog("[Notification] Upload failed: \(error.localizedDescription)", color: .systemRed)
            } else {
                self?.appendLog("[Notification] Upload completed: \(ctx.taskId.prefix(8))...", color: .systemGreen)
            }
        }
        pipeline.addStage(notification)

        // Metrics collector
        let metrics = UploadMetricsCollector()
        metrics.onStatsUpdated = { [weak self] stat in
            DispatchQueue.main.async {
                self?.currentSpeed = stat.formattedSpeed
                self?.currentETA = stat.formattedETA
                self?.currentBandwidth = stat.formattedSpeed
            }
        }

        config.pipeline = pipeline
        config.metricsCollector = metrics

        // Save chunk data for integrity verification
        config.onChunkSent = { tid, idx, offset, data in
            DemoURLProtocol.saveChunk(taskId: tid, chunkIndex: idx, offset: offset, data: data)
        }

        // Traffic control (prevent overwhelming the network)
        config.trafficController = TrafficController(maxConcurrentChunks: 3, maxBytesPerSecond: nil)

        // Circuit breaker (prevent cascading failures)
        config.circuitBreaker = CircuitBreaker(name: "upload", failureThreshold: 5, recoveryTimeout: 30)

        usedConfig = config

        do {
            manager = try FileUploadManager(
                config: config,
                encryption: nil,
                authentication: nil,
                integrityChecker: SHA256IntegrityChecker(),
                mockProtocolClasses: [DemoURLProtocol.self]
            )
            appendLog("[Manager] Initialized successfully", color: .systemGreen)
        } catch {
            appendLog("[Manager] Init failed: \(error)", color: .systemRed)
        }
        isReady = true
    }

    // MARK: Demo Scenarios

    func runStandardUpload() {
        guard let manager = manager else { appendLog("[Demo] Manager not ready yet", color: .systemOrange); return }
        guard let fileURL = createTestFile(name: "test_upload", sizeMB: 10) else {
            appendLog("[Demo] Failed to create test file", color: .systemRed); return
        }

        isUploading = true
        currentProgress = 0
        let tid = UUID().uuidString

        do {
            let task = try manager.uploadFile(
                at: fileURL,
                taskId: tid,
                metadata: ["description": "Standard upload demo", "userId": "demo-user-123"]
            ) { [weak self] error in
                DispatchQueue.main.async {
                    self?.isUploading = false
                    if let error = error {
                        self?.appendLog("[Demo 1] Standard upload failed: \(error.localizedDescription)", color: .systemRed)
                    } else {
                        self?.appendLog("[Demo 1] Standard upload completed successfully", color: .systemGreen)
                        DemoURLProtocol.verifyUpload(taskId: tid, against: fileURL)
                    }
                    self?.currentProgress = nil
                    self?.currentTaskId = nil
                }
            }

            currentTask = task
            currentTaskId = task.taskId

            task.onProgress = { [weak self] progress in
                DispatchQueue.main.async {
                    self?.currentProgress = progress
                }
            }

            task.onChunkComplete = { [weak self] idx, total in
                self?.appendLog("[Demo 1] Chunk \(idx + 1)/\(total) completed", color: .systemGray)
            }

            appendLog("[Demo 1] Started upload: \(task.taskId.prefix(8))...", color: .systemBlue)
        } catch {
            appendLog("[Demo 1] Error: \(error)", color: .systemRed)
            isUploading = false
        }
    }

    func runImageUpload() {
        guard let manager = manager else { return }
        // Create a simulated image file
        guard let fileURL = createSimulatedImageFile() else {
            appendLog("[Demo 2] Failed to create image file", color: .systemRed); return
        }

        isUploading = true
        currentProgress = 0

        do {
            let task = try manager.uploadFile(
                at: fileURL,
                metadata: ["description": "Image upload with compression"],
                validate: true // This triggers the validation + compression pipeline
            ) { [weak self] error in
                DispatchQueue.main.async {
                    self?.isUploading = false
                    if let error = error {
                        self?.appendLog("[Demo 2] Image upload failed: \(error.localizedDescription)", color: .systemRed)
                    } else {
                        self?.appendLog("[Demo 2] Image upload completed with compression", color: .systemGreen)
                    }
                    self?.currentProgress = nil
                }
            }

            currentTask = task
            currentTaskId = task.taskId

            task.onProgress = { [weak self] p in
                DispatchQueue.main.async { self?.currentProgress = p }
            }

            appendLog("[Demo 2] Image upload started (pipeline will compress)", color: .systemBlue)
        } catch {
            appendLog("[Demo 2] Error: \(error)", color: .systemRed)
            isUploading = false
        }
    }

    func runStreamingUpload() {
        guard let manager = manager else { return }
        isUploading = true
        currentProgress = 0

        do {
            let handle = try manager.createStreamingUpload(
                metadata: ["description": "Streaming upload demo"]
            )
            currentTaskId = handle.taskId

            handle.onProgress = { [weak self] p in
                DispatchQueue.main.async { self?.currentProgress = p }
            }

            handle.onComplete = { [weak self] error in
                DispatchQueue.main.async {
                    self?.isUploading = false
                    if let error = error {
                        self?.appendLog("[Demo 3] Streaming upload failed: \(error)", color: .systemRed)
                    } else {
                        self?.appendLog("[Demo 3] Streaming upload completed (\(handle.bytesWritten) bytes)", color: .systemGreen)
                    }
                    self?.currentProgress = nil
                }
            }

            appendLog("[Demo 3] Streaming upload created: \(handle.taskId.prefix(8))...", color: .systemBlue)

            // Simulate data arriving in chunks (like receiving from URLSession delegate)
            DispatchQueue.global().async { [weak self] in
                let totalChunks = 20
                for i in 0..<totalChunks {
                    let chunk = Data(repeating: UInt8((i * 13) % 255), count: 512 * 1024) // 512KB each
                    do {
                        try handle.append(data: chunk)
                        let msg = "Appended chunk \(i + 1)/\(totalChunks) (\(chunk.count / 1024)KB)"
                        DispatchQueue.main.async { self?.appendLog("[Demo 3] \(msg)", color: .systemGray) }
                    } catch {
                        DispatchQueue.main.async {
                            self?.appendLog("[Demo 3] Append error: \(error)", color: .systemRed)
                        }
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.3) // Simulate network delay
                }
                handle.finish()
                DispatchQueue.main.async {
                    self?.appendLog("[Demo 3] All data appended, finishing...", color: .systemBlue)
                }
            }
        } catch {
            appendLog("[Demo 3] Streaming error: \(error)", color: .systemRed)
            isUploading = false
        }
    }

    func runPauseResumeTest() {
        guard let manager = manager else { return }
        guard let fileURL = createTestFile(name: "pause_resume_test", sizeMB: 20) else { return }

        isUploading = true
        currentProgress = 0
        let tid = UUID().uuidString

        do {
            let task = try manager.uploadFile(at: fileURL, taskId: tid, metadata: ["test": "pause-resume"]) { [weak self] error in
                DispatchQueue.main.async {
                    self?.isUploading = false
                    self?.appendLog("[Demo 4] Final: \(error?.localizedDescription ?? "success")",
                                     color: error == nil ? .systemGreen : .systemRed)
                    if error == nil {
                        DemoURLProtocol.verifyUpload(taskId: tid, against: fileURL)
                    }
                    self?.currentProgress = nil
                }
            }

            currentTask = task
            currentTaskId = task.taskId

            task.onProgress = { [weak self] p in
                DispatchQueue.main.async { self?.currentProgress = p }
            }

            task.onStateChanged = { [weak self] status in
                self?.appendLog("[Demo 4] State → \(status.rawValue)", color: .systemOrange)
            }

            appendLog("[Demo 4] Upload started, will auto pause/resume...", color: .systemBlue)

            // Pause after 3 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                do { try self?.manager.pause(taskId: task.taskId) }
                catch { self?.appendLog("Pause error: \(error)", color: .systemRed) }
                self?.appendLog("[Demo 4] Paused at \(Int((self?.currentProgress ?? 0) * 100))%", color: .systemOrange)

                // Resume after 2 more seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    do { try self?.manager.resume(taskId: task.taskId) }
                    catch { self?.appendLog("Resume error: \(error)", color: .systemRed) }
                    self?.appendLog("[Demo 4] Resumed!", color: .systemOrange)
                }
            }
        } catch {
            appendLog("[Demo 4] Error: \(error)", color: .systemRed)
            isUploading = false
        }
    }

    func runCancelTest() {
        guard let manager = manager else { return }
        guard let fileURL = createTestFile(name: "cancel_test", sizeMB: 30) else { return }

        isUploading = true
        currentProgress = 0

        do {
            let task = try manager.uploadFile(at: fileURL, metadata: ["test": "cancel"]) { [weak self] error in
                DispatchQueue.main.async {
                    self?.isUploading = false
                    self?.appendLog("[Demo 5] Upload cancelled/failed as expected", color: .systemGray)
                    self?.currentProgress = nil
                }
            }

            currentTask = task
            currentTaskId = task.taskId

            task.onProgress = { [weak self] p in
                DispatchQueue.main.async { self?.currentProgress = p }
            }

            appendLog("[Demo 5] Upload started, will cancel after 2s...", color: .systemBlue)

            // Cancel after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                do { try self?.manager.cancel(taskId: task.taskId, cleanupServer: true) }
                catch { self?.appendLog("Cancel error: \(error)", color: .systemRed) }
                self?.appendLog("[Demo 5] Cancelled!", color: .systemOrange)
            }
        } catch {
            appendLog("[Demo 5] Error: \(error)", color: .systemRed)
            isUploading = false
        }
    }

    // MARK: Validation Tests

    func testValidationRejection() {
        guard let manager = manager else { return }
        // Create a file that's too large
        guard let fileURL = createTestFile(name: "too_large", sizeMB: 200) else { return }
        do {
            _ = try manager.uploadFile(at: fileURL, validate: true) { _ in }
        } catch {
            appendLog("[Validate] Correctly rejected: \(error.localizedDescription)", color: .systemGreen)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func testExtensionRejection() {
        guard let manager = manager else { return }
        // Create a .exe file (blocked)
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("malware.exe")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(repeating: 0, count: 100))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try manager.uploadFile(at: fileURL, validate: true) { _ in }
        } catch {
            appendLog("[Validate] Correctly rejected .exe: \(error.localizedDescription)", color: .systemGreen)
        }
    }

    // MARK: Batch Control

    func pauseAll() {
        guard let manager = manager else { return }
        manager.pauseAll()
        appendLog("[Control] All tasks paused", color: .systemOrange)
    }

    func resumeAll() {
        guard let manager = manager else { return }
        manager.resumeAll()
        appendLog("[Control] All paused tasks resumed", color: .systemGreen)
    }

    func cancelAll() {
        guard let manager = manager else { return }
        manager.cancelAll()
        isUploading = false
        currentProgress = nil
        appendLog("[Control] All tasks cancelled", color: .systemRed)
    }

    // MARK: Helpers

    private func createTestFile(name: String, sizeMB: Int) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(name)_\(UUID().uuidString.prefix(6)).data")
        let chunkSize = 1024 * 1024
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: fileURL) else { return nil }
        var remaining = sizeMB * chunkSize
        var byte: UInt8 = 0
        while remaining > 0 {
            let writeSize = min(chunkSize, remaining)
            let data = Data(repeating: byte, count: writeSize)
            fh.write(data)
            remaining -= writeSize
            byte = byte &+ 1
        }
        try? fh.close()
        appendLog("[File] Created \(sizeMB)MB test file: \(fileURL.lastPathComponent)", color: .systemGray)
        return fileURL
    }

    private func createSimulatedImageFile() -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("photo_\(UUID().uuidString.prefix(6)).jpg")
        // Simulate a 5MB JPEG file
        let header = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
        var data = Data()
        data.append(header)
        data.append(Data(repeating: 0xAB, count: 5 * 1024 * 1024 - header.count))
        try? data.write(to: fileURL)
        appendLog("[File] Created simulated 5MB JPEG", color: .systemGray)
        return fileURL
    }

    private func appendLog(_ message: String, color: UIColor = .label) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        DispatchQueue.main.async {
            self.logText += line
            // Trim log to prevent unbounded growth
            if self.logText.count > 50_000 {
                self.logText = String(self.logText.suffix(30_000))
            }
        }
    }

    func refreshStatus() {
        guard let manager = manager else { return }
        activeTaskCount = manager.allTasks.count
        pausedTaskCount = manager.allTasks.filter { $0.safeIsPaused }.count
        if let cb = usedConfig?.circuitBreaker as? CircuitBreaker {
            circuitBreakerState = cb.state.rawValue
        }
        if let metrics = usedConfig?.metricsCollector, let tid = currentTaskId {
            if let stat = metrics.getStats(taskId: tid) as? UploadStatistics {
                currentSpeed = stat.formattedSpeed
                currentETA = stat.formattedETA
            }
        }
    }
}

#Preview {
    ContentView()
}
