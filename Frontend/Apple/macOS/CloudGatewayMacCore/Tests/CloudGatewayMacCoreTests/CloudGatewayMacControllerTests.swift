import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCore

@Test @MainActor func macControllerRestoresAccountAndHidesInventoryAfterSignOutWithoutStoppingVPN() async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }
    fixture.controller.start()
    #expect(fixture.auth.registrationCount == 1)
    #expect(fixture.snapshot.accountId == "user-a")
    #expect(fixture.snapshot.groups.flatMap(\.rows).map(\.identifier) == [fixture.config.identifier])
    #expect(try await fixture.cache.load(accountId: "user-a").accessAllowed)

    fixture.controller.signOut()
    let signedOut = fixture.snapshot
    #expect(signedOut.accountId == nil)
    #expect(signedOut.groups.isEmpty)
    #expect(signedOut.lastSelectedIdentifier == nil)
    #expect(signedOut.reconnectIdentifier == nil)
    #expect(!signedOut.canCreateClient)
    #expect(!signedOut.canToggleVPN)
    #expect(signedOut.hasActiveTunnel)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: MacControllerRestoreCase.allCases)
@MainActor private func macControllerOfflineRestoreRequiresAuthorizedCacheForTheCurrentAccount(
    scenario: MacControllerRestoreCase
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    if scenario == .deniedCache { try await fixture.cache.deny(accountId: "user-a") }
    if scenario == .otherAccount { fixture.auth.emit(AuthenticatedUser(uid: "user-b", email: nil)) }
    fixture.inventory.accessError = scenario == .unavailable ? CloudGatewayMacInventoryError.unavailable
        : scenario == .accessDenied ? CloudGatewayMacInventoryError.accessDenied : CloudGatewayMacInventoryError.offline
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.snapshot.isRestoringSession }
    try await controllerWaitUntil { await fixture.profiles.completedReads == 1 }

    if scenario == .authorizedCache {
        try await controllerWaitUntil { fixture.snapshot.reconnectIdentifier == fixture.config.identifier }
        #expect(fixture.snapshot.accountId == "user-a")
        #expect(fixture.snapshot.groups.flatMap(\.rows).map(\.identifier) == [fixture.config.identifier])
        #expect(fixture.snapshot.reconnectIdentifier == fixture.config.identifier)
        #expect(fixture.snapshot.statusTitle == "VPN off")
        #expect(!fixture.snapshot.canCreateClient)
    } else {
        #expect(fixture.snapshot.accountId == nil)
        #expect(fixture.snapshot.groups.isEmpty)
        #expect(fixture.snapshot.reconnectIdentifier == nil)
        #expect(fixture.snapshot.errorMessage != nil)
    }
    #expect(fixture.inventory.fetchCount == 0)
    if scenario == .accessDenied {
        #expect(fixture.auth.currentUser == nil)
        #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed))
    }
}

@Test @MainActor func macControllerConnectUsesStoredReadinessInsteadOfPresentationReadiness() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start(ready: false)
    defer { fixture.controller.shutdown() }
    #expect(fixture.snapshot.groups.flatMap(\.rows).first?.isEnabled == true)
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier))
    #expect(fixture.snapshot.canCreateClient)
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)

    fixture.controller.setSetupState(.ready)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.lastSelectedIdentifier == fixture.config.identifier }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
}

@Test(arguments: ["user-a", "user-b"])
@MainActor func macControllerRejectsCreationContextAfterSessionOrAccountChange(nextAccount: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let stale = try #require(fixture.controller.clientCreationContext())
    fixture.controller.signOut()
    fixture.auth.emit(AuthenticatedUser(uid: nextAccount, email: nil))
    try await controllerWaitUntil { fixture.snapshot.accountId == nextAccount && fixture.snapshot.canCreateClient }
    #expect(fixture.controller.clientCreationContext() != stale)
    await #expect(throws: CancellationError.self) {
        try await fixture.controller.loadCreateRegions(context: stale)
    }
    #expect(fixture.inventory.regionsCount == 0)
    #expect(!fixture.controller.createClient(regionId: "region", clientName: "Stale", context: stale))
    #expect(fixture.snapshot.canCreateClient)
    #expect(fixture.inventory.createdNames.isEmpty)

    let current = try #require(fixture.controller.clientCreationContext())
    #expect(fixture.controller.createClient(regionId: "region", clientName: "Current", context: current))
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(fixture.inventory.createdNames == ["Current"])
    #expect(fixture.inventory.createdAccountIds == [nextAccount])
}

@Test @MainActor func macControllerDiscardsRegionResponseAfterAccountChanges() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let gate = MacControllerGate()
    fixture.inventory.regionsGate = gate
    let context = try #require(fixture.controller.clientCreationContext())
    let request = Task { try await fixture.controller.loadCreateRegions(context: context) }
    try await controllerWaitUntil { await gate.entered }
    fixture.auth.emit(AuthenticatedUser(uid: "user-b", email: nil))
    try await controllerWaitUntil { fixture.snapshot.accountId == "user-b" && fixture.snapshot.canCreateClient }
    await gate.release()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(fixture.snapshot.accountId == "user-b")
    #expect(fixture.snapshot.errorMessage == nil)
}

@Test(arguments: [false, true])
@MainActor func macControllerCreationAccessDenialInvalidatesOfflineAuthorization(duringCreate: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    if duringCreate {
        fixture.inventory.createError = CloudGatewayAppError.apiAccessDenied("Account access denied")
        let context = try #require(fixture.controller.clientCreationContext())
        fixture.controller.createClient(regionId: "region", clientName: "New Mac", context: context)
        try await controllerWaitUntil { fixture.auth.currentUser == nil }
    } else {
        fixture.inventory.regionsError = CloudGatewayMacInventoryError.accessDenied
        let context = try #require(fixture.controller.clientCreationContext())
        await #expect(throws: CloudGatewayMacInventoryError.accessDenied) {
            try await fixture.controller.loadCreateRegions(context: context)
        }
    }
    #expect(fixture.snapshot.accountId == nil)
    #expect(fixture.snapshot.groups.isEmpty)
    #expect(fixture.snapshot.errorMessage?.contains("access was denied") == true)
    let reopened = CloudGatewayMacAccountCache(directory: fixture.directory)
    let denied = try await reopened.load(accountId: "user-a")
    #expect(!denied.accessAllowed)
    #expect(denied.configs.isEmpty)
    #expect(denied.selectedIdentifier == nil)
}

@Test @MainActor func macControllerAcceptedConnectSurvivesFrontendCancellationAndObserverRemoval() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    let frontendLifetime = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var notifications = 0
    fixture.controller.onChange = { notifications += 1 }
    let frontend = Task {
        fixture.controller.connectClient(identifier: fixture.config.identifier)
        await frontendLifetime.arriveAndWait()
    }
    try await controllerWaitUntil { await authorization.entered }
    #expect(fixture.controller.hasPendingWork)
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier))
    #expect(!fixture.controller.turnOff())
    #expect(notifications > 0)
    fixture.controller.onChange = nil
    frontend.cancel()
    await frontendLifetime.release()
    await frontend.value
    await authorization.release()
    try await controllerWaitUntil {
        fixture.snapshot.lastSelectedIdentifier == fixture.config.identifier && fixture.snapshot.canCreateClient
    }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(try await fixture.cache.load(accountId: "user-a").selectedIdentifier == fixture.config.identifier)
    #expect(fixture.snapshot.errorMessage == nil)
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
}

@Test @MainActor func macControllerAcceptedCreationSurvivesFrontendCancellationAndObserverRemoval() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let context = try #require(fixture.controller.clientCreationContext())
    let creation = MacControllerGate()
    let frontendLifetime = MacControllerGate()
    fixture.inventory.createGate = creation
    var notifications = 0
    fixture.controller.onChange = { notifications += 1 }
    let frontend = Task {
        fixture.controller.createClient(regionId: "region", clientName: "New Mac", context: context)
        await frontendLifetime.arriveAndWait()
    }
    try await controllerWaitUntil { await creation.entered }
    #expect(notifications > 0)
    fixture.controller.onChange = nil
    frontend.cancel()
    await frontendLifetime.release()
    await frontend.value
    let created = fixture.option(clientId: "created", name: "New Mac")
    fixture.inventory.options = [created]
    await creation.release()
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(fixture.inventory.createdNames == ["New Mac"])
    #expect(fixture.snapshot.groups.flatMap(\.rows).map(\.identifier) == ["user-a/region/created"])
    #expect(fixture.snapshot.errorMessage == nil)
    #expect(try await fixture.cache.load(accountId: "user-a").accessAllowed)
}

@Test @MainActor func macControllerReportsConfirmedCreationWhenInventoryRefreshFails() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let context = try #require(fixture.controller.clientCreationContext())
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.unavailable
    #expect(fixture.controller.createClient(regionId: "region", clientName: "Work Mac", context: context))
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(fixture.inventory.createdNames == ["Work Mac"])
    #expect(fixture.snapshot.errorMessage == "Client was created, but the client list could not refresh. Choose Refresh before trying again")
}

@Test @MainActor func macControllerKeepsActiveTunnelDuringDelayedAndFailedProfileReads() async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }
    let delayed = MacControllerGate()
    await fixture.profiles.setProfiles([])
    await fixture.profiles.pauseNextRead(delayed)
    fixture.controller.profilesDidChange()
    try await controllerWaitUntil { await delayed.entered }
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.canTurnOff)

    await fixture.profiles.failReads()
    fixture.controller.profilesDidChange()
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.canTurnOff)
    await delayed.release()
    try await controllerWaitUntil { await fixture.profiles.completedReads >= 3 }
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.errorMessage == "Unable to read VPN preferences. Try Refresh again")
}

@Test @MainActor func macControllerShutdownDetachesAuthListenerAndRejectsFutureCommands() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { await fixture.profiles.completedReads == 1 }
    let context = try #require(fixture.controller.clientCreationContext())
    let accessCount = fixture.inventory.accessCount
    let readCount = await fixture.profiles.readCount
    var notifications = 0
    fixture.controller.onChange = { notifications += 1 }
    fixture.controller.shutdown()
    fixture.controller.shutdown()
    #expect(!fixture.auth.listenerIsActive)
    #expect(fixture.controller.onChange == nil)
    fixture.auth.emit(AuthenticatedUser(uid: "user-b", email: nil))
    fixture.controller.start()
    fixture.controller.signIn()
    fixture.controller.signOut()
    fixture.controller.cancelSignIn()
    fixture.controller.refresh()
    fixture.controller.menuWillOpen()
    fixture.controller.profilesDidChange()
    fixture.controller.setSetupState(.required)
    fixture.controller.connectClient(identifier: fixture.config.identifier)
    fixture.controller.createClient(regionId: "region", clientName: "Too late", context: context)
    fixture.controller.turnOff()
    await #expect(throws: CancellationError.self) { try await fixture.controller.loadCreateRegions(context: context) }
    #expect(fixture.inventory.accessCount == accessCount)
    #expect(fixture.inventory.createdNames.isEmpty)
    #expect(fixture.inventory.regionsCount == 0)
    #expect(await fixture.deviceAuth.requestCount == 0)
    #expect(await fixture.profiles.readCount == readCount)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(fixture.auth.registrationCount == 1)
    #expect(fixture.auth.signOutCount == 0)
    #expect(fixture.controller.clientCreationContext() == nil)
    #expect(!fixture.snapshot.canCreateClient)
    #expect(notifications == 0)
}

@Test(arguments: [false, true])
@MainActor func macControllerShowsVPNOffBeforeCloudRefreshFinishes(refreshFails: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }

    let refresh = MacControllerGate()
    fixture.inventory.fetchGate = refresh
    if refreshFails { fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline }
    fixture.controller.refresh()
    try await controllerWaitUntil { await refresh.entered }
    #expect(fixture.snapshot.inventoryInFlight)
    #expect(fixture.controller.turnOff())
    try await controllerWaitUntil { fixture.snapshot.statusTitle == "VPN off" }
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(!fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.inventoryInFlight)

    await refresh.release()
    try await controllerWaitUntil { !fixture.snapshot.inventoryInFlight }
    #expect(fixture.snapshot.statusTitle == "VPN off")
    #expect(fixture.snapshot.reconnectIdentifier == fixture.config.identifier)
    #expect(fixture.snapshot.errorMessage == nil)
}

@Test(arguments: [false, true])
@MainActor func macControllerConnectsAuthorizedConfigsWhileRefreshIsStalled(profileExists: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    if profileExists { await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)]) }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let refresh = MacControllerGate()
    fixture.inventory.fetchGate = refresh
    fixture.controller.refresh()
    try await controllerWaitUntil { await refresh.entered }
    #expect(fixture.snapshot.inventoryInFlight)
    #expect(fixture.snapshot.canToggleVPN)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.savedIdentifiers == (profileExists ? [] : [fixture.config.identifier]))
    #expect(!fixture.snapshot.inventoryInFlight)
    #expect(fixture.snapshot.errorMessage == nil)
    await refresh.release()
}

@Test @MainActor func macControllerInstallsAnInMemoryConfigWithoutWaitingForRefresh() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let refresh = MacControllerGate()
    fixture.inventory.fetchGate = refresh
    fixture.controller.refresh()
    try await controllerWaitUntil { await refresh.entered }
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.lastSelectedIdentifier == fixture.config.identifier }
    #expect(await fixture.secrets.installCount == 1)
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(fixture.snapshot.errorMessage == nil)
    await refresh.release()
}

@Test @MainActor func macControllerExposesCachedConfigsBeforeInitialInventoryFinishes() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let refresh = MacControllerGate()
    fixture.inventory.fetchGate = refresh
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await refresh.entered }
    #expect(fixture.snapshot.inventoryInFlight)
    #expect(fixture.snapshot.canToggleVPN)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.savedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.secrets.installCount == 0)
    await refresh.release()
}

@Test @MainActor func macControllerRestoresACachedProfileWithoutCloudAccess() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.canToggleVPN }
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { await fixture.profiles.startedIdentifiers == [fixture.config.identifier] }
    #expect(await fixture.profiles.savedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.secrets.installCount == 0)
    #expect(fixture.inventory.fetchCount == 0)
}

@Test @MainActor func macControllerRejectsCachedConfigAfterAuthorizationWasInvalidated() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await fixture.cache.deny(accountId: "user-a")
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerCannotRestoreCachedConfigWithAMissingSecret() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    await fixture.secrets.setAvailable(false)
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.canToggleVPN }
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerMenuOpenReusesRecentInventoryAndExplicitRefreshStillFetches() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.controller.menuWillOpen()
    fixture.controller.menuWillOpen()
    #expect(!fixture.snapshot.inventoryInFlight)
    #expect(fixture.inventory.fetchCount == fetches)
    fixture.controller.refresh()
    try await controllerWaitUntil { !fixture.snapshot.inventoryInFlight }
    #expect(fixture.inventory.fetchCount == fetches + 1)
}

private enum MacControllerRestoreCase: CaseIterable, Sendable {
    case authorizedCache, deniedCache, otherAccount, unavailable, accessDenied
}

private struct MacControllerWaitTimeout: Error {}

@MainActor
private func controllerWaitUntil(
    _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<5000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Controller did not reach the expected state", sourceLocation: sourceLocation)
    throw MacControllerWaitTimeout()
}

private let controllerWireGuardConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
AllowedIPs = 0.0.0.0/0
Endpoint = wg.example.com:51820
"""

@MainActor
private struct MacControllerFixture {
    let directory: URL
    let auth: MacControllerAuth
    let deviceAuth: MacControllerDeviceAuth
    let inventory: MacControllerInventory
    let profiles: MacControllerProfiles
    let secrets: MacControllerSecrets
    let cache: CloudGatewayMacAccountCache
    let config: CloudGatewayMacInstalledConfig
    let controller: CloudGatewayMacController

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayControllerTests-\(UUID())")
        auth = MacControllerAuth()
        deviceAuth = MacControllerDeviceAuth()
        inventory = MacControllerInventory()
        profiles = MacControllerProfiles()
        let reference = try CloudGatewayMacSecretReference(value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        secrets = MacControllerSecrets(reference: reference)
        cache = CloudGatewayMacAccountCache(directory: directory)
        config = CloudGatewayMacInstalledConfig(
            accountId: "user-a", identifier: "user-a/region/client",
            snapshot: CloudGatewayConfigSnapshot(
                clientId: "client", regionId: "region", clientName: "Mac", regionDisplayName: "Region",
                status: .active, configHash: CloudGatewayConfigHash.make(for: try CloudGatewayWireGuardConfig(controllerWireGuardConfig)),
                secretReference: CloudGatewayConfigSecretReference(
                    service: CloudGatewayMacInstalledConfig.secretService, account: reference.value
                ), readAt: Date(timeIntervalSince1970: 1), updatedAt: nil
            )
        )
        controller = CloudGatewayMacController(
            auth: auth, deviceAuth: deviceAuth, inventory: inventory, profiles: profiles, cache: cache,
            configs: CloudGatewayMacConfigCoordinator(secrets: secrets, profiles: profiles, snapshots: cache),
            dashboardOrigin: URL(string: "https://dashboard.example.com")!
        )
        inventory.options = [option()]
    }

    var snapshot: CloudGatewayMacControllerSnapshot { controller.snapshot(setupState: .ready) }

    func option(clientId: String = "client", name: String = "Mac") -> CloudGatewayClientOption {
        CloudGatewayClientOption(
            client: CloudGatewayClient(
                clientId: clientId, clientName: name, regionId: "region", status: .active,
                wireGuardConfig: controllerWireGuardConfig, ownerUid: "user-a"
            ), region: CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true)
        )
    }

    func profile(status: CloudGatewayTunnelStatus) throws -> CloudGatewayMacInstalledProfile {
        CloudGatewayMacInstalledProfile(identifier: config.identifier, reference: try config.reference, status: status)
    }

    func seedCache() async throws {
        try await cache.authorize(accountId: "user-a", role: .user, options: [option()])
        try await cache.save(config)
        try await cache.select(identifier: config.identifier, accountId: "user-a")
    }

    func start(ready: Bool = true) async throws {
        if ready { controller.setSetupState(.ready) }
        controller.start()
        try await controllerWaitUntil { snapshot.canCreateClient && !snapshot.isRestoringSession }
    }
}

@MainActor
private final class MacControllerAuth: CloudGatewayMacControllerAuthServicing {
    var currentUser: AuthenticatedUser? = AuthenticatedUser(uid: "user-a", email: nil)
    let isCustomTokenSignInSettling = false
    private var listener: ((AuthenticatedUser?) -> Void)?
    private let listenerState = MacControllerListenerState()
    private(set) var registrationCount = 0
    private(set) var signOutCount = 0

    var listenerIsActive: Bool { listenerState.active.withLock { $0 } }

    func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        registrationCount += 1
        self.listener = listener
        listenerState.active.withLock { $0 = true }
        return CloudGatewayAuthStateListenerRegistration { [listenerState] in
            listenerState.active.withLock { $0 = false }
        }
    }

    func emit(_ user: AuthenticatedUser?) {
        currentUser = user
        if listenerIsActive { listener?(user) }
    }

    func signIn(customToken: String) async throws -> AuthenticatedUser {
        throw CloudGatewayDeviceAuthError.unavailable
    }

    func cancelCustomTokenSignIn() throws {}

    func signOut() throws {
        signOutCount += 1
        emit(nil)
    }
}

private final class MacControllerListenerState: Sendable {
    let active = Mutex(false)
}

private actor MacControllerDeviceAuth: CloudGatewayDeviceAuthServicing {
    private(set) var requestCount = 0

    func requestCode(secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceCode {
        requestCount += 1
        throw CloudGatewayDeviceAuthError.unavailable
    }

    func pollToken(requestId: String, secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceTokenResult {
        throw CloudGatewayDeviceAuthError.unavailable
    }
}

@MainActor
private final class MacControllerInventory: CloudGatewayMacInventoryServicing {
    var options: [CloudGatewayClientOption] = []
    var accessError: (any Error)?
    var regionsError: (any Error)?
    var createError: (any Error)?
    var fetchError: (any Error)?
    var regionsGate: MacControllerGate?
    var createGate: MacControllerGate?
    var fetchGate: MacControllerGate?
    private(set) var accessCount = 0
    private(set) var fetchCount = 0
    private(set) var regionsCount = 0
    private(set) var createdNames: [String] = []
    private(set) var createdAccountIds: [String] = []

    func checkAccess(for _: AuthenticatedUser) async throws -> CloudGatewayMacAccountRole {
        accessCount += 1
        if let accessError { throw accessError }
        return .user
    }

    func fetchOptions(for user: AuthenticatedUser, role _: CloudGatewayMacAccountRole) async throws -> [CloudGatewayClientOption] {
        fetchCount += 1
        await fetchGate?.arriveAndWait()
        if let fetchError { throw fetchError }
        return options.filter { $0.client.ownerUid == user.uid }
    }

    func fetchCreateRegions(for _: AuthenticatedUser) async throws -> [CloudGatewayRegion] {
        regionsCount += 1
        await regionsGate?.arriveAndWait()
        if let regionsError { throw regionsError }
        return [CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true)]
    }

    func createClient(regionId _: String, clientName: String, for user: AuthenticatedUser) async throws -> String {
        createdNames.append(clientName)
        createdAccountIds.append(user.uid)
        await createGate?.arriveAndWait()
        try Task.checkCancellation()
        if let createError { throw createError }
        return clientName
    }
}

private actor MacControllerProfiles: CloudGatewayMacProfileAdapter {
    private var values: [CloudGatewayMacInstalledProfile] = []
    private var nextReadGate: MacControllerGate?
    private var readFails = false
    private(set) var readCount = 0
    private(set) var completedReads = 0
    private(set) var startedIdentifiers: [String] = []
    private(set) var savedIdentifiers: [String] = []
    private(set) var stoppedIdentifiers: [String] = []

    func setProfiles(_ profiles: [CloudGatewayMacInstalledProfile]) { values = profiles }
    func pauseNextRead(_ gate: MacControllerGate) { nextReadGate = gate }
    func failReads() { readFails = true }

    func installedProfiles() async throws -> [CloudGatewayMacInstalledProfile] {
        readCount += 1
        defer { completedReads += 1 }
        let snapshot = values
        let shouldFail = readFails
        let gate = nextReadGate
        nextReadGate = nil
        await gate?.arriveAndWait()
        if shouldFail { throw CloudGatewayMacConfigError.unavailable }
        return snapshot
    }

    func saveAndReload(_ config: CloudGatewayMacInstalledConfig) async throws {
        try Task.checkCancellation()
        savedIdentifiers.append(config.identifier)
        values.removeAll { $0.identifier == config.identifier }
        values.append(CloudGatewayMacInstalledProfile(
            identifier: config.identifier, reference: try config.reference, status: .disconnected
        ))
    }

    func start(identifier: String, grant: String) async throws {
        try Task.checkCancellation()
        startedIdentifiers.append(identifier)
    }

    func stopAndWait(identifier: String) async throws {
        try Task.checkCancellation()
        stoppedIdentifiers.append(identifier)
        values = values.map {
            $0.identifier == identifier
                ? CloudGatewayMacInstalledProfile(identifier: $0.identifier, reference: $0.reference, status: .disconnected)
                : $0
        }
    }
}

private actor MacControllerSecrets: CloudGatewayMacSecretClient {
    let reference: CloudGatewayMacSecretReference
    private var authorizationGate: MacControllerGate?
    private var available = true
    private(set) var installCount = 0

    init(reference: CloudGatewayMacSecretReference) { self.reference = reference }
    func pauseAuthorization(_ gate: MacControllerGate) { authorizationGate = gate }
    func setAvailable(_ available: Bool) { self.available = available }

    func install(configId: String, config: CloudGatewayWireGuardConfig) async throws -> CloudGatewayMacSecretReference {
        try Task.checkCancellation()
        installCount += 1
        return reference
    }

    func commit(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
    }

    func rollback(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
    }

    func isAvailable(reference: CloudGatewayMacSecretReference, configId: String) async throws -> Bool {
        try Task.checkCancellation()
        return available
    }

    func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String) async throws -> String {
        await authorizationGate?.arriveAndWait()
        try Task.checkCancellation()
        return "synthetic-start-grant"
    }
}

private actor MacControllerGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
