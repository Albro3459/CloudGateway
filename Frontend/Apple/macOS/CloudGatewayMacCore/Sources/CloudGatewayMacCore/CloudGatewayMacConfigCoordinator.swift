import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

public struct CloudGatewayMacInstalledConfig: Codable, Equatable, Sendable {
    public static let secretService = "com.gocloudlaunch.gateway.macos.system-secret"
    public let accountId: String
    public let identifier: String
    public let snapshot: CloudGatewayConfigSnapshot
    public var mode: CloudGatewayRoutingMode = .full

    // Inject the account preference for each start, outside canonical cached config metadata
    private enum CodingKeys: String, CodingKey {
        case accountId, identifier, snapshot
    }

    public init(accountId: String, identifier: String, snapshot: CloudGatewayConfigSnapshot) {
        self.accountId = accountId
        self.identifier = identifier
        self.snapshot = snapshot
    }

    public var reference: CloudGatewayMacSecretReference {
        get throws {
            guard snapshot.secretReference.service == Self.secretService else {
                throw CloudGatewayMacConfigError.invalidConfig
            }
            return try CloudGatewayMacSecretReference(value: snapshot.secretReference.account)
        }
    }
}

public struct CloudGatewayMacInstalledProfile: Equatable, Sendable {
    public let identifier: String
    public let reference: CloudGatewayMacSecretReference
    public let status: CloudGatewayTunnelStatus
    public var mode: CloudGatewayRoutingMode?

    public init(identifier: String, reference: CloudGatewayMacSecretReference, status: CloudGatewayTunnelStatus, mode: CloudGatewayRoutingMode? = .full) {
        self.identifier = identifier
        self.reference = reference
        self.status = status
        self.mode = mode
    }

    public var needsConfirmedStop: Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting:
            return true
        case .invalid, .disconnected:
            return false
        }
    }
}

public protocol CloudGatewayMacProfileAdapter: Sendable {
    func installedProfiles() async throws -> [CloudGatewayMacInstalledProfile]
    func saveAndReload(_ config: CloudGatewayMacInstalledConfig) async throws
    func start(identifier: String, grant: String) async throws
    func start(identifier: String, grant: String, displacingOtherProfiles: Bool) async throws
    func stopAndWait(identifier: String) async throws
    func stopAndWait(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws
    func remove(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws
}

public extension CloudGatewayMacProfileAdapter {
    func start(identifier: String, grant: String, displacingOtherProfiles: Bool) async throws {
        if !displacingOtherProfiles {
            let current = try await installedProfiles()
            guard !current.contains(where: { $0.needsConfirmedStop && $0.identifier != identifier }) else {
                throw CloudGatewayMacConfigError.busy
            }
        }
        try await start(identifier: identifier, grant: grant)
    }
}

public protocol CloudGatewayMacSnapshotPersisting: Sendable {
    func save(_ config: CloudGatewayMacInstalledConfig) async throws
}

public enum CloudGatewayMacConfigError: Error, Equatable, Sendable {
    case busy
    case clientActive
    case cancelled
    case invalidConfig
    case profileInstallationFailed
    case secretCommitFailed
    case snapshotPersistenceFailed
    case stopTimedOut
    case unavailable
}

public actor CloudGatewayMacConfigCoordinator {
    private let secrets: any CloudGatewayMacSecretClient
    private let profiles: any CloudGatewayMacProfileAdapter
    private let snapshots: any CloudGatewayMacSnapshotPersisting
    private var busy = false
    private var generation: UInt64 = 0
    private var cancelActiveCommand: (@Sendable () -> Void)?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        secrets: any CloudGatewayMacSecretClient,
        profiles: any CloudGatewayMacProfileAdapter,
        snapshots: any CloudGatewayMacSnapshotPersisting
    ) {
        self.secrets = secrets
        self.profiles = profiles
        self.snapshots = snapshots
    }

    public func cancelPendingWork() {
        generation &+= 1
        cancelActiveCommand?()
    }

    public func waitForPendingWork() async {
        guard busy else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    public func install(
        option: CloudGatewayClientOption,
        accountId: String,
        mode: CloudGatewayRoutingMode = .full
    ) async throws -> CloudGatewayMacInstalledConfig {
        try await runCommand { command in
            try await self.performInstall(option: option, accountId: accountId, mode: mode, command: command)
        }
    }

    private func performInstall(
        option: CloudGatewayClientOption,
        accountId: String,
        mode: CloudGatewayRoutingMode,
        command: UInt64
    ) async throws -> CloudGatewayMacInstalledConfig {
        guard !accountId.isEmpty, option.client.hasUsableConfig,
              option.region?.enabled == true else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        let identifier = "\(accountId)/\(option.client.regionId)/\(option.client.clientId)"
        let config = try CloudGatewayConfigSelection.wireGuardConfig(from: option)
        // Reject malformed configs before transferring any private material
        _ = try CloudGatewayWireGuardConfigParser.parse(config.rawValue, named: "CloudGateway")
        try requireCurrent(command)
        let reference = try await secrets.install(configId: identifier, config: config)
        do {
            try requireCurrent(command)
        } catch {
            await rollbackIfUnreferenced(reference, identifier: identifier)
            throw error
        }
        let snapshot = CloudGatewayConfigSnapshot(
            clientId: option.client.clientId,
            regionId: option.client.regionId,
            clientName: option.client.clientName,
            regionDisplayName: option.regionDisplayName,
            status: option.client.status,
            configHash: CloudGatewayConfigHash.make(for: config),
            secretReference: CloudGatewayConfigSecretReference(
                service: CloudGatewayMacInstalledConfig.secretService,
                account: reference.value
            ),
            readAt: Date(),
            updatedAt: option.client.updatedAt,
            assignedTunnelIpv4: option.client.assignedTunnelIpv4,
            serverEndpointIpv4: option.client.serverEndpointIpv4,
            serverEndpointHostname: option.client.serverEndpointHostname
        )
        var installed = CloudGatewayMacInstalledConfig(
            accountId: accountId,
            identifier: identifier,
            snapshot: snapshot
        )
        installed.mode = mode
        do {
            try await profiles.saveAndReload(installed)
        } catch {
            try await recoverFailedInstallation(installed)
            try requireCurrent(command)
            throw CloudGatewayMacConfigError.profileInstallationFailed
        }
        try await persistInstallation(installed)
        try requireCurrent(command)
        return installed
    }

    private func persistInstallation(_ installed: CloudGatewayMacInstalledConfig) async throws {
        let reference = try installed.reference
        // A referenced secret must finish its commit even if the command was cancelled
        try await Task { [secrets, snapshots] in
            do {
                try await secrets.commit(reference: reference, configId: installed.identifier)
            } catch {
                throw CloudGatewayMacConfigError.secretCommitFailed
            }
            do {
                try await snapshots.save(installed)
            } catch {
                throw CloudGatewayMacConfigError.snapshotPersistenceFailed
            }
        }.value
    }

    private func recoverFailedInstallation(_ config: CloudGatewayMacInstalledConfig) async throws {
        let reference = try config.reference
        let installed = await Task { [profiles] in
            try? await profiles.installedProfiles()
        }.value
        // A failed preferences read cannot prove the saved profile is absent
        guard let installed else { return }
        if installed.contains(where: { $0.identifier == config.identifier && $0.reference == reference }) {
            try await persistInstallation(config)
        } else if !installed.contains(where: { $0.reference == reference }) {
            await Task { [secrets] in
                try? await secrets.rollback(reference: reference, configId: config.identifier)
            }.value
        }
    }

    public func restore(_ config: CloudGatewayMacInstalledConfig) async throws {
        try await runCommand { command in
            let reference = try config.reference
            guard config.snapshot.status == .active else {
                throw CloudGatewayMacConfigError.unavailable
            }
            try await self.requireAvailableSecret(reference: reference, identifier: config.identifier)
            try await self.requireCurrent(command)
            do { try await self.profiles.saveAndReload(config) }
            catch {
                try await self.requireCurrent(command)
                throw CloudGatewayMacConfigError.profileInstallationFailed
            }
            try await self.requireCurrent(command)
        }
    }

    // False means the matching profile was already active, so no start was submitted
    @discardableResult
    public func connect(_ config: CloudGatewayMacInstalledConfig, displacingOtherProfiles: Bool = true) async throws -> Bool {
        try await runCommand { command in
            try await self.performConnect(config, command: command, displacingOtherProfiles: displacingOtherProfiles)
        }
    }

    private func performConnect(_ config: CloudGatewayMacInstalledConfig, command: UInt64, displacingOtherProfiles: Bool) async throws -> Bool {
        let reference = try config.reference
        try await requireAvailableSecret(reference: reference, identifier: config.identifier)
        try requireCurrent(command)
        let installedProfiles = try await profiles.installedProfiles()
        try requireCurrent(command)
        guard let selected = installedProfiles.first(where: {
            $0.identifier == config.identifier && $0.reference == reference
        }) else {
            throw CloudGatewayMacConfigError.unavailable
        }
        let activeProfiles = installedProfiles.filter(\.needsConfirmedStop)
        guard displacingOtherProfiles || !activeProfiles.contains(where: { $0.identifier != config.identifier }) else {
            throw CloudGatewayMacConfigError.busy
        }
        if selected.status == .connecting, selected.mode != config.mode {
            throw CloudGatewayMacConfigError.busy
        }
        if selected.mode == config.mode,
           selected.status == .connected || selected.status == .reasserting || selected.status == .connecting {
            return false
        }
        for active in activeProfiles {
            try requireCurrent(command)
            try await profiles.stopAndWait(identifier: active.identifier)
        }
        try requireCurrent(command)
        if selected.mode != config.mode {
            do { try await profiles.saveAndReload(config) }
            catch {
                try requireCurrent(command)
                throw CloudGatewayMacConfigError.profileInstallationFailed
            }
            try requireCurrent(command)
        }
        let grant = try await secrets.authorizeStart(reference: reference, configId: config.identifier)
        try requireCurrent(command)
        try await profiles.start(identifier: config.identifier, grant: grant, displacingOtherProfiles: displacingOtherProfiles)
        return true
    }

    public func turnOff() async throws {
        try await runCommand { command in
            try await self.performTurnOff(command: command)
        }
    }

    public func disconnectClient(
        identifier: String,
        authorize: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        try await runCommand { command in
            try await authorize()
            let installed = try await self.profiles.installedProfiles()
            try await authorize()
            try await self.requireCurrent(command)
            let targets = installed.filter { $0.identifier == identifier }
            guard targets.count <= 1 else { throw CloudGatewayMacConfigError.unavailable }
            if targets.first?.needsConfirmedStop == true {
                try await self.profiles.stopAndWait(identifier: identifier, authorize: authorize)
                try await authorize()
            }
        }
    }

    public func validateInactiveClient(
        identifier: String,
        authorize: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        try await runCommand { command in
            try await self.requireInactiveProfile(identifier: identifier, command: command, authorize: authorize)
        }
    }

    public func removeClientProfile(
        identifier: String,
        authorize: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        try await runCommand { command in
            try await self.requireInactiveProfile(identifier: identifier, command: command, authorize: authorize)
            try await self.profiles.remove(identifier: identifier, authorize: authorize)
            try await authorize()
            try await self.requireCurrent(command)
        }
    }

    private func requireInactiveProfile(
        identifier: String,
        command: UInt64,
        authorize: @MainActor @Sendable () throws -> Void
    ) async throws {
        guard CloudGatewayMacProfileMetadata.validIdentifier(identifier) else {
            throw CloudGatewayMacConfigError.invalidConfig
        }
        try requireCurrent(command)
        try await authorize()
        try requireCurrent(command)
        let installed = try await profiles.installedProfiles()
        try await authorize()
        try requireCurrent(command)
        _ = try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: installed)
    }

    private func requireAvailableSecret(reference: CloudGatewayMacSecretReference, identifier: String) async throws {
        let available: Bool
        do {
            available = try await secrets.isAvailable(reference: reference, configId: identifier)
        } catch CloudGatewayMacSecretError.storageFailure, CloudGatewayMacSecretError.unavailable {
            // A saved reference can outlive the extension's Keychain access
            throw CloudGatewayMacConfigError.unavailable
        }
        guard available else { throw CloudGatewayMacConfigError.unavailable }
    }

    private func performTurnOff(command: UInt64) async throws {
        let installed = try await profiles.installedProfiles()
        for profile in installed where profile.needsConfirmedStop {
            try requireCurrent(command)
            try await profiles.stopAndWait(identifier: profile.identifier)
        }
    }

    private func runCommand<Result: Sendable>(
        _ operation: @escaping @Sendable (UInt64) async throws -> Result
    ) async throws -> Result {
        let command = try beginCommand()
        defer {
            busy = false
            cancelActiveCommand = nil
            let waiters = drainWaiters
            drainWaiters = []
            waiters.forEach { $0.resume() }
        }
        let task = Task { try await operation(command) }
        cancelActiveCommand = { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try requireCurrent(command)
            return result
        } catch is CancellationError {
            throw CloudGatewayMacConfigError.cancelled
        }
    }

    private func beginCommand() throws -> UInt64 {
        guard !busy else { throw CloudGatewayMacConfigError.busy }
        busy = true
        return generation
    }

    private func requireCurrent(_ command: UInt64) throws {
        guard generation == command, !Task.isCancelled else {
            throw CloudGatewayMacConfigError.cancelled
        }
    }

    private func rollbackIfUnreferenced(
        _ reference: CloudGatewayMacSecretReference,
        identifier: String
    ) async {
        await Task { [profiles, secrets] in
            // A failed preferences read cannot prove the saved profile is absent
            guard let installed = try? await profiles.installedProfiles(),
                  !installed.contains(where: { $0.reference == reference }) else { return }
            try? await secrets.rollback(reference: reference, configId: identifier)
        }.value
    }
}
