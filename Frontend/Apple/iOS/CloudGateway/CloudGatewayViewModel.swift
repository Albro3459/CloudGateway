import CloudGatewayKit
import Combine
import Foundation

enum CloudGatewayAppMode: Equatable {
    case loading
    case guest
    case signedIn
}

enum CloudGatewayAccountDeleteReauthMethod {
    case password
    case apple
    case google
    case unsupported
}

enum CloudGatewayAuthProvider: String, CaseIterable, Identifiable, Equatable {
    case password
    case google = "google.com"
    case apple = "apple.com"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .password:
            "Email and password"
        case .google:
            "Google"
        case .apple:
            "Apple"
        }
    }
}

enum CloudGatewayAccountLinkReauthMethod: Equatable {
    case none
    case password
    case apple
}

struct CloudGatewaySyncResult: Identifiable, Equatable {
    let regionId: String
    let syncedAt: String
    let added: Int
    let updated: Int
    let removed: Int
    let noChanges: Bool
    // Full peer-sync audit log from the API (AdminSyncResponse.log), same text
    // the web surfaces: title, region, syncedAt, summary, and per-removed-peer detail.
    let log: String

    var id: String {
        "\(regionId)-\(syncedAt)"
    }

    var summary: String {
        noChanges
            ? "\(regionId): no changes"
            : "\(regionId): +\(added) ~\(updated) -\(removed)"
    }

    var logText: String {
        log
    }
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
    // Client whose VPN toggle is mid-flight, so its row can show a spinner while
    // the tunnel starts/stops instead of looking frozen.
    @Published private(set) var togglingClientId: String?
    @Published private(set) var errorText: String?
    @Published private(set) var successText: String?
    @Published private(set) var staleText: String?
    @Published private(set) var lastRefreshText: String?
    @Published private(set) var syncResult: CloudGatewaySyncResult?
    @Published private(set) var tunnelHealthSnapshot: GatewayTunnelHealthSnapshot?
    @Published private(set) var remoteInvalidInstalledConfig = false
    // True when the last remote refresh failed (offline / API error). Gates the
    // cached-row fallback so a client removed remotely while online does not
    // linger as a ghost row.
    @Published private(set) var remoteRefreshUnavailable = false
    @Published var selectedRegionId: String?
    @Published var selectedClientId: String? {
        didSet {
            syncSelectedConfigPresentation()
        }
    }
    @Published var newClientName = ""
    @Published var newAccessEmail = ""
    @Published var deleteAccountPassword = ""
    @Published var linkEmail = ""
    @Published var linkPassword = ""
    @Published var linkCurrentPassword = ""
    @Published private(set) var linkedProviderIds = [String]()
    @Published private(set) var accountLinkReauthMethod: CloudGatewayAccountLinkReauthMethod = .none
    @Published private(set) var pendingLinkProvider: CloudGatewayAuthProvider?

    private let service: CloudGatewayServicing
    private let configManager: CloudGatewayConfigManager
    private let healthReader: CloudGatewayTunnelHealthReading
    private var configState = CloudGatewayConfigManagerState()
    private var authHandle: Any?
    private static let missingInstalledTunnelMessage = "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
    static let deadTunnelMessage = "Your VPN server isn't responding. Disconnect to restore your connection."
    static let activeConfigDeleteMessage = "Disconnect this VPN before deleting its config."
    static let activeAccountDeleteMessage = "Disconnect your VPN before deleting your account."

    var isSignedIn: Bool {
        appMode == .signedIn
    }

    var shouldShowDeadTunnelWarning: Bool {
        guard tunnelHealthSnapshot?.health == .notPassingTraffic,
              let tunnelIdentifier = tunnelHealthSnapshot?.tunnelIdentifier else {
            return false
        }
        switch configState.tunnelStatus(for: tunnelIdentifier) {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, nil:
            return false
        }
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

    // Rows to render for the selected region. Adds locally cached installed
    // configs that the remote list does not cover - e.g. an installed (possibly
    // connected) tunnel on an offline cold launch - so a running VPN stays
    // visible and can be toggled off without connectivity. Cached rows are
    // region-filtered like the remote ones, so they never leak across regions.
    var displayedClientOptions: [CloudGatewayClientOption] {
        let options = filteredClientOptions
        guard isSignedIn, remoteRefreshUnavailable else {
            return options
        }
        let representedIds = Set(options.map(\.client.clientId))
        let cachedOnly = CloudGatewayConfigSelection.offlineClientOptions(from: installedSnapshots)
            .filter { !representedIds.contains($0.client.clientId) }
        let cachedInRegion = CloudGatewayConfigSelection.clientOptions(in: selectedRegionId, options: cachedOnly)
        return cachedInRegion.isEmpty ? options : options + cachedInRegion
    }

    var isUsingOfflineRegionFallback: Bool {
        isSignedIn && remoteRefreshUnavailable && clientOptions.isEmpty
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

    // A config cannot be deleted while its own tunnel is routing: with a
    // full-tunnel config, the DELETE response is blackholed by the tunnel it is
    // deleting. The user must disconnect (or switch configs) first.
    func isTunnelActive(clientId: String) -> Bool {
        configState.tunnelStatus(for: clientId)?.blocksDestructiveOperation ?? false
    }

    func isTunnelActiveNow(clientId: String) async -> Bool {
        guard let statuses = try? await configManager.allInstalledStatuses() else {
            return isTunnelActive(clientId: clientId)
        }
        return statuses[clientId]?.blocksDestructiveOperation ?? false
    }

    // Account deletion removes every peer, so any active tunnel blocks it.
    var hasActiveTunnel: Bool {
        tunnelStatuses.values.contains { $0.blocksDestructiveOperation }
    }

    func hasActiveTunnelNow() async -> Bool {
        guard let statuses = try? await configManager.allInstalledStatuses() else {
            return hasActiveTunnel
        }
        return statuses.values.contains { $0.blocksDestructiveOperation }
    }

    // True when at least one VPN config is installed on this device. Used to
    // decide whether a notification prompt is worth showing.
    var hasInstalledConfig: Bool {
        !installedSnapshots.isEmpty
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

    // Reauth order per the provider-ordering standard: Apple, then Google, then
    // email & password last (for convenience when other providers are linked).
    var accountDeleteReauthMethod: CloudGatewayAccountDeleteReauthMethod {
        let providerIds = currentProviderIds
        if providerIds.contains("apple.com") {
            return .apple
        }
        if providerIds.contains("google.com") {
            return .google
        }
        if providerIds.contains("password") {
            return .password
        }
        return .unsupported
    }

    var deleteAccountPasswordRequired: Bool {
        accountDeleteReauthMethod == .password
    }

    // Link order per the provider-ordering standard: email & password, Apple,
    // then Google.
    private static let linkProviderOrder: [CloudGatewayAuthProvider] = [.password, .apple, .google]

    var missingLinkProviders: [CloudGatewayAuthProvider] {
        Self.linkProviderOrder.filter { !currentProviderIds.contains($0.rawValue) }
    }

    var canLinkAnotherProvider: Bool {
        isSignedIn && !missingLinkProviders.isEmpty
    }

    var linkPasswordDisabled: Bool {
        isWorking
            || linkEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || linkPassword.isEmpty
            || (accountLinkReauthMethod == .password && linkCurrentPassword.isEmpty)
    }

    private var currentProviderIds: [String] {
        linkedProviderIds.isEmpty ? service.providerIds() : linkedProviderIds
    }

    var createDisabled: Bool {
        isWorking || newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedRegionAllowsCreate
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

    var isLoadingRegions: Bool {
        isWorking && regions.isEmpty
    }

    var isLoadingClients: Bool {
        isSignedIn && isWorking && clientOptions.isEmpty
    }

    init(
        service: CloudGatewayServicing,
        configManager: CloudGatewayConfigManager,
        healthReader: CloudGatewayTunnelHealthReading = NoopTunnelHealthReader()
    ) {
        self.service = service
        self.configManager = configManager
        self.healthReader = healthReader
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
            guard !password.isEmpty else {
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

    func linkEmailPassword() async {
        await linkAccountProvider(.password) {
            let email = self.linkEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = self.linkPassword
            guard email.contains("@"), email.contains(".") else {
                throw CloudGatewayAppError.invalidEmail
            }
            guard !password.isEmpty else {
                throw CloudGatewayAppError.accessDenied("Enter a password to link.")
            }
            return try await self.service.linkEmailPassword(email: email, password: password)
        }
    }

    func linkGoogle() async {
        await linkAccountProvider(.google) {
            try await self.service.linkGoogle()
        }
    }

    func linkApple(idToken: String, rawNonce: String) async {
        await linkAccountProvider(.apple) {
            try await self.service.linkApple(idToken: idToken, rawNonce: rawNonce)
        }
    }

    func completeAccountLinkAppleReauth(idToken: String, rawNonce: String, authorizationCode: String) async {
        guard let pendingLinkProvider else {
            return
        }
        await run {
            try await service.reauthenticateWithApple(
                idToken: idToken,
                rawNonce: rawNonce,
                authorizationCode: authorizationCode,
                revoke: false
            )
            accountLinkReauthMethod = .none
            switch pendingLinkProvider {
            case .password:
                let email = linkEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = linkPassword
                _ = try await service.linkEmailPassword(email: email, password: password)
            case .google:
                _ = try await service.linkGoogle()
            case .apple:
                throw CloudGatewayAppError.providerAlreadyLinked
            }
            didLinkProvider(pendingLinkProvider)
        }
    }

    func clearAccountLinkState() {
        linkEmail = ""
        linkPassword = ""
        linkCurrentPassword = ""
        accountLinkReauthMethod = .none
        pendingLinkProvider = nil
    }

    func signOut() async {
        await run {
            try service.signOut()
            try await loadGuestState()
        }
    }

    func refresh() async {
        await reloadCurrentState(showsWorkingOverlay: true)
    }

    func selectRegion(_ regionId: String) {
        selectedRegionId = regionId
        pruneSelectedClient()
    }

    func refreshTunnelHealth() {
        let snapshot = healthReader.currentSnapshot()
        tunnelHealthSnapshot = snapshot?.isFresh() == true ? snapshot : nil
    }

    func disconnectDeadTunnel() async {
        refreshTunnelHealth()
        guard shouldShowDeadTunnelWarning,
              let tunnelIdentifier = tunnelHealthSnapshot?.tunnelIdentifier else {
            return
        }
        await run {
            apply(try await configManager.stopTunnel(identifier: tunnelIdentifier))
            tunnelHealthSnapshot = nil
        }
    }

    func pullToRefresh() async {
        // SwiftUI cancels the .refreshable task when its pull control retracts,
        // and the early @Published updates in loadRemoteState can trigger that
        // retraction before the network reload finishes - silently aborting it
        // (run swallows the CancellationError). Run the reload in an independent
        // task so it always completes, while still awaiting it to keep the pull
        // spinner up until the refresh is done.
        await Task { await self.reloadCurrentState(showsWorkingOverlay: false) }.value
    }

    private func reloadCurrentState(showsWorkingOverlay: Bool) async {
        await run(showsWorkingOverlay: showsWorkingOverlay) {
            if let user = service.currentUser {
                do {
                    try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: false)
                } catch {
                    if isSignedIn {
                        await applyRemoteRefreshUnavailable()
                    }
                    throw error
                }
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
            let result = CloudGatewaySyncResult(
                regionId: response.regionId,
                syncedAt: response.syncedAt,
                added: response.added,
                updated: response.updated,
                removed: response.removed,
                noChanges: response.noChanges,
                log: response.log
            )
            syncResult = result
            try await loadRemoteStateMarkingUnavailable(for: user)
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
            let trimmedClientName = newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedClientName.isEmpty else {
                throw CloudGatewayAppError.accessDenied("Enter a display name, for example John's iPhone.")
            }
            let token = try await service.idToken()
            let created = try await service.createClient(
                regionId: regionId,
                clientName: trimmedClientName,
                idToken: token
            )
            newClientName = ""
            selectedClientId = nil
            try await loadRemoteStateMarkingUnavailable(for: user, existingClients: [created])
            successText = "\(created.displayName) was created."
        }
    }

    // Deletes exactly the client captured when the confirmation alert opened.
    // Taking the option explicitly (rather than reading selectedClientOption at
    // confirm time) avoids deleting the wrong client if a background refresh
    // prunes or moves the selection between opening and confirming.
    func deleteClient(_ option: CloudGatewayClientOption) async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            try await ensureDestructiveOperationAllowed(
                clientId: option.client.clientId,
                message: Self.activeConfigDeleteMessage
            )
            let token = try await service.idToken()
            let response = try await service.deleteClient(
                clientId: option.client.clientId,
                userId: option.client.ownerUid ?? user.uid,
                regionId: option.client.regionId,
                idToken: token
            )
            if selectedClientId == option.client.clientId {
                selectedClientId = nil
            }
            apply(try await configManager.removeInstalledConfigIfMatches(
                clientId: response.clientId,
                regionId: response.regionId
            ))
            try await loadRemoteStateMarkingUnavailable(for: user)
            successText = "\(option.client.displayName) was deleted."
        }
    }

    func deleteAccountWithPassword() async {
        await deleteAccount {
            let password = self.deleteAccountPassword
            guard !password.isEmpty else {
                throw CloudGatewayAppError.accessDenied("Enter your password to delete your account.")
            }
            try await self.service.reauthenticateWithPassword(password)
        }
    }

    func deleteAccountWithGoogle() async {
        await deleteAccount {
            try await self.service.reauthenticateWithGoogle(revoke: true)
        }
    }

    func deleteAccountWithApple(idToken: String, rawNonce: String, authorizationCode: String) async {
        await deleteAccount {
            try await self.service.reauthenticateWithApple(
                idToken: idToken,
                rawNonce: rawNonce,
                authorizationCode: authorizationCode,
                revoke: true
            )
        }
    }

    private func linkAccountProvider(
        _ provider: CloudGatewayAuthProvider,
        operation: @escaping () async throws -> AuthenticatedUser
    ) async {
        await run {
            guard service.currentUser != nil else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            if accountLinkReauthMethod == .password {
                let password = linkCurrentPassword
                guard !password.isEmpty else {
                    throw CloudGatewayAppError.accessDenied("Enter your current password, then try again.")
                }
                try await service.reauthenticateWithPassword(password)
                accountLinkReauthMethod = .none
            }

            do {
                _ = try await operation()
                didLinkProvider(provider)
            } catch CloudGatewayAppError.requiresRecentLogin {
                if try await prepareRecentLoginRecovery(for: provider) {
                    _ = try await operation()
                    didLinkProvider(provider)
                }
            }
        }
    }

    private func prepareRecentLoginRecovery(for provider: CloudGatewayAuthProvider) async throws -> Bool {
        pendingLinkProvider = provider
        let providerIds = currentProviderIds
        // Reauth order per the standard: Apple, then Google, then password last.
        if providerIds.contains(CloudGatewayAuthProvider.apple.rawValue) {
            accountLinkReauthMethod = .apple
            throw CloudGatewayAppError.accessDenied("Sign in with Apple again, then try linking once more.")
        }
        if providerIds.contains(CloudGatewayAuthProvider.google.rawValue) {
            try await service.reauthenticateWithGoogle(revoke: false)
            accountLinkReauthMethod = .none
            return true
        }
        if providerIds.contains(CloudGatewayAuthProvider.password.rawValue) {
            accountLinkReauthMethod = .password
            throw CloudGatewayAppError.accessDenied("Enter your current password, then try again.")
        }
        throw CloudGatewayAppError.requiresRecentLogin
    }

    private func didLinkProvider(_ provider: CloudGatewayAuthProvider) {
        refreshLinkedProviderIds()
        clearAccountLinkState()
        successText = "\(provider.title) was linked to your account."
    }

    private func deleteAccount(reauthenticate: @escaping () async throws -> Void) async {
        await run {
            guard service.currentUser != nil else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            try await ensureDestructiveOperationAllowed(message: Self.activeAccountDeleteMessage)
            try await reauthenticate()
            let token = try await service.idToken(forceRefresh: true)
            _ = try await service.deleteAccount(idToken: token)
            await removeInstalledConfigsAfterAccountDelete()
            deleteAccountPassword = ""
            try service.signOut()
            try await loadGuestState()
        }
    }

    private func removeInstalledConfigsAfterAccountDelete() async {
        let cachedIdentifiers = installedSnapshots.map(\.clientId)
        // The account is already deleted server-side, so this local cleanup must
        // catch on-device profiles that are not in the cached snapshot. A
        // transient failure here would silently leave a stale system VPN
        // profile behind, so retry the live query briefly before giving up.
        let installedIdentifiers = await installedIdentifiersWithRetry()
        for identifier in Set(cachedIdentifiers).union(installedIdentifiers) {
            _ = try? await configManager.removeTunnel(identifier: identifier)
        }
        if let state = try? await configManager.loadLocalState() {
            apply(state)
        }
    }

    private func installedIdentifiersWithRetry(attempts: Int = 3) async -> Set<String> {
        for attempt in 0..<attempts {
            if let statuses = try? await configManager.allInstalledStatuses() {
                return Set(statuses.keys)
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return []
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

    // Install button for a not-yet-installed client: pull the latest config from
    // Firebase, then install, so a stale cached config is never installed.
    func installFromCloud(_ option: CloudGatewayClientOption) async {
        await run {
            _ = try await pullFreshAndInstall(option)
        }
    }

    private func pullFreshAndInstall(_ option: CloudGatewayClientOption) async throws -> String {
        guard let user = service.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        try await loadRemoteStateMarkingUnavailable(for: user)
        guard let freshOption = clientOptions.first(where: {
            $0.client.clientId == option.client.clientId
                && $0.client.regionId == option.client.regionId
                && $0.client.hasUsableConfig
        }) else {
            throw CloudGatewayAppError.accessDenied("This VPN client is not ready to install.")
        }
        selectedClientId = freshOption.client.clientId
        apply(try await configManager.install(freshOption))
        return freshOption.client.displayName
    }

    // The client whose tunnel is actually established (connected/reasserting), so
    // the switch prompt only offers to "turn off" a VPN that is really on - not one
    // that is merely mid-connect.
    var activeTunnelClient: CloudGatewayClientOption? {
        // Mirror toggleIsOn's "on" set so a client that is still connecting is
        // treated as the active tunnel to switch away from, not left running
        // alongside a newly started one on this single-tunnel provider.
        let representedIds = Set(clientOptions.map(\.client.clientId))
        let cachedOnly = CloudGatewayConfigSelection.offlineClientOptions(from: installedSnapshots)
            .filter { !representedIds.contains($0.client.clientId) }
        let options = clientOptions + cachedOnly
        return options.first { option in
            switch configState.tunnelStatus(for: option.client.clientId) {
            case .connected, .connecting, .reasserting:
                return true
            case .disconnecting, .disconnected, .invalid, nil:
                return false
            }
        }
    }

    // Turn off the currently active tunnel (if different) and start this one.
    func switchTunnel(to option: CloudGatewayClientOption) async {
        togglingClientId = option.client.clientId
        defer { togglingClientId = nil }
        await run {
            if let active = activeTunnelClient, active.client.clientId != option.client.clientId {
                apply(try await configManager.stopTunnel(identifier: active.client.clientId))
            }
            selectedClientId = option.client.clientId
            apply(try await configManager.startTunnel(identifier: option.client.clientId))
        }
    }

    func startTunnel() async {
        togglingClientId = selectedClientId
        defer { togglingClientId = nil }
        await run {
            guard let selectedClientId else {
                throw CloudGatewayAppError.accessDenied("Choose an installed config to start.")
            }
            apply(try await configManager.startTunnel(identifier: selectedClientId))
        }
    }

    func startTunnel(for option: CloudGatewayClientOption) async {
        selectedClientId = option.client.clientId
        await startTunnel()
    }

    func stopTunnel() async {
        togglingClientId = selectedClientId
        defer { togglingClientId = nil }
        await run {
            guard let selectedClientId else {
                throw CloudGatewayAppError.accessDenied("Choose an installed config to stop.")
            }
            apply(try await configManager.stopTunnel(identifier: selectedClientId))
        }
    }

    func stopTunnel(for option: CloudGatewayClientOption) async {
        selectedClientId = option.client.clientId
        await stopTunnel()
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

    func staleText(for option: CloudGatewayClientOption) -> String? {
        configState.staleText(for: option.client.clientId)
    }

    func dismissMessages() {
        errorText = nil
        successText = nil
    }

    func dismissSyncResult() {
        syncResult = nil
    }

    func installStateLabel(for option: CloudGatewayClientOption) -> String? {
        switch configState.installState(for: option) {
        case .installed:
            return nil
        case .updateAvailable:
            return "Update Available"
        case nil:
            return nil
        }
    }

    func installButtonTitle(for option: CloudGatewayClientOption) -> String {
        installStateLabel(for: option) == nil ? "Install" : "Install Update"
    }

    func installDisabled(for option: CloudGatewayClientOption) -> Bool {
        isWorking || !isSignedIn || !option.client.hasUsableConfig
    }

    func isInstalled(_ option: CloudGatewayClientOption) -> Bool {
        configState.installState(for: option) != nil
            && configState.tunnelStatus(for: option.client.clientId) != nil
    }

    private func ensureDestructiveOperationAllowed(clientId: String? = nil, message: String) async throws {
        let statuses = try await configManager.allInstalledStatuses()
        let statusValues: [GatewayTunnelStatus]
        if let clientId {
            // Per-client delete only cares about that client's own tunnel. If it
            // has no installed tunnel, there is nothing to block on.
            statusValues = statuses[clientId].map { [$0] } ?? []
        } else {
            statusValues = Array(statuses.values)
        }
        guard !statusValues.contains(where: { $0.blocksDestructiveOperation }) else {
            throw CloudGatewayAppError.accessDenied(message)
        }
    }

    func toggleDisabled(for option: CloudGatewayClientOption) -> Bool {
        let clientId = option.client.clientId
        let status = configState.tunnelStatus(for: clientId)
        return isWorking
            || !isSignedIn
            || status == nil
            || status == .invalid
            || configState.remoteInvalidInstalledConfig(for: clientId)
    }

    func toggleIsOn(for option: CloudGatewayClientOption) -> Bool {
        switch configState.tunnelStatus(for: option.client.clientId) {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, nil:
            return false
        }
    }

    func isToggling(for option: CloudGatewayClientOption) -> Bool {
        togglingClientId == option.client.clientId
    }

    private func handleAuthState(_ user: AuthenticatedUser?) async {
        if let user {
            signedInEmail = user.email
            signedInUid = user.uid
            refreshLinkedProviderIds()
            appMode = .signedIn
            if !isWorking && configOptions.isEmpty {
                await refresh()
            }
        } else if appMode == .guest {
            // A sign-out path (manual sign-out or a forced sign-out after a
            // failed load) already dropped us to guest and loaded guest state,
            // so this listener callback is redundant. appMode flips to .guest
            // synchronously at the start of every guest load, so this also
            // covers the callback that fires while that load is still in flight.
        } else if isWorking {
            // Session ended mid-operation from outside our sign-out paths: drop
            // to guest directly (not via refresh) so we don't nest another
            // working run while one is already active.
            try? await loadGuestState()
        } else {
            await refresh()
        }
    }

    private func loadLocalState() async {
        do {
            applyLocal(try await configManager.loadLocalState())
            refreshTunnelHealth()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadRemoteState(for user: AuthenticatedUser) async throws {
        try await loadRemoteState(for: user, existingClients: [])
    }

    private func loadRemoteStateMarkingUnavailable(
        for user: AuthenticatedUser,
        existingClients: [CloudGatewayClient] = []
    ) async throws {
        do {
            try await loadRemoteState(for: user, existingClients: existingClients)
        } catch {
            if isSignedIn {
                await applyRemoteRefreshUnavailable()
            }
            throw error
        }
    }

    // A remote refresh failed (offline, API error, cold launch with no network).
    // Reload the local cache first so installed configs stay visible and
    // controllable, then flag them as stale/offline.
    private func applyRemoteRefreshUnavailable() async {
        _ = try? await configManager.loadLocalState()
        var state = await configManager.markRemoteRefreshUnavailable()
        if state.regions.isEmpty {
            state.regions = CloudGatewayConfigSelection.offlineRegions(from: state.installedSnapshots)
        }
        apply(state)
        remoteRefreshUnavailable = true
        ensureSelectedRegion()
        pruneSelectedClient()
    }

    private func loadRemoteState(for user: AuthenticatedUser, existingClients: [CloudGatewayClient]) async throws {
        signedInEmail = user.email
        signedInUid = user.uid
        refreshLinkedProviderIds()
        appMode = .signedIn
        let token = try await service.idToken()
        let enabledRegions = try await service.fetchRegions()
        guard !enabledRegions.isEmpty else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        let access = try await service.checkAccess(idToken: token, regions: enabledRegions)
        // Explicitly flatten so both a missing UserRoles doc (fetch returns nil)
        // and a fetch failure fall back to the check-access role.
        role = ((try? await service.fetchUserRole(uid: user.uid)) ?? nil) ?? access.role
        let regions = await service.addCapacity(to: enabledRegions, idToken: token)
        let fetchedClients = role == "admin"
            ? try await service.fetchAllClients()
            : try await service.fetchOwnedClients(uid: user.uid)
        let clients = merge(existingClients: existingClients, fetchedClients: fetchedClients)
        apply(try await configManager.applyRemoteState(regions: regions, clients: clients))
        remoteRefreshUnavailable = false
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
                await dropToGuest()
            }
            throw loadError
        } catch {
            if signOutOnAnyFailure {
                try? service.signOut()
                await dropToGuest()
            }
            throw error
        }
    }

    private func shouldSignOut(after error: CloudGatewayAppError) -> Bool {
        switch error {
        case .accessDenied(_), .noEnabledRegions:
            return true
        case .missingCurrentUser, .missingSelectedRegion, .invalidAPIResponse, .cancelled, .appleSignInFailed, .requiresRecentLogin, .credentialAlreadyInUse, .providerAlreadyLinked, .invalidEmail, .weakPassword, .invalidSignInCredentials, .wrongPassword:
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
        syncResult = nil
        remoteInvalidInstalledConfig = false
        remoteRefreshUnavailable = false
        successText = nil
        selectedRegionId = nil
        selectedClientId = nil
        newClientName = ""
        // Clear credentials on sign-out; leave `email` populated for convenience.
        password = ""
        deleteAccountPassword = ""
        clearAccountLinkState()
        linkedProviderIds = []
    }

    private func refreshLinkedProviderIds() {
        linkedProviderIds = service.providerIds()
    }

    // Drop to guest and populate it directly rather than depending on the
    // auth-state listener firing. clearRemoteState (inside loadGuestState) flips
    // appMode to .guest synchronously and the region fetch fills the guest
    // dashboard, so it isn't left empty after a forced sign-out. Any failure here
    // is secondary to the sign-out error the caller is already surfacing.
    private func dropToGuest() async {
        try? await loadGuestState()
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
           configState.installedSnapshot(
               clientId: selectedClientId,
               regionId: selectedRegionId
           ) != nil {
            return
        }
        let prunedSelection = CloudGatewayConfigSelection.prunedClientSelection(
            current: selectedClientId,
            regionId: selectedRegionId,
            options: clientOptions
        )
        selectedClientId = prunedSelection
            ?? installedSnapshots.first(where: { snapshot in
                selectedRegionId == nil || snapshot.regionId == selectedRegionId
            })?.clientId
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

    private func run(showsWorkingOverlay: Bool = true, _ operation: () async throws -> Void) async {
        if showsWorkingOverlay {
            isWorking = true
        }
        errorText = nil
        successText = nil
        defer {
            if showsWorkingOverlay {
                isWorking = false
            }
        }

        do {
            try await operation()
        } catch is CancellationError {
        } catch CloudGatewayAppError.cancelled {
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        } catch GatewayVPNError.missingInstalledTunnel {
            errorText = Self.missingInstalledTunnelMessage
            if let state = try? await configManager.loadLocalState() {
                apply(state)
            }
        } catch {
            refreshTunnelHealth()
            if isRequestTimeout(error), shouldShowDeadTunnelWarning {
                errorText = nil
            } else {
                errorText = error.localizedDescription
            }
        }
    }

    private func isRequestTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
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
            "Connected"
        case .connected:
            "Connected"
        case .reasserting:
            "Reasserting"
        case .disconnecting:
            "Disconnected"
        }
    }
}
