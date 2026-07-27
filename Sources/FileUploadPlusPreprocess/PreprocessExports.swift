//  PreprocessExports.swift
//  FileUploadPlusPreprocess
//
//  File preprocessing chain: transform files before upload.
//  Stages: EXIF stripping, HEIC→JPEG, resizing, video transcoding, watermarking.

import Foundation
import ImageIO

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
import CoreImage
import UniformTypeIdentifiers

// MARK: - Preprocess Stage Protocol

public protocol PreprocessStage: AnyObject {
    var name: String { get }
    var isEnabled: Bool { get set }
    /// Transform the file at sourceURL, writing output to a new URL. Return the output URL.
    func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL
}

// MARK: - Preprocess Chain

public final class PreprocessChain {
    private var stages: [PreprocessStage] = []
    private let logger: LogService?
    private let workingDir: URL

    public init(stages: [PreprocessStage] = [], logger: LogService? = nil) {
        self.stages = stages
        self.logger = logger
        self.workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileUploadPlusPreprocess", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
    }

    public func addStage(_ stage: PreprocessStage) { stages.append(stage) }

    /// Run all enabled stages sequentially. Returns the final output URL.
    public func process(fileAt sourceURL: URL, metadata: [String: String] = [:]) async throws -> URL {
        var currentURL = sourceURL
        for stage in stages where stage.isEnabled {
            logger?.debug("Preprocess: \(stage.name) on \(sourceURL.lastPathComponent)")
            currentURL = try await stage.process(fileAt: currentURL, metadata: metadata)
        }
        return currentURL
    }

    /// Clean up temporary files produced by the chain.
    public func cleanup() {
        try? FileManager.default.removeItem(at: workingDir)
    }
}

// MARK: - EXIF Stripper

/// Strips all EXIF/metadata from images for privacy.
public final class EXIFStripper: PreprocessStage {
    public let name = "EXIFStripper"
    public var isEnabled = true

    public init() {}

    public func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return sourceURL
        }

        let outURL = tempURL(from: sourceURL)
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, type, 1, nil) else {
            return sourceURL
        }
        CGImageDestinationAddImage(dest, cgImage, nil) // no metadata dict = stripped
        guard CGImageDestinationFinalize(dest) else { return sourceURL }
        return outURL
    }
}

// MARK: - HEIC to JPEG Converter

/// Converts HEIC/HEIF images to JPEG for universal compatibility.
public final class HEICtoJPEGConverter: PreprocessStage {
    public let name = "HEICtoJPEG"
    public var isEnabled = true
    public var compressionQuality: CGFloat

    public init(compressionQuality: CGFloat = 0.85) {
        self.compressionQuality = compressionQuality
    }

    public func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "heic" || ext == "heif" else { return sourceURL }

        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return sourceURL
        }

        let outURL = tempURL(from: sourceURL, newExtension: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return sourceURL
        }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return sourceURL }
        return outURL
    }
}

// MARK: - Image Resizer

/// Resizes images to fit within max dimensions while preserving aspect ratio.
public final class ImageResizer: PreprocessStage {
    public let name = "ImageResizer"
    public var isEnabled = true
    public var maxWidth: CGFloat
    public var maxHeight: CGFloat
    public var compressionQuality: CGFloat

    public init(maxWidth: CGFloat = 4096, maxHeight: CGFloat = 4096, compressionQuality: CGFloat = 0.85) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.compressionQuality = compressionQuality
    }

    public func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL {
        guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return sourceURL
        }

        let ow = CGFloat(cgImage.width)
        let oh = CGFloat(cgImage.height)
        guard ow > maxWidth || oh > maxHeight else { return sourceURL }

        let scale = min(maxWidth / ow, maxHeight / oh, 1.0)
        let tw = floor(ow * scale)
        let th = floor(oh * scale)

        guard let cs = cgImage.colorSpace,
              let ctx = CGContext(data: nil, width: Int(tw), height: Int(th),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return sourceURL
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))

        guard let ri = ctx.makeImage() else { return sourceURL }

        let outURL = tempURL(from: sourceURL, newExtension: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return sourceURL
        }
        CGImageDestinationAddImage(dest, ri, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return sourceURL }
        return outURL
    }
}

// MARK: - Video Transcoder (Hook)

/// Placeholder for video transcoding. Extend with AVFoundation for real transcoding.
public final class VideoTranscoder: PreprocessStage {
    public let name = "VideoTranscoder"
    public var isEnabled = true

    /// Supported input formats for transcoding.
    public var sourceFormats: Set<String> = ["mov", "avi", "mkv"]
    /// Target output format.
    public var targetFormat: String = "mp4"
    /// Max bitrate in bps (nil = keep original).
    public var maxBitrate: Int?
    /// Max resolution (nil = keep original).
    public var maxResolution: CGSize?

    private let transcoder: (@Sendable (URL, [String: String]) async throws -> URL)?

    /// Inject a custom transcoding function (e.g. AVAssetExportSession-based).
    public init(transcoder: (@Sendable (URL, [String: String]) async throws -> URL)? = nil) {
        self.transcoder = transcoder
    }

    public func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL {
        guard sourceFormats.contains(sourceURL.pathExtension.lowercased()),
              let transcoder = transcoder else {
            return sourceURL
        }
        return try await transcoder(sourceURL, metadata)
    }
}

// MARK: - Watermarker (Hook)

/// Placeholder for watermarking images. Inject a custom render function.
public final class Watermarker: PreprocessStage {
    public let name = "Watermarker"
    public var isEnabled = true

    /// Image types eligible for watermarking.
    public var eligibleFormats: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    /// Watermark position.
    public enum Position { case topLeft, topRight, bottomLeft, bottomRight, center }
    public var position: Position = .bottomRight
    /// Padding from edge in points.
    public var padding: CGFloat = 20

    private let renderer: (@Sendable (CGContext, CGSize) -> Void)?

    /// Inject a custom watermark rendering closure.
    /// - Parameter renderer: Called with the CGContext and image size; draw your watermark here.
    public init(renderer: (@Sendable (CGContext, CGSize) -> Void)? = nil) {
        self.renderer = renderer
    }

    public func process(fileAt sourceURL: URL, metadata: [String: String]) async throws -> URL {
        guard eligibleFormats.contains(sourceURL.pathExtension.lowercased()),
              let renderer = renderer,
              let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return sourceURL
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard let cs = cgImage.colorSpace,
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return sourceURL
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        renderer(ctx, CGSize(width: w, height: h))

        guard let ri = ctx.makeImage() else { return sourceURL }

        let outURL = tempURL(from: sourceURL)
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, type, 1, nil) else {
            return sourceURL
        }
        CGImageDestinationAddImage(dest, ri, nil)
        guard CGImageDestinationFinalize(dest) else { return sourceURL }
        return outURL
    }
}

// MARK: - Helpers

private func tempURL(from sourceURL: URL, newExtension: String? = nil) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileUploadPlusPreprocess", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let base = sourceURL.deletingPathExtension().lastPathComponent
    let ext = newExtension ?? sourceURL.pathExtension
    let name = "\(base)_\(UUID().uuidString.prefix(8)).\(ext)"
    return dir.appendingPathComponent(name)
}
