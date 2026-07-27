//  CDNExports.swift
//  FileUploadPlusCDN
//
//  CDN edge routing: multi-region endpoint selection, geo-based routing,
//  and latency-optimized edge node selection for upload endpoints.

import Foundation

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
// MARK: - CDN Edge Node

public struct CDNEdgeNode: Sendable {
    public let region: String         // e.g. "us-east-1", "ap-southeast-1"
    public let displayName: String    // e.g. "US East (Virginia)"
    public let endpoint: URL
    public let latitude: Double
    public let longitude: Double
    public var priority: Int = 0      // Lower = higher priority
    public var weight: Double = 1.0   // Load balancing weight
    public var isActive: Bool = true

    public init(region: String, displayName: String, endpoint: URL,
                latitude: Double = 0, longitude: Double = 0,
                priority: Int = 0, weight: Double = 1.0, isActive: Bool = true) {
        self.region = region; self.displayName = displayName; self.endpoint = endpoint
        self.latitude = latitude; self.longitude = longitude
        self.priority = priority; self.weight = weight; self.isActive = isActive
    }
}

// MARK: - CDN Router Configuration

public struct CDNRouterConfig {
    /// Edge nodes available for routing.
    public var nodes: [CDNEdgeNode] = []
    /// How the best node is selected.
    public enum Strategy: Sendable {
        case priority          // Lowest priority value first
        case weightedRandom    // Random selection weighted by node weight
        case latencyBased      // Probe latency and pick fastest
        case geoClosest(_ lat: Double, _ lon: Double) // Closest by haversine distance
    }
    public var strategy: Strategy = .priority
    /// Probed latencies (populated when using latencyBased strategy).
    public var latencies: [URL: Double] = [:]

    public init() {}
}

// MARK: - CDN Router

public final class CDNRouter {
    private var config: CDNRouterConfig
    private let logger: LogService?

    public init(config: CDNRouterConfig, logger: LogService? = nil) {
        self.config = config; self.logger = logger
    }

    /// Update routing configuration.
    public func updateConfig(_ config: CDNRouterConfig) { self.config = config }

    /// Add an edge node.
    public func addNode(_ node: CDNEdgeNode) { config.nodes.append(node) }

    /// Select the best endpoint based on configured strategy.
    public func selectEndpoint() -> URL? {
        let activeNodes = config.nodes.filter(\.isActive)
        guard !activeNodes.isEmpty else { return nil }

        switch config.strategy {
        case .priority:
            return activeNodes.min { $0.priority < $1.priority }?.endpoint

        case .weightedRandom:
            return weightedRandom(nodes: activeNodes)?.endpoint

        case .latencyBased:
            return activeNodes.min { a, b in
                (config.latencies[a.endpoint] ?? Double.greatestFiniteMagnitude)
                    < (config.latencies[b.endpoint] ?? Double.greatestFiniteMagnitude)
            }?.endpoint

        case .geoClosest(let lat, let lon):
            return activeNodes.min { a, b in
                haversine(lat1: lat, lon1: lon, lat2: a.latitude, lon2: a.longitude)
                    < haversine(lat1: lat, lon1: lon, lat2: b.latitude, lon2: b.longitude)
            }?.endpoint
        }
    }

    /// Get the top N best endpoints for the current strategy.
    public func topEndpoints(_ count: Int = 3) -> [URL] {
        let activeNodes = config.nodes.filter(\.isActive)
        guard !activeNodes.isEmpty else { return [] }

        switch config.strategy {
        case .priority:
            return activeNodes.sorted { $0.priority < $1.priority }.prefix(count).map(\.endpoint)

        case .latencyBased:
            return activeNodes.sorted { a, b in
                (config.latencies[a.endpoint] ?? Double.greatestFiniteMagnitude)
                    < (config.latencies[b.endpoint] ?? Double.greatestFiniteMagnitude)
            }.prefix(count).map(\.endpoint)

        case .geoClosest(let lat, let lon):
            return activeNodes.sorted { a, b in
                haversine(lat1: lat, lon1: lon, lat2: a.latitude, lon2: a.longitude)
                    < haversine(lat1: lat, lon1: lon, lat2: b.latitude, lon2: b.longitude)
            }.prefix(count).map(\.endpoint)

        case .weightedRandom:
            return activeNodes.shuffled().prefix(count).map(\.endpoint)
        }
    }

    /// Update the latency for a specific endpoint (e.g. from health check probing).
    public func recordLatency(endpoint: URL, latencyMs: Double) {
        config.latencies[endpoint] = latencyMs
        logger?.debug("CDN latency: \(endpoint.absoluteString.prefix(50)) = \(String(format: "%.1f", latencyMs))ms")
    }

    /// Mark a node as inactive (for circuit breaking).
    public func deactivateNode(region: String) {
        guard let idx = config.nodes.firstIndex(where: { $0.region == region }) else { return }
        config.nodes[idx].isActive = false
        logger?.warn("CDN node deactivated: \(region)")
    }

    /// Reactivate a previously deactivated node.
    public func activateNode(region: String) {
        guard let idx = config.nodes.firstIndex(where: { $0.region == region }) else { return }
        config.nodes[idx].isActive = true
        logger?.info("CDN node reactivated: \(region)")
    }

    // MARK: - Private

    private func weightedRandom(nodes: [CDNEdgeNode]) -> CDNEdgeNode? {
        let totalWeight = nodes.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nodes.randomElement() }
        var r = Double.random(in: 0..<totalWeight)
        for node in nodes {
            r -= node.weight
            if r <= 0 { return node }
        }
        return nodes.last
    }

    private func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0 // Earth radius in km
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - CDN Presets

extension CDNRouterConfig {
    /// Common CDN edge regions, useful as a starting point.
    public static func awsS3Regions() -> [CDNEdgeNode] {
        [
            CDNEdgeNode(region: "us-east-1", displayName: "US East (Virginia)",
                        endpoint: URL(string: "https://s3.us-east-1.amazonaws.com")!,
                        latitude: 38.9517, longitude: -77.4489, priority: 0),
            CDNEdgeNode(region: "us-west-2", displayName: "US West (Oregon)",
                        endpoint: URL(string: "https://s3.us-west-2.amazonaws.com")!,
                        latitude: 45.5231, longitude: -122.6765, priority: 1),
            CDNEdgeNode(region: "eu-west-1", displayName: "EU (Ireland)",
                        endpoint: URL(string: "https://s3.eu-west-1.amazonaws.com")!,
                        latitude: 53.3498, longitude: -6.2603, priority: 2),
            CDNEdgeNode(region: "ap-southeast-1", displayName: "Asia Pacific (Singapore)",
                        endpoint: URL(string: "https://s3.ap-southeast-1.amazonaws.com")!,
                        latitude: 1.3521, longitude: 103.8198, priority: 3),
            CDNEdgeNode(region: "ap-northeast-1", displayName: "Asia Pacific (Tokyo)",
                        endpoint: URL(string: "https://s3.ap-northeast-1.amazonaws.com")!,
                        latitude: 35.6762, longitude: 139.6503, priority: 4),
        ]
    }
}
