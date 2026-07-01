import CloudGatewayKit
import Combine
import FirebaseAuth
import Foundation

@MainActor
final class CloudGatewayViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
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
    private let configManager: CloudGatewayConfigManager
    private var configState = CloudGatewayConfigManagerState()
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
        configManager = CloudGatewayConfigManager(
            tunnelManager: GatewayVPNManager(platform: platform),
            cache: CloudGatewayConfigCache(platform: platform)
        )
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
            apply(try await configManager.install(option))
        }
    }

    func startTunnel() async {
        await run {
            apply(try await configManager.startTunnel())
        }
    }

    func stopTunnel() async {
        await run {
            apply(try await configManager.stopTunnel())
        }
    }

    func removeTunnel() async {
        await run {
            apply(try await configManager.removeTunnel())
        }
    }

    func installStateLabel(for option: CloudGatewayClientOption) -> String? {
        switch configState.installState(for: option) {
        case .installed:
            return "Installed"
        case .updateAvailable:
            return "Update Available"
        case nil:
            return nil
        }
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
            apply(try await configManager.loadLocalState())
        } catch {
            errorText = error.localizedDescription
        }
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
        apply(try await configManager.applyRemoteState(regions: regions, clients: clients))
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

    private func clearRemoteState() {
        signedInEmail = nil
        signedInUid = nil
        role = nil
        configOptions = []
        staleText = nil
        lastRefreshText = nil
        remoteInvalidInstalledConfig = false
    }

    private func apply(_ state: CloudGatewayConfigManagerState) {
        configState = state
        configOptions = state.configOptions
        cachedSnapshot = state.cachedSnapshot
        tunnelStatus = state.tunnelStatus
        staleText = state.staleText
        remoteInvalidInstalledConfig = state.remoteInvalidInstalledConfig
        if let lastRefreshDate = state.lastRefreshDate {
            lastRefreshText = "Updated \(lastRefreshDate.formatted(date: .omitted, time: .shortened))"
        }
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
            if isSignedIn {
                apply(await configManager.markRemoteRefreshUnavailable())
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
