import XCTest
import FileUploadPlusCore

final class UploadConfigurationTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = UploadConfiguration()
        XCTAssertEqual(config.chunkSize, 2 * 1024 * 1024)
        XCTAssertEqual(config.maxConcurrentUploads, 3)
        XCTAssertEqual(config.maxRetryAttempts, 5)
        XCTAssertEqual(config.adaptiveChunkSizing, false)
    }

    func testCustomConfiguration() {
        var config = UploadConfiguration()
        config.chunkSize = 5 * 1024 * 1024
        config.maxConcurrentUploads = 5
        config.adaptiveChunkSizing = true
        XCTAssertEqual(config.chunkSize, 5 * 1024 * 1024)
        XCTAssertEqual(config.maxConcurrentUploads, 5)
        XCTAssertTrue(config.adaptiveChunkSizing)
    }
}

final class ValidationResultTests: XCTestCase {
    func testValidResult() {
        XCTAssertTrue(ValidationResult.valid.isValid)
        XCTAssertTrue(ValidationResult.valid.errors.isEmpty)
    }

    func testInvalidResult() {
        let r = ValidationResult.invalid("test error")
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.errors, ["test error"])
    }
}

final class ChunkStateTests: XCTestCase {
    func testChunkStateInit() {
        let c = ChunkState(index: 0, offset: 0, size: 1024 * 1024)
        XCTAssertEqual(c.index, 0)
        XCTAssertEqual(c.offset, 0)
        XCTAssertEqual(c.size, 1024 * 1024)
        XCTAssertEqual(c.status, .pending)
        XCTAssertEqual(c.retryCount, 0)
        XCTAssertNil(c.md5)
    }
}

final class UploadStateTests: XCTestCase {
    func testResumeOffset() {
        let chunks = [
            ChunkState(index: 0, offset: 0, size: 100),
            ChunkState(index: 1, offset: 100, size: 100),
            ChunkState(index: 2, offset: 200, size: 100),
        ]
        let state = UploadState(taskId: "test", filePath: "/tmp/test", totalChunks: 3, chunks: chunks)
        XCTAssertEqual(state.resumeOffset, 0)

        state.chunks[0].status = .completed
        state.chunks[1].status = .completed
        XCTAssertEqual(state.resumeOffset, 200)
    }
}
