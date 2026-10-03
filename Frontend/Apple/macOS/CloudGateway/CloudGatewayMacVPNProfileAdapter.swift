import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation
import NetworkExtension

enum CloudGatewayMacVPNProfileError: Error {
    case invalidProfile
    case duplicateProfile
    case missingProfile
    case missingSession
    case stopTimedOut
    case invalidGrant
}

@MainActor
final class CloudGatewayMacVPNProfileAdapter: CloudGatewayMacProfileAdapter {
    private static let providerBundleIdentifier = "com.gocloudlaunch.gateway.tunnel.macos"
    var onChange: (() -> Void)?
    private let stopTimeout: TimeInterval
    private var managers: [NETunnelProviderManager] = []
    private var observers: [NSObjectProtocol] = []
    private var loadGeneration: UInt64 = 0

    init(stopTimeout: TimeInterval = 10) {
        self.stopTimeout = stopTimeout
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                guard let self, managers.contains(where: { $0.connection === connection }) else { return }
                onChange?()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        })
    }

    func installedProfiles() async throws -> [CloudGatewayMacInstalledProfile] {
        let loaded = try await loadManagers()
        let profiles = try loaded.filter(Self.isOwned).map(Self.profile)
        guard Set(profiles.map(\.identifier)).count == profiles.count else {
            throw CloudGatewayMacVPNProfileError.duplicateProfile
        }
        return profiles
    }

    func saveAndReload(_ config: CloudGatewayMacInstalledConfig) async throws {
        let loaded = try await loadManagers()
        let matching = try loaded.filter(Self.isOwned).filter { try Self.profile($0).identifier == config.identifier }
        guard matching.count <= 1 else { throw CloudGatewayMacVPNProfileError.duplicateProfile }
        let manager = matching.first ?? NETunnelProviderManager()
        let existing = try matching.first.map(Self.profile)
        try await CloudGatewayMacProfileReplacement.perform(existing: existing, stop: { @MainActor [stopTimeout] in
            try await MacVPNStopWaiter(connection: manager.connection, timeout: stopTimeout).stopAndWait()
        }, replace: { @MainActor in
            try Task.checkCancellation()
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = Self.providerBundleIdentifier
            protocolConfiguration.serverAddress = "\(config.snapshot.regionDisplayName) - \(config.snapshot.clientDisplayName)"
            protocolConfiguration.providerConfiguration = [
                CloudGatewayProviderConfigurationKey.tunnelIdentifier: config.identifier,
                CloudGatewayProviderConfigurationKey.configHash: config.snapshot.configHash,
                CloudGatewayMacProviderKey.configId: config.identifier,
                CloudGatewayMacProviderKey.secretReference: try config.reference.value,
            ]
            let otherActive = loaded.contains { other in
                other !== manager && Self.needsConfirmedStop(other.connection.status)
            }
            manager.localizedDescription = protocolConfiguration.serverAddress
            manager.protocolConfiguration = protocolConfiguration
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            manager.isEnabled = !otherActive
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            let reloaded = try Self.profile(manager)
            guard reloaded.identifier == config.identifier, reloaded.reference == (try config.reference) else {
                throw CloudGatewayMacVPNProfileError.invalidProfile
            }
        })
        _ = try await loadManagers()
    }

    func start(identifier: String, grant: String) async throws {
        guard Data(base64Encoded: grant)?.count == 32 else { throw CloudGatewayMacVPNProfileError.invalidGrant }
        let manager = try await installedManager(identifier: identifier)
        try Task.checkCancellation()
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
        }
        try await manager.loadFromPreferences()
        guard try Self.profile(manager).identifier == identifier else {
            throw CloudGatewayMacVPNProfileError.invalidProfile
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw CloudGatewayMacVPNProfileError.missingSession
        }
        try Task.checkCancellation()
        try session.startTunnel(options: [CloudGatewayMacProviderKey.startGrant: grant as NSString])
    }

    func stopAndWait(identifier: String) async throws {
        let manager = try await installedManager(identifier: identifier)
        try await MacVPNStopWaiter(connection: manager.connection, timeout: stopTimeout).stopAndWait()
    }

    private func installedManager(identifier: String) async throws -> NETunnelProviderManager {
        let loaded = try await loadManagers()
        let matching = try loaded.filter(Self.isOwned).filter { try Self.profile($0).identifier == identifier }
        guard matching.count <= 1 else { throw CloudGatewayMacVPNProfileError.duplicateProfile }
        guard let manager = matching.first else { throw CloudGatewayMacVPNProfileError.missingProfile }
        return manager
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        loadGeneration &+= 1
        let generation = loadGeneration
        let loaded = try await NETunnelProviderManager.loadAllFromPreferences()
        if generation == loadGeneration {
            managers = loaded.filter(Self.isOwned)
        }
        return loaded
    }

    private static func isOwned(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
    }

    private static func profile(_ manager: NETunnelProviderManager) throws -> CloudGatewayMacInstalledProfile {
        guard isOwned(manager),
              let metadata = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let identifier = metadata[CloudGatewayMacProviderKey.configId] as? String,
              !identifier.isEmpty,
              metadata[CloudGatewayProviderConfigurationKey.tunnelIdentifier] as? String == identifier,
              let value = metadata[CloudGatewayMacProviderKey.secretReference] as? String,
              let reference = try? CloudGatewayMacSecretReference(value: value) else {
            throw CloudGatewayMacVPNProfileError.invalidProfile
        }
        return CloudGatewayMacInstalledProfile(
            identifier: identifier,
            reference: reference,
            status: CloudGatewayTunnelStatus(manager.connection.status)
        )
    }

    private static func needsConfirmedStop(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: true
        case .invalid, .disconnected: false
        @unknown default: true
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

@MainActor
private final class MacVPNStopWaiter {
    private let connection: NEVPNConnection
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init(connection: NEVPNConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    func stopAndWait() async throws {
        try Task.checkCancellation()
        if connection.status == .disconnected || connection.status == .invalid { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(
                    forName: .NEVPNStatusDidChange,
                    object: connection,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.checkStatus() }
                }
                timeoutTask = Task { @MainActor [weak self, timeout] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        self?.finish(.failure(CloudGatewayMacVPNProfileError.stopTimedOut))
                    } catch {}
                }
                connection.stopVPNTunnel()
                checkStatus()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func checkStatus() {
        if connection.status == .disconnected || connection.status == .invalid {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
