import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation

public struct CloudGatewayMacInstalledConfig: Codable, Equatable, Sendable {
    public static let secretService = "com.gocloudlaunch.gateway.macos.system-secret"
    public let accountId: String
    public let identifier: String
    public let snapshot: CloudGatewayConfigSnapshot

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

    public init(identifier: String, reference: CloudGatewayMacSecretReference, status: CloudGatewayTunnelStatus) {
        self.identifier = identifier
        self.reference = reference
        self.status = status
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
    func stopAndWait(identifier: String) async throws
}

public protocol CloudGatewayMacSnapshotPersisting: Sendable {
    func save(_ config: CloudGatewayMacInstalledConfig) async throws
}

public enum CloudGatewayMacConfigError: Error, Equatable, Sendable {
    case busy
    case cancelled
    case invalidConfig
    case profileInstallationFailed
    case secretCommitFailed
    case snapshotPersistenceFailed
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
        accountId: String
    ) async throws -> CloudGatewayMacInstalledConfig {
        try await runCommand { command in
            try await self.performInstall(option: option, accountId: accountId, command: command)
        }
    }

    private func performInstall(
        option: CloudGatewayClientOption,
        accountId: String,
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
        let installed = CloudGatewayMacInstalledConfig(
            accountId: accountId,
            identifier: identifier,
            snapshot: snapshot
        )
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

    public func connect(_ config: CloudGatewayMacInstalledConfig) async throws {
        try await runCommand { command in
            try await self.performConnect(config, command: command)
        }
    }

    private func performConnect(_ config: CloudGatewayMacInstalledConfig, command: UInt64) async throws {
        let reference = try config.reference
        guard try await secrets.isAvailable(reference: reference, configId: config.identifier) else {
            throw CloudGatewayMacConfigError.unavailable
        }
        try requireCurrent(command)
        let installedProfiles = try await profiles.installedProfiles()
        try requireCurrent(command)
        guard let selected = installedProfiles.first(where: {
            $0.identifier == config.identifier && $0.reference == reference
        }) else {
            throw CloudGatewayMacConfigError.unavailable
        }
        let activeProfiles = installedProfiles.filter(\.needsConfirmedStop)
        if selected.status == .connected || selected.status == .reasserting || selected.status == .connecting {
            return
        }
        for active in activeProfiles {
            try requireCurrent(command)
            try await profiles.stopAndWait(identifier: active.identifier)
        }
        try requireCurrent(command)
        let grant = try await secrets.authorizeStart(reference: reference, configId: config.identifier)
        try requireCurrent(command)
        try await profiles.start(identifier: config.identifier, grant: grant)
    }

    public func turnOff() async throws {
        try await runCommand { command in
            try await self.performTurnOff(command: command)
        }
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
