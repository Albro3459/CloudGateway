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
    case invalidGrant
    case anotherProfileIsActive
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
        var profiles: [CloudGatewayMacInstalledProfile] = []
        for manager in loaded where Self.isOwned(manager) {
            var profile = try Self.profile(manager)
            if profile.needsConfirmedStop {
                let state = await MacVPNModeReader().read(manager.connection as? NETunnelProviderSession)
                let status = CloudGatewayTunnelStatus(manager.connection.status)
                profile = .init(identifier: profile.identifier, reference: profile.reference, status: status,
                                mode: profile.mode != nil && state?.configId == profile.identifier
                                    && (status == .connected || status == .reasserting) ? state?.mode : nil)
            }
            profiles.append(profile)
        }
        try CloudGatewayMacProfileMetadata.validateUnique(profiles)
        return profiles
    }

    func hasAnyActiveTunnel() async throws -> Bool {
        try await loadManagers().contains { Self.isOwned($0) && Self.needsConfirmedStop($0.connection.status) }
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
                CloudGatewayMacProviderKey.routingMode: config.mode.rawValue,
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
            guard reloaded.identifier == config.identifier, reloaded.reference == (try config.reference),
                  reloaded.mode == config.mode else {
                throw CloudGatewayMacVPNProfileError.invalidProfile
            }
        })
        _ = try await loadManagers()
    }

    func start(identifier: String, grant: String) async throws {
        try await start(identifier: identifier, grant: grant, displacingOtherProfiles: true)
    }

    func start(identifier: String, grant: String, displacingOtherProfiles: Bool) async throws {
        guard Data(base64Encoded: grant)?.count == 32 else { throw CloudGatewayMacVPNProfileError.invalidGrant }
        let manager = try await installedManager(identifier: identifier)
        try Task.checkCancellation()
        if !displacingOtherProfiles { try await requireNoOtherActiveProfile(identifier: identifier) }
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
        }
        try await manager.loadFromPreferences()
        let profile = try Self.profile(manager)
        guard profile.identifier == identifier, profile.mode != nil else {
            throw CloudGatewayMacVPNProfileError.invalidProfile
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw CloudGatewayMacVPNProfileError.missingSession
        }
        try Task.checkCancellation()
        if !displacingOtherProfiles { try await requireNoOtherActiveProfile(identifier: identifier) }
        try Task.checkCancellation()
        try session.startTunnel(options: [CloudGatewayMacProviderKey.startGrant: grant as NSString])
    }

    private func requireNoOtherActiveProfile(identifier: String) async throws {
        let loaded = try await loadManagers()
        for manager in loaded where Self.needsConfirmedStop(manager.connection.status) {
            guard Self.isOwned(manager), try Self.profile(manager).identifier == identifier else {
                throw CloudGatewayMacVPNProfileError.anotherProfileIsActive
            }
        }
    }

    func stopAndWait(identifier: String) async throws {
        try await stopAndWait(identifier: identifier, authorize: {})
    }

    func stopAndWait(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        let manager = try await installedManager(identifier: identifier)
        try await MacVPNStopWaiter(connection: manager.connection, timeout: stopTimeout).stopAndWait(authorize: authorize)
    }

    func remove(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        try await CloudGatewayMacProfileRemoval.perform(identifier: identifier, authorize: authorize, load: {
            try await self.loadManagers().filter(Self.isOwned)
        }, profile: { manager in
            let profile = try Self.profile(manager)
            // Fail closed when a future NE status maps to invalid
            guard profile.needsConfirmedStop == Self.needsConfirmedStop(manager.connection.status) else {
                throw CloudGatewayMacConfigError.unavailable
            }
            return profile
        }, reload: { manager in
            try await manager.loadFromPreferences()
        }, remove: { manager in
            try await manager.removeFromPreferences()
        })
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
              let metadata = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            throw CloudGatewayMacVPNProfileError.invalidProfile
        }
        return try CloudGatewayMacProfileMetadata.decode(metadata, status: CloudGatewayTunnelStatus(manager.connection.status))
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

    func stopAndWait(authorize: @escaping @MainActor @Sendable () throws -> Void = {}) async throws {
        try Task.checkCancellation()
        try authorize()
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
                        self?.finish(.failure(CloudGatewayMacConfigError.stopTimedOut))
                    } catch {}
                }
                do { try authorize() }
                catch {
                    finish(.failure(error))
                    return
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

@MainActor
private final class MacVPNModeReader {
    private var continuation: CheckedContinuation<CloudGatewayMacTunnelAppliedState?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func read(_ session: NETunnelProviderSession?) async -> CloudGatewayMacTunnelAppliedState? {
        guard let session, session.status == .connected || session.status == .reasserting else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.finish(nil)
            }
            do {
                try session.sendProviderMessage(CloudGatewayMacTunnelAppliedState.request) { [weak self] data in
                    let state = data.flatMap { try? JSONDecoder().decode(CloudGatewayMacTunnelAppliedState.self, from: $0) }
                    Task { @MainActor [weak self] in self?.finish(state) }
                }
            } catch { finish(nil) }
        }
    }

    private func finish(_ state: CloudGatewayMacTunnelAppliedState?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: state)
    }
}
