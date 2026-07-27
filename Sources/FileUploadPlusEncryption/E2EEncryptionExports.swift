//  E2EEncryptionExports.swift
//  FileUploadPlusEncryption
//
//  End-to-end encryption: client-side encrypt, server never sees plaintext.
//  Zero-knowledge workflow: key never leaves the device.
//  Supports AES-GCM and ChaCha20-Poly1305 via CryptoKit.

import Foundation
import CryptoKit

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Key Material

/// Represents a symmetric key for file encryption. Never persisted to disk by default.
public struct EncryptionKey: Sendable {
    public let raw: SymmetricKey
    public let keyId: String // Unique identifier for key rotation tracking

    public init(raw: SymmetricKey, keyId: String = UUID().uuidString) {
        self.raw = raw; self.keyId = keyId
    }

    /// Generate a fresh 256-bit key.
    public static func generate() -> EncryptionKey {
        EncryptionKey(raw: SymmetricKey(size: .bits256))
    }

    /// Derive a key from a password using HKDF-SHA256.
    public static func derive(from password: String, salt: Data, keyId: String? = nil) -> EncryptionKey {
        let keyMaterial = SymmetricKey(data: Data(password.utf8))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: keyMaterial, salt: salt,
            outputByteCount: 32
        )
        return EncryptionKey(raw: derived, keyId: keyId ?? UUID().uuidString)
    }
}

// MARK: - Encrypted File Metadata

public struct EncryptedFileHeader: Codable, Sendable {
    public let keyId: String
    public let algorithm: String // "AES-GCM" or "ChaCha20-Poly1305"
    public let nonce: Data        // 12 bytes for AES-GCM, 12 bytes for ChaCha20
    public let tag: Data          // 16 bytes authentication tag
    public let originalSize: UInt64
    public let chunkSize: Int     // Size of each encrypted chunk (including auth tag)

    public init(keyId: String, algorithm: String, nonce: Data, tag: Data,
                originalSize: UInt64, chunkSize: Int) {
        self.keyId = keyId; self.algorithm = algorithm; self.nonce = nonce
        self.tag = tag; self.originalSize = originalSize; self.chunkSize = chunkSize
    }
}

// MARK: - E2E Encryptor

/// Encrypts file data before upload. Only the holder of the key can decrypt.
public final class E2EEncryptor {
    public enum Algorithm: String, Sendable {
        case aesGCM = "AES-GCM"
        case chaCha20Poly1305 = "ChaCha20-Poly1305"
    }

    private let key: EncryptionKey
    private let algorithm: Algorithm

    public init(key: EncryptionKey, algorithm: Algorithm = .aesGCM) {
        self.key = key; self.algorithm = algorithm
    }

    /// Encrypt an entire file, returning a new encrypted file URL and its header.
    public func encryptFile(at sourceURL: URL) throws -> (encryptedURL: URL, header: EncryptedFileHeader) {
        let data = try Data(contentsOf: sourceURL)
        let (encrypted, header) = try encrypt(data: data)
        let outURL = tempURL(named: sourceURL.lastPathComponent + ".enc")
        try encrypted.write(to: outURL, options: .atomic)
        return (outURL, header)
    }

    /// Encrypt a single data blob (chunk or whole file).
    public func encrypt(data: Data) throws -> (encrypted: Data, header: EncryptedFileHeader) {
        switch algorithm {
        case .aesGCM:
            return try encryptAESGCM(data: data)
        case .chaCha20Poly1305:
            return try encryptChaCha20(data: data)
        }
    }

    /// Encrypt a stream chunk, maintaining state for chunked encryption.
    public func encryptChunk(data: Data, chunkIndex: Int, nonce: Data) throws -> Data {
        switch algorithm {
        case .aesGCM:
            let nonce12 = nonce.prefix(12)
            let fullNonce = nonceWithCounter(base: Data(nonce12), counter: UInt32(chunkIndex))
            let sealed = try AES.GCM.seal(data, using: key.raw, nonce: AES.GCM.Nonce(data: fullNonce))
            return sealed.ciphertext + sealed.tag
        case .chaCha20Poly1305:
            let nonce12 = nonce.prefix(12)
            let fullNonce = nonceWithCounter(base: Data(nonce12), counter: UInt32(chunkIndex))
            let sealed = try ChaChaPoly.seal(data, using: key.raw, nonce: ChaChaPoly.Nonce(data: fullNonce))
            return sealed.ciphertext + sealed.tag
        }
    }

    // MARK: - Private

    private func encryptAESGCM(data: Data) throws -> (Data, EncryptedFileHeader) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key.raw, nonce: nonce)
        let header = EncryptedFileHeader(
            keyId: key.keyId, algorithm: Algorithm.aesGCM.rawValue,
            nonce: Data(nonce), tag: sealed.tag,
            originalSize: UInt64(data.count),
            chunkSize: data.count + sealed.tag.count
        )
        return (sealed.ciphertext + sealed.tag, header)
    }

    private func encryptChaCha20(data: Data) throws -> (Data, EncryptedFileHeader) {
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(data, using: key.raw, nonce: nonce)
        let header = EncryptedFileHeader(
            keyId: key.keyId, algorithm: Algorithm.chaCha20Poly1305.rawValue,
            nonce: Data(nonce), tag: sealed.tag,
            originalSize: UInt64(data.count),
            chunkSize: data.count + sealed.tag.count
        )
        return (sealed.ciphertext + sealed.tag, header)
    }

    private func nonceWithCounter(base: Data, counter: UInt32) -> Data {
        var full = Data(base)
        var c = counter.bigEndian
        full.append(Data(bytes: &c, count: MemoryLayout<UInt32>.size))
        return full
    }
}

// MARK: - E2E Decryptor (Client-Side Recovery)

public final class E2EDecryptor {
    public static func decrypt(data: Data, header: EncryptedFileHeader, key: EncryptionKey) throws -> Data {
        guard header.algorithm == E2EEncryptor.Algorithm.aesGCM.rawValue ||
              header.algorithm == E2EEncryptor.Algorithm.chaCha20Poly1305.rawValue else {
            throw UploadError.internalError("Unknown algorithm: \(header.algorithm)")
        }

        let tagSize = 16
        guard data.count > tagSize else { throw UploadError.internalError("Data too short") }

        let ciphertext = data.prefix(data.count - tagSize)
        let tag = data.suffix(tagSize)

        if header.algorithm == E2EEncryptor.Algorithm.aesGCM.rawValue {
            let nonce = try AES.GCM.Nonce(data: header.nonce)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: key.raw)
        } else {
            let nonce = try ChaChaPoly.Nonce(data: header.nonce)
            let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(sealed, using: key.raw)
        }
    }
}

// MARK: - Zero-Knowledge Key Manager

/// Manages encryption keys with optional secure enclave storage.
/// Keys are identified by keyId; the raw key material never leaves the device.
public final class ZeroKnowledgeKeyManager {
    private var keys: [String: EncryptionKey] = [:]
    private let lock = NSLock()

    public init() {}

    /// Generate and store a new key.
    @discardableResult
    public func generateKey() -> EncryptionKey {
        let key = EncryptionKey.generate()
        lock.lock(); keys[key.keyId] = key; lock.unlock()
        return key
    }

    /// Store a key received via secure channel (e.g. QR code, secure link).
    public func storeKey(_ key: EncryptionKey) {
        lock.lock(); keys[key.keyId] = key; lock.unlock()
    }

    /// Retrieve a key by ID.
    public func getKey(id: String) -> EncryptionKey? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }

    /// Delete a key (for key rotation / revocation).
    public func deleteKey(id: String) {
        lock.lock(); keys.removeValue(forKey: id); lock.unlock()
    }

    public var keyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }
}

// MARK: - Helper

private func tempURL(named name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileUploadPlusE2E", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}
