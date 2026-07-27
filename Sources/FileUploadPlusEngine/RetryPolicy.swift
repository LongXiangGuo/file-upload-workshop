//  RetryPolicy.swift
//  FileUploadPlusEngine

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    func shouldRetry(attempt: Int, error: Error) -> Bool {
        guard attempt <= maxAttempts else { return false }
        if let uploadError = error as? UploadError { return uploadError.isRetryable }
        return (error as NSError).domain == NSURLErrorDomain
    }

    func nextDelay(attempt: Int) -> TimeInterval {
        let delay = baseDelay * pow(2.0, Double(attempt - 1))
        let jittered = delay * Double.random(in: 0.8...1.2)
        return min(jittered, maxDelay)
    }
}
