//  ServicesExports.swift
//  FileUploadPlusServices
//
//  All service implementations: Logging, Auth, Validators,
//  URL Builders, Request Signers, Encryption.
//

import Foundation
import CryptoKit

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
import OSLog
import UniformTypeIdentifiers

// MARK: - Console Log Service

public final class ConsoleLogService: LogService {
    public var minimumLevel: LogLevel
    public init(minimumLevel: LogLevel = .debug) { self.minimumLevel = minimumLevel }
    public func log(_ entry: LogEntry) { print(entry.formatted) }
}

// MARK: - File Log Service (with rotation)

public final class FileLogService: LogService {
    public var minimumLevel: LogLevel
    private let fileURL: URL; private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.upload.filelogger")
    private let maxFileSize: UInt64; private let maxBackupCount: Int

    public init?(directory: URL? = nil, fileName: String = "upload.log",
                 minimumLevel: LogLevel = .info, maxFileSize: UInt64 = 10*1024*1024, maxBackupCount: Int = 5) {
        self.minimumLevel = minimumLevel; self.maxFileSize = maxFileSize; self.maxBackupCount = maxBackupCount
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UploadLogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
        guard let fh = try? FileHandle(forWritingTo: fileURL) else { return nil }
        self.fileHandle = fh; fh.seekToEndOfFile()
    }

    deinit { try? fileHandle.close() }

    public func log(_ entry: LogEntry) {
        queue.async { [weak self] in
            guard let self = self, let data = (entry.formatted + "\n").data(using: .utf8) else { return }
            self.fileHandle.write(data)
            if let a = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
               let s = a[.size] as? UInt64, s >= self.maxFileSize { self.rotate() }
        }
    }

    private func rotate() {
        try? fileHandle.close()
        for i in stride(from: maxBackupCount-1, through: 1, by: -1) {
            let o = fileURL.deletingPathExtension().appendingPathExtension("\(i).log")
            let n = fileURL.deletingPathExtension().appendingPathExtension("\(i+1).log")
            try? FileManager.default.removeItem(at: n); try? FileManager.default.moveItem(at: o, to: n)
        }
        let b = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: b); try? FileManager.default.moveItem(at: fileURL, to: b)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}

// MARK: - OSLog Service

@available(iOS 14.0, *)
public final class OSLogService: LogService {
    public var minimumLevel: LogLevel
    private let logger = os.Logger(subsystem: "com.upload", category: "Upload")
    public init(minimumLevel: LogLevel = .debug) { self.minimumLevel = minimumLevel }
    public func log(_ entry: LogEntry) {
        switch entry.level {
        case .debug: logger.debug("\(entry.formatted)")
        case .info:  logger.info("\(entry.formatted)")
        case .warn:  logger.warning("\(entry.formatted)")
        case .error: logger.error("\(entry.formatted)")
        case .fatal: logger.fault("\(entry.formatted)")
        }
    }
}

// MARK: - Composite Log Service

public final class CompositeLogService: LogService {
    public var minimumLevel: LogLevel { didSet { services.forEach { $0.minimumLevel = minimumLevel } } }
    private var services: [LogService]
    public init(services: [LogService]) { self.services = services; self.minimumLevel = services.map(\.minimumLevel).min() ?? .debug }
    public func add(_ service: LogService) { services.append(service) }
    public func log(_ entry: LogEntry) { services.forEach { $0.log(entry) } }
}

// MARK: - Callback Log Service (for UI binding)

/// Captures log entries into a closure — use to display library logs in app UI.
public final class CallbackLogService: LogService {
    public var minimumLevel: LogLevel
    public var onLog: ((LogEntry) -> Void)?

    public init(minimumLevel: LogLevel = .debug, onLog: ((LogEntry) -> Void)? = nil) {
        self.minimumLevel = minimumLevel
        self.onLog = onLog
    }

    public func log(_ entry: LogEntry) {
        guard minimumLevel <= entry.level else { return }
        onLog?(entry)
    }
}

// MARK: - Token Authentication

public final class TokenAuthentication: Authentication {
    private var accessToken: String; private let refreshToken: String?; private let refreshURL: URL?
    private var expiresAt: Date?; private let lock = NSLock()
    public var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expiresAt.map { Date() >= $0 } ?? false }

    public init(accessToken: String, refreshToken: String? = nil, refreshURL: URL? = nil, expiresIn: TimeInterval? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.refreshURL = refreshURL
        self.expiresAt = expiresIn.map { Date(timeIntervalSinceNow: $0) }
    }

    public func updateToken(_ token: String, expiresIn: TimeInterval? = nil) {
        lock.lock(); accessToken = token; expiresAt = expiresIn.map { Date(timeIntervalSinceNow: $0) }; lock.unlock()
    }

    public func authenticate(request: URLRequest) -> URLRequest {
        var r = request; lock.lock(); let t = accessToken; lock.unlock()
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization"); return r
    }

    public func refreshCredentials(completion: @escaping (Bool) -> Void) {
        guard let url = refreshURL, let rt = refreshToken else { completion(false); return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": rt])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else { completion(false); return }
            self?.updateToken(token, expiresIn: json["expires_in"] as? TimeInterval)
            completion(true)
        }.resume()
    }
}

// MARK: - HMAC Authentication

public final class HMACAuthentication: Authentication {
    private let accessKey: String; private let secretKey: String
    public var isExpired: Bool { false }
    public init(accessKey: String, secretKey: String) { self.accessKey = accessKey; self.secretKey = secretKey }
    public func authenticate(request: URLRequest) -> URLRequest {
        var r = request; let ts = String(Int64(Date().timeIntervalSince1970)); let nonce = UUID().uuidString
        let msg = "\(r.httpMethod ?? "GET")\n\(r.url?.path ?? "/")\n\(ts)\n\(nonce)"
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))).map { String(format: "%02x", $0) }.joined()
        r.setValue(accessKey, forHTTPHeaderField: "X-Access-Key"); r.setValue(ts, forHTTPHeaderField: "X-Timestamp")
        r.setValue(nonce, forHTTPHeaderField: "X-Nonce"); r.setValue(sig, forHTTPHeaderField: "X-Signature")
        return r
    }
    public func refreshCredentials(completion: @escaping (Bool) -> Void) { completion(true) }
}

// MARK: - File Validators

public final class FileSizeValidator: FileValidator {
    public let name = "FileSize"; public let minBytes: UInt64; public let maxBytes: UInt64
    public init(minBytes: UInt64 = 1, maxBytes: UInt64) { self.minBytes = minBytes; self.maxBytes = maxBytes }
    public func validate(fileURL: URL, metadata: [String: String]) -> ValidationResult {
        guard let a = try? FileManager.default.attributesOfItem(atPath: fileURL.path), let s = a[.size] as? UInt64 else { return .invalid("Cannot read size") }
        if s < minBytes { return .invalid("Too small: \(s)B < \(minBytes)B") }
        if s > maxBytes { return .invalid("Too large: \(s)B > \(maxBytes)B") }
        return .valid
    }
}

public final class FileTypeValidator: FileValidator {
    public let name = "FileType"
    private let exts: Set<String>; private let mimes: Set<String>
    public init(allowedExtensions: Set<String> = [], allowedMIMETypes: Set<String> = []) { self.exts = allowedExtensions; self.mimes = allowedMIMETypes }
    public func validate(fileURL: URL, metadata: [String: String]) -> ValidationResult {
        let e = fileURL.pathExtension.lowercased()
        if !exts.isEmpty, !exts.contains(e) { return .invalid("Extension '\(e)' not allowed") }
        if !mimes.isEmpty, let ut = UTType(filenameExtension: e), let m = ut.preferredMIMEType, !mimes.contains(m) { return .invalid("MIME '\(m)' not allowed") }
        return .valid
    }
}

public final class FileNameValidator: FileValidator {
    public let name = "FileName"; private let maxLen: Int; private let blocked: Set<String>
    public init(maxNameLength: Int = 255, blockedExtensions: Set<String> = ["exe","sh","php","dmg","app"]) { self.maxLen = maxNameLength; self.blocked = blockedExtensions }
    public func validate(fileURL: URL, metadata: [String: String]) -> ValidationResult {
        let n = fileURL.lastPathComponent
        if n.contains("/") || n.contains("\\") || n.contains("..") { return .invalid("Path traversal detected") }
        if n.hasPrefix(".") { return .invalid("Hidden files not allowed") }
        if n.count > maxLen { return .invalid("Name too long: \(n.count) > \(maxLen)") }
        let e = fileURL.pathExtension.lowercased()
        if !e.isEmpty, blocked.contains(e) { return .invalid("Blocked extension: \(e)") }
        return .valid
    }
}

public final class CompositeFileValidator: FileValidator {
    public let name = "Composite"; private let validators: [FileValidator]
    public init(validators: [FileValidator]) { self.validators = validators }
    public func validate(fileURL: URL, metadata: [String: String]) -> ValidationResult {
        var es: [String] = []
        for v in validators { let r = v.validate(fileURL: fileURL, metadata: metadata); if !r.isValid { es.append(contentsOf: r.errors) } }
        return es.isEmpty ? .valid : ValidationResult(isValid: false, errors: es)
    }
}

// MARK: - URL Builders

public final class StandardURLBuilder: URLBuilder {
    private let base: URL; private let ver: String?
    public init(baseURL: URL, apiVersion: String? = nil) { self.base = baseURL; self.ver = apiVersion }
    public func buildInitURL(taskId: String, metadata: [String: String]) -> URL { base.appendingPathComponent("\(ver.map{"/\($0)"} ?? "")/uploads/\(taskId)/init") }
    public func buildChunkURL(taskId: String, uploadId: String, chunkIndex: Int) -> URL { base.appendingPathComponent("\(ver.map{"/\($0)"} ?? "")/uploads/\(taskId)/chunks/\(chunkIndex)") }
    public func buildCompleteURL(taskId: String, uploadId: String) -> URL { base.appendingPathComponent("\(ver.map{"/\($0)"} ?? "")/uploads/\(taskId)/complete") }
    public func buildAbortURL(taskId: String, uploadId: String) -> URL { base.appendingPathComponent("\(ver.map{"/\($0)"} ?? "")/uploads/\(taskId)/abort") }
}

public final class TencentCOSURLBuilder: URLBuilder {
    private let ep: String; private let bk: String; private let aid: String?
    public init(endpoint: String, bucket: String, appId: String? = nil) { self.ep = endpoint; self.bk = bucket; self.aid = appId }
    private var host: String { aid.map { "\(bk)-\($0).\(ep)" } ?? "\(bk).\(ep)" }
    private func makeURL(path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path; if !query.isEmpty { c.queryItems = query }; return c.url!
    }
    public func buildInitURL(taskId: String, metadata: [String: String]) -> URL { makeURL(path: "/\(taskId)", query: [URLQueryItem(name: "uploads", value: "")]) }
    public func buildChunkURL(taskId: String, uploadId: String, chunkIndex: Int) -> URL { makeURL(path: "/\(taskId)", query: [URLQueryItem(name: "uploadId", value: uploadId), URLQueryItem(name: "partNumber", value: "\(chunkIndex+1)")]) }
    public func buildCompleteURL(taskId: String, uploadId: String) -> URL { makeURL(path: "/\(taskId)", query: [URLQueryItem(name: "uploadId", value: uploadId)]) }
    public func buildAbortURL(taskId: String, uploadId: String) -> URL { buildCompleteURL(taskId: taskId, uploadId: uploadId) }
}

// MARK: - Request Signers

public final class HMACSHA256Signer: RequestSigner {
    public let name = "HMAC-SHA256"; private let ak: String; private let sk: String
    public init(accessKey: String, secretKey: String) { self.ak = accessKey; self.sk = secretKey }
    public func sign(request: URLRequest, body: Data?) throws -> URLRequest {
        var r = request; let date = ISO8601DateFormatter().string(from: Date())
        r.setValue(date, forHTTPHeaderField: "X-Date"); r.setValue(ak, forHTTPHeaderField: "X-Access-Key")
        let bh = (body ?? Data()).withUnsafeBytes { SHA256.hash(data: $0).compactMap { String(format: "%02x", $0) }.joined() }
        let msg = "\(r.httpMethod ?? "GET")\n\(r.url?.path ?? "/")\n\(r.url?.query ?? "")\n\(date)\n\(bh)"
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: Data(sk.utf8)))).map { String(format: "%02x", $0) }.joined()
        r.setValue(sig, forHTTPHeaderField: "X-Signature"); return r
    }
}

public final class TencentCOSSigner: RequestSigner {
    public let name = "TencentCOS"; private let sid: String; private let sk: String
    public init(secretId: String, secretKey: String) { self.sid = secretId; self.sk = secretKey }
    public func sign(request: URLRequest, body: Data?) throws -> URLRequest {
        var r = request; let t = Int64(Date().timeIntervalSince1970)
        let kt = "\(t);\(t+3600)"
        let http = "\(r.httpMethod?.lowercased() ?? "put")\n\(r.url?.path ?? "/")\n\(r.url?.query ?? "")\n\n"
        let sigKey = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(kt.utf8), using: SymmetricKey(data: Data(sk.utf8))))
        let sig = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data("sha1\n\(kt)\n\(Data(Insecure.SHA1.hash(data: Data(http.utf8))).map { String(format: "%02x", $0) }.joined())\n".utf8), using: SymmetricKey(data: sigKey))).map { String(format: "%02x", $0) }.joined()
        r.setValue("q-sign-algorithm=sha1&q-ak=\(sid)&q-sign-time=\(kt)&q-key-time=\(kt)&q-header-list=&q-url-param-list=&q-signature=\(sig)", forHTTPHeaderField: "Authorization")
        return r
    }
}

// MARK: - Encryption

public final class AESEncryption: Encryption {
    private let key: SymmetricKey
    public init?(keyString: String) { guard let d = keyString.data(using: .utf8), d.count >= 32 else { return nil }; self.key = SymmetricKey(data: d.prefix(32)) }
    public func encrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data {
        let n = AES.GCM.Nonce(); let s = try AES.GCM.seal(data, using: key, nonce: n)
        var r = Data(); r.append(Data(n)); r.append(s.ciphertext); r.append(s.tag); return r
    }
    public func decrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data {
        guard data.count > 28 else { throw UploadError.encryptionFailed }
        let n = try AES.GCM.Nonce(data: data.prefix(12))
        let s = try AES.GCM.SealedBox(nonce: n, ciphertext: data.dropFirst(12).dropLast(16), tag: data.suffix(16))
        return try AES.GCM.open(s, using: key)
    }
}

public final class NoOpEncryption: Encryption {
    public init() {}
    public func encrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data { data }
    public func decrypt(data: Data, chunkIndex: Int, uploadId: String) throws -> Data { data }
}

// MARK: - Integrity Checkers

public final class SHA256IntegrityChecker: IntegrityChecker {
    public init() {}
    public func checksum(data: Data) -> String { SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined() }
    public func verifyFile(at url: URL, expectedChecksum: String) -> Bool { (try? Data(contentsOf: url)).map { checksum(data: $0) == expectedChecksum } ?? false }
}

public final class MD5IntegrityChecker: IntegrityChecker {
    public init() {}
    public func checksum(data: Data) -> String { Data(Insecure.MD5.hash(data: data)).map { String(format: "%02x", $0) }.joined() }
    public func verifyFile(at url: URL, expectedChecksum: String) -> Bool { (try? Data(contentsOf: url)).map { checksum(data: $0) == expectedChecksum } ?? false }
}
