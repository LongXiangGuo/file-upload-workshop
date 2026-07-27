//  UploadError.swift
//  FileUploadPlusCore

import Foundation

public enum UploadError: Error, CustomStringConvertible {
    case fileNotFound
    case fileAccessDenied
    case invalidFileSize
    case chunkReadFailed
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case authenticationFailed
    case encryptionFailed
    case integrityCheckFailed
    case validationFailed([String])
    case uploadAlreadyExists
    case uploadNotFound
    case uploadCancelled
    case uploadCompleted
    case circuitBreakerOpen
    case signFailed(Error)
    case initFailed(String)
    case completeFailed(String)
    case internalError(String)

    public var description: String {
        switch self {
        case .fileNotFound: return "File not found"
        case .fileAccessDenied: return "File access denied"
        case .invalidFileSize: return "Invalid file size"
        case .chunkReadFailed: return "Failed to read chunk data"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .serverError(let code, let msg): return "Server error \(code): \(msg ?? "unknown")"
        case .authenticationFailed: return "Authentication failed"
        case .encryptionFailed: return "Encryption failed"
        case .integrityCheckFailed: return "Integrity check failed"
        case .validationFailed(let errors): return "Validation failed: \(errors.joined(separator: "; "))"
        case .uploadAlreadyExists: return "Upload task already exists"
        case .uploadNotFound: return "Upload task not found"
        case .uploadCancelled: return "Upload cancelled by user"
        case .uploadCompleted: return "Upload already completed"
        case .circuitBreakerOpen: return "Circuit breaker is open"
        case .signFailed(let e): return "Request signing failed: \(e.localizedDescription)"
        case .initFailed(let msg): return "Upload init failed: \(msg)"
        case .completeFailed(let msg): return "Upload complete failed: \(msg)"
        case .internalError(let s): return "Internal error: \(s)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkError, .serverError, .chunkReadFailed, .initFailed, .completeFailed, .circuitBreakerOpen:
            return true
        default: return false
        }
    }
}
