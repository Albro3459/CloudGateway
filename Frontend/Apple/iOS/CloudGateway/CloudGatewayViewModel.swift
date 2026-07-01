import CloudGatewayKit
import Combine
import FirebaseAuth
import Foundation

@MainActor
final class CloudGatewayViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var debugWireGuardConfig = ""
    @Published private(set) var signedInEmail: String?
    @Published private(set) var signedInUid: String?
    @Published private(set) var role: String?
    @Published private(set) var configOptions = [CloudGatewayClientOption]()
    @Published private(set) var cachedSnapshot: CloudGatewayConfigSnapshot?
    @Published private(set) var tunnelStatus: GatewayTunnelStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorText: String?
    @Published private(set) var staleText: String?
    @Published private(set) var lastRefreshText: String?
    @Published private(set) var remoteInvalidInstalledConfig = false

    private let service = CloudGatewayFirebaseService()
    private let manager: GatewayVPNManager
    private let cache: CloudGatewayConfigCache
    private var authHandle: AuthStateDidChangeListenerHandle?

    var isSignedIn: Bool {
        signedInUid != nil
    }

    var statusText: String {
        tunnelStatus?.displayName ?? "Not installed"
    }

    var startDisabled: Bool {
        isWorking
            || tunnelStatus == nil
            || tunnelStatus == .connected
            || tunnelStatus == .connecting
            || remoteInvalidInstalledConfig
    }

    init() {
        let platform = GatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.gocloudlaunch.gateway",
            appBundleIdentifier: "com.gocloudlaunch.gateway",
            providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
            tunnelDisplayName: "CloudGateway"
        )
        manager = GatewayVPNManager(platform: platform)
        cache = CloudGatewayConfigCache(platform: platform)
        authHandle = service.addAuthStateListener { [weak self] user in
            Task { @MainActor in
                await self?.handleAuthState(user)
            }
        }
        Task {
            await loadLocalState()
        }
    }

    deinit {
        if let authHandle {
            service.removeAuthStateListener(authHandle)
        }
    }

    func signIn() async {
        await run {
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
                throw CloudGatewayAppError.accessDenied("Enter a valid email address.")
            }
            guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudGatewayAppError.accessDenied("Password is required.")
            }
            let user = try await service.signIn(email: trimmedEmail, password: password)
            try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: true)
            password = ""
        }
    }

    func signOut() async {
        await run {
            try service.signOut()
            clearRemoteState()
        }
    }

    func refresh() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: false)
        }
    }

    func install(_ option: CloudGatewayClientOption) async {
        await run {
            let snapshot = try CloudGatewayConfigSelection.snapshot(from: option)
            try await manager.installTunnel(snapshot.tunnelConfiguration())
            try await cache.save(snapshot)
            cachedSnapshot = snapshot
            staleText = nil
            remoteInvalidInstalledConfig = false
            await refreshStatus()
        }
    }

    func installDebugConfig() async {
        await run {
            let config = try GatewayWireGuardConfig(debugWireGuardConfig)
            let snapshot = CloudGatewayConfigSnapshot(
                clientId: "debug",
                regionId: "debug",
                clientName: "Debug Config",
                regionDisplayName: "Debug",
                status: .active,
                wireGuardConfig: config.rawValue,
                readAt: Date(),
                updatedAt: nil
            )
            try await manager.installTunnel(GatewayTunnelConfiguration(identifier: "debug", wireGuardConfig: config))
            try await cache.save(snapshot)
            cachedSnapshot = snapshot
            staleText = nil
            remoteInvalidInstalledConfig = false
            await refreshStatus()
        }
    }

    func startTunnel() async {
        await run {
            guard !remoteInvalidInstalledConfig else {
                throw CloudGatewayAppError.accessDenied("The installed config is no longer active remotely. Choose another config before starting.")
            }
            try await manager.startTunnel()
            await refreshStatus()
        }
    }

    func stopTunnel() async {
        await run {
            try await manager.stopTunnel()
            await refreshStatus()
        }
    }

    func removeTunnel() async {
        await run {
            try await manager.removeTunnel()
            try await cache.clear()
            cachedSnapshot = nil
            tunnelStatus = nil
            staleText = nil
            remoteInvalidInstalledConfig = false
        }
    }

    func installStateLabel(for option: CloudGatewayClientOption) -> String? {
        guard let cachedSnapshot,
              cachedSnapshot.clientId == option.client.clientId,
              cachedSnapshot.regionId == option.client.regionId else {
            return nil
        }
        if CloudGatewayConfigSelection.configMatches(cachedSnapshot, option: option) {
            return "Installed"
        }
        return "Update Available"
    }

    func installButtonTitle(for option: CloudGatewayClientOption) -> String {
        installStateLabel(for: option) == nil ? "Install" : "Install Update"
    }

    private func handleAuthState(_ user: User?) async {
        if let user {
            signedInEmail = user.email
            signedInUid = user.uid
            if !isWorking && configOptions.isEmpty {
                await refresh()
            }
        } else {
            clearRemoteState()
        }
    }

    private func loadLocalState() async {
        do {
            cachedSnapshot = try await cache.load()
        } catch {
            errorText = error.localizedDescription
        }
        await refreshStatus()
    }

    private func loadRemoteState(for user: User) async throws {
        signedInEmail = user.email
        signedInUid = user.uid
        let token = try await service.idToken(for: user)
        let access = try await service.checkAccess(idToken: token)
        role = (try? await service.fetchUserRole(uid: user.uid)) ?? access.role
        let regions = try await service.fetchEnabledRegions()
        guard !regions.isEmpty else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        let clients = try await service.fetchOwnedClients(uid: user.uid)
        configOptions = CloudGatewayConfigSelection.usableOptions(clients: clients, regions: regions)
        cachedSnapshot = try await cache.load()
        updateStaleState()
        lastRefreshText = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
        await refreshStatus()
    }

    private func loadRemoteStateOrSignOut(
        for user: User,
        signOutOnAnyFailure: Bool
    ) async throws {
        do {
            try await loadRemoteState(for: user)
        } catch let loadError as CloudGatewayAppError {
            if signOutOnAnyFailure || shouldSignOut(after: loadError) {
                try? service.signOut()
                clearRemoteState()
            }
            throw loadError
        } catch {
            if signOutOnAnyFailure {
                try? service.signOut()
                clearRemoteState()
            }
            throw error
        }
    }

    private func shouldSignOut(after error: CloudGatewayAppError) -> Bool {
        switch error {
        case .accessDenied(_), .noEnabledRegions:
            return true
        case .missingCurrentUser, .invalidAPIResponse:
            return false
        }
    }

    private func updateStaleState() {
        remoteInvalidInstalledConfig = false
        guard let cachedSnapshot else {
            staleText = nil
            return
        }
        if cachedSnapshot.clientId == "debug" {
            staleText = "Debug config is installed."
            return
        }
        guard let matchingOption = CloudGatewayConfigSelection.matchingOption(for: cachedSnapshot, in: configOptions) else {
            staleText = "The last installed config is not active remotely. Choose another config before starting."
            remoteInvalidInstalledConfig = true
            return
        }
        if CloudGatewayConfigSelection.configMatches(cachedSnapshot, option: matchingOption) {
            staleText = nil
        } else {
            staleText = "The installed config has changed remotely. Install the update to refresh the local tunnel."
        }
    }

    private func refreshStatus() async {
        do {
            tunnelStatus = try await manager.installedStatus()
        } catch GatewayVPNError.missingInstalledTunnel {
            tunnelStatus = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearRemoteState() {
        signedInEmail = nil
        signedInUid = nil
        role = nil
        configOptions = []
        staleText = nil
        lastRefreshText = nil
        remoteInvalidInstalledConfig = false
    }

    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        errorText = nil
        defer {
            isWorking = false
        }

        do {
            try await operation()
        } catch {
            errorText = error.localizedDescription
            if isSignedIn, cachedSnapshot != nil, staleText == nil {
                staleText = "Unable to refresh remote state. The last installed config remains available offline."
                remoteInvalidInstalledConfig = false
            }
        }
    }
}

private extension GatewayTunnelStatus {
    var displayName: String {
        switch self {
        case .invalid:
            "Invalid"
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .reasserting:
            "Reasserting"
        case .disconnecting:
            "Disconnecting"
        }
    }
}
