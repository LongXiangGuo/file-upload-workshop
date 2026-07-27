//  NetworkClient.swift
//  FileUploadPlusEngine

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
protocol NetworkClientDelegate: AnyObject {
    func networkClient(_ client: NetworkClient, didCompleteChunk taskId: String, chunkIndex: Int, data: Data?)
    func networkClient(_ client: NetworkClient, didFailChunk taskId: String, chunkIndex: Int, error: Error)
}

final class NetworkClient: NSObject {
    private let config: UploadConfiguration
    private var defaultSession: URLSession!
    private var backgroundSession: URLSession!
    private var taskCompletions: [Int: (Result<Data, Error>) -> Void] = [:]
    private var taskInfo: [Int: (taskId: String, chunkIndex: Int)] = [:]
    private let completionLock = NSLock()
    weak var delegate: NetworkClientDelegate?
    weak var logService: LogService?

    init(config: UploadConfiguration, mockProtocolClasses: [AnyClass]? = nil) {
        self.config = config
        super.init()
        setupSessions(mockProtocolClasses: mockProtocolClasses)
    }

    private func setupSessions(mockProtocolClasses: [AnyClass]? = nil) {
        let defaultConfig = URLSessionConfiguration.default
        defaultConfig.timeoutIntervalForRequest = config.requestTimeout
        defaultConfig.allowsCellularAccess = config.allowsCellularAccess
        if let mocks = mockProtocolClasses { defaultConfig.protocolClasses = mocks + (defaultConfig.protocolClasses ?? []) }
        defaultSession = URLSession(configuration: defaultConfig, delegate: self, delegateQueue: nil)

        if config.enableBackgroundUpload, mockProtocolClasses == nil {
            let bgConfig = URLSessionConfiguration.background(withIdentifier: config.backgroundSessionIdentifier)
            bgConfig.timeoutIntervalForRequest = config.requestTimeout
            bgConfig.timeoutIntervalForResource = 86400
            bgConfig.allowsCellularAccess = config.allowsCellularAccess
            bgConfig.isDiscretionary = false
            bgConfig.sessionSendsLaunchEvents = true
            backgroundSession = URLSession(configuration: bgConfig, delegate: self, delegateQueue: nil)
        } else {
            backgroundSession = defaultSession
        }
    }

    func uploadChunk(request: URLRequest, data: Data, taskId: String,
                     chunkIndex: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        var req = request
        req.httpBody = data
        defaultSession.dataTask(with: req) { _, response, error in
            if let error = error { completion(.failure(UploadError.networkError(error))); return }
            guard let resp = response as? HTTPURLResponse, 200..<300 ~= resp.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(UploadError.serverError(statusCode: status, message: nil))); return
            }
            completion(.success(Data()))
        }.resume()
    }

    func initUpload(url: URL, body: [String: Any], auth: Authentication?, signer: RequestSigner?,
                    completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = config.requestTimeout

        if let s = signer { do { req = try s.sign(request: req, body: req.httpBody) } catch { completion(.failure(UploadError.signFailed(error))); return } }
        if let a = auth { req = a.authenticate(request: req) }

        defaultSession.dataTask(with: req) { [weak self] data, response, error in
            if let error = error { completion(.failure(UploadError.networkError(error))); return }
            guard let resp = response as? HTTPURLResponse, 200..<300 ~= resp.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let msg = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(UploadError.serverError(statusCode: status, message: msg))); return
            }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadId = (json["uploadId"] ?? json["upload_id"] ?? json["data"]) as? String else {
                completion(.failure(UploadError.initFailed("No uploadId"))); return
            }
            self?.logService?.info("Init upload success, uploadId: \(uploadId.prefix(8))...")
            completion(.success(uploadId))
        }.resume()
    }

    func completeUpload(url: URL, uploadId: String, chunks: [ChunkState], auth: Authentication?, signer: RequestSigner?,
                        completion: @escaping (Result<Data, Error>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uploadId": uploadId, "parts": chunks.filter { $0.status == .completed }
            .map { ["partNumber": $0.index + 1, "md5": $0.md5 ?? "", "size": $0.size] }, "totalChunks": chunks.count]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let s = signer { do { req = try s.sign(request: req, body: req.httpBody) } catch { completion(.failure(UploadError.signFailed(error))); return } }
        if let a = auth { req = a.authenticate(request: req) }

        defaultSession.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(UploadError.networkError(error))); return }
            guard let resp = response as? HTTPURLResponse, 200..<300 ~= resp.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(UploadError.serverError(statusCode: status, message: nil))); return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }

    func abortUpload(url: URL, uploadId: String, auth: Authentication?, signer: RequestSigner?,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if let s = signer { do { req = try s.sign(request: req, body: nil) } catch { completion(.failure(error)); return } }
        if let a = auth { req = a.authenticate(request: req) }
        defaultSession.dataTask(with: req) { _, resp, error in
            if let error = error { completion(.failure(error)); return }
            completion(.success(()))
        }.resume()
    }

    func cancelAllTasks() {
        backgroundSession.getAllTasks { $0.forEach { $0.cancel() } }
        defaultSession.getAllTasks { $0.forEach { $0.cancel() } }
    }
}

extension NetworkClient: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completionLock.lock()
        let completion = taskCompletions[task.taskIdentifier]
        taskCompletions.removeValue(forKey: task.taskIdentifier)
        taskInfo.removeValue(forKey: task.taskIdentifier)
        completionLock.unlock()
        if let error = error { completion?(.failure(error)) }
        else { completion?(.success(Data())) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("UploadBackgroundEventsCompleted"), object: nil)
        }
    }
}
