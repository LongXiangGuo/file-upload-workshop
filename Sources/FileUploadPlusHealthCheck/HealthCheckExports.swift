//  HealthCheckExports.swift
//  FileUploadPlusHealthCheck
//
//  Multi-endpoint health probing with latency ranking and failover.
//  Periodically probes upload endpoints, ranks by response time,
//  and provides automatic failover when the active endpoint degrades.

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - Health Status

public struct HealthStatus: Sendable {
    public let endpoint: URL
    public let isHealthy: Bool
    public let latencyMs: Double
    public let error: Error?
    public let timestamp: Date

    public init(endpoint: URL, isHealthy: Bool, latencyMs: Double, error: Error? = nil, timestamp: Date = Date()) {
        self.endpoint = endpoint; self.isHealthy = isHealthy; self.latencyMs = latencyMs
        self.error = error; self.timestamp = timestamp
    }
}

// MARK: - Probe Configuration

public struct HealthCheckConfig {
    /// Interval between full probing cycles.
    public var probeInterval: TimeInterval = 30
    /// Timeout per endpoint probe.
    public var probeTimeout: TimeInterval = 5
    /// Endpoints to monitor.
    public var endpoints: [URL] = []
    /// Max latency (ms) before an endpoint is considered degraded.
    public var latencyThresholdMs: Double = 2000
    /// Number of consecutive failures before marking unhealthy.
    public var failureThreshold: Int = 2
    /// Number of consecutive successes to mark healthy again.
    public var recoveryThreshold: Int = 2
    /// Automatically failover to best healthy endpoint on failure.
    public var autoFailover: Bool = true

    public init() {}
}

// MARK: - Health Check Manager

public final class HealthCheckManager: @unchecked Sendable {
    private let config: HealthCheckConfig
    private let logger: LogService?
    private let session: URLSession
    private let syncQueue = DispatchQueue(label: "com.upload.healthcheck")

    /// Latest health status per endpoint.
    private var statuses: [URL: HealthStatus] = [:]
    /// Consecutive failure count per endpoint.
    private var failureCounts: [URL: Int] = [:]
    /// Consecutive success count per endpoint (for recovery).
    private var successCounts: [URL: Int] = [:]
    /// Currently active (selected) endpoint.
    private var activeEndpoint: URL?
    /// Ranked healthy endpoints (sorted by latency, fastest first).
    private var rankedEndpoints: [URL] = []

    private var probeTask: Task<Void, Never>?
    private var isRunning = false

    /// Callback when active endpoint changes due to failover.
    public var onFailover: ((URL, URL) -> Void)?
    /// Callback when an endpoint health status changes.
    public var onHealthChange: ((HealthStatus) -> Void)?
    /// Callback after each probe cycle completes.
    public var onProbeCycleComplete: (([HealthStatus]) -> Void)?

    public init(config: HealthCheckConfig, logger: LogService? = nil) {
        self.config = config
        self.logger = logger
        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = config.probeTimeout
        sc.timeoutIntervalForResource = config.probeTimeout
        self.session = URLSession(configuration: sc)
        if let first = config.endpoints.first { activeEndpoint = first }
    }

    // MARK: - Public API

    /// Start periodic health probing.
    public func start() {
        var alreadyRunning = false
        syncQueue.sync { if isRunning { alreadyRunning = true } else { isRunning = true } }
        guard !alreadyRunning else { return }

        probeTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runProbeCycle()
            while !Task.isCancelled {
                var running = false
                self.syncQueue.sync { running = self.isRunning }
                guard running else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.config.probeInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self.syncQueue.sync { running = self.isRunning }
                guard running else { break }
                await self.runProbeCycle()
            }
        }
        logger?.info("HealthCheckManager started: \(config.endpoints.count) endpoints, interval=\(config.probeInterval)s")
    }

    /// Stop probing.
    public func stop() {
        syncQueue.sync { isRunning = false }
        probeTask?.cancel()
        probeTask = nil
        logger?.info("HealthCheckManager stopped")
    }

    /// Get the current best endpoint (lowest latency among healthy endpoints).
    public func bestEndpoint() -> URL? {
        syncQueue.sync { activeEndpoint }
    }

    /// Get ranked list of healthy endpoints (fastest first).
    public func healthyEndpoints() -> [URL] {
        syncQueue.sync { rankedEndpoints }
    }

    /// All latest health statuses.
    public func allStatuses() -> [HealthStatus] {
        syncQueue.sync { Array(statuses.values).sorted { $0.latencyMs < $1.latencyMs } }
    }

    /// Check whether a specific endpoint is healthy.
    public func isHealthy(_ endpoint: URL) -> Bool {
        syncQueue.sync { statuses[endpoint]?.isHealthy ?? true }
    }

    /// Force an immediate probe of all endpoints.
    public func probeNow() async {
        await runProbeCycle()
    }

    /// Notify manager of an upload failure on the current endpoint (triggers failover).
    public func recordFailure(on endpoint: URL) {
        var shouldFailover = false
        var currentActive: URL?

        syncQueue.sync {
            let count = (failureCounts[endpoint] ?? 0) + 1
            failureCounts[endpoint] = count
            successCounts[endpoint] = 0
            currentActive = activeEndpoint
            shouldFailover = count >= config.failureThreshold && config.autoFailover && endpoint == currentActive
        }

        if shouldFailover, let active = currentActive {
            updateHealth(endpoint: endpoint, healthy: false,
                        latencyMs: syncQueue.sync { statuses[endpoint]?.latencyMs ?? 9999 },
                        error: UploadError.internalError("Threshold exceeded"))
            performFailover(from: active)
        }
    }

    // MARK: - Probing

    private func runProbeCycle() async {
        let endpoints = config.endpoints
        guard !endpoints.isEmpty else { return }

        let results = await withTaskGroup(of: (URL, HealthStatus).self) { group in
            for endpoint in endpoints {
                group.addTask { await self.probeEndpoint(endpoint) }
            }
            var dict: [URL: HealthStatus] = [:]
            for await (url, status) in group { dict[url] = status }
            return dict
        }

        var failoverFrom: URL?
        var failoverTo: URL?
        var recoveredEndpoint: URL?

        syncQueue.sync {
            for (url, status) in results {
                statuses[url] = status
                if status.isHealthy {
                    failureCounts[url] = 0
                    let sc = (successCounts[url] ?? 0) + 1
                    successCounts[url] = sc
                    if sc >= config.recoveryThreshold, statuses[url]?.isHealthy == false {
                        recoveredEndpoint = url
                    }
                } else {
                    successCounts[url] = 0
                    failureCounts[url] = (failureCounts[url] ?? 0) + 1
                }
            }

            rankedEndpoints = results.values
                .filter { $0.isHealthy }
                .sorted { $0.latencyMs < $1.latencyMs }
                .map(\.endpoint)

            if let best = rankedEndpoints.first, activeEndpoint != best {
                failoverFrom = activeEndpoint
                activeEndpoint = best
                failoverTo = best
            }
        }

        if let ep = recoveredEndpoint {
            logger?.info("Endpoint recovered: \(ep.absoluteString)")
        }
        if let from = failoverFrom, let to = failoverTo {
            logger?.info("Failover: \(from.absoluteString.prefix(50)) -> \(to.absoluteString.prefix(50))")
            onFailover?(from, to)
        }

        for (_, status) in results { onHealthChange?(status) }
        onProbeCycleComplete?(Array(results.values))
    }

    private func probeEndpoint(_ endpoint: URL) async -> (URL, HealthStatus) {
        let start = Date()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = config.probeTimeout

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Date().timeIntervalSince(start) * 1000
            let httpResp = response as? HTTPURLResponse
            let healthy = httpResp.map { (200...399).contains($0.statusCode) } ?? false
            return (endpoint, HealthStatus(endpoint: endpoint, isHealthy: healthy, latencyMs: latency))
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            return (endpoint, HealthStatus(endpoint: endpoint, isHealthy: false, latencyMs: latency, error: error))
        }
    }

    // MARK: - Failover

    private func updateHealth(endpoint: URL, healthy: Bool, latencyMs: Double, error: Error?) {
        syncQueue.sync {
            statuses[endpoint] = HealthStatus(endpoint: endpoint, isHealthy: healthy,
                                              latencyMs: latencyMs, error: error)
        }
        onHealthChange?(HealthStatus(endpoint: endpoint, isHealthy: healthy, latencyMs: latencyMs, error: error))
    }

    private func performFailover(from failedEndpoint: URL) {
        let next: URL? = syncQueue.sync {
            rankedEndpoints.first(where: { $0 != failedEndpoint })
        }

        guard let next = next else {
            logger?.warn("No healthy failover endpoint available")
            return
        }

        syncQueue.sync { activeEndpoint = next }
        logger?.info("Failover: \(failedEndpoint.absoluteString.prefix(50)) -> \(next.absoluteString.prefix(50))")
        onFailover?(failedEndpoint, next)
    }
}
