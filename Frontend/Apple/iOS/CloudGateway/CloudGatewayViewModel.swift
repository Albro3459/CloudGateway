import CloudGatewayKit
import Combine
import Foundation

enum CloudGatewayAppMode: Equatable {
    case loading
    case guest
    case signedIn
}

@MainActor
final class CloudGatewayViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var appMode: CloudGatewayAppMode = .loading
    @Published private(set) var signedInEmail: String?
    @Published private(set) var signedInUid: String?
    @Published private(set) var role: String?
    @Published private(set) var regions = [CloudGatewayRegion]()
    @Published private(set) var clientOptions = [CloudGatewayClientOption]()
    @Published private(set) var configOptions = [CloudGatewayClientOption]()
    @Published private(set) var installedSnapshots = [CloudGatewayConfigSnapshot]()
    @Published private(set) var tunnelStatuses = [String: GatewayTunnelStatus]()
    @Published private(set) var isWorking = false
    @Published private(set) var errorText: String?
    @Published private(set) var successText: String?
    @Published private(set) var staleText: String?
    @Published private(set) var lastRefreshText: String?
    @Published private(set) var lastSyncText: String?
    @Published private(set) var remoteInvalidInstalledConfig = false
    @Published var selectedRegionId: String?
    @Published var selectedClientId: String? {
        didSet {
            syncSelectedConfigPresentation()
        }
    }
    @Published var newClientName = ""
    @Published var newAccessEmail = ""

    private let service: CloudGatewayServicing
    private let configManager: CloudGatewayConfigManager
    private var configState = CloudGatewayConfigManagerState()
    private var authHandle: Any?
    private var isSigningOut = false

    var isSignedIn: Bool {
        appMode == .signedIn
    }

    var statusText: String {
        visibleTunnelStatus?.displayName ?? "Not installed"
    }

    var visibleInstalledSnapshot: CloudGatewayConfigSnapshot? {
        isSignedIn ? selectedInstalledSnapshot : nil
    }

    var visibleTunnelStatus: GatewayTunnelStatus? {
        isSignedIn ? selectedTunnelStatus : nil
    }

    var selectedRegion: CloudGatewayRegion? {
        CloudGatewayConfigSelection.selectedRegion(id: selectedRegionId, in: regions)
    }

    var filteredClientOptions: [CloudGatewayClientOption] {
        CloudGatewayConfigSelection.clientOptions(in: selectedRegionId, options: clientOptions)
    }

    var selectedClientOption: CloudGatewayClientOption? {
        CloudGatewayConfigSelection.selectedOption(clientId: selectedClientId, in: filteredClientOptions)
    }

    var selectedConfigOption: CloudGatewayClientOption? {
        CloudGatewayConfigSelection.usableSelection(selectedClientOption)
    }

    var selectedInstalledSnapshot: CloudGatewayConfigSnapshot? {
        guard let selectedClientId else {
            return nil
        }
        return configState.installedSnapshot(clientId: selectedClientId)
    }

    var selectedTunnelStatus: GatewayTunnelStatus? {
        guard let selectedClientId else {
            return nil
        }
        return configState.tunnelStatus(for: selectedClientId)
    }

    var canSyncSelectedRegion: Bool {
        role == "admin" && selectedRegion != nil && !isWorking
    }

    var canGrantAccess: Bool {
        isAdmin
            && !newAccessEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && regions.first != nil
            && !isWorking
    }

    var isAdmin: Bool {
        isSignedIn && role == "admin"
    }

    var createDisabled: Bool {
        isWorking || !selectedRegionAllowsCreate
    }

    var deleteDisabled: Bool {
        isWorking || selectedClientOption == nil
    }

    func deleteDisabled(for option: CloudGatewayClientOption) -> Bool {
        isWorking || !isSignedIn || option.client.status == .removed
    }

    var installDisabled: Bool {
        isWorking || !isSignedIn || selectedConfigOption == nil
    }

    var startDisabled: Bool {
        isWorking
            || !isSignedIn
            || selectedClientId == nil
            || visibleTunnelStatus == nil
            || visibleTunnelStatus == .connected
            || visibleTunnelStatus == .connecting
            || remoteInvalidInstalledConfig
    }

    var stopDisabled: Bool {
        isWorking
            || !isSignedIn
            || selectedClientId == nil
            || visibleTunnelStatus == nil
            || visibleTunnelStatus == .disconnected
            || visibleTunnelStatus == .disconnecting
    }

    var removeTunnelDisabled: Bool {
        isWorking || selectedClientId == nil || visibleTunnelStatus == nil
    }

    init(service: CloudGatewayServicing, configManager: CloudGatewayConfigManager) {
        self.service = service
        self.configManager = configManager
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

    func resetPassword() async {
        await run {
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
                throw CloudGatewayAppError.accessDenied("Enter a valid email address.")
            }
            try await service.sendPasswordReset(email: trimmedEmail)
            successText = "Password reset email sent."
        }
    }

    func completeAppleSignIn(idToken: String, rawNonce: String) async {
        await run {
            let user = try await service.signInWithApple(idToken: idToken, rawNonce: rawNonce)
            try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: true)
        }
    }

    func signInWithGoogle() async {
        await run {
            do {
                let user = try await service.signInWithGoogle()
                try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: true)
            } catch CloudGatewayAppError.cancelled {
                // User dismissed the Google sheet; not an error.
            }
        }
    }

    // The Apple button reports non-cancellation failures from the view layer;
    // route them through run so they surface like every other CloudGatewayAppError.
    func reportAppleSignInFailure() async {
        await run {
            throw CloudGatewayAppError.appleSignInFailed
        }
    }

    func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        await run {
            try service.signOut()
            try await loadGuestState()
        }
    }

    func refresh() async {
        await run {
            if let user = service.currentUser {
                try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: false)
            } else {
                try await loadGuestState()
            }
        }
    }

    // Guest entry point from the login screen; refresh() already resolves to
    // guest state when there is no signed-in user.
    func continueAsGuest() async {
        await refresh()
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
            let token = try await service.idToken()
            let response = try await service.syncRegion(regionId: regionId, idToken: token)
            lastSyncText = "\(response.regionId): +\(response.added) ~\(response.updated) -\(response.removed)"
            try await loadRemoteState(for: user)
            successText = "Synced \(response.regionId)."
        }
    }

    func grantAccess() async {
        await run {
            guard service.currentUser != nil else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            guard role == "admin" else {
                throw CloudGatewayAppError.accessDenied("Admin access is required to grant access.")
            }
            let trimmedEmail = newAccessEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
                throw CloudGatewayAppError.accessDenied("Enter a valid email address.")
            }
            guard let regionId = regions.first?.regionId else {
                throw CloudGatewayAppError.missingSelectedRegion
            }
            let token = try await service.idToken()
            let response = try await service.grantAccess(email: trimmedEmail, regionId: regionId, idToken: token)
            newAccessEmail = ""
            successText = response.alreadyExisted
                ? "Existing account granted access: \(response.email)"
                : "User access granted: \(response.email)"
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
            guard selectedRegionAllowsCreate else {
                let capacity = selectedRegion?.capacity
                let message = (capacity?.isKnown == true && capacity?.isAtCapacity == true)
                    ? "This region is full."
                    : "Capacity for this region is unavailable."
                throw CloudGatewayAppError.accessDenied(message)
            }
            let token = try await service.idToken()
            let created = try await service.createClient(
                regionId: regionId,
                clientName: newClientName,
                idToken: token
            )
            newClientName = ""
            selectedClientId = nil
            try await loadRemoteState(for: user, existingClients: [created])
            successText = "\(created.displayName) was created."
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
            let token = try await service.idToken()
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
            successText = "\(selectedClientOption.client.displayName) was deleted."
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
            successText = "\(option.client.displayName) is installed."
        }
    }

    func startTunnel() async {
        await run {
            guard let selectedClientId else {
                throw CloudGatewayAppError.accessDenied("Choose an installed config to start.")
            }
            apply(try await configManager.startTunnel(identifier: selectedClientId))
            successText = "VPN started."
        }
    }

    func stopTunnel() async {
        await run {
            guard let selectedClientId else {
                throw CloudGatewayAppError.accessDenied("Choose an installed config to stop.")
            }
            apply(try await configManager.stopTunnel(identifier: selectedClientId))
            successText = "VPN stopped."
        }
    }

    func removeTunnel() async {
        await run {
            guard let selectedClientId else {
                throw CloudGatewayAppError.accessDenied("Choose an installed config to remove.")
            }
            apply(try await configManager.removeTunnel(identifier: selectedClientId))
            successText = "VPN removed."
        }
    }

    func tunnelStatusLabel(for option: CloudGatewayClientOption) -> String? {
        configState.tunnelStatus(for: option.client.clientId)?.displayName
    }

    func dismissMessages() {
        errorText = nil
        successText = nil
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

    private func handleAuthState(_ user: AuthenticatedUser?) async {
        if let user {
            signedInEmail = user.email
            signedInUid = user.uid
            appMode = .signedIn
            if !isWorking && configOptions.isEmpty {
                await refresh()
            }
        } else if isWorking {
            // Session ended mid-operation: drop to guest but keep regions loaded
            // so the guest dashboard isn't left empty until a manual refresh.
            // signOut() already drives this transition, so skip the redundant load.
            if !isSigningOut {
                try? await loadGuestState()
            }
        } else {
            await refresh()
        }
    }

    private func loadLocalState() async {
        do {
            applyLocal(try await configManager.loadLocalState())
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadRemoteState(for user: AuthenticatedUser) async throws {
        try await loadRemoteState(for: user, existingClients: [])
    }

    private func loadRemoteState(for user: AuthenticatedUser, existingClients: [CloudGatewayClient]) async throws {
        signedInEmail = user.email
        signedInUid = user.uid
        appMode = .signedIn
        let token = try await service.idToken()
        let enabledRegions = try await service.fetchRegions()
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
        for user: AuthenticatedUser,
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
        case .missingCurrentUser, .missingSelectedRegion, .invalidAPIResponse, .cancelled, .appleSignInFailed:
            return false
        }
    }

    private func clearRemoteState() {
        appMode = .guest
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
        successText = nil
        selectedRegionId = nil
        selectedClientId = nil
        newClientName = ""
    }

    private func loadGuestState() async throws {
        clearRemoteState()
        let enabledRegions = try await service.fetchRegions()
        guard !enabledRegions.isEmpty else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        regions = CloudGatewayConfigSelection.sortedRegions(enabledRegions.map(regionWithoutCapacity))
        ensureSelectedRegion()
    }

    private func apply(_ state: CloudGatewayConfigManagerState) {
        configState = state
        regions = state.regions
        clientOptions = state.clientOptions
        configOptions = state.configOptions
        installedSnapshots = state.installedSnapshots
        tunnelStatuses = state.tunnelStatuses
        syncSelectedConfigPresentation()
        if let lastRefreshDate = state.lastRefreshDate {
            lastRefreshText = "Updated \(lastRefreshDate.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func applyLocal(_ state: CloudGatewayConfigManagerState) {
        configState.installedSnapshots = state.installedSnapshots
        configState.tunnelStatuses = state.tunnelStatuses
        configState.staleTexts = state.staleTexts
        configState.remoteInvalidInstalledConfigIds = state.remoteInvalidInstalledConfigIds
        installedSnapshots = state.installedSnapshots
        tunnelStatuses = state.tunnelStatuses
        syncSelectedConfigPresentation()
    }

    private func syncSelectedConfigPresentation() {
        guard let selectedClientId else {
            staleText = nil
            remoteInvalidInstalledConfig = false
            return
        }
        staleText = configState.staleText(for: selectedClientId)
        remoteInvalidInstalledConfig = configState.remoteInvalidInstalledConfig(for: selectedClientId)
    }

    private func ensureSelectedRegion() {
        selectedRegionId = CloudGatewayConfigSelection.resolvedRegionSelection(
            current: selectedRegionId,
            regions: regions
        )
    }

    private func pruneSelectedClient() {
        if let selectedClientId,
           configState.installedSnapshot(clientId: selectedClientId) != nil {
            return
        }
        let prunedSelection = CloudGatewayConfigSelection.prunedClientSelection(
            current: selectedClientId,
            regionId: selectedRegionId,
            options: clientOptions
        )
        selectedClientId = prunedSelection ?? installedSnapshots.first?.clientId
    }

    private var selectedRegionAllowsCreate: Bool {
        guard isSignedIn, let capacity = selectedRegion?.capacity, capacity.isKnown else {
            return false
        }
        return !capacity.isAtCapacity
    }

    private func regionWithoutCapacity(_ region: CloudGatewayRegion) -> CloudGatewayRegion {
        CloudGatewayRegion(
            regionId: region.regionId,
            displayName: region.displayName,
            enabled: region.enabled,
            displayOrder: region.displayOrder
        )
    }

    private func merge(
        existingClients: [CloudGatewayClient],
        fetchedClients: [CloudGatewayClient]
    ) -> [CloudGatewayClient] {
        CloudGatewayConfigSelection.mergeClients(existing: existingClients, fetched: fetchedClients)
    }

    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        errorText = nil
        successText = nil
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
