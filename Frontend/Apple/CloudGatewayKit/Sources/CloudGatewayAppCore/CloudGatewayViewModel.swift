import CloudGatewayKit
import Combine
import Foundation

public enum CloudGatewayAppMode: Equatable {
    case loading
    case guest
    case signedIn
}

public enum CloudGatewayAccountDeleteReauthMethod {
    case password
    case apple
    case google
    case unsupported
}

public enum CloudGatewayAuthProvider: String, CaseIterable, Identifiable, Equatable {
    case password
    case google = "google.com"
    case apple = "apple.com"

    public var id: String {
        rawValue
    }

    public var title: String {
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

public enum CloudGatewayAccountLinkReauthMethod: Equatable {
    case none
    case password
    case apple
}

@MainActor
public final class CloudGatewayViewModel: ObservableObject {
    @Published public var email = ""
    @Published public var password = ""
    @Published public private(set) var appMode: CloudGatewayAppMode = .loading
    @Published public private(set) var signedInEmail: String?
    @Published public private(set) var signedInUid: String?
    @Published public private(set) var role: String?
    @Published public private(set) var regions = [CloudGatewayRegion]()
    @Published public private(set) var clientOptions = [CloudGatewayClientOption]()
    @Published public private(set) var configOptions = [CloudGatewayClientOption]()
    @Published public private(set) var installedSnapshots = [CloudGatewayConfigSnapshot]()
    @Published public private(set) var tunnelStatuses = [String: CloudGatewayTunnelStatus]()
    @Published public private(set) var isWorking = false
    // Client whose VPN toggle is mid-flight, so its row can show a spinner while
    // the tunnel starts/stops instead of looking frozen.
    @Published public private(set) var togglingClientId: String?
    @Published public private(set) var errorText: String?
    @Published public private(set) var successText: String?
    @Published public private(set) var staleText: String?
    @Published public private(set) var lastRefreshText: String?
    @Published public private(set) var tunnelHealthSnapshot: CloudGatewayTunnelHealthSnapshot?
    @Published public private(set) var remoteInvalidInstalledConfig = false
    // True when the last remote refresh failed (offline / API error). Gates the
    // cached-row fallback so a client removed remotely while online does not
    // linger as a ghost row.
    @Published public private(set) var remoteRefreshUnavailable = false
    @Published public var selectedRegionId: String?
    @Published public var selectedClientId: String? {
        didSet {
            syncSelectedConfigPresentation()
        }
    }
    @Published public var newClientName = ""
    @Published public var newAccessEmail = ""
    @Published public var deleteAccountPassword = ""
    @Published public var linkEmail = ""
    @Published public var linkPassword = ""
    @Published public var linkCurrentPassword = ""
    @Published public private(set) var linkedProviderIds = [String]()
    @Published public private(set) var accountLinkReauthMethod: CloudGatewayAccountLinkReauthMethod = .none
    @Published public private(set) var pendingLinkProvider: CloudGatewayAuthProvider?

    private let service: CloudGatewayServicing
    private let configManager: CloudGatewayConfigManager
    private let healthReader: CloudGatewayTunnelHealthReading
    private let notificationAuthorizer: CloudGatewayNotificationAuthorizing
    private let presentationSleeper: any CloudGatewayPresentationSleeping
    private let deadTunnelDisconnectTimeout: Duration
    private let deadTunnelDisconnectPollInterval: Duration
    private var configState = CloudGatewayConfigManagerState()
    private var authRegistration: CloudGatewayAuthStateListenerRegistration?
    private var authStateGeneration: UInt64 = 0
    private var loadedRemoteUserId: String?
    // Resumed when a working `run` finishes, so a deferred auth reload can await
    // in-flight work instead of busy-polling `isWorking`.
    private var workDidFinishContinuations: [CheckedContinuation<Void, Never>] = []
    private var pendingLinkUserId: String?
    private var lastDeadTunnelStatusRefreshKey: DeadTunnelStatusRefreshKey?
    private var presentationMonitorGeneration: UInt64 = 0
    private var activePresentationMonitorGeneration: UInt64?
    private static let presentationRefreshInterval: Duration = .seconds(5)
    private static let missingInstalledTunnelMessage = "The VPN profile is no longer installed on this device. Refresh, then you can install the config again."
    public static let deadTunnelMessage = CloudGatewayTunnelHealthNotification.body
    public static let deadTunnelDisconnectTimeoutMessage = "The VPN is taking longer than expected to disconnect. Wait a moment, then pull to refresh."
    public static let activeConfigDeleteMessage = "Disconnect this VPN before deleting its config."
    public static let activeAccountDeleteMessage = "Disconnect your VPN before deleting your account."

    private struct DeadTunnelStatusRefreshKey: Equatable {
        // periphery:ignore - compared via synthesized Equatable
        let tunnelIdentifier: String
        // periphery:ignore - compared via synthesized Equatable
        let updatedAt: Date
    }

    public var isSignedIn: Bool {
        appMode == .signedIn
    }

    public var shouldShowDeadTunnelWarning: Bool {
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

    public var selectedRegion: CloudGatewayRegion? {
        CloudGatewayConfigSelection.selectedRegion(id: selectedRegionId, in: regions)
    }

    public var filteredClientOptions: [CloudGatewayClientOption] {
        CloudGatewayConfigSelection.clientOptions(in: selectedRegionId, options: clientOptions)
    }

    // Rows to render for the selected region. Adds locally cached installed
    // configs that the remote list does not cover - e.g. an installed (possibly
    // connected) tunnel on an offline cold launch - so a running VPN stays
    // visible and can be toggled off without connectivity. Cached rows are
    // region-filtered like the remote ones, so they never leak across regions.
    public var displayedClientOptions: [CloudGatewayClientOption] {
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

    public var isUsingOfflineRegionFallback: Bool {
        isSignedIn && remoteRefreshUnavailable && clientOptions.isEmpty
    }

    // A config cannot be deleted while its own tunnel is routing: with a
    // full-tunnel config, the DELETE response is blackholed by the tunnel it is
    // deleting. The user must disconnect (or switch configs) first.
    func isTunnelActive(clientId: String) -> Bool {
        configState.tunnelStatus(for: clientId)?.blocksDestructiveOperation ?? false
    }

    public func isTunnelActiveNow(clientId: String) async -> Bool {
        guard let statuses = try? await configManager.allInstalledStatuses() else {
            return isTunnelActive(clientId: clientId)
        }
        return statuses[clientId]?.blocksDestructiveOperation ?? false
    }

    // Account deletion removes every peer, so any active tunnel blocks it.
    var hasActiveTunnel: Bool {
        tunnelStatuses.values.contains { $0.blocksDestructiveOperation }
    }

    public func hasActiveTunnelNow() async -> Bool {
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

    public var canGrantAccess: Bool {
        isAdmin
            && !newAccessEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && regions.first != nil
            && !isWorking
    }

    public var isAdmin: Bool {
        isSignedIn && role == "admin"
    }

    // Reauth order per the provider-ordering standard: Apple, then Google, then
    // email & password last (for convenience when other providers are linked).
    public var accountDeleteReauthMethod: CloudGatewayAccountDeleteReauthMethod {
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

    // Link order per the provider-ordering standard: email & password, Apple,
    // then Google.
    private static let linkProviderOrder: [CloudGatewayAuthProvider] = [.password, .apple, .google]

    public var missingLinkProviders: [CloudGatewayAuthProvider] {
        Self.linkProviderOrder.filter { !currentProviderIds.contains($0.rawValue) }
    }

    public var canLinkAnotherProvider: Bool {
        isSignedIn && !missingLinkProviders.isEmpty
    }

    public var linkPasswordDisabled: Bool {
        isWorking
            || linkEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || linkPassword.isEmpty
            || (accountLinkReauthMethod == .password && linkCurrentPassword.isEmpty)
    }

    private var currentProviderIds: [String] {
        linkedProviderIds.isEmpty ? service.providerIds() : linkedProviderIds
    }

    public var createDisabled: Bool {
        isWorking || newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedRegionAllowsCreate
    }

    public func deleteDisabled(for option: CloudGatewayClientOption) -> Bool {
        isWorking || !isSignedIn || option.client.status == .removed
    }

    public var isLoadingRegions: Bool {
        isWorking && regions.isEmpty
    }

    public var isLoadingClients: Bool {
        isSignedIn && isWorking && clientOptions.isEmpty
    }

    public init(
        service: CloudGatewayServicing,
        configManager: CloudGatewayConfigManager,
        healthReader: CloudGatewayTunnelHealthReading = NoopTunnelHealthReader(),
        notificationAuthorizer: CloudGatewayNotificationAuthorizing = NoopCloudGatewayNotificationAuthorizer(),
        presentationSleeper: any CloudGatewayPresentationSleeping = CloudGatewayContinuousPresentationSleeper(),
        deadTunnelDisconnectTimeout: Duration = .seconds(30),
        deadTunnelDisconnectPollInterval: Duration = .milliseconds(250)
    ) {
        self.service = service
        self.configManager = configManager
        self.healthReader = healthReader
        self.notificationAuthorizer = notificationAuthorizer
        self.presentationSleeper = presentationSleeper
        self.deadTunnelDisconnectTimeout = deadTunnelDisconnectTimeout
        self.deadTunnelDisconnectPollInterval = deadTunnelDisconnectPollInterval
        authRegistration = service.addAuthStateListener { [weak self] user in
            Task { @MainActor in
                await self?.handleAuthState(user)
            }
        }
        Task {
            await loadLocalState()
        }
    }

    deinit {
        authRegistration?.cancel()
    }

    public func signIn() async {
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

    public func resetPassword() async {
        await run {
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
                throw CloudGatewayAppError.accessDenied("Enter a valid email address.")
            }
            try await service.sendPasswordReset(email: trimmedEmail)
            successText = "Password reset email sent."
        }
    }

    public func completeAppleSignIn(idToken: String, rawNonce: String) async {
        await run {
            let user = try await service.signInWithApple(idToken: idToken, rawNonce: rawNonce)
            try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: true)
        }
    }

    public func signInWithGoogle() async {
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
    public func reportAppleSignInFailure() async {
        await run {
            throw CloudGatewayAppError.appleSignInFailed
        }
    }

    public func linkEmailPassword() async {
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

    public func linkGoogle() async {
        await linkAccountProvider(.google) {
            try await self.service.linkGoogle()
        }
    }

    public func linkApple(idToken: String, rawNonce: String) async {
        await linkAccountProvider(.apple) {
            try await self.service.linkApple(idToken: idToken, rawNonce: rawNonce)
        }
    }

    public func completeAccountLinkAppleReauth(idToken: String, rawNonce: String, authorizationCode: String) async {
        guard let pendingLinkProvider,
              let pendingLinkUserId,
              let user = service.currentUser,
              user.uid == pendingLinkUserId else {
            return
        }
        let generation = authStateGeneration
        await run {
            try ensureCurrentSession(user, generation: generation)
            try await performForCurrentUser(user, generation: generation) {
                try await service.reauthenticateWithApple(
                    idToken: idToken,
                    rawNonce: rawNonce,
                    authorizationCode: authorizationCode,
                    revoke: false
                )
            }
            accountLinkReauthMethod = .none
            switch pendingLinkProvider {
            case .password:
                let email = linkEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = linkPassword
                _ = try await performForCurrentUser(user, generation: generation) {
                    try await service.linkEmailPassword(email: email, password: password)
                }
            case .google:
                _ = try await performForCurrentUser(user, generation: generation) {
                    try await service.linkGoogle()
                }
            case .apple:
                throw CloudGatewayAppError.providerAlreadyLinked
            }
            didLinkProvider(pendingLinkProvider)
        }
    }

    public func clearAccountLinkState() {
        linkEmail = ""
        linkPassword = ""
        linkCurrentPassword = ""
        accountLinkReauthMethod = .none
        pendingLinkProvider = nil
        pendingLinkUserId = nil
    }

    public func signOut() async {
        await run {
            try service.signOut()
            try await loadGuestState()
        }
    }

    public func refresh() async {
        await reloadCurrentState(showsWorkingOverlay: true)
    }

    public func selectRegion(_ regionId: String) {
        selectedRegionId = regionId
        pruneSelectedClient()
    }

    public func refreshTunnelHealth() {
        let snapshot = healthReader.currentSnapshot()
        tunnelHealthSnapshot = snapshot?.isFresh(timing: .production) == true ? snapshot : nil
        if tunnelHealthSnapshot?.health != .notPassingTraffic {
            lastDeadTunnelStatusRefreshKey = nil
        }
    }

    public func presentationDidAppear() {
        refreshTunnelHealth()
    }

    public func monitorPresentationHealthAndStatus() async {
        presentationMonitorGeneration &+= 1
        let generation = presentationMonitorGeneration
        activePresentationMonitorGeneration = generation
        defer {
            if activePresentationMonitorGeneration == generation {
                activePresentationMonitorGeneration = nil
            }
        }

        while activePresentationMonitorGeneration == generation, !Task.isCancelled {
            await refreshTunnelHealthAndStatus(expectedPresentationMonitorGeneration: generation)
            guard activePresentationMonitorGeneration == generation, !Task.isCancelled else {
                return
            }
            do {
                try await presentationSleeper.sleep(for: Self.presentationRefreshInterval)
            } catch {
                return
            }
        }
    }

    public func refreshTunnelHealthAndStatus() async {
        await refreshTunnelHealthAndStatus(expectedPresentationMonitorGeneration: nil)
    }

    private func refreshTunnelHealthAndStatus(
        expectedPresentationMonitorGeneration: UInt64?
    ) async {
        refreshTunnelHealth()
        guard let snapshot = tunnelHealthSnapshot,
              snapshot.health == .notPassingTraffic else {
            return
        }
        let refreshKey = DeadTunnelStatusRefreshKey(
            tunnelIdentifier: snapshot.tunnelIdentifier,
            updatedAt: snapshot.updatedAt
        )
        guard refreshKey != lastDeadTunnelStatusRefreshKey,
              let state = try? await configManager.loadLocalState() else {
            return
        }
        guard !Task.isCancelled,
              expectedPresentationMonitorGeneration.map({
                  activePresentationMonitorGeneration == $0
              }) ?? true,
              let currentSnapshot = tunnelHealthSnapshot,
              currentSnapshot.health == .notPassingTraffic,
              DeadTunnelStatusRefreshKey(
                  tunnelIdentifier: currentSnapshot.tunnelIdentifier,
                  updatedAt: currentSnapshot.updatedAt
              ) == refreshKey else {
            return
        }
        applyLocal(state)
        lastDeadTunnelStatusRefreshKey = refreshKey
    }

    public func disconnectDeadTunnel() async {
        refreshTunnelHealth()
        guard tunnelHealthSnapshot?.health == .notPassingTraffic else {
            return
        }
        await run {
            var didDisconnect = false
            try await withDeadTunnelDisconnectTimeout {
                await self.refreshTunnelHealthAndStatus()
                try Task.checkCancellation()
                guard self.shouldShowDeadTunnelWarning,
                      let tunnelIdentifier = self.tunnelHealthSnapshot?.tunnelIdentifier else {
                    return
                }
                let state = try await self.configManager.stopTunnel(identifier: tunnelIdentifier)
                try Task.checkCancellation()
                self.apply(state)
                try await self.waitForDeadTunnelDisconnect(identifier: tunnelIdentifier)
                try Task.checkCancellation()
                didDisconnect = true
            }
            guard didDisconnect else { return }
            tunnelHealthSnapshot = nil
            // The tunnel is down, so the device now has direct internet. Reload
            // fresh state over the real network, mirroring pull-to-refresh, so
            // the user lands on an up-to-date dashboard instead of stale data.
            await reloadCurrentState(showsWorkingOverlay: false)
        }
    }

    private func waitForDeadTunnelDisconnect(identifier: String) async throws {
        while true {
            let statuses = try await configManager.allInstalledStatuses()
            try Task.checkCancellation()
            switch statuses[identifier] {
            case .invalid, .disconnected, nil:
                if let state = try? await configManager.loadLocalState(), !Task.isCancelled {
                    applyLocal(state)
                }
                return
            case .connecting, .connected, .reasserting, .disconnecting:
                break
            }

            try await ContinuousClock().sleep(for: deadTunnelDisconnectPollInterval)
        }
    }

    private func withDeadTunnelDisconnectTimeout(
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let race = CloudGatewayAsyncResult<Void>()
        let operationTask = Task { @MainActor in
            do {
                try await operation()
                await race.resolve(.success(()))
            } catch {
                await race.resolve(.failure(error))
            }
        }
        let timeout = deadTunnelDisconnectTimeout
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: timeout)
                await race.resolve(.failure(
                    CloudGatewayAppError.accessDenied(Self.deadTunnelDisconnectTimeoutMessage)
                ))
            } catch is CancellationError {
            } catch {
                await race.resolve(.failure(error))
            }
        }
        let result = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task {
                await race.resolve(.failure(CancellationError()))
            }
        }
        operationTask.cancel()
        timeoutTask.cancel()
        try result.get()
    }

    public func pullToRefresh() async {
        // SwiftUI cancels the .refreshable task when its pull control retracts,
        // and the early @Published updates in loadRemoteState can trigger that
        // retraction before the network reload finishes - silently aborting it
        // (run swallows the CancellationError). Run the reload in an independent
        // task so it always completes, while still awaiting it to keep the pull
        // spinner up until the refresh is done.
        await Task { await self.reloadCurrentState(showsWorkingOverlay: false) }.value
    }

    private func reloadCurrentState(showsWorkingOverlay: Bool) async {
        let generation = authStateGeneration
        await run(showsWorkingOverlay: showsWorkingOverlay) {
            if let user = service.currentUser {
                do {
                    try await loadRemoteStateOrSignOut(for: user, signOutOnAnyFailure: false)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isCurrentUser(user), isSignedIn {
                        try await applyRemoteRefreshUnavailable(for: user, generation: generation)
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
    public func continueAsGuest() async {
        await refresh()
    }

    public func grantAccess() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let generation = authStateGeneration
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
            let token = try await performForCurrentUser(user, generation: generation) { try await service.idToken() }
            let response = try await performForCurrentUser(user, generation: generation) {
                try await service.grantAccess(email: trimmedEmail, regionId: regionId, idToken: token)
            }
            newAccessEmail = ""
            successText = response.alreadyExisted
                ? "Existing account granted access: \(response.email)"
                : "User access granted: \(response.email)"
        }
    }

    public func createClient() async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let generation = authStateGeneration
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
            let token = try await performForCurrentUser(user, generation: generation) { try await service.idToken() }
            let created = try await performForCurrentUser(user, generation: generation) {
                try await service.createClient(
                    regionId: regionId,
                    clientName: trimmedClientName,
                    idToken: token
                )
            }
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
    public func deleteClient(_ option: CloudGatewayClientOption) async {
        await run {
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let generation = authStateGeneration
            try await performForCurrentUser(user, generation: generation) {
                try await ensureDestructiveOperationAllowed(
                    clientId: option.client.clientId,
                    message: Self.activeConfigDeleteMessage
                )
            }
            let token = try await performForCurrentUser(user, generation: generation) { try await service.idToken() }
            let response = try await performForCurrentUser(user, generation: generation) {
                try await service.deleteClient(
                    clientId: option.client.clientId,
                    userId: option.client.ownerUid ?? user.uid,
                    regionId: option.client.regionId,
                    idToken: token
                )
            }
            if selectedClientId == option.client.clientId {
                selectedClientId = nil
            }
            let state = try await configManager.removeInstalledConfigIfMatches(
                clientId: response.clientId,
                regionId: response.regionId
            )
            try ensureCurrentSession(user, generation: generation)
            apply(state)
            try await loadRemoteStateMarkingUnavailable(for: user)
            successText = "\(option.client.displayName) was deleted."
        }
    }

    public func deleteAccountWithPassword() async {
        await deleteAccount {
            let password = self.deleteAccountPassword
            guard !password.isEmpty else {
                throw CloudGatewayAppError.accessDenied("Enter your password to delete your account.")
            }
            try await self.service.reauthenticateWithPassword(password)
        }
    }

    public func deleteAccountWithGoogle() async {
        await deleteAccount {
            try await self.service.reauthenticateWithGoogle(revoke: true)
        }
    }

    public func deleteAccountWithApple(idToken: String, rawNonce: String, authorizationCode: String) async {
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
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let generation = authStateGeneration
            if accountLinkReauthMethod == .password {
                let password = linkCurrentPassword
                guard !password.isEmpty else {
                    throw CloudGatewayAppError.accessDenied("Enter your current password, then try again.")
                }
                try await performForCurrentUser(user, generation: generation) {
                    try await service.reauthenticateWithPassword(password)
                }
                accountLinkReauthMethod = .none
            }

            do {
                _ = try await performForCurrentUser(user, generation: generation, operation)
                didLinkProvider(provider)
            } catch CloudGatewayAppError.requiresRecentLogin {
                if try await prepareRecentLoginRecovery(for: provider, user: user, generation: generation) {
                    _ = try await performForCurrentUser(user, generation: generation, operation)
                    didLinkProvider(provider)
                }
            }
        }
    }

    private func prepareRecentLoginRecovery(
        for provider: CloudGatewayAuthProvider,
        user: AuthenticatedUser,
        generation: UInt64
    ) async throws -> Bool {
        pendingLinkProvider = provider
        pendingLinkUserId = user.uid
        let providerIds = currentProviderIds
        // Reauth order per the standard: Apple, then Google, then password last.
        if providerIds.contains(CloudGatewayAuthProvider.apple.rawValue) {
            accountLinkReauthMethod = .apple
            throw CloudGatewayAppError.accessDenied("Sign in with Apple again, then try linking once more.")
        }
        if providerIds.contains(CloudGatewayAuthProvider.google.rawValue) {
            try await performForCurrentUser(user, generation: generation) {
                try await service.reauthenticateWithGoogle(revoke: false)
            }
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
            guard let user = service.currentUser else {
                throw CloudGatewayAppError.missingCurrentUser
            }
            let generation = authStateGeneration
            try await performForCurrentUser(user, generation: generation) {
                try await ensureDestructiveOperationAllowed(message: Self.activeAccountDeleteMessage)
            }
            try await performForCurrentUser(user, generation: generation, reauthenticate)
            let token = try await performForCurrentUser(user, generation: generation) {
                try await service.idToken(forceRefresh: true)
            }
            do {
                _ = try await service.deleteAccount(idToken: token)
            } catch {
                try ensureCurrentSession(user, generation: generation)
                throw error
            }
            try ensureNoReplacementUser(user, generation: generation)
            try await removeInstalledConfigsAfterAccountDelete(for: user, generation: generation)
            try ensureNoReplacementUser(user, generation: generation)
            deleteAccountPassword = ""
            try service.signOut()
            try await loadGuestState()
        }
    }

    private func removeInstalledConfigsAfterAccountDelete(
        for user: AuthenticatedUser,
        generation: UInt64
    ) async throws {
        let cachedIdentifiers = installedSnapshots.map(\.clientId)
        // The account is already deleted server-side, so this local cleanup must
        // catch on-device profiles that are not in the cached snapshot. A
        // transient failure here would silently leave a stale system VPN
        // profile behind, so retry the live query briefly before giving up.
        let installedIdentifiers = await installedIdentifiersWithRetry()
        try ensureNoReplacementUser(user, generation: generation)
        for identifier in Set(cachedIdentifiers).union(installedIdentifiers) {
            try ensureNoReplacementUser(user, generation: generation)
            _ = try? await configManager.removeTunnel(identifier: identifier)
        }
        try ensureNoReplacementUser(user, generation: generation)
        if let state = try? await configManager.loadLocalState() {
            try ensureNoReplacementUser(user, generation: generation)
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

    // Install button for a not-yet-installed client: pull the latest config from
    // Firebase, then install, so a stale cached config is never installed.
    public func installFromCloud(_ option: CloudGatewayClientOption) async {
        await run {
            _ = try await pullFreshAndInstall(option)
        }
    }

    private func pullFreshAndInstall(_ option: CloudGatewayClientOption) async throws -> String {
        guard let user = service.currentUser else {
            throw CloudGatewayAppError.missingCurrentUser
        }
        let generation = authStateGeneration
        try await loadRemoteStateMarkingUnavailable(for: user)
        guard let freshOption = clientOptions.first(where: {
            $0.client.clientId == option.client.clientId
                && $0.client.regionId == option.client.regionId
                && $0.client.hasUsableConfig
        }) else {
            throw CloudGatewayAppError.accessDenied("This VPN client is not ready to install.")
        }
        // Fence the install tail like deleteClient: a user swap during the install
        // must not select or apply this stale flow's local result under the new
        // session. The device-local "pull fresh, then install" ordering is kept.
        let installedState = try await performForCurrentUser(user, generation: generation) {
            try await configManager.install(freshOption)
        }
        selectedClientId = freshOption.client.clientId
        apply(installedState)
        return freshOption.client.displayName
    }

    // The client whose tunnel is actually established (connected/reasserting), so
    // the switch prompt only offers to "turn off" a VPN that is really on - not one
    // that is merely mid-connect.
    public var activeTunnelClient: CloudGatewayClientOption? {
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
    public func switchTunnel(to option: CloudGatewayClientOption) async {
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

    public func startTunnel(for option: CloudGatewayClientOption) async {
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

    public func stopTunnel(for option: CloudGatewayClientOption) async {
        selectedClientId = option.client.clientId
        await stopTunnel()
    }

    public func tunnelStatusLabel(for option: CloudGatewayClientOption) -> String? {
        configState.tunnelStatus(for: option.client.clientId)?.displayName
    }

    public func staleText(for option: CloudGatewayClientOption) -> String? {
        configState.staleText(for: option.client.clientId)
    }

    public func dismissMessages() {
        errorText = nil
        successText = nil
    }

    public func installStateLabel(for option: CloudGatewayClientOption) -> String? {
        switch configState.installState(for: option) {
        case .installed:
            return nil
        case .updateAvailable:
            return "Update Available"
        case nil:
            return nil
        }
    }

    public func installDisabled(for option: CloudGatewayClientOption) -> Bool {
        isWorking || !isSignedIn || !option.client.hasUsableConfig
    }

    public func isInstalled(_ option: CloudGatewayClientOption) -> Bool {
        configState.installState(for: option) != nil
            && configState.tunnelStatus(for: option.client.clientId) != nil
    }

    private func ensureDestructiveOperationAllowed(clientId: String? = nil, message: String) async throws {
        let statuses = try await configManager.allInstalledStatuses()
        let statusValues: [CloudGatewayTunnelStatus]
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

    public func toggleDisabled(for option: CloudGatewayClientOption) -> Bool {
        let clientId = option.client.clientId
        let status = configState.tunnelStatus(for: clientId)
        return isWorking
            || !isSignedIn
            || status == nil
            || status == .invalid
            || configState.remoteInvalidInstalledConfig(for: clientId)
    }

    public func toggleIsOn(for option: CloudGatewayClientOption) -> Bool {
        switch configState.tunnelStatus(for: option.client.clientId) {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, nil:
            return false
        }
    }

    public func isToggling(for option: CloudGatewayClientOption) -> Bool {
        togglingClientId == option.client.clientId
    }

    private func handleAuthState(_ user: AuthenticatedUser?) async {
        let identityChanged: Bool
        if let user {
            identityChanged = appMode != .signedIn || signedInUid != user.uid
        } else {
            identityChanged = appMode != .guest
        }
        if identityChanged {
            authStateGeneration &+= 1
        }
        let generation = authStateGeneration
        if let user {
            let changedUser = identityChanged
            if changedUser {
                clearRemoteState()
            }
            signedInEmail = user.email
            signedInUid = user.uid
            refreshLinkedProviderIds()
            appMode = .signedIn
            if changedUser || loadedRemoteUserId != user.uid {
                await reloadAuthState(
                    for: user,
                    generation: generation
                )
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

    private func reloadAuthState(
        for user: AuthenticatedUser,
        generation: UInt64
    ) async {
        // Wait for the in-flight operation to finish instead of polling. The
        // check and the continuation append run without an intervening suspension,
        // so a `run` completing here always resumes this waiter (no lost wakeup).
        while isWorking {
            guard authStateGeneration == generation, isCurrentUser(user) else {
                return
            }
            await withCheckedContinuation { continuation in
                workDidFinishContinuations.append(continuation)
            }
        }
        guard authStateGeneration == generation,
              isCurrentUser(user),
              loadedRemoteUserId != user.uid else {
            return
        }
        await refresh()
    }

    private func loadLocalState() async {
        do {
            applyLocal(try await configManager.loadLocalState())
            CloudGatewayExistingInstallNotificationAuthorization.requestIfNeeded(
                hasInstalledConfig: hasInstalledConfig,
                authorizer: notificationAuthorizer
            )
            refreshTunnelHealth()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadRemoteStateMarkingUnavailable(
        for user: AuthenticatedUser,
        existingClients: [CloudGatewayClient] = []
    ) async throws {
        let generation = authStateGeneration
        do {
            try await loadRemoteState(
                for: user,
                existingClients: existingClients,
                generation: generation
            )
        } catch {
            try ensureCurrentSession(user, generation: generation)
            if isSignedIn {
                try await applyRemoteRefreshUnavailable(for: user, generation: generation)
            }
            throw error
        }
    }

    // A remote refresh failed (offline, API error, cold launch with no network).
    // Reload the local cache first so installed configs stay visible and
    // controllable, then flag them as stale/offline.
    private func applyRemoteRefreshUnavailable(
        for user: AuthenticatedUser,
        generation: UInt64
    ) async throws {
        _ = try? await configManager.loadLocalState()
        try ensureCurrentSession(user, generation: generation)
        var state = await configManager.markRemoteRefreshUnavailable()
        try ensureCurrentSession(user, generation: generation)
        if state.regions.isEmpty {
            state.regions = CloudGatewayConfigSelection.offlineRegions(from: state.installedSnapshots)
        }
        apply(state)
        remoteRefreshUnavailable = true
        ensureSelectedRegion()
        pruneSelectedClient()
    }

    private func loadRemoteState(
        for user: AuthenticatedUser,
        existingClients: [CloudGatewayClient],
        generation: UInt64
    ) async throws {
        try ensureCurrentSession(user, generation: generation)
        let isNewSignedInUser = appMode != .signedIn || signedInUid != user.uid
        signedInEmail = user.email
        signedInUid = user.uid
        refreshLinkedProviderIds()
        appMode = .signedIn
        let token = try await service.idToken()
        let enabledRegions = try await service.fetchRegions()
        guard !enabledRegions.isEmpty else {
            throw CloudGatewayAppError.noEnabledRegions
        }
        let access = try await service.checkAccess(idToken: token)
        // Explicitly flatten so both a missing UserRoles doc (fetch returns nil)
        // and a fetch failure fall back to the check-access role.
        let resolvedRole = ((try? await service.fetchUserRole(uid: user.uid)) ?? nil) ?? access.role
        try ensureCurrentSession(user, generation: generation)
        let regions = await service.addCapacity(to: enabledRegions, idToken: token)
        let fetchedClients = resolvedRole == "admin"
            ? try await service.fetchAllClients()
            : try await service.fetchOwnedClients(uid: user.uid)
        try ensureCurrentSession(user, generation: generation)
        let clients = merge(existingClients: existingClients, fetchedClients: fetchedClients)
        let state = try await configManager.applyRemoteState(regions: regions, clients: clients)
        try ensureCurrentSession(user, generation: generation)
        role = resolvedRole
        apply(state)
        loadedRemoteUserId = user.uid
        remoteRefreshUnavailable = false
        if isNewSignedInUser {
            selectedRegionId = nil
            selectedClientId = nil
        }
        ensureSelectedRegion()
        pruneSelectedClient()
    }

    private func ensureCurrentUser(_ user: AuthenticatedUser) throws {
        guard isCurrentUser(user) else {
            throw CancellationError()
        }
    }

    private func performForCurrentUser<T>(
        _ user: AuthenticatedUser,
        generation: UInt64? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        let generation = generation ?? authStateGeneration
        do {
            try ensureCurrentSession(user, generation: generation)
            let value = try await operation()
            try ensureCurrentSession(user, generation: generation)
            return value
        } catch {
            try ensureCurrentSession(user, generation: generation)
            throw error
        }
    }

    private func ensureCurrentSession(_ user: AuthenticatedUser, generation: UInt64) throws {
        guard authStateGeneration == generation else {
            throw CancellationError()
        }
        try ensureCurrentUser(user)
    }

    private func ensureNoReplacementUser(_ user: AuthenticatedUser, generation: UInt64) throws {
        guard service.currentUser?.uid == nil
                || (isCurrentUser(user) && authStateGeneration == generation) else {
            throw CancellationError()
        }
    }

    private func isCurrentUser(_ user: AuthenticatedUser) -> Bool {
        service.currentUser?.uid == user.uid
    }

    private func loadRemoteStateOrSignOut(
        for user: AuthenticatedUser,
        signOutOnAnyFailure: Bool
    ) async throws {
        let generation = authStateGeneration
        do {
            try await loadRemoteState(
                for: user,
                existingClients: [],
                generation: generation
            )
        } catch let loadError as CloudGatewayAppError {
            try ensureCurrentSession(user, generation: generation)
            if signOutOnAnyFailure || shouldSignOut(after: loadError) {
                try? service.signOut()
                await dropToGuest()
            }
            throw loadError
        } catch {
            try ensureCurrentSession(user, generation: generation)
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
        loadedRemoteUserId = nil
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
        if appMode != .guest {
            authStateGeneration &+= 1
        }
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
            regions: regions,
            clientOptions: clientOptions
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
                let waiters = workDidFinishContinuations
                workDidFinishContinuations.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        do {
            try await operation()
        } catch is CancellationError {
        } catch CloudGatewayAppError.cancelled {
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        } catch CloudGatewayVPNError.missingInstalledTunnel {
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

private actor CloudGatewayAsyncResult<Success: Sendable> {
    private var result: Result<Success, Error>?
    private var continuation: CheckedContinuation<Result<Success, Error>, Never>?

    func resolve(_ result: Result<Success, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func value() async -> Result<Success, Error> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private extension CloudGatewayTunnelStatus {
    // .connecting and .disconnecting deliberately show the optimistic final
    // state: Apple can report the transition for 10-15s after the toggle even
    // though Control Center flips in about a second. Matching Control Center
    // avoids a status label that looks stuck (see
    // CloudGatewayTunnelStatus.blocksDestructiveOperation for the same reasoning).
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
