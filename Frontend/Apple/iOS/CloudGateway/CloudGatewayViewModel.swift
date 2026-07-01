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
    @Published private(set) var regions = [CloudGatewayRegion]()
    @Published private(set) var clientOptions = [CloudGatewayClientOption]()
    @Published private(set) var configOptions = [CloudGatewayClientOption]()
    @Published private(set) var cachedSnapshot: CloudGatewayConfigSnapshot?
    @Published private(set) var tunnelStatus: GatewayTunnelStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorText: String?
    @Published private(set) var staleText: String?
    @Published private(set) var lastRefreshText: String?
    @Published private(set) var lastSyncText: String?
    @Published private(set) var remoteInvalidInstalledConfig = false
    @Published var selectedRegionId: String?
    @Published var selectedClientId: String?
    @Published var newClientName = ""

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

    var selectedRegion: CloudGatewayRegion? {
        guard let selectedRegionId else {
            return nil
        }
        return regions.first { $0.regionId == selectedRegionId }
    }

    var filteredClientOptions: [CloudGatewayClientOption] {
        CloudGatewayConfigSelection.clientOptions(in: selectedRegionId, options: clientOptions)
    }

    var selectedClientOption: CloudGatewayClientOption? {
        guard let selectedClientId else {
            return nil
        }
        return filteredClientOptions.first { $0.client.clientId == selectedClientId }
    }

    var selectedConfigOption: CloudGatewayClientOption? {
        guard let selectedClientOption,
              selectedClientOption.client.hasUsableConfig,
              selectedClientOption.region?.enabled == true else {
            return nil
        }
        return selectedClientOption
    }

    var canSyncSelectedRegion: Bool {
        role == "admin" && selectedRegion != nil && !isWorking
    }

    var createDisabled: Bool {
        isWorking || selectedRegion == nil || selectedRegion?.capacity?.isAtCapacity == true
    }

    var deleteDisabled: Bool {
        isWorking || selectedClientOption == nil
    }

    var installDisabled: Bool {
        isWorking || selectedConfigOption == nil
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

    func syncSelectedRegion() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            guard let regionId = selectedRegionId else {
                throw CloudGatewayAppError.missingSelectedRegion
            }
            guard role == "admin" else {
                throw CloudGatewayAppError.accessDenied("Admin access is required to sync a region.")
            }
            let token = try await service.idToken(for: user)
            let response = try await service.syncRegion(regionId: regionId, idToken: token)
            lastSyncText = "\(response.regionId): +\(response.added) ~\(response.updated) -\(response.removed)"
            try await loadRemoteState(for: user)
        }
    }

    func createClient() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            guard let regionId = selectedRegionId else {
                throw CloudGatewayAppError.missingSelectedRegion
            }
            let token = try await service.idToken(for: user)
            let created = try await service.createClient(
                regionId: regionId,
                clientName: newClientName,
                idToken: token
            )
            newClientName = ""
            selectedClientId = nil
            try await loadRemoteState(for: user, existingClients: [created])
        }
    }

    func deleteSelectedClient() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            guard let selectedClientOption else {
                throw CloudGatewayAppError.accessDenied("Choose a config to delete.")
            }
            let token = try await service.idToken(for: user)
            let response = try await service.deleteClient(
                clientId: selectedClientOption.client.clientId,
                userId: user.uid,
                regionId: selectedClientOption.client.regionId,
                idToken: token
            )
            selectedClientId = nil
            apply(try await configManager.removeInstalledConfigIfMatches(
                clientId: response.clientId,
                regionId: response.regionId
            ))
            try await loadRemoteState(for: user)
        }
    }

    func installSelectedClient() async {
        guard let selectedConfigOption else {
            errorText = "Choose an active config with an available WireGuard configuration."
            return
        }
        await install(selectedConfigOption)
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
        try await loadRemoteState(for: user, existingClients: [])
    }

    private func loadRemoteState(for user: User, existingClients: [CloudGatewayClient]) async throws {
        signedInEmail = user.email
        signedInUid = user.uid
        let token = try await service.idToken(for: user)
        let enabledRegions = try await service.fetchEnabledRegions()
        guard !enabledRegions.isEmpty else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        let access = try await service.checkAccess(idToken: token, regions: enabledRegions)
        role = (try? await service.fetchUserRole(uid: user.uid)) ?? access.role
        let regions = await service.addCapacity(to: enabledRegions, idToken: token)
        let clients = merge(existingClients: existingClients, fetchedClients: try await service.fetchOwnedClients(uid: user.uid))
        apply(try await configManager.applyRemoteState(regions: regions, clients: clients))
        ensureSelectedRegion()
        pruneSelectedClient()
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
        case .missingCurrentUser, .missingSelectedRegion, .invalidAPIResponse:
            return false
        }
    }

    private func clearRemoteState() {
        signedInEmail = nil
        signedInUid = nil
        role = nil
        regions = []
        clientOptions = []
        configOptions = []
        staleText = nil
        lastRefreshText = nil
        lastSyncText = nil
        remoteInvalidInstalledConfig = false
        selectedRegionId = nil
        selectedClientId = nil
        newClientName = ""
    }

    private func apply(_ state: CloudGatewayConfigManagerState) {
        configState = state
        regions = state.regions
        clientOptions = state.clientOptions
        configOptions = state.configOptions
        cachedSnapshot = state.cachedSnapshot
        tunnelStatus = state.tunnelStatus
        staleText = state.staleText
        remoteInvalidInstalledConfig = state.remoteInvalidInstalledConfig
        if let lastRefreshDate = state.lastRefreshDate {
            lastRefreshText = "Updated \(lastRefreshDate.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func ensureSelectedRegion() {
        if let selectedRegionId, regions.contains(where: { $0.regionId == selectedRegionId }) {
            return
        }
        selectedRegionId = regions.first?.regionId
    }

    private func pruneSelectedClient() {
        guard let selectedClientId else {
            return
        }
        if !filteredClientOptions.contains(where: { $0.client.clientId == selectedClientId }) {
            self.selectedClientId = nil
        }
    }

    private func merge(
        existingClients: [CloudGatewayClient],
        fetchedClients: [CloudGatewayClient]
    ) -> [CloudGatewayClient] {
        var clientsByKey = Dictionary(
            uniqueKeysWithValues: fetchedClients.map { ("\($0.regionId)/\($0.clientId)", $0) }
        )
        for client in existingClients {
            clientsByKey["\(client.regionId)/\(client.clientId)"] = client
        }
        return Array(clientsByKey.values)
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
