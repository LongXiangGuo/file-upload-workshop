//  main.swift
//  FileUploadPlusDemo

import Foundation

import FileUploadPlus

print("===== FileUploadPlus Demo =====\n")

// 1. Setup logging
let consoleLog = ConsoleLogService(minimumLevel: .debug)
consoleLog.info("Demo starting")

// 2. Configure the upload engine
var config = UploadConfiguration()
config.chunkSize = 1 * 1024 * 1024
config.maxConcurrentUploads = 3
config.maxRetryAttempts = 3
config.adaptiveChunkSizing = true
config.logService = consoleLog
config.urlBuilder = StandardURLBuilder(baseURL: URL(string: "https://api.example.com")!, apiVersion: "v1")
config.validators = [
    FileSizeValidator(maxBytes: 100 * 1024 * 1024),
    FileNameValidator(),
]

// 3. Create pipeline
let pipeline = UploadPipeline(logger: consoleLog)
pipeline.addStage(FileValidationStage(validators: config.validators, logger: consoleLog))

// 4. Traffic control and circuit breaker
let tc = TrafficController(maxConcurrentChunks: 3)
let cb = CircuitBreaker(name: "demo", failureThreshold: 5, recoveryTimeout: 30)

config.pipeline = pipeline
config.trafficController = tc
config.circuitBreaker = cb

// 5. Create manager
let manager: FileUploadManager
do {
    manager = try FileUploadManager(config: config)
    print("Manager initialized successfully\n")
} catch {
    print("Manager init failed: \(error)")
    exit(1)
}

// 6. Test validation rejection
let testDir = FileManager.default.temporaryDirectory
let badFile = testDir.appendingPathComponent("malware.exe")
FileManager.default.createFile(atPath: badFile.path, contents: Data(repeating: 0, count: 100))
defer { try? FileManager.default.removeItem(at: badFile) }

print("Testing validation (should reject .exe):")
do {
    _ = try manager.uploadFile(at: badFile, validate: true) { _ in }
    print("  FAILED: should have rejected .exe file")
} catch {
    print("  OK: rejected - \(error.localizedDescription)")
}

// 7. Create a test file and simulate upload (no real server)
let testFile = testDir.appendingPathComponent("test_upload_\(UUID().uuidString.prefix(6)).data")
let testSize = 5 * 1024 * 1024 // 5MB
FileManager.default.createFile(atPath: testFile.path, contents: nil)
if let fh = try? FileHandle(forWritingTo: testFile) {
    var b: UInt8 = 0
    var remaining = testSize
    while remaining > 0 {
        let chunk = min(1_000_000, remaining)
        fh.write(Data(repeating: b, count: chunk))
        remaining -= chunk; b = b &+ 1
    }
    try? fh.close()
}
defer { try? FileManager.default.removeItem(at: testFile) }

print("\nStarting upload demo (no real server — will fail network)...")
do {
    let task = try manager.uploadFile(at: testFile) { error in
        if let error = error {
            print("Upload completed with error (expected): \(error.localizedDescription)")
        } else {
            print("Upload completed successfully")
        }
    }
    task.onProgress = { p in
        if Int(p * 100) % 20 == 0 { print("  Progress: \(Int(p * 100))%") }
    }

    // Wait 3 seconds for demo
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))

    // Pause
    print("\nPausing...")
    try manager.pause(taskId: task.taskId)

    // Resume
    try manager.resume(taskId: task.taskId)
    print("Resumed")

    // Let it run a bit more then cancel
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))

    print("\nCancelling...")
    try manager.cancel(taskId: task.taskId)

    print("Demo complete!")
} catch {
    print("Upload error: \(error)")
}

// 8. Download demo
print("\n===== Download Demo =====")
var dlConfig = DownloadConfiguration()
dlConfig.logService = consoleLog
let dlManager = FileDownloadManager(config: dlConfig)

// Schedule a download (will fail since no real URL)
do {
    let dlTask = try dlManager.download(
        from: URL(string: "https://example.com/sample.pdf")!,
        taskId: "demo-download-1"
    )
    dlTask.onProgress = { p, d, t in
        print("  Download: \(Int(p*100))% (\(d)/\(t) bytes)")
    }
    dlTask.onComplete = { error in
        print("Download finished: \(error?.localizedDescription ?? "success")")
    }
    dlTask.onStateChanged = { state in
        print("  Download state: \(state.rawValue)")
    }

    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    print("    Progress: \(dlTask.snapshot)")
    dlManager.cancel(taskId: dlTask.id)
} catch {
    print("Download error: \(error)")
}

print("\n===== All demos complete =====")
