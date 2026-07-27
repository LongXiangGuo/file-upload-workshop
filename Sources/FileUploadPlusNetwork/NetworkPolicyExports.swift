//  NetworkPolicyExports.swift
//  FileUploadPlusNetwork
//
//  Network-aware upload policy: Wi-Fi only, data plan awareness,
//  and reactive network condition monitoring via NWPathMonitor.

import Foundation
import Network

#if canImport(FileUploadPlusCore)
import FileUploadPlusCore
#endif
#if os(iOS)
import UIKit
#endif

// MARK: - Network Type

public enum NetworkType: Sendable {
    case wifi
    case cellular
    case wired
    case other
    case unavailable
}

// MARK: - Network Policy

public struct NetworkPolicy: Sendable {
    public enum Mode: Sendable {
        /// Allow uploads on any connection.
        case unrestricted
        /// Only allow on Wi-Fi or wired connections.
        case wifiOnly
        /// Allow cellular only if not marked as expensive (respects Low Data Mode).
        case avoidExpensive
        /// Custom predicate evaluated before each upload.
        case custom(@Sendable (NetworkType, Bool) -> Bool)
    }

    public var mode: Mode
    /// Maximum file size (bytes) allowed on cellular when not strictly wifiOnly.
    public var cellularMaxFileSize: UInt64?
    /// Minimum battery level (0.0–1.0) required for cellular uploads.
    public var cellularMinBattery: Float?

    public init(mode: Mode = .avoidExpensive) {
        self.mode = mode
    }

    /// Evaluate whether an upload should proceed given current conditions.
    public func shouldUpload(networkType: NetworkType, isExpensive: Bool, fileSize: UInt64 = 0) -> Bool {
        switch mode {
        case .unrestricted:
            return true
        case .wifiOnly:
            return networkType == .wifi || networkType == .wired
        case .avoidExpensive:
            if isExpensive { return false }
            if case .cellular = networkType, let maxSize = cellularMaxFileSize, fileSize > maxSize {
                return false
            }
            if case .cellular = networkType, let minBattery = cellularMinBattery {
                let level = currentBatteryLevel()
                if level > 0, level < minBattery { return false }
            }
            return true
        case .custom(let predicate):
            return predicate(networkType, isExpensive)
        }
    }
}

// MARK: - Network Monitor

public final class NetworkMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.upload.network.monitor")
    private let logger: LogService?

    private var _currentType: NetworkType = .unavailable
    private var _isExpensive: Bool = false
    private var _isConstrained: Bool = false
    private var _availableInterfaces: Set<String> = []

    /// Current network type.
    public var currentType: NetworkType { monitorQueue.sync { _currentType } }
    /// Whether the current connection is marked expensive (e.g. cellular, hotspot).
    public var isExpensive: Bool { monitorQueue.sync { _isExpensive } }
    /// Whether the connection is in Low Data Mode.
    public var isConstrained: Bool { monitorQueue.sync { _isConstrained } }
    /// Currently available interface types.
    public var availableInterfaces: Set<String> { monitorQueue.sync { _availableInterfaces } }

    /// Fires on every network path change.
    public var onNetworkChange: ((NetworkType, Bool) -> Void)?
    /// Fires when transitioning from unavailable to available.
    public var onNetworkAvailable: (() -> Void)?
    /// Fires when transitioning from available to unavailable.
    public var onNetworkLost: (() -> Void)?

    public init(logger: LogService? = nil) {
        self.logger = logger
        self.monitor = NWPathMonitor()
    }

    /// Start monitoring network changes.
    public func start() {
        var wasAvailable = false
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let type = self.classify(path: path)
            let isAvailable = path.status == .satisfied

            self.monitorQueue.sync {
                self._currentType = type
                self._isExpensive = path.isExpensive
                self._isConstrained = path.isConstrained
                self._availableInterfaces = self.collectInterfaces(path: path)
            }

            self.logger?.debug("Network change: \(type), expensive=\(path.isExpensive), constrained=\(path.isConstrained)")
            self.onNetworkChange?(type, path.isExpensive)

            if isAvailable, !wasAvailable { self.onNetworkAvailable?() }
            if !isAvailable, wasAvailable { self.onNetworkLost?() }
            wasAvailable = isAvailable
        }
        monitor.start(queue: monitorQueue)
        logger?.info("NetworkMonitor started")
    }

    /// Stop monitoring.
    public func stop() {
        monitor.cancel()
        logger?.info("NetworkMonitor stopped")
    }

    /// Check current path once (non-continuous).
    public func currentPath() -> (type: NetworkType, isExpensive: Bool, isConstrained: Bool) {
        monitorQueue.sync { (_currentType, _isExpensive, _isConstrained) }
    }

    // MARK: - Helpers

    private func classify(path: NWPath) -> NetworkType {
        if path.status != .satisfied { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    private func collectInterfaces(path: NWPath) -> Set<String> {
        var set = Set<String>()
        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
            (.loopback, "loopback"), (.other, "other"),
        ]
        for (type, name) in interfaces where path.usesInterfaceType(type) { set.insert(name) }
        return set
    }
}

// MARK: - Network-Aware Upload Guard

/// Convenience guard that combines NetworkMonitor + NetworkPolicy for upload gating.
public final class NetworkUploadGuard {
    private let monitor: NetworkMonitor
    public var policy: NetworkPolicy

    public init(monitor: NetworkMonitor, policy: NetworkPolicy = NetworkPolicy()) {
        self.monitor = monitor; self.policy = policy
    }

    /// Check whether an upload is currently allowed.
    public func canUpload(fileSize: UInt64 = 0) -> Bool {
        let (type, expensive, _) = monitor.currentPath()
        return policy.shouldUpload(networkType: type, isExpensive: expensive, fileSize: fileSize)
    }

    /// Throw if upload is blocked by current policy.
    public func guardUpload(fileSize: UInt64 = 0) throws {
        let (type, expensive, _) = monitor.currentPath()
        guard policy.shouldUpload(networkType: type, isExpensive: expensive, fileSize: fileSize) else {
            throw UploadError.internalError("Upload blocked by network policy: type=\(type), expensive=\(expensive)")
        }
    }

    /// Wait (with timeout) for an eligible network before proceeding.
    public func waitForEligibleNetwork(timeout: TimeInterval = 60, fileSize: UInt64 = 0) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if canUpload(fileSize: fileSize) { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw UploadError.internalError("Timed out waiting for eligible network")
    }
}

// MARK: - Battery Helper

private func currentBatteryLevel() -> Float {
    #if os(iOS)
    return UIDevice.current.batteryLevel
    #else
    return 1.0
    #endif
}
