//  PipelineExports.swift
//  FileUploadPlusPipeline

import Foundation
import ImageIO

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Pipeline Stage Protocol

public protocol PipelineStage: AnyObject {
    var name: String { get }
    var isEnabled: Bool { get set }
    func onPreUpload(context: UploadContext) async throws -> Bool
    func onChunkData(chunk: ChunkContext) async throws -> ChunkContext
    func onPostUpload(context: UploadContext, error: Error?) async
}

public extension PipelineStage {
    func onPreUpload(context: UploadContext) async throws -> Bool { true }
    func onChunkData(chunk: ChunkContext) async throws -> ChunkContext { chunk }
    func onPostUpload(context: UploadContext, error: Error?) async {}
}

// MARK: - Pipeline Orchestrator

public final class UploadPipeline: PipelineStageExecutor {
    private var stages: [PipelineStage] = []
    private let logger: LogService?

    public init(stages: [PipelineStage] = [], logger: LogService? = nil) {
        self.stages = stages; self.logger = logger
    }

    public func addStage(_ stage: PipelineStage) { stages.append(stage) }

    public func executePreUpload(context: UploadContext) async throws -> Bool {
        for s in stages where s.isEnabled {
            guard try await s.onPreUpload(context: context) else { return false }
        }
        return true
    }

    public func processChunk(_ chunk: ChunkContext) async throws -> ChunkContext {
        var c = chunk
        for s in stages where s.isEnabled { c = try await s.onChunkData(chunk: c); if c.skipUpload { break } }
        return c
    }

    public func executePostUpload(context: UploadContext, error: Error?) async {
        for s in stages where s.isEnabled { await s.onPostUpload(context: context, error: error) }
    }
}

// MARK: - Built-in Stages

public final class FileValidationStage: PipelineStage {
    public let name = "FileValidation"; public var isEnabled = true
    private let validators: [FileValidator]; private let logger: LogService?
    public init(validators: [FileValidator], logger: LogService? = nil) { self.validators = validators; self.logger = logger }
    public func onPreUpload(context: UploadContext) async throws -> Bool {
        for v in validators {
            let r = v.validate(fileURL: context.fileURL, metadata: context.metadata)
            if !r.isValid { throw UploadError.validationFailed(r.errors) }
        }
        return true
    }
}

public final class ChecksumStage: PipelineStage {
    public let name = "Checksum"; public var isEnabled = true
    private let checker: IntegrityChecker
    public init(checker: IntegrityChecker) { self.checker = checker }
    public func onChunkData(chunk: ChunkContext) async throws -> ChunkContext {
        var c = chunk; c.md5 = checker.checksum(data: c.data); return c
    }
}

public final class EncryptionStage: PipelineStage {
    public let name = "Encryption"; public var isEnabled = true
    private let enc: Encryption
    public init(encryption: Encryption) { self.enc = encryption }
    public func onChunkData(chunk: ChunkContext) async throws -> ChunkContext {
        var c = chunk; c.data = try enc.encrypt(data: c.data, chunkIndex: c.chunkIndex, uploadId: c.uploadId ?? ""); return c
    }
}

public final class ImageCompressionStage: PipelineStage {
    public let name = "ImageCompression"; public var isEnabled = true
    public var compressionQuality: CGFloat; public var maxDimension: CGFloat?
    public init(compressionQuality: CGFloat = 0.8, maxDimension: CGFloat? = 2048) {
        self.compressionQuality = compressionQuality; self.maxDimension = maxDimension
    }
    public func onPreUpload(context: UploadContext) async throws -> Bool {
        let exts = Set(["jpg","jpeg","png","heic","heif","bmp","tiff"])
        guard exts.contains(context.fileURL.pathExtension.lowercased()),
              let data = try? Data(contentsOf: context.fileURL),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return true }
        let ow = CGFloat(cg.width); let oh = CGFloat(cg.height)
        let s = maxDimension.map { min($0/ow, $0/oh, 1) } ?? 1
        let tw = floor(ow*s); let th = floor(oh*s)
        guard let cs = cg.colorSpace, let ctx = CGContext(data: nil, width: Int(tw), height: Int(th), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: cg.bitmapInfo.rawValue) else { return true }
        ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let ri = ctx.makeImage(), let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return true }
        CGImageDestinationAddImage(dest, ri, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return true }
        try (out as Data).write(to: context.fileURL, options: .atomic)
        context.fileSize = UInt64((out as Data).count); context.mimeType = "image/jpeg"; return true
    }
}

public final class NotificationStage: PipelineStage {
    public let name = "Notification"; public var isEnabled = true
    public var onStart: ((UploadContext) -> Void)?
    public var onProgress: ((String, Double) -> Void)?
    public var onComplete: ((UploadContext, Error?) -> Void)?
    public init() {}
    public func onPreUpload(context: UploadContext) async throws -> Bool { onStart?(context); return true }
    public func onPostUpload(context: UploadContext, error: Error?) async { onComplete?(context, error) }
}

public final class MetricsStage: PipelineStage {
    public let name = "Metrics"; public var isEnabled = true
    private let collector: MetricsCollectorProtocol
    public init(collector: MetricsCollectorProtocol) { self.collector = collector }
    public func onPreUpload(context: UploadContext) async throws -> Bool { collector.recordStart(taskId: context.taskId, fileSize: context.fileSize ?? 0); return true }
    public func onPostUpload(context: UploadContext, error: Error?) async {
        if let e = error { collector.recordFailure(taskId: context.taskId, error: e) }
        else { collector.recordCompletion(taskId: context.taskId) }
    }
}
