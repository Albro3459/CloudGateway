import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCLI

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
    #expect(fixture.domainSnapshot.domain.access == .online)

    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    let signedOut = fixture.snapshot
    #expect(signedOut.accountId == nil)
    #expect(signedOut.groups.isEmpty)
    #expect(signedOut.lastSelectedIdentifier == nil)
    #expect(signedOut.reconnectIdentifier == nil)
    #expect(!signedOut.canCreateClient)
    #expect(signedOut.canTurnOff)
    #expect(signedOut.hasActiveTunnel)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerRestoredSessionAllowsMenuRemovalWithoutBrowserSignIn(offline: Bool) async throws {
    let fixture = try MacControllerFixture()
    if offline {
        try await fixture.seedCache()
        fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    #expect(fixture.snapshot.accountId == "user-a")
    #expect(fixture.domainSnapshot.domain.accessAuthorized)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == (offline ? .cached : .current))
    #expect(fixture.snapshot.browserState == .signedOut)
    #expect(fixture.snapshot.canRemoveClient)
    #expect(await fixture.deviceAuth.requestCount == 0)

    #expect(await fixture.controller.awaitRefresh() == (offline ? .unavailable : .refreshed))
    #expect(fixture.snapshot.canRemoveClient)
    #expect(fixture.controller.signOut())
    #expect(!fixture.snapshot.canRemoveClient)
}

@Test(arguments: [false, true])
@MainActor func macControllerOnlineInventoryRepairsInvalidAdminCache(validJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedInvalidAdminCache(validJSON: validJSON)
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    #expect(fixture.inventory.fetchCount == 1)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [fixture.config.identifier])
    let rewritten = try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a")
    #expect(rewritten.accessAllowed)
    #expect(rewritten.configs.isEmpty)
    #expect(rewritten.selectedIdentifier == nil)
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.inventory.fetchCount == 2)
}

@Test(arguments: [CloudGatewayMacInventoryError.offline, .accessDenied])
@MainActor func macControllerInvalidCacheStillRejectsOfflineAndDeniedInventory(
    failure: CloudGatewayMacInventoryError
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedInvalidAdminCache()
    fixture.inventory.fetchError = failure
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == 1)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers.isEmpty)
    #expect(fixture.snapshot.lastSelectedIdentifier == nil)
    #expect(!fixture.snapshot.canRemoveClient)
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
    if failure == .offline {
        #expect(fixture.auth.currentUser?.uid == "user-a")
        #expect(fixture.domainSnapshot.domain.inventoryFreshness == .unavailable)
        await #expect(throws: CloudGatewayMacCacheError.unavailable) {
            try await fixture.cache.load(accountId: "user-a")
        }
    } else {
        #expect(fixture.auth.currentUser == nil)
        #expect(fixture.domainSnapshot.domain.access == .denied)
        #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed))
    }
}

@Test @MainActor func macControllerCacheRecoveryRequiresAuthoritativePersistence() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedInvalidAdminCache()
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await fetch.entered }
    let namespace = try #require(FileManager.default.contentsOfDirectory(
        at: fixture.directory, includingPropertiesForKeys: nil
    ).first)
    try FileManager.default.moveItem(at: namespace, to: fixture.directory.appendingPathComponent("backup"))
    try Data("block writes".utf8).write(to: namespace)
    await fetch.release()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .unavailable)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.snapshot.lastSelectedIdentifier == nil)
    #expect(await fixture.controller.awaitRefresh() == .unavailable)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerReportsFailedSignOutCleanupAndAllowsRetry(suppressesSession: Bool) async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }
    fixture.auth.signOutError = .unavailable
    fixture.auth.suppressesFailedSignOut = suppressesSession

    #expect(!fixture.controller.signOut())
    #expect(fixture.domainSnapshot.browserState == .failed(.unavailable))
    #expect(fixture.domainSnapshot.isAuthSettling == suppressesSession)
    #expect(fixture.domainSnapshot.domain.accountId == nil)
    #expect(!fixture.domainSnapshot.domain.accessAuthorized)
    #expect(fixture.auth.currentUser?.uid == (suppressesSession ? nil : "user-a"))
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)

    fixture.auth.signOutError = nil
    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.domainSnapshot.browserState == .signedOut)
    #expect(!fixture.domainSnapshot.isAuthSettling)
    #expect(fixture.auth.currentUser == nil)
    #expect(fixture.snapshot.hasActiveTunnel)
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
        #expect(fixture.snapshot.canCreateClient)
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
    let domain = fixture.domainSnapshot.domain
    let expected: [MacControllerRestoreCase: CloudGatewayMacAccessState] = [
        .authorizedCache: .offline, .deniedCache: .unreachable, .otherAccount: .unreachable,
        .unavailable: .unreachable, .accessDenied: .denied
    ]
    #expect(domain.access == expected[scenario])
    #expect(domain.hasRetainedSession == (scenario != .accessDenied))
    #expect(domain.credentials == (scenario == .accessDenied ? .unknown : .available))
}

@Test @MainActor func macControllerPublishesRawClientMetadataAndEligibility() async throws {
    let fixture = try MacControllerFixture()
    fixture.inventory.options = [
        ("active", CloudGatewayClientStatus.active, true, controllerWireGuardConfig),
        ("creating", .creating, true, controllerWireGuardConfig),
        ("removed", .removed, true, controllerWireGuardConfig),
        ("disabled", .active, false, controllerWireGuardConfig),
        ("missing", .active, true, "")
    ].map { id, status, enabled, config in
        CloudGatewayClientOption(
            client: CloudGatewayClient(
                clientId: id, clientName: "Mac \(id)", regionId: id, status: status,
                wireGuardConfig: config, assignedTunnelIpv4: "10.0.0.9", updatedAt: Date(timeIntervalSince1970: 42),
                ownerUid: "user-a", ownerEmail: "Owner Label"
            ),
            region: CloudGatewayRegion(regionId: id, displayName: "Region \(id)", enabled: enabled, displayOrder: 7)
        )
    }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let domain = fixture.domainSnapshot.domain
    #expect(domain.accessAuthorized)
    #expect(domain.clients.map(\.identifier) == ["user-a/active/active", "user-a/creating/creating", "user-a/disabled/disabled", "user-a/missing/missing"])
    #expect(domain.clients.map(\.eligibility) == [.eligible, .inactive, .regionUnavailable, .configMissing])
    #expect(domain.clients.map(\.cloudState) == [.active, .creating, .active, .active])
    #expect(domain.clients.allSatisfy { $0.source == .cloud && $0.readAt == fixture.clock.now && !$0.isInstalled })
    #expect(domain.clients.allSatisfy { $0.internalIp == "10.0.0.9" && $0.updatedAt == Date(timeIntervalSince1970: 42) })
    let active = try #require(domain.clients.first { $0.eligibility == .eligible })
    #expect(active.clientName == "Mac active")
    #expect(active.ownerLabel == "Owner Label")
    #expect(active.regionId == "active")
    #expect(active.regionName == "Region active")
    #expect(active.regionOrder == 7)
    #expect(active.status == nil)
    #expect(domain.clients.filter { $0.eligibility == .eligible }.count == 1)
    let rows = fixture.snapshot.groups.flatMap(\.rows)
    #expect(rows.first { $0.identifier == active.identifier }?.title == "Mac active (Owner Label)")
    for client in domain.clients where client.eligibility != .eligible {
        #expect(rows.first { $0.identifier == client.identifier }?.isEnabled == false)
        #expect(!fixture.controller.connectClient(identifier: client.identifier))
    }
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test(arguments: [false, true], [nil, "", "  \n ", "wg.region.example.com"] as [String?])
@MainActor func macControllerDetailsUseCloudAndSavedEndpointFallback(offline: Bool, hostname: String?) async throws {
    let fixture = try MacControllerFixture()
    let option = fixture.option(hostname: hostname, ipv4: "192.0.2.7", ownerEmail: "owner@example.com", assignedIp: "10.0.0.2/32")
    fixture.inventory.options = [option]
    if offline {
        try await fixture.cache.authorize(accountId: "user-a", role: .user, options: [option])
        let snapshot = fixture.config.snapshot
        try await fixture.cache.save(.init(accountId: "user-a", identifier: fixture.config.identifier, snapshot: .init(
            clientId: snapshot.clientId, regionId: snapshot.regionId, clientName: snapshot.clientName,
            regionDisplayName: snapshot.regionDisplayName, status: snapshot.status, configHash: snapshot.configHash,
            secretReference: snapshot.secretReference, readAt: snapshot.readAt, updatedAt: snapshot.updatedAt,
            assignedTunnelIpv4: "10.0.0.2/32", serverEndpointIpv4: "192.0.2.7", serverEndpointHostname: hostname
        )))
        fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let client = try #require(fixture.domainSnapshot.domain.clients.first)
    #expect(client.clientId == "client")
    #expect(client.connectionUrl == (hostname == "wg.region.example.com" ? hostname : "192.0.2.7"))
    #expect(client.ownerLabel == (offline ? nil : "owner@example.com"))
    #expect(client.source == (offline ? .cache : .cloud))
    #expect(client.internalIp == "10.0.0.2/32")
    let state = CloudGatewayMacControllerState(snapshot: fixture.domainSnapshot, setupState: .ready, canUpdateExtension: false)
    let payload = CloudGatewayMacControllerProtocol.encodeReply(
        .init(state: state), appVersion: "1.0", appBuild: "2", instanceId: UUID()
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(payload, appVersion: "1.0", appBuild: "2")
    let decoded = try #require(reply.state?.clients.first)
    #expect(decoded.internalIp == "10.0.0.2")
    #expect(decoded.source == client.source)
    #expect(decoded.connectionUrl == client.connectionUrl)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: [false, true])
@MainActor func macControllerCachedClientStatusRequiresTheMatchingProfileReference(matchesReference: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    let reference = try (matchesReference ? fixture.config.reference
        : CloudGatewayMacSecretReference(value: "11111111-1111-1111-1111-111111111111"))
    await fixture.profiles.setProfiles([.init(identifier: fixture.config.identifier, reference: reference, status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }
    let client = try #require(fixture.domainSnapshot.domain.clients.first)
    #expect(client.eligibility == .eligible)
    #expect(client.source == .cache)
    #expect(client.isInstalled)
    #expect(client.readAt == fixture.config.snapshot.readAt)
    #expect(fixture.domainSnapshot.domain.access == .offline)
    #expect(client.status == (matchesReference ? .connected : nil))
    #expect(fixture.snapshot.groups.first?.rows.first?.status == (matchesReference ? .connected : nil))
    #expect(fixture.snapshot.canTurnOff)
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

@Test(arguments: [false, true])
@MainActor func macControllerCreationRetriesAfterInventoryTransportFailureAndChecksAccess(accessAllowed: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    fixture.controller.refresh()
    try await controllerWaitUntil { !fixture.snapshot.inventoryInFlight }
    #expect(fixture.snapshot.canCreateClient)
    let context = try #require(fixture.controller.clientCreationContext())
    let regions = try await fixture.controller.loadCreateRegions(context: context)
    #expect(regions.map(\.regionId) == ["region"])

    let accessChecks = fixture.inventory.accessCount
    if !accessAllowed { fixture.inventory.accessError = CloudGatewayMacInventoryError.accessDenied }
    fixture.inventory.fetchError = nil
    fixture.inventory.options = [fixture.option(clientId: "created", name: "New Mac")]
    #expect(fixture.controller.createClient(regionId: "region", clientName: "New Mac", context: context))
    if accessAllowed {
        try await controllerWaitUntil { fixture.snapshot.canCreateClient }
        #expect(fixture.inventory.createdNames == ["New Mac"])
        #expect(fixture.snapshot.groups.flatMap(\.rows).map(\.identifier) == ["user-a/region/created"])
        #expect(fixture.snapshot.errorMessage == nil)
    } else {
        try await controllerWaitUntil { fixture.auth.currentUser == nil }
        #expect(fixture.inventory.createdNames.isEmpty)
        #expect(!fixture.snapshot.canCreateClient)
        #expect(!(try await fixture.cache.load(accountId: "user-a")).accessAllowed)
    }
    #expect(fixture.inventory.accessCount == accessChecks + 1)
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
    #expect(!fixture.domainSnapshot.domain.observationIsFresh)
    #expect(fixture.snapshot.statusTitle == "VPN connected · Full (last observed)")

    await fixture.profiles.failReads()
    fixture.controller.profilesDidChange()
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.canTurnOff)
    await delayed.release()
    try await controllerWaitUntil { await fixture.profiles.completedReads >= 3 }
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(fixture.snapshot.errorMessage == "Unable to read VPN preferences. Try Refresh again")
    #expect(!fixture.domainSnapshot.domain.observationIsFresh)
    #expect(fixture.snapshot.statusTitle == "VPN connected · Full (last observed)")
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
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    try await controllerWaitUntil { completion != nil }
    #expect(completion == .failed(.configUnavailable))
    #expect(fixture.snapshot.errorMessage != nil)
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
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    try await controllerWaitUntil { completion != nil }
    #expect(completion == .failed(.configUnavailable))
    #expect(fixture.snapshot.errorMessage != nil)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerReportsFailedConnectForAMissingOfflineSecretWithAnExistingProfile() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    await fixture.secrets.setAvailable(false)
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    try await controllerWaitUntil { completion != nil }
    #expect(completion == .failed(.configUnavailable))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: MacControllerConnectFailure.allCases)
@MainActor private func macControllerReportsFailedConnectForDefiniteStartFailures(
    failure: MacControllerConnectFailure
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let active = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles([active, try fixture.profile(status: .disconnected)])
    if failure == .stop { await fixture.profiles.setStopError(.profileInstallationFailed) }
    if failure == .startGrant { await fixture.secrets.setAuthorizationError(.unauthorized) }
    if failure == .start { await fixture.profiles.setStartError(.profileInstallationFailed) }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    try await controllerWaitUntil { completion != nil }
    #expect(completion == .failed(.vpnFailed))
    #expect(fixture.snapshot.errorMessage != nil)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: [false, true])
@MainActor func macControllerReportsCompletedConnectWhenMetadataFails(writeFails: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let submission = MacControllerGate()
    await fixture.profiles.pauseStart(submission)
    var completions: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completions.append($0) })
    try await controllerWaitUntil { await submission.entered }
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(
        at: fixture.directory, includingPropertiesForKeys: nil
    ).first)
    defer {
        if writeFails { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: accountDirectory.path) }
    }
    if writeFails {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: accountDirectory.path)
        #expect(try await fixture.cache.load(accountId: "user-a").accessAllowed)
    } else {
        try Data("{}".utf8).write(to: accountDirectory.appendingPathComponent("inventory.json"), options: .atomic)
    }
    await submission.release()
    try await controllerWaitUntil { !completions.isEmpty }
    #expect(completions == [.startRequested(identifier: fixture.config.identifier, warning: .selectionNotSaved)])
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(fixture.snapshot.errorMessage == "VPN connection was accepted, but offline metadata could not refresh. Choose Refresh before trying again")
}

@Test @MainActor func macControllerReportsUnknownWhenTheSessionChangesDuringConnect() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var completions: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completions.append($0) })
    try await controllerWaitUntil { await authorization.entered }
    #expect(fixture.controller.signOut())
    await authorization.release()
    try await controllerWaitUntil { !completions.isEmpty }
    #expect(completions == [.unknown])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test(arguments: [CloudGatewayTunnelStatus.connected, .connecting, .reasserting])
@MainActor func macControllerReportsCompletedConnectForAnAlreadyActiveProfile(status: CloudGatewayTunnelStatus) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: status)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var completions: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completions.append($0) })
    try await controllerWaitUntil { !completions.isEmpty }
    #expect(completions == [.alreadyActive(identifier: fixture.config.identifier, warning: nil)])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(fixture.snapshot.errorMessage == nil)
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerReinstallsUnavailableSavedSecretBeforeSwitching(
    profileExists: Bool, storageFails: Bool
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let old = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles(profileExists ? [old, try fixture.profile(status: .disconnected)] : [old])
    let replacement = try CloudGatewayMacSecretReference(value: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    await fixture.secrets.setInstallReference(replacement)
    if storageFails { await fixture.secrets.setAvailabilityError(.storageFailure) }
    else { await fixture.secrets.setAvailable(false) }
    try await fixture.start()
    defer { fixture.controller.shutdown() }

    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { await fixture.profiles.startedIdentifiers == [fixture.config.identifier] }
    try await controllerWaitUntil { fixture.snapshot.canCreateClient }
    #expect(await fixture.secrets.installCount == 1)
    #expect(await fixture.profiles.savedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.stoppedIdentifiers == [old.identifier])
    #expect(fixture.snapshot.errorMessage == nil)
    let cached = try await fixture.cache.load(accountId: "user-a")
    #expect(try cached.configs.first?.reference == replacement)
}

@Test(arguments: [false, true])
@MainActor func macControllerUnavailableSecretWithoutOnlineRecoveryPreservesActiveVPN(offline: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let old = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles([old])
    await fixture.secrets.setAvailabilityError(offline ? .storageFailure : .unauthorized)
    if offline { fixture.inventory.accessError = CloudGatewayMacInventoryError.offline }
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.canCreateClient && !fixture.snapshot.isRestoringSession }

    let before = try await fixture.cache.load(accountId: "user-a")

    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    let cached = try await fixture.cache.load(accountId: "user-a")
    #expect(cached.configs == before.configs)
    #expect(cached.selectedIdentifier == before.selectedIdentifier)
}

@Test @MainActor func macControllerFailedSecretReplacementPreservesActiveVPNAndCachedReference() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let old = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles([old])
    await fixture.secrets.setAvailabilityError(.storageFailure)
    await fixture.secrets.setInstallError(.storageFailure)
    try await fixture.start()
    defer { fixture.controller.shutdown() }

    let before = try await fixture.cache.load(accountId: "user-a")

    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { fixture.snapshot.errorMessage != nil }
    #expect(fixture.snapshot.errorMessage == "Unable to access secure VPN storage")
    #expect(await fixture.secrets.installCount == 1)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    let cached = try await fixture.cache.load(accountId: "user-a")
    #expect(cached.configs == before.configs)
    #expect(cached.selectedIdentifier == before.selectedIdentifier)
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

@Test @MainActor func macControllerTimerMenuAndExplicitRefreshShareOneFetch() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    fixture.controller.menuWillOpen()
    fixture.controller.recordUserActivity(refreshIfStale: true)
    let explicit = Task { await fixture.controller.awaitRefresh() }
    try await controllerWaitUntil { await fetch.entered }
    #expect(fixture.inventory.fetchCount == fetches + 1)
    await fetch.release()
    #expect(await explicit.value == .refreshed)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.inventory.fetchCount == fetches + 1)
}

@Test @MainActor func macControllerExplicitRefreshStartsANewFetchAfterActivityRefreshCompletes() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
    fixture.controller.recordUserActivity(refreshIfStale: false)
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 2)
}

@Test @MainActor func macControllerFreshnessStartsWhenInventoryCommitsAndFailureDoesNotRenewIt() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    try await controllerWaitUntil { await fetch.entered }
    fixture.clock.elapsed = .seconds(100)
    await fetch.release()
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
    fixture.clock.elapsed = .seconds(159)
    fixture.controller.menuWillOpen()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.unavailable
    fixture.clock.elapsed = .seconds(160)
    fixture.controller.menuWillOpen()
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .unavailable }
    fixture.inventory.fetchError = nil
    fixture.clock.elapsed = .seconds(161)
    fixture.controller.menuWillOpen()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
    #expect(fixture.inventory.fetchCount == fetches + 3)
}

@Test @MainActor func macControllerAutomaticFailureBackoffAllowsExplicitRetry() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.unavailable
    for seconds in [60, 120] {
        fixture.clock.elapsed = .seconds(seconds)
        fixture.controller.recordUserActivity(refreshIfStale: false)
        fixture.controller.refreshInventoryIfDue()
        try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    }
    #expect(fixture.inventory.fetchCount == fetches + 2)
    fixture.clock.elapsed = .seconds(180)
    fixture.controller.recordUserActivity(refreshIfStale: false)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .unavailable)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    fixture.inventory.fetchError = nil
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 3)
}

@Test @MainActor func macControllerAutomaticRetryAfterEarlyExplicitFailureDoesNotWaitForStaleInventory() async throws {
    let fixture = try MacControllerFixture(inventoryJitter: { 0 })
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.clock.elapsed = .seconds(1)
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.unavailable
    #expect(await fixture.controller.awaitRefresh() == .unavailable)
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.clock.elapsed = .seconds(48)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness != .refreshing)
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.inventory.fetchError = nil
    fixture.clock.elapsed = .seconds(49) + .nanoseconds(1)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == fetches + 2)
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)
    #expect(fixture.inventory.fetchCount == fetches + 2)
}

@Test @MainActor func macControllerFiveMinuteTierRetriesFailuresBeforeResumingItsCadence() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.unavailable
    for seconds in [300, 360] {
        fixture.clock.elapsed = .seconds(seconds - 1)
        fixture.controller.refreshInventoryIfDue()
        #expect(fixture.domainSnapshot.domain.inventoryFreshness != .refreshing)
        fixture.clock.elapsed = .seconds(seconds)
        fixture.controller.refreshInventoryIfDue()
        #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
        try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    }
    #expect(fixture.inventory.fetchCount == fetches + 2)
    fixture.clock.elapsed = .seconds(479)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.inventory.fetchCount == fetches + 2)
    fixture.inventory.fetchError = nil
    fixture.clock.elapsed = .seconds(480)
    fixture.controller.refreshInventoryIfDue()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == fetches + 3)
    fixture.clock.elapsed = .seconds(779)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)
    #expect(fixture.inventory.fetchCount == fetches + 3)
    fixture.clock.elapsed = .seconds(780)
    fixture.controller.refreshInventoryIfDue()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == fetches + 4)
}

@Test @MainActor func macControllerStaleActivityWaitsForCommandsAndIsImmediatelyObservable() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    let submission = MacControllerGate()
    await fixture.profiles.pauseStart(submission)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    try await controllerWaitUntil { await submission.entered }
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.inventory.fetchCount == fetches)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    #expect(fixture.inventory.fetchCount == fetches)
    let refresh = Task { await fixture.controller.awaitRefresh() }
    await submission.release()
    #expect(await refresh.value == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 1)
}

@Test @MainActor func macControllerWakeDoesOneDueFetchAndLongSleepNeedsRealActivity() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.clock.elapsed = .seconds(700)
    fixture.controller.refreshInventoryIfDue()
    fixture.controller.refreshInventoryIfDue()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.clock.elapsed = .seconds(701)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.clock.elapsed = .seconds(3_600)
    fixture.controller.refreshInventoryIfDue()
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.inventory.fetchCount == fetches + 2)
}

@Test @MainActor func macControllerDefersActivityBehindAdmissionAndDiscardsItWhileDraining() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    fixture.clock.elapsed = .seconds(60)
    fixture.controller.setAutomaticInventoryRefreshAllowed(false, discardDeferred: false)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    #expect(fixture.inventory.fetchCount == fetches)
    fixture.controller.setAutomaticInventoryRefreshAllowed(true, discardDeferred: false)
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.clock.elapsed = .seconds(120)
    fixture.controller.setAutomaticInventoryRefreshAllowed(false, discardDeferred: false)
    fixture.controller.recordUserActivity(refreshIfStale: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    fixture.controller.setAutomaticInventoryRefreshAllowed(false, discardDeferred: true)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)
    #expect(fixture.inventory.fetchCount == fetches + 1)
    fixture.clock.elapsed = .seconds(3_600)
    fixture.controller.setAutomaticInventoryRefreshAllowed(true, discardDeferred: false)
    #expect(fixture.inventory.fetchCount == fetches + 1)
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerResolvesConnectAfterCommittedInventoryPublishes(savedConfig: Bool, removed: Bool) async throws {
    let fixture = try MacControllerFixture()
    if savedConfig { try await fixture.seedCache() }
    let active = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles([active])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let replacement = fixture.option(wireGuardConfig: controllerWireGuardConfig.replacingOccurrences(
        of: "Address = 10.0.0.2/32", with: "Address = 10.0.0.3/32"
    ))
    let publication = MacControllerGate()
    fixture.commitProbe.gate = publication
    fixture.inventory.options = removed ? [] : [replacement]
    fixture.controller.refresh()
    try await controllerWaitUntil { await publication.entered }
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty)
    #expect(fixture.snapshot.groups.flatMap(\.rows).map(\.identifier) == [fixture.config.identifier])
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    for _ in 0..<50 { await Task.yield() }
    #expect(completion == nil)
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    await publication.release()
    try await controllerWaitUntil { completion != nil }
    if removed {
        #expect(completion == .failed(.configUnavailable))
        #expect(await fixture.secrets.installCount == 0)
        #expect(await fixture.profiles.savedIdentifiers.isEmpty)
        #expect(await fixture.profiles.startedIdentifiers.isEmpty)
        #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    } else {
        #expect(completion == .startRequested(identifier: fixture.config.identifier, warning: nil))
        let replacementHash = CloudGatewayConfigHash.make(for: try CloudGatewayConfigSelection.wireGuardConfig(from: replacement))
        #expect(await fixture.secrets.installedHashes == [replacementHash])
        #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
        #expect(await fixture.profiles.stoppedIdentifiers == [active.identifier])
        #expect(try await fixture.cache.load(accountId: "user-a").configs.first?.snapshot.configHash == replacementHash)
    }
}

@Test @MainActor func macControllerFailedCommitReconciliationPreservesTheActiveVPN() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let publication = MacControllerGate()
    fixture.commitProbe.gate = publication
    fixture.controller.refresh()
    try await controllerWaitUntil { await publication.entered }
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { completion = $0 })
    try await fixture.cache.deny(accountId: "user-a")
    await publication.release()
    try await controllerWaitUntil { completion != nil }
    #expect(completion == .failed(.accessDenied))
    #expect(fixture.snapshot.groups.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerInventoryMutationAdmissionWaitsForFetchAndPublication(committing: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let context = try #require(fixture.controller.clientCreationContext())
    let session = try #require(fixture.controller.session)
    let pendingInventory = MacControllerGate()
    if committing { fixture.commitProbe.gate = pendingInventory }
    else { fixture.inventory.fetchGate = pendingInventory }
    fixture.controller.refresh()
    try await controllerWaitUntil { await pendingInventory.entered }
    let saved = try await fixture.cache.load(accountId: "user-a")
    #expect(!fixture.controller.canStartInventoryMutation)
    #expect(fixture.controller.clientCreationContext() == nil)
    #expect(!fixture.controller.createClient(regionId: "region", clientName: "Other", context: context))
    var removal: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.removeClient(identifier: fixture.config.identifier) { removal = $0 })
    #expect(removal == .failed(.busy))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    await #expect(throws: CloudGatewayMacConfigError.busy) {
        try await fixture.controller.evictCachedClient(identifier: fixture.config.identifier, session: session)
    }
    #expect(try await fixture.cache.load(accountId: "user-a").configs == saved.configs)
    await pendingInventory.release()
    try await controllerWaitUntil { fixture.controller.canStartInventoryMutation }
}

@Test @MainActor func macControllerEvictionRequiresCommandOwnershipAndTheCurrentSession() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let session = try #require(fixture.controller.session)
    let saved = try await fixture.cache.load(accountId: "user-a")
    await #expect(throws: CloudGatewayMacConfigError.busy) {
        try await fixture.controller.evictCachedClient(identifier: fixture.config.identifier, session: session)
    }
    #expect(try await fixture.cache.load(accountId: "user-a") == saved)

    #expect(fixture.controller.signOut())
    fixture.auth.emit(AuthenticatedUser(uid: "user-a", email: nil))
    try await controllerWaitUntil { fixture.controller.canStartInventoryMutation }
    #expect(fixture.controller.session != session)
    let current = try await fixture.cache.load(accountId: "user-a")
    await #expect(throws: CancellationError.self) {
        try await fixture.controller.evictCachedClient(identifier: fixture.config.identifier, session: session)
    }
    #expect(try await fixture.cache.load(accountId: "user-a") == current)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == [fixture.config.identifier])
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerEvictionUpdatesPresentationAndHoldsRefreshUnderCommandOwnership(
    hasRemainingClient: Bool, selectedTarget: Bool
) async throws {
    let fixture = try MacControllerFixture()
    let remainingOption = fixture.option(clientId: "remaining", name: "Other Mac")
    let remaining = CloudGatewayMacInstalledConfig(
        accountId: "user-a", identifier: "user-a/region/remaining",
        snapshot: CloudGatewayConfigSnapshot(
            clientId: "remaining", regionId: "region", clientName: "Other Mac", regionDisplayName: "Region",
            status: .active, configHash: fixture.config.snapshot.configHash,
            secretReference: fixture.config.snapshot.secretReference, readAt: Date(timeIntervalSince1970: 1), updatedAt: nil
        )
    )
    fixture.inventory.options = [fixture.option()] + (hasRemainingClient ? [remainingOption] : [])
    try await fixture.cache.authorize(accountId: "user-a", role: .user, options: fixture.inventory.options)
    try await fixture.cache.save(fixture.config)
    if hasRemainingClient { try await fixture.cache.save(remaining) }
    let selected = selectedTarget ? fixture.config.identifier : (hasRemainingClient ? remaining.identifier : nil)
    if let selected { try await fixture.cache.select(identifier: selected, accountId: "user-a") }
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let command = MacControllerGate()
    fixture.inventory.removalTokenGate = command
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { completion = $0 })
    try await controllerWaitUntil { await command.entered }
    let fetches = fixture.inventory.fetchCount
    fixture.controller.refresh()
    let expectedIdentifiers = hasRemainingClient ? [remaining.identifier] : []
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == expectedIdentifiers)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == expectedIdentifiers)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == (selectedTarget ? nil : selected))
    #expect(fixture.inventory.fetchCount == fetches)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)
    #expect(!fixture.controller.canStartInventoryMutation)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await fixture.cache.save(fixture.config) }
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)

    fixture.inventory.options = hasRemainingClient ? [remainingOption] : []
    await command.release()
    try await controllerWaitUntil { completion != nil && !fixture.controller.hasPendingWork }
    #expect(completion == .completed(warning: nil))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == expectedIdentifiers)
    let reopened = CloudGatewayMacAccountCache(directory: fixture.directory)
    #expect(try await reopened.load(accountId: "user-a").configs.map(\.identifier) == expectedIdentifiers)
    #expect(try await reopened.load(accountId: "user-a").selectedIdentifier == (selectedTarget ? nil : selected))
    if hasRemainingClient {
        var connected: CloudGatewayMacCommandOutcome?
        #expect(fixture.controller.connectClient(identifier: remaining.identifier) { connected = $0 })
        try await controllerWaitUntil { connected != nil }
        #expect(connected == .startRequested(identifier: remaining.identifier, warning: nil))
    }
}

@Test @MainActor func macControllerFailedEvictionKeepsPresentationAndThrowsToCommand() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let session = try #require(fixture.controller.session)
    let command = MacControllerGate()
    fixture.inventory.accessGate = command
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    var completed = false
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { _ in completed = true })
    try await controllerWaitUntil { await command.entered }
    let before = fixture.domainSnapshot
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil).first)
    let backup = fixture.directory.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: accountDirectory, to: backup)
    try Data().write(to: accountDirectory)
    await #expect(throws: CloudGatewayMacCacheError.unavailable) {
        try await fixture.controller.evictCachedClient(identifier: fixture.config.identifier, session: session)
    }
    #expect(fixture.domainSnapshot.domain.clients == before.domain.clients)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == before.domain.installedIdentifiers)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == before.lastSelectedIdentifier)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    try FileManager.default.moveItem(at: accountDirectory, to: fixture.directory.appendingPathComponent("blocker"))
    try FileManager.default.moveItem(at: backup, to: accountDirectory)
    await command.release()
    try await controllerWaitUntil { completed && !fixture.controller.hasPendingWork }
}

@Test(arguments: [false, true])
@MainActor func macControllerLocalStopIsSignedOutAndIdempotent(active: Bool) async throws {
    let fixture = try MacControllerFixture()
    if active { await fixture.profiles.setProfiles([try fixture.profile(status: .connected)]) }
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.controller.signOut()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    var completions: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.turnOff { completions.append($0) })
    try await controllerWaitUntil { completions.count == 1 }
    #expect(fixture.controller.turnOff { completions.append($0) })
    try await controllerWaitUntil { completions.count == 2 }
    #expect(completions == [.completed(warning: nil), .completed(warning: nil)])
    #expect(await fixture.profiles.stoppedIdentifiers == (active ? [fixture.config.identifier] : []))
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.domain.accountId == nil)
    #expect(!fixture.domainSnapshot.domain.accessAuthorized)
}

@Test(arguments: [
    (CloudGatewayMacInventoryError.unavailable, CloudGatewayMacCommandOutcome.completed(warning: .inventoryNotRefreshed)),
    (.offline, .completed(warning: .inventoryNotRefreshed)),
    (nil, .unknown)
] as [(CloudGatewayMacInventoryError?, CloudGatewayMacCommandOutcome)])
@MainActor func macControllerCreationCompletionDistinguishesConfirmedAndUnknownResults(
    refreshError: CloudGatewayMacInventoryError?, expected: CloudGatewayMacCommandOutcome
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let context = try #require(fixture.controller.clientCreationContext())
    if let refreshError { fixture.inventory.fetchError = refreshError }
    else { fixture.inventory.createError = CloudGatewayMacInventoryError.offline }
    var completion: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.createClient(regionId: "region", clientName: "Work Mac", context: context) { completion = $0 })
    #expect(completion == nil)
    try await controllerWaitUntil { completion != nil }
    #expect(completion == expected)
    if refreshError != nil {
        try await controllerWaitUntil { fixture.snapshot.canCreateClient }
        #expect(fixture.inventory.createdNames == ["Work Mac"])
        #expect(fixture.snapshot.errorMessage == "Client was created, but the client list could not refresh. Choose Refresh before trying again")
    }
}

@Test @MainActor func macControllerRejectsConnectWithTypedReasonsBeforeSubmittingWork() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start(ready: false)
    defer { fixture.controller.shutdown() }
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    fixture.controller.setSetupState(.ready)
    #expect(!fixture.controller.connectClient(identifier: "user-a/region/missing") { outcomes.append($0) })
    let submission = MacControllerGate()
    await fixture.profiles.pauseStart(submission)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { await submission.entered }
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    #expect(!fixture.controller.turnOff { outcomes.append($0) })
    await submission.release()
    try await controllerWaitUntil { outcomes.count == 5 }
    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    #expect(outcomes == [
        .failed(.initialSetupRequired), .failed(.configUnavailable), .failed(.busy), .failed(.busy),
        .startRequested(identifier: fixture.config.identifier, warning: nil), .failed(.signInRequired)
    ])
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
}

@Test @MainActor func macControllerReportsUnconfirmedStopAsADeadlineFailure() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let active = CloudGatewayMacInstalledProfile(
        identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected
    )
    await fixture.profiles.setProfiles([active, try fixture.profile(status: .disconnected)])
    await fixture.profiles.setStopError(.stopTimedOut)
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { outcomes.count == 1 }
    #expect(fixture.controller.turnOff { outcomes.append($0) })
    try await controllerWaitUntil { outcomes.count == 2 }
    #expect(outcomes == [.failed(.stopTimedOut), .failed(.stopTimedOut)])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(fixture.snapshot.hasActiveTunnel)
}

@Test @MainActor func macControllerSeparatesRetainedProfileFromInvalidatedInstalledMetadata() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.snapshot.hasActiveTunnel }
    var client = try #require(fixture.domainSnapshot.domain.clients.first)
    #expect(client.isInstalled)
    #expect(client.source == .cloud)
    #expect(client.readAt == fixture.clock.now)
    #expect(fixture.domainSnapshot.domain.profilesObservedAt == fixture.clock.now)

    fixture.clock.now = Date(timeIntervalSince1970: 6_000)
    fixture.inventory.options = [fixture.option(wireGuardConfig: controllerWireGuardConfig.replacingOccurrences(
        of: "Address = 10.0.0.2/32", with: "Address = 10.0.0.3/32"
    ))]
    fixture.controller.refresh()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    let domain = fixture.domainSnapshot.domain
    client = try #require(domain.clients.first)
    #expect(!client.isInstalled)
    #expect(client.status == .connected)
    #expect(client.eligibility == .eligible)
    #expect(client.readAt == fixture.clock.now)
    #expect(domain.installedIdentifiers.isEmpty)
    #expect(domain.observedProfiles == [.init(identifier: fixture.config.identifier, status: .connected)])
    #expect(domain.profilesObservedAt == fixture.clock.now)
    #expect(fixture.snapshot.hasActiveTunnel)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerReportsRetainedIdentityWhileAccessIsChecked() async throws {
    let fixture = try MacControllerFixture()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    var domain = fixture.domainSnapshot.domain
    #expect(domain.access == .checking)
    #expect(domain.hasRetainedSession)
    #expect(domain.accountId == nil)
    #expect(!domain.accessAuthorized)
    #expect(domain.credentials == .available)
    await access.release()
    try await controllerWaitUntil { fixture.domainSnapshot.domain.access == .online }
    #expect(fixture.domainSnapshot.domain.accountId == "user-a")

    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    domain = fixture.domainSnapshot.domain
    #expect(domain.access == .unverified)
    #expect(!domain.hasRetainedSession)
    #expect(domain.credentials == .unknown)
}

@Test @MainActor func macControllerReportsUnknownWhenShutdownInterruptsConnect() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    let read = MacControllerGate()
    await fixture.profiles.pauseNextRead(read)
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { await read.entered }
    fixture.controller.shutdown()
    await read.release()
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(outcomes == [.unknown])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerScopedStopLeavesAnotherRunningConfigAlone(targetIsInstalled: Bool) async throws {
    let fixture = try MacControllerFixture()
    let other = CloudGatewayMacInstalledProfile(identifier: "other-account/region/client", reference: try fixture.config.reference, status: .connected)
    var profiles = [other]
    if targetIsInstalled { profiles.append(try fixture.profile(status: .disconnected)) }
    await fixture.profiles.setProfiles(profiles)
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(outcomes == [.completed(warning: nil)])
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: [CloudGatewayMacClientEligibility.inactive, .configMissing, .regionUnavailable])
@MainActor func macControllerScopedStopDoesNotRequireConnectEligibility(eligibility: CloudGatewayMacClientEligibility) async throws {
    let fixture = try MacControllerFixture()
    fixture.inventory.options = [.init(
        client: .init(clientId: "client", clientName: "Mac", regionId: "region",
                      status: eligibility == .inactive ? .creating : .active,
                      wireGuardConfig: eligibility == .configMissing ? "" : controllerWireGuardConfig,
                      ownerUid: "user-a"),
        region: .init(regionId: "region", displayName: "Region", enabled: eligibility != .regionUnavailable)
    )]
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    #expect(fixture.domainSnapshot.domain.clients.first?.eligibility == eligibility)
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(outcomes == [.completed(warning: nil)])
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerScopedStopWorksWithAuthorizedOfflineInventory() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start(ready: false)
    defer { fixture.controller.shutdown() }
    #expect(fixture.domainSnapshot.domain.access == .offline)
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(outcomes == [.completed(warning: nil)])
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(fixture.inventory.fetchCount == 0)
}

@Test @MainActor func macControllerScopedStopRejectsUnknownAndSignedOutTargets() async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(!fixture.controller.disconnectClient(identifier: "user-a/region/unknown") { outcomes.append($0) })
    #expect(outcomes == [.failed(.configUnavailable)])
    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(!fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    #expect(outcomes.last == .failed(.signInRequired))
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(fixture.controller.turnOff { outcomes.append($0) })
    try await controllerWaitUntil { outcomes.count == 3 }
    #expect(outcomes.last == .completed(warning: nil))
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
}

@Test(arguments: [false, true])
@MainActor func macControllerScopedStopFencesAccountChangesDuringObservation(changeAccount: Bool) async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    let read = MacControllerGate()
    await fixture.profiles.pauseNextRead(read)
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { await read.entered }
    fixture.auth.emit(changeAccount ? AuthenticatedUser(uid: "user-b", email: nil) : nil)
    await read.release()
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(outcomes == [.unknown])
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerScopedStopRechecksInventoryAfterTheAdapterLookup() async throws {
    let fixture = try MacControllerFixture()
    let other = CloudGatewayMacInstalledProfile(identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connected)
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected), other])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    let session = fixture.controller.session
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.controller.refresh()
    try await controllerWaitUntil { await fetch.entered }
    let secondLookup = MacControllerGate()
    await fixture.profiles.pauseScopedStopLookup(secondLookup)
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { outcomes.append($0) })
    try await controllerWaitUntil { await secondLookup.entered }
    fixture.inventory.options = [fixture.option(clientId: "other")]
    await fetch.release()
    try await controllerWaitUntil {
        fixture.domainSnapshot.domain.clients.map(\.identifier) == [other.identifier]
            && fixture.domainSnapshot.domain.inventoryFreshness == .current
    }
    #expect(fixture.controller.session == session)
    #expect(fixture.domainSnapshot.domain.accessAuthorized)
    #expect(outcomes.isEmpty)
    await secondLookup.release()
    try await controllerWaitUntil { !outcomes.isEmpty }
    #expect(await fixture.profiles.scopedStopWasCancelled == false)
    #expect(outcomes == [.failed(.configUnavailable)])
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    let profiles = try await fixture.profiles.installedProfiles()
    #expect(profiles.first { $0.identifier == fixture.config.identifier }?.status == .connected)
    #expect(profiles.first { $0.identifier == other.identifier }?.status == .connected)
}

@Test @MainActor func macControllerBareConnectResolvesThisAccountSelectionOrOffersChoices() async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcomes: [CloudGatewayMacCommandOutcome] = []
    #expect(!fixture.controller.connectClient(identifier: nil) { outcomes.append($0) })
    #expect(outcomes == [.failed(.selectionUnavailable)])
    let choices = fixture.domainSnapshot.domain.clients.filter { $0.eligibility == .eligible }.map(\.identifier)
    #expect(choices == [fixture.config.identifier])

    try await fixture.seedCache()
    fixture.controller.refresh()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == fixture.config.identifier)
    #expect(fixture.controller.connectClient(identifier: nil) { outcomes.append($0) })
    try await controllerWaitUntil { outcomes.count == 2 }
    #expect(outcomes.last == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
}

@Test @MainActor func macControllerAwaitedRefreshReportsItsOwnFetchResult() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 1)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .current)

    fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    #expect(await fixture.controller.awaitRefresh() == .unavailable)
    let stale = fixture.domainSnapshot.domain
    #expect(stale.inventoryFreshness == .cached)
    #expect(stale.clients.map(\.identifier) == [fixture.config.identifier])
    #expect(stale.clients.allSatisfy { $0.source == .cache && $0.readAt != fixture.clock.now })

    fixture.inventory.fetchError = nil
    fixture.inventory.accessError = CloudGatewayMacInventoryError.accessDenied
    #expect(await fixture.controller.awaitRefresh() == .denied)
    #expect(fixture.domainSnapshot.domain.accountId == nil)
    #expect(await fixture.controller.awaitRefresh() == .signInRequired)
}

@Test(arguments: MacControllerFallbackCache.allCases, [false, true])
@MainActor private func macControllerFilteredCLIReportsOfflineInventoryFailuresBeforeRegionUsage(
    fallback: MacControllerFallbackCache, refresh: Bool
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.cache.authorize(accountId: "user-a", role: .user, options: [])
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await fetch.entered }
    #expect(fixture.domainSnapshot.domain.accountId == "user-a")
    #expect(fixture.domainSnapshot.domain.accessAuthorized)
    #expect(fixture.domainSnapshot.domain.inventoryFreshness == .refreshing)

    let namespace = try #require(FileManager.default.contentsOfDirectory(
        at: fixture.directory, includingPropertiesForKeys: nil
    ).first)
    let path = namespace.appendingPathComponent("inventory.json")
    switch fallback {
    case .missing:
        try FileManager.default.moveItem(at: path, to: namespace.appendingPathComponent("saved-inventory.json"))
    case .invalid:
        try Data("invalid JSON".utf8).write(to: path)
    case .unauthorized:
        try await fixture.cache.deny(accountId: "user-a")
    case .authorizedEmpty: break
    }

    let harness = MacControllerCLIHarness(controller: fixture.controller)
    let arguments = (refresh ? ["list", "--refresh"] : ["ls"]) + ["--region", "chicago", "--json"]
    let invocation = Task { await harness.run(arguments) }
    try await controllerWaitUntil { harness.actions.contains(refresh ? .awaitRefresh : .snapshot) }
    await fetch.release()
    let authorizedEmpty = fallback == .authorizedEmpty
    #expect(await invocation.value == (authorizedEmpty ? 2 : 6))
    let result = try #require(JSONSerialization.jsonObject(with: Data(harness.output.utf8)) as? [String: Any])
    let error = try #require(result["error"] as? [String: Any])
    #expect(error["code"] as? String == (authorizedEmpty ? "usage" : "network_unavailable"))
    #expect(result["command"] as? String == "list")
    let snapshot = fixture.domainSnapshot.domain
    #expect(snapshot.accountId == "user-a")
    #expect(snapshot.accessAuthorized)
    #expect(snapshot.access == .offline)
    #expect(snapshot.inventoryFreshness == (authorizedEmpty ? .cached : .unavailable))
    #expect(snapshot.clients.isEmpty)
    #expect(harness.actions.contains(.awaitRefresh) == refresh)
    #expect(harness.diagnostics.isEmpty)
}

@Test @MainActor func macControllerAwaitedRefreshIsSupersededByAStartAndDeferredDuringCommands() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    let refresh = Task { await fixture.controller.awaitRefresh() }
    try await controllerWaitUntil { await fetch.entered }
    let submission = MacControllerGate()
    await fixture.profiles.pauseStart(submission)
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier))
    await fetch.release()
    #expect(await refresh.value == .superseded)
    try await controllerWaitUntil { await submission.entered }
    let deferred = Task { await fixture.controller.awaitRefresh() }
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .refreshing }
    await submission.release()
    #expect(await deferred.value == .refreshed)
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
}

@Test @MainActor func macControllerRepeatedAwaitedRefreshJoinsTheFetchInFlight() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let fetches = fixture.inventory.fetchCount
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    let first = Task { await fixture.controller.awaitRefresh() }
    try await controllerWaitUntil { await fetch.entered }
    let second = Task { await fixture.controller.awaitRefresh() }
    for _ in 0..<20 { await Task.yield() }
    await fetch.release()
    #expect(await first.value == .refreshed)
    #expect(await second.value == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 1)
}

@Test @MainActor func macControllerAwaitedRefreshWaitsForRetainedIdentityRestoration() async throws {
    let fixture = try MacControllerFixture()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let refresh = Task { await fixture.controller.awaitRefresh() }
    await access.release()
    #expect(await refresh.value == .refreshed)
    #expect(fixture.domainSnapshot.domain.access == .online)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [fixture.config.identifier])
}

private enum MacControllerRestoreCase: CaseIterable, Sendable {
    case authorizedCache, deniedCache, otherAccount, unavailable, accessDenied
}

private enum MacControllerConnectFailure: CaseIterable, Sendable {
    case stop, startGrant, start
}

private enum MacControllerFallbackCache: CaseIterable, Sendable {
    case missing, invalid, unauthorized, authorizedEmpty
}

@MainActor
private final class MacControllerCLIHarness {
    private let controller: CloudGatewayMacController
    private let identity = CloudGatewayMacBuildIdentity(version: "1.0", build: "2", codeHash: String(repeating: "a", count: 64))
    private let instanceId = UUID()
    private(set) var actions: [CloudGatewayMacControllerRequest.Action] = []
    private(set) var output = ""
    private(set) var diagnostics = ""

    init(controller: CloudGatewayMacController) {
        self.controller = controller
    }

    func run(_ arguments: [String]) async -> Int32 {
        let cli = CloudGatewayMacCLI(
            version: identity.version, build: identity.build,
            terminal: .init(isOutputTerminal: false, variables: [:]), clock: .continuous,
            output: { self.output += $0 }, diagnostics: { self.diagnostics += $0 },
            connect: {
                CloudGatewayMacFrontendClient(identity: self.identity, transport: { try await self.send($0) }, bootstrap: {})
            }
        )
        return await cli.run(arguments)
    }

    private func send(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        actions.append(request.action)
        let reply: CloudGatewayMacControllerReply
        switch request.action {
        case .lifecycle:
            reply = .init(lifecycle: .init(running: identity, installed: identity, state: .current))
        case .userActivity:
            controller.recordUserActivity(refreshIfStale: true)
            reply = .init(state: state())
        case .snapshot:
            reply = .init(state: state())
        case .awaitRefresh:
            let refresh = await controller.awaitRefresh()
            reply = .init(state: state(), refresh: refresh)
        default:
            Issue.record("Unexpected controller request \(request.action)")
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        let payload = CloudGatewayMacControllerProtocol.encodeReply(
            reply, appVersion: identity.version, appBuild: identity.build, instanceId: instanceId, action: request.action
        )
        return try CloudGatewayMacControllerProtocol.decodeReply(
            payload, appVersion: identity.version, appBuild: identity.build, action: request.action
        )
    }

    private func state() -> CloudGatewayMacControllerState {
        .init(snapshot: controller.snapshot(), setupState: .ready, canUpdateExtension: false)
    }
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
    let commitProbe: MacControllerCommitProbe
    let evictionProbe: MacControllerCommitProbe
    let clock = MacControllerClock()
    let loginClock = AuthDeadlineClock()

    init(loginTimer: (@Sendable (Duration) async throws -> Void)? = nil,
         inventoryJitter: @escaping () -> Double = { 0.5 }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGatewayControllerTests-\(UUID())")
        auth = MacControllerAuth()
        deviceAuth = MacControllerDeviceAuth()
        inventory = MacControllerInventory(auth: auth)
        profiles = MacControllerProfiles()
        let reference = try CloudGatewayMacSecretReference(value: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        secrets = MacControllerSecrets(reference: reference)
        cache = CloudGatewayMacAccountCache(directory: directory)
        let commitProbe = MacControllerCommitProbe()
        self.commitProbe = commitProbe
        let evictionProbe = MacControllerCommitProbe()
        self.evictionProbe = evictionProbe
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
            dashboardOrigin: URL(string: "https://dashboard.example.com")!,
            inventoryAuthorizationDidCommit: { await commitProbe.gate?.arriveAndWait() },
            cacheEvictionDidCommit: { await evictionProbe.gate?.arriveAndWait() },
            now: { [clock] in clock.now },
            loginTimer: loginTimer ?? { [loginClock] in try await loginClock.timer($0) },
            loginNow: { [loginClock] in loginClock.now },
            loginSleep: { [loginClock] in await loginClock.sleep($0) },
            inventoryNow: { [clock] in clock.elapsed }, inventoryJitter: inventoryJitter
        )
        inventory.options = [option()]
    }

    var domainSnapshot: CloudGatewayMacControllerSnapshot { controller.snapshot() }
    var snapshot: CloudGatewayMacControllerView {
        .init(state: .init(snapshot: domainSnapshot, setupState: .ready, canUpdateExtension: false))
    }

    func option(
        clientId: String = "client", name: String = "Mac", wireGuardConfig: String = controllerWireGuardConfig,
        hostname: String? = nil, ipv4: String? = nil, ownerEmail: String? = nil, assignedIp: String? = nil,
        ownerUid: String? = "user-a", status: CloudGatewayClientStatus = .active, enabled: Bool = true
    ) -> CloudGatewayClientOption {
        CloudGatewayClientOption(
            client: CloudGatewayClient(
                clientId: clientId, clientName: name, regionId: "region", status: status,
                wireGuardConfig: wireGuardConfig, assignedTunnelIpv4: assignedIp,
                serverEndpointIpv4: ipv4, serverEndpointHostname: hostname,
                ownerUid: ownerUid, ownerEmail: ownerEmail
            ), region: CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: enabled)
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

    func seedInvalidAdminCache(validJSON: Bool = false) async throws {
        inventory.role = .admin
        try await cache.authorize(accountId: "user-a", role: .admin, options: [option()])
        let namespace = try #require(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first)
        let path = namespace.appendingPathComponent("inventory.json")
        if validJSON {
            var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            payload["version"] = 2
            try JSONSerialization.data(withJSONObject: payload).write(to: path)
        } else { try Data("invalid JSON".utf8).write(to: path) }
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
    var isCustomTokenSignInSettling = false
    var signOutError: CloudGatewayDeviceAuthError?
    var allowsSignIn = false
    var suppressesFailedSignOut = false
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
        guard allowsSignIn else { throw CloudGatewayDeviceAuthError.unavailable }
        let candidate = AuthenticatedUser(uid: "user-a", email: nil)
        emit(candidate)
        return candidate
    }

    func cancelCustomTokenSignIn() throws {}

    func signOut() throws {
        signOutCount += 1
        if let signOutError {
            if suppressesFailedSignOut {
                isCustomTokenSignInSettling = true
                emit(nil)
            }
            throw signOutError
        }
        isCustomTokenSignInSettling = false
        emit(nil)
    }
}

private final class MacControllerListenerState: Sendable {
    let active = Mutex(false)
}

private actor MacControllerDeviceAuth: CloudGatewayDeviceAuthServicing {
    private(set) var requestCount = 0
    private var allowsLogin = false
    private var requestGate: MacControllerGate?

    func allowLogin(requestGate: MacControllerGate? = nil) { allowsLogin = true; self.requestGate = requestGate }

    func requestCode(secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceCode {
        requestCount += 1
        await requestGate?.arriveAndWait()
        guard allowsLogin else { throw CloudGatewayDeviceAuthError.unavailable }
        return .init(requestId: String(repeating: "a", count: 32), userCode: "000012",
                     verificationURL: URL(string: "https://dashboard.example.com/#/auth/code?deviceRequestId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&userCode=000012")!,
                     expiresIn: 100, interval: 5)
    }

    func pollToken(requestId: String, secret: CloudGatewayDeviceSecret) async throws -> CloudGatewayDeviceTokenResult {
        guard allowsLogin else { throw CloudGatewayDeviceAuthError.unavailable }
        return .approved(customToken: "fixture-token")
    }
}

@MainActor
private final class MacControllerInventory: CloudGatewayMacInventoryServicing {
    private let auth: MacControllerAuth
    let removalSession = MacClientRemovalSession()
    var creationSession: MacClientRemovalSession?
    var options: [CloudGatewayClientOption] = []
    var accessError: (any Error)?
    var regionsError: (any Error)?
    var createError: (any Error)?
    var fetchError: (any Error)?
    var regionsGate: MacControllerGate?
    var createGate: MacControllerGate?
    var fetchGate: MacControllerGate?
    var accessGate: MacControllerGate?
    var role: CloudGatewayMacAccountRole = .user
    var filtersOwners = true
    var removalTokenGate: MacControllerGate?
    var removalTokenError: (any Error)?
    private(set) var accessCount = 0
    private(set) var fetchCount = 0
    private(set) var regionsCount = 0
    private(set) var createdNames: [String] = []
    private(set) var createdAccountIds: [String] = []

    init(auth: MacControllerAuth) { self.auth = auth }

    func checkAccess(for _: AuthenticatedUser) async throws -> CloudGatewayMacAccountRole {
        accessCount += 1
        await accessGate?.arriveAndWait()
        if let accessError { throw accessError }
        return role
    }

    func fetchOptions(for user: AuthenticatedUser, role: CloudGatewayMacAccountRole) async throws -> [CloudGatewayClientOption] {
        fetchCount += 1
        await fetchGate?.arriveAndWait()
        if let fetchError { throw fetchError }
        return options.filter { !filtersOwners || role == .admin || $0.client.ownerUid == user.uid }
    }

    func fetchCreateRegions(for _: AuthenticatedUser) async throws -> [CloudGatewayRegion] {
        regionsCount += 1
        await regionsGate?.arriveAndWait()
        if let regionsError { throw regionsError }
        return [CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true,
                                   capacity: .known(limit: 10, allocated: 1))]
    }

    func createClient(regionId: String, clientName: String, for user: AuthenticatedUser) async throws -> String {
        createdNames.append(clientName)
        createdAccountIds.append(user.uid)
        await createGate?.arriveAndWait()
        try Task.checkCancellation()
        if let createError { throw createError }
        if let creationSession {
            let client = CloudGatewayControlPlaneClient(originHost: "gocloudlaunch.com", session: creationSession)
            let response = try await client.createClient(regionId: regionId, clientName: clientName, idToken: "fixture-token")
            try Task.checkCancellation()
            guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
            return response.clientName
        }
        return clientName
    }

    func deleteClient(
        clientId: String, ownerUid: String, regionId: String, for user: AuthenticatedUser,
        authorize: @escaping @MainActor () async throws -> Void,
        onDispatch: @escaping @MainActor () -> Void
    ) async throws -> CloudGatewayDeleteClientResponse {
        try await CloudGatewayMacClientRemovalRequest.perform(
            clientId: clientId, ownerUid: ownerUid, regionId: regionId,
            originHost: "gocloudlaunch.com", session: removalSession,
            loadToken: { [self] in
                await removalTokenGate?.arriveAndWait()
                if let removalTokenError { throw removalTokenError }
                return "fixture-token"
            },
            validateSession: { [self] in
                guard auth.currentUser?.uid == user.uid else { throw CancellationError() }
            },
            authorize: authorize, onDispatch: onDispatch
        )
    }
}

private actor MacControllerProfiles: CloudGatewayMacProfileAdapter {
    private var values: [CloudGatewayMacInstalledProfile] = []
    private var nextReadGate: MacControllerGate?
    private var readFails = false
    private var stopError: CloudGatewayMacConfigError?
    private var startError: CloudGatewayMacConfigError?
    private var startGate: MacControllerGate?
    private var stopGate: MacControllerGate?
    private var scopedStopLookupGate: MacControllerGate?
    private var removeError: CloudGatewayMacConfigError?
    private var removeGate: MacControllerGate?
    private(set) var scopedStopWasCancelled: Bool?
    private(set) var readCount = 0
    private(set) var completedReads = 0
    private(set) var startedIdentifiers: [String] = []
    private(set) var savedIdentifiers: [String] = []
    private(set) var savedModes: [CloudGatewayRoutingMode] = []
    private(set) var stoppedIdentifiers: [String] = []
    private(set) var removedIdentifiers: [String] = []

    func setProfiles(_ profiles: [CloudGatewayMacInstalledProfile]) { values = profiles }
    func pauseNextRead(_ gate: MacControllerGate) { nextReadGate = gate }
    func failReads() { readFails = true }
    func setStopError(_ error: CloudGatewayMacConfigError) { stopError = error }
    func setStartError(_ error: CloudGatewayMacConfigError) { startError = error }
    func pauseStart(_ gate: MacControllerGate) { startGate = gate }
    func pauseStop(_ gate: MacControllerGate) { stopGate = gate }
    func pauseScopedStopLookup(_ gate: MacControllerGate) { scopedStopLookupGate = gate }
    func setRemoveError(_ error: CloudGatewayMacConfigError) { removeError = error }
    func pauseRemove(_ gate: MacControllerGate) { removeGate = gate }

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
        savedModes.append(config.mode)
        values.removeAll { $0.identifier == config.identifier }
        values.append(CloudGatewayMacInstalledProfile(
            identifier: config.identifier, reference: try config.reference, status: .disconnected, mode: config.mode
        ))
    }

    func start(identifier: String, grant: String) async throws {
        try Task.checkCancellation()
        if let startError { throw startError }
        startedIdentifiers.append(identifier)
        await startGate?.arriveAndWait()
    }

    func stopAndWait(identifier: String) async throws {
        await stopGate?.arriveAndWait()
        try Task.checkCancellation()
        try finishStop(identifier: identifier)
    }

    func stopAndWait(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        await scopedStopLookupGate?.arriveAndWait()
        await stopGate?.arriveAndWait()
        scopedStopWasCancelled = Task.isCancelled
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        try finishStop(identifier: identifier)
    }

    private func finishStop(identifier: String) throws {
        if let stopError { throw stopError }
        stoppedIdentifiers.append(identifier)
        values = values.map {
            $0.identifier == identifier
                ? CloudGatewayMacInstalledProfile(identifier: $0.identifier, reference: $0.reference, status: .disconnected, mode: $0.mode)
                : $0
        }
    }

    func remove(identifier: String, authorize: @escaping @MainActor @Sendable () throws -> Void) async throws {
        await removeGate?.arriveAndWait()
        try Task.checkCancellation()
        try await authorize()
        _ = try CloudGatewayMacProfileMetadata.inactiveTarget(identifier: identifier, profiles: values)
        if let removeError { throw removeError }
        removedIdentifiers.append(identifier)
        values.removeAll { $0.identifier == identifier }
    }
}

private actor MacControllerSecrets: CloudGatewayMacSecretClient {
    let reference: CloudGatewayMacSecretReference
    private var installReference: CloudGatewayMacSecretReference?
    private var availabilityError: CloudGatewayMacSecretError?
    private var installError: CloudGatewayMacSecretError?
    private var authorizationError: CloudGatewayMacSecretError?
    private var authorizationGate: MacControllerGate?
    private var available = true
    private(set) var installCount = 0
    private(set) var installedHashes: [String] = []
    private(set) var authorizationCount = 0

    init(reference: CloudGatewayMacSecretReference) { self.reference = reference }
    func pauseAuthorization(_ gate: MacControllerGate) { authorizationGate = gate }
    func setAvailable(_ available: Bool) { self.available = available }
    func setInstallReference(_ reference: CloudGatewayMacSecretReference) { installReference = reference }
    func setAvailabilityError(_ error: CloudGatewayMacSecretError) { availabilityError = error }
    func setInstallError(_ error: CloudGatewayMacSecretError) { installError = error }
    func setAuthorizationError(_ error: CloudGatewayMacSecretError) { authorizationError = error }

    func install(configId: String, config: CloudGatewayWireGuardConfig) async throws -> CloudGatewayMacSecretReference {
        try Task.checkCancellation()
        installCount += 1
        installedHashes.append(CloudGatewayConfigHash.make(for: config))
        if let installError { throw installError }
        return installReference ?? reference
    }

    func commit(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
    }

    func rollback(reference: CloudGatewayMacSecretReference, configId: String) async throws {
        try Task.checkCancellation()
    }

    func isAvailable(reference: CloudGatewayMacSecretReference, configId: String) async throws -> Bool {
        try Task.checkCancellation()
        if reference != self.reference { return true }
        if let availabilityError { throw availabilityError }
        return available
    }

    func authorizeStart(reference: CloudGatewayMacSecretReference, configId: String) async throws -> String {
        authorizationCount += 1
        await authorizationGate?.arriveAndWait()
        try Task.checkCancellation()
        if let authorizationError { throw authorizationError }
        return "synthetic-start-grant"
    }
}

@MainActor
private final class MacControllerClock {
    var now = Date(timeIntervalSince1970: 5_000)
    var elapsed = Duration.zero
}

@MainActor
private final class MacControllerCommitProbe {
    var gate: MacControllerGate?
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

@Test(arguments: [CloudGatewayMacLoginStatus.Result.authorized, .cancelled, .expired])
@MainActor func macControllerLoginTerminalChangesPreserveAnAcceptedStop(_ terminal: CloudGatewayMacLoginStatus.Result) async throws {
    let fixture = try MacControllerFixture()
    fixture.auth.currentUser = nil
    fixture.auth.allowsSignIn = true
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    fixture.controller.setSetupState(.ready)
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil {
        fixture.domainSnapshot.domain.observationIsFresh && fixture.domainSnapshot.domain.stopAllowed == true
    }
    let stop = MacControllerGate()
    await fixture.profiles.pauseStop(stop)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.turnOff { outcome = $0 })
    try await controllerWaitUntil { await stop.entered }
    let request = MacControllerGate()
    await fixture.deviceAuth.allowLogin(requestGate: terminal == .authorized ? nil : request)
    let id = UUID()
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).result == nil)
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).attemptId == id)
    if terminal != .authorized { try await controllerWaitUntil { await request.entered } }
    switch terminal {
    case .cancelled: #expect(fixture.controller.cancelLogin(attemptId: id).result == .cancelled)
    case .expired: fixture.loginClock.advance(to: .seconds(500))
    default: break
    }
    try await controllerWaitUntil { fixture.controller.loginStatus(attemptId: id).result == terminal }
    #expect(outcome == nil)
    #expect(fixture.domainSnapshot.domain.commandInFlight)
    await stop.release()
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .completed(warning: nil))
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    if terminal == .authorized {
        try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
        #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [fixture.config.identifier])
        #expect(fixture.inventory.fetchCount == 1)
    } else {
        #expect(fixture.domainSnapshot.domain.accountId == nil)
        #expect(fixture.domainSnapshot.domain.clients.isEmpty)
        #expect(fixture.inventory.accessCount == 0)
        #expect(fixture.inventory.fetchCount == 0)
    }
    await request.release()
    if terminal != .authorized {
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.domainSnapshot.domain.accountId == nil)
        #expect(fixture.inventory.accessCount == 0)
        #expect(fixture.inventory.fetchCount == 0)
    }
}

@Test @MainActor func macControllerStaleLoginCancellationPreservesAuthorizedAccountAndBusyAttempt() async throws {
    let fixture = try MacControllerFixture()
    fixture.auth.currentUser = nil
    fixture.auth.allowsSignIn = true
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    let request = MacControllerGate()
    await fixture.deviceAuth.allowLogin(requestGate: request)
    let first = UUID()
    _ = fixture.controller.beginLogin(attemptId: first, origin: .cli)
    try await controllerWaitUntil { await request.entered }
    let other = UUID()
    #expect(fixture.controller.beginLogin(attemptId: other, origin: .menu).result == .busy)
    _ = fixture.controller.cancelLogin(attemptId: other)
    #expect(fixture.controller.loginStatus(attemptId: first).result == nil)
    await request.release()
    try await controllerWaitUntil { fixture.controller.loginStatus(attemptId: first).result == .authorized }
    _ = fixture.controller.cancelLogin(attemptId: first)
    #expect(fixture.domainSnapshot.domain.accountId == "user-a")
    #expect(fixture.controller.beginLogin(attemptId: UUID(), origin: .menu).result == .authorized)
}

@Test @MainActor func macControllerRetainedLoginVerificationExpiresWithoutFrontendAndIgnoresLateAccess() async throws {
    let fixture = try MacControllerFixture()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let id = UUID()
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).phase == .restoring)
    #expect(fixture.controller.beginLogin(attemptId: UUID(), origin: .menu).result == .busy)
    fixture.loginClock.advance(to: .seconds(500))
    try await controllerWaitUntil { fixture.controller.loginStatus(attemptId: id).result == .expired }
    await access.release()
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.domainSnapshot.domain.accountId == nil)
    #expect(fixture.auth.currentUser?.uid == "user-a")
    #expect(fixture.auth.signOutCount == 0)
}

@Test @MainActor func macControllerRetainedLoginRequiresSignInWhenFirebaseDropsTheSession() async throws {
    let fixture = try MacControllerFixture()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let id = UUID()
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).phase == .restoring)
    // Firebase signs out once it rejects the refresh token
    fixture.auth.emit(nil)
    await access.release()
    try await controllerWaitUntil { fixture.controller.loginStatus(attemptId: id).result == .signInRequired }
    #expect(fixture.domainSnapshot.domain.accountId == nil)
}

@Test @MainActor func macControllerRetainedLoginAuthorizationIsTerminalBeforeAccountPublication() async throws {
    let fixture = try MacControllerFixture()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let id = UUID()
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).phase == .restoring)
    var publishedPhases = [CloudGatewayMacLoginStatus.Phase]()
    fixture.controller.onChange = {
        guard fixture.domainSnapshot.domain.accountId != nil else { return }
        let status = fixture.controller.loginStatus(attemptId: id)
        publishedPhases.append(status.phase)
        if status.phase == .restoring { _ = fixture.controller.cancelLogin(attemptId: id) }
    }
    await access.release()
    try await controllerWaitUntil { !publishedPhases.isEmpty }
    #expect(publishedPhases.allSatisfy { $0 == .finished })
    #expect(fixture.controller.loginStatus(attemptId: id).result == .authorized)
    _ = fixture.controller.cancelLogin(attemptId: id)
    #expect(fixture.domainSnapshot.domain.accountId == "user-a")
    #expect(fixture.auth.currentUser?.uid == "user-a")
}

@Test @MainActor func macControllerLateOfflineRestoreExpiresBeforeDelayedWatchdogPublishesCachedAccount() async throws {
    let watchdog = MacControllerGate()
    let fixture = try MacControllerFixture(loginTimer: { _ in await watchdog.arriveAndWait() })
    try await fixture.seedCache()
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let id = UUID()
    #expect(fixture.controller.beginLogin(attemptId: id, origin: .cli).phase == .restoring)
    try await controllerWaitUntil { await watchdog.entered }
    fixture.loginClock.advance(to: .seconds(31))
    await access.release()
    try await controllerWaitUntil { fixture.controller.loginStatus(attemptId: id).result == .expired }
    #expect(fixture.domainSnapshot.domain.accountId == nil)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    #expect(fixture.auth.currentUser?.uid == "user-a")
    #expect(fixture.auth.signOutCount == 0)
    #expect(fixture.inventory.fetchCount == 0)
    await watchdog.release()
    #expect(fixture.controller.loginStatus(attemptId: id).result == .expired)
}


@Test @MainActor func macControllerUpdateCaptureUsesFreshActiveIdentityWithoutSecretRPC() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.options = [fixture.option(), fixture.option(clientId: "actual")]
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    await fixture.secrets.setAvailabilityError(.storageFailure)
    let actual = "user-a/region/actual"
    await fixture.profiles.setProfiles([.init(identifier: actual, reference: try fixture.config.reference, status: .reasserting)])
    let observation = try await fixture.controller.managedUpdateObservation()
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == fixture.config.identifier)
    #expect(observation.accountId == "user-a")
    #expect(observation.profiles.filter(\.needsStop).map(\.identifier) == [actual])
    #expect(observation.authorizedIdentifiers.contains(actual))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerManagedReconnectRefusesAnotherActiveProfileBeforeInstalling() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    await fixture.profiles.setProfiles([
        try fixture.profile(status: .disconnected),
        .init(identifier: "user-a/region/other", reference: try fixture.config.reference, status: .connecting),
    ])
    var result: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { result = $0 })
    try await controllerWaitUntil { result != nil }
    #expect(result == .failed(.busy))
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerManagedReconnectRechecksOtherProfilesAfterStartAuthorization() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var result: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { result = $0 })
    try await controllerWaitUntil { await authorization.entered }
    await fixture.profiles.setProfiles([
        try fixture.profile(status: .disconnected),
        .init(identifier: "other-account/region/client", reference: try fixture.config.reference, status: .connected),
    ])
    await authorization.release()
    try await controllerWaitUntil { result != nil }
    #expect(result == .failed(.busy))
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerNewStopCancelsAndDrainsManagedReconnect() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var connected: CloudGatewayMacCommandOutcome?
    var stopped: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { connected = $0 })
    try await controllerWaitUntil { await authorization.entered }
    #expect(fixture.controller.turnOff { stopped = $0 })
    await authorization.release()
    try await controllerWaitUntil { connected != nil && stopped != nil }
    #expect(stopped == .completed(warning: nil))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerAuthHookTracksAccountEventsWithoutInvalidatingRestorationOrShutdown() async throws {
    let fixture = try MacControllerFixture()
    var invalidations = 0
    fixture.controller.onAuthenticationChange = { invalidations += 1 }
    try await fixture.start()
    #expect(invalidations == 0)
    fixture.auth.emit(nil)
    #expect(invalidations == 1)
    fixture.auth.emit(.init(uid: "user-a", email: nil))
    #expect(invalidations == 2)
    try await controllerWaitUntil { fixture.snapshot.accountId == "user-a" }
    #expect(invalidations == 2)
    fixture.controller.shutdown()
    #expect(invalidations == 2)
    #expect(fixture.controller.onAuthenticationChange == nil)
}

@Test(arguments: [
    (CloudGatewayMacSetupState.required, CloudGatewayMacCommandFailure.initialSetupRequired),
    (.updateRequired, .extensionMismatch), (.invalidBundle, .invalidBundle), (.awaitingApproval, .approvalRequired),
    (.awaitingRestart, .restartRequired), (.checkingConnection, .checkingReadiness), (.activating, .checkingReadiness),
    (.failed(code: 7), .activationFailed),
])
@MainActor func macControllerConnectReportsActualSetupRequirement(
    state: CloudGatewayMacSetupState, expected: CloudGatewayMacCommandFailure
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.controller.setSetupState(state)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier) { outcome = $0 })
    #expect(outcome == .failed(expected))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerUnrelatedScopedStopWaitsForManagedReconnectWithoutCancellingIt(otherBecomesActive: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    fixture.inventory.options = [fixture.option(), fixture.option(clientId: "other")]
    let other = "user-a/region/other"
    await fixture.profiles.setProfiles([
        try fixture.profile(status: .disconnected),
        .init(identifier: other, reference: try fixture.config.reference, status: .disconnected),
    ])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let submission = MacControllerGate()
    await fixture.profiles.pauseStart(submission)
    var connected: CloudGatewayMacCommandOutcome?
    var stopped: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { connected = $0 })
    try await controllerWaitUntil { await submission.entered }
    await fixture.profiles.setProfiles([
        try fixture.profile(status: .connected),
        .init(identifier: other, reference: try fixture.config.reference, status: otherBecomesActive ? .connected : .disconnected),
    ])
    #expect(fixture.controller.disconnectClient(identifier: other) { stopped = $0 })
    #expect(connected == nil && stopped == nil)
    await submission.release()
    try await controllerWaitUntil { connected != nil && stopped != nil }
    #expect(connected == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(stopped == .completed(warning: nil))
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.stoppedIdentifiers == (otherBecomesActive ? [other] : []))
    let observation = try await fixture.controller.managedUpdateObservation()
    #expect(observation.profiles.filter(\.needsStop).map(\.identifier) == [fixture.config.identifier])
}

@Test @MainActor func macControllerCapturedScopedStopCancelsManagedReconnectBeforeStart() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var connected: CloudGatewayMacCommandOutcome?
    var stopped: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { connected = $0 })
    try await controllerWaitUntil { await authorization.entered }
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { stopped = $0 })
    await authorization.release()
    try await controllerWaitUntil { connected != nil && stopped != nil }
    #expect(stopped == .completed(warning: nil))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerUpdateObservationWaitsForExistingAuthRestorationWithoutRevocation() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    var invalidations = 0
    fixture.controller.onAuthenticationChange = { invalidations += 1 }
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await access.entered }
    let pending = try await fixture.controller.managedUpdateObservation()
    #expect(pending.isRestoringSession)
    #expect(pending.accountId == nil)
    #expect(!pending.accessAuthorized)
    #expect(invalidations == 0)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    await access.release()
    try await controllerWaitUntil { fixture.snapshot.canCreateClient && !fixture.snapshot.isRestoringSession }
    let restored = try await fixture.controller.managedUpdateObservation()
    #expect(!restored.isRestoringSession)
    #expect(restored.accountId == "user-a")
    #expect(restored.accessAuthorized)
    #expect(invalidations == 0)
}

@Test @MainActor func macControllerUpdateObservationWaitsForInitialInventoryAuthorization() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    fixture.controller.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { await fetch.entered }
    try await controllerWaitUntil { !fixture.domainSnapshot.isRestoringSession }
    let pending = try await fixture.controller.managedUpdateObservation()
    #expect(pending.isRestoringSession)
    #expect(!pending.accessAuthorized)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    await fetch.release()
    try await controllerWaitUntil { fixture.domainSnapshot.domain.inventoryFreshness == .current }
    let restored = try await fixture.controller.managedUpdateObservation()
    #expect(!restored.isRestoringSession)
    #expect(restored.accessAuthorized)
    #expect(restored.authorizedIdentifiers.contains(fixture.config.identifier))
}

@Test(arguments: [false, true])
@MainActor func macControllerManagedCancellationDrainsOnlyItsCapturedReconnect(managed: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var result: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: !managed) { result = $0 })
    try await controllerWaitUntil { await authorization.entered }
    await fixture.controller.cancelManagedReconnect(identifier: "user-a/region/other")
    #expect(result == nil)
    var drained = false
    let cancellation = Task { @MainActor in
        await fixture.controller.cancelManagedReconnect(identifier: fixture.config.identifier)
        drained = true
    }
    if managed {
        for _ in 0..<20 { await Task.yield() }
        #expect(!drained)
        #expect(fixture.controller.hasPendingWork)
    } else {
        await cancellation.value
        #expect(drained)
        #expect(result == nil)
    }
    await authorization.release()
    await cancellation.value
    try await controllerWaitUntil { result != nil }
    #expect(drained)
    #expect(await fixture.profiles.startedIdentifiers == (managed ? [] : [fixture.config.identifier]))
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [false, true], [CloudGatewayTunnelStatus.disconnected, .invalid])
@MainActor func macControllerRemovalEvictsBeforeHTTPAndPreservesOtherSelectionAndActiveVPN(
    selectedTarget: Bool, targetStatus: CloudGatewayTunnelStatus
) async throws {
    let fixture = try MacControllerFixture()
    let other = CloudGatewayMacInstalledConfig(
        accountId: "user-a", identifier: "user-a/region/other",
        snapshot: CloudGatewayConfigSnapshot(
            clientId: "other", regionId: "region", clientName: "Other", regionDisplayName: "Region",
            status: .active, configHash: fixture.config.snapshot.configHash,
            secretReference: fixture.config.snapshot.secretReference, readAt: Date(), updatedAt: nil
        )
    )
    fixture.inventory.options = [fixture.option(), fixture.option(clientId: "other")]
    try await fixture.cache.authorize(accountId: "user-a", role: .user, options: fixture.inventory.options)
    try await fixture.cache.save(fixture.config)
    try await fixture.cache.save(other)
    try await fixture.cache.select(identifier: selectedTarget ? fixture.config.identifier : other.identifier, accountId: "user-a")
    await fixture.profiles.setProfiles([
        try fixture.profile(status: targetStatus),
        .init(identifier: other.identifier, reference: try other.reference, status: .connected),
    ])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let token = MacControllerGate()
    fixture.inventory.removalTokenGate = token
    var outcome: CloudGatewayMacCommandOutcome?
    let caller = Task { @MainActor in
        fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 }
    }
    #expect(await caller.value)
    caller.cancel()
    try await controllerWaitUntil { await token.entered }
    let reopened = CloudGatewayMacAccountCache(directory: fixture.directory)
    #expect(try await reopened.load(accountId: "user-a").configs.map(\.identifier) == [other.identifier])
    #expect(try await reopened.load(accountId: "user-a").selectedIdentifier == (selectedTarget ? nil : other.identifier))
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [other.identifier])
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == [other.identifier])
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == (selectedTarget ? nil : other.identifier))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(fixture.controller.hasPendingWork)
    let fetches = fixture.inventory.fetchCount
    fixture.controller.refresh()
    #expect(fixture.inventory.fetchCount == fetches)
    var rejected: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.removeClient(identifier: other.identifier) { rejected = $0 })
    #expect(rejected == .failed(.busy))
    await token.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: nil))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [other.identifier])
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == (selectedTarget ? nil : other.identifier))
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await fixture.cache.save(fixture.config) }
    #expect(await fixture.profiles.removedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
    #expect(try await fixture.profiles.installedProfiles().map(\.identifier) == [other.identifier])
    var connected: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier) { connected = $0 })
    #expect(connected == .failed(.configUnavailable))
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerRemovalAllowsDisabledConfiglessUninstalledAndAdminTargets(admin: Bool, configless: Bool) async throws {
    let fixture = try MacControllerFixture()
    fixture.inventory.role = admin ? .admin : .user
    fixture.inventory.options = [fixture.option(
        wireGuardConfig: configless ? "" : controllerWireGuardConfig,
        ownerUid: admin ? "target-owner" : "user-a", enabled: false
    )]
    fixture.inventory.removalSession.body = admin
        ? #"{"userId":"target-owner","regionId":"region","clientId":"client","status":"removed"}"#
        : #"{"userId":"user-a","regionId":"region","clientId":"client","status":"removed"}"#
    try await fixture.start(ready: false)
    defer { fixture.controller.shutdown() }
    let accesses = fixture.inventory.accessCount
    let fetches = fixture.inventory.fetchCount
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .completed(warning: nil))
    #expect(fixture.inventory.accessCount == accesses + 2)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    let request = try #require(fixture.inventory.removalSession.requests.first)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "https://region.gocloudlaunch.com/api/clients/client")
    let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
    #expect(body == ["userId": admin ? "target-owner" : "user-a", "regionId": "region"])
    #expect(fixture.inventory.regionsCount == 0)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
}

@Test(arguments: ["user-b/region/client", "user-a/region", "user-a/region/client/other", "user-a/../client", ""])
@MainActor func macControllerRemovalRejectsMalformedOrForeignNamespaceSynchronously(identifier: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let accesses = fixture.inventory.accessCount
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.removeClient(identifier: identifier) { outcome = $0 })
    #expect(outcome == .failed(.configUnavailable))
    #expect(fixture.inventory.accessCount == accesses)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
}

@Test(arguments: ["missing", "removed", "duplicate", "ownerless", "blank-owner", "foreign"])
@MainActor func macControllerRemovalRequiresOneFreshNonremovedOwnedRecord(kind: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let before = try await fixture.cache.load(accountId: "user-a")
    fixture.inventory.filtersOwners = false
    fixture.inventory.options = switch kind {
    case "missing": []
    case "removed": [fixture.option(status: .removed)]
    case "duplicate": [fixture.option(), fixture.option()]
    case "ownerless": [fixture.option(ownerUid: nil)]
    case "blank-owner": [fixture.option(ownerUid: "  ")]
    default: [fixture.option(ownerUid: "foreign-owner")]
    }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(kind == "foreign" ? .accessDenied : .configUnavailable))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    if kind != "foreign" { #expect(try await fixture.cache.load(accountId: "user-a") == before) }
    else { #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed)) }
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [CloudGatewayTunnelStatus.connecting, .connected, .reasserting, .disconnecting])
@MainActor func macControllerRemovalRejectsAnActiveTargetWithoutEviction(status: CloudGatewayTunnelStatus) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: status)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.clientActive))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.map(\.identifier) == [fixture.config.identifier])
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalRejectsUnreadableOrDuplicateProfilesBeforeHTTP(duplicate: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    if duplicate { await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected), try fixture.profile(status: .invalid)]) }
    else { await fixture.profiles.failReads() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.configUnavailable))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.count == 1)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test(arguments: ["active", "unobservable", "logout", "account", "settling"])
@MainActor func macControllerRemovalRechecksAfterTokenLoadingBeforeHandoff(change: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let gate = MacControllerGate()
    fixture.inventory.removalTokenGate = gate
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await gate.entered }
    #expect(fixture.domainSnapshot.domain.installedIdentifiers.isEmpty)
    switch change {
    case "active": await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    case "unobservable": await fixture.profiles.failReads()
    case "logout": #expect(fixture.controller.signOut())
    case "account": fixture.auth.emit(.init(uid: "user-b", email: nil))
    default: fixture.auth.isCustomTokenSignInSettling = true
    }
    await gate.release()
    try await controllerWaitUntil { outcome != nil }
    let failure: CloudGatewayMacCommandFailure = change == "active" ? .clientActive
        : change == "unobservable" ? .configUnavailable : .signInRequired
    #expect(outcome == .failed(failure))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a").configs.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalFencesSessionAfterFinalProfileReload(logout: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let token = MacControllerGate()
    fixture.inventory.removalTokenGate = token
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await token.entered }
    let profile = MacControllerGate()
    await fixture.profiles.pauseNextRead(profile)
    await token.release()
    try await controllerWaitUntil { await profile.entered }
    if logout { #expect(fixture.controller.signOut()) }
    else { fixture.auth.emit(.init(uid: "user-b", email: nil)) }
    await profile.release()
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.signInRequired))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test(arguments: ["active", "unobservable", "remove-fails", "logout", "account", "refresh-fails", "cleanup-and-refresh"])
@MainActor func macControllerRemovalPreservesRemoteSuccessThroughCleanupAndRefreshFailures(change: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    #expect(fixture.inventory.removalSession.requests.count == 1)
    switch change {
    case "active": await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    case "unobservable": await fixture.profiles.failReads()
    case "remove-fails": await fixture.profiles.setRemoveError(.profileInstallationFailed)
    case "logout": #expect(fixture.controller.signOut())
    case "account": fixture.auth.emit(.init(uid: "user-b", email: nil))
    case "refresh-fails": fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    default:
        await fixture.profiles.failReads()
        fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    }
    response.resume()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: change == "refresh-fails" ? .inventoryNotRefreshed : .localCleanupIncomplete))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.removedIdentifiers == (change == "refresh-fails" ? [fixture.config.identifier] : []))
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a").configs.isEmpty)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    if change == "account" { #expect(fixture.domainSnapshot.domain.accountId == "user-b") }
}

@Test(arguments: [401, 403, 400, 404, 409, 500, 200])
@MainActor func macControllerRemovalClassifiesHTTPDenialsAndUncertainResponses(status: Int) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.inventory.removalSession.statusCode = status
    fixture.inventory.removalSession.body = #"{"error":{"message":"403 already removed"}}"#
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == (status == 401 || status == 403 ? .failed(.accessDenied) : .unknown))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty)
    #expect(fixture.domainSnapshot.domain.access == (status == 401 || status == 403 ? .denied : .online))
}

@Test(arguments: [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCancelled])
@MainActor func macControllerRemovalResponseLossIsUnknownAndSurvivesDeferredRefreshFailure(code: Int) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    fixture.inventory.removalSession.error = URLError(URLError.Code(rawValue: code))
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    fixture.controller.refresh()
    response.resume()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .unknown)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty)
}

@Test(arguments: ["access", "options", "token"])
@MainActor func macControllerRemovalPreDispatchReadFailureDoesNotDeleteOrUseOfflineCache(boundary: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    if boundary == "access" { fixture.inventory.accessError = CloudGatewayMacInventoryError.offline }
    if boundary == "options" { fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline }
    if boundary == "token" { fixture.inventory.removalTokenError = CloudGatewayMacInventoryError.offline }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.networkUnavailable))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty == (boundary == "token"))
}

@Test(arguments: ["access", "options", "token"])
@MainActor func macControllerRemovalPredispatchDenialInvalidatesAccount(boundary: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    if boundary == "access" { fixture.inventory.accessError = CloudGatewayMacInventoryError.accessDenied }
    if boundary == "options" { fixture.inventory.fetchError = CloudGatewayMacInventoryError.accessDenied }
    if boundary == "token" { fixture.inventory.removalTokenError = CloudGatewayMacInventoryError.accessDenied }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.accessDenied))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed))
    #expect(fixture.domainSnapshot.domain.access == .denied)
}

@Test @MainActor func macControllerRemovalRefreshesRoleAndHonorsDemotionBeforeResolvingOwner() async throws {
    let fixture = try MacControllerFixture()
    fixture.inventory.role = .admin
    fixture.inventory.options = [fixture.option(ownerUid: "foreign-owner")]
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.inventory.filtersOwners = false
    let access = MacControllerGate()
    fixture.inventory.accessGate = access
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await access.entered }
    fixture.inventory.role = .user
    await access.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.accessDenied))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed))
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerRemovalEvictionWriteFailurePreventsHTTP() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    let profile = MacControllerGate()
    await fixture.profiles.pauseNextRead(profile)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await profile.entered }
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil).first)
    try FileManager.default.moveItem(at: accountDirectory, to: fixture.directory.appendingPathComponent("backup"))
    try Data().write(to: accountDirectory)
    await profile.release()
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.configUnavailable))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == [fixture.config.identifier])
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalEvictionSurvivesRestartOffline(confirmed: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let profile = try fixture.profile(status: .disconnected)
    await fixture.profiles.setProfiles([profile])
    try await fixture.start()
    if !confirmed { fixture.inventory.removalSession.error = URLError(.networkConnectionLost) }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == (confirmed ? .completed(warning: nil) : .unknown))
    fixture.controller.shutdown()
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    let cache = CloudGatewayMacAccountCache(directory: fixture.directory)
    let restarted = CloudGatewayMacController(
        auth: fixture.auth, deviceAuth: fixture.deviceAuth, inventory: fixture.inventory, profiles: fixture.profiles,
        cache: cache, configs: CloudGatewayMacConfigCoordinator(secrets: fixture.secrets, profiles: fixture.profiles, snapshots: cache),
        dashboardOrigin: URL(string: "https://dashboard.example.com")!
    )
    restarted.start()
    defer { restarted.shutdown() }
    try await controllerWaitUntil { !restarted.hasPendingWork }
    #expect(restarted.snapshot().domain.accountId == "user-a")
    #expect(restarted.snapshot().domain.access == .offline)
    #expect(restarted.snapshot().domain.clients.isEmpty)
    #expect(restarted.snapshot().domain.installedIdentifiers.isEmpty)
    #expect(restarted.snapshot().lastSelectedIdentifier == nil)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(try await cache.load(accountId: "user-a").configs.isEmpty)
    #expect(try await cache.load(accountId: "user-a").selectedIdentifier == nil)
    #expect(try await fixture.profiles.installedProfiles() == (confirmed ? [] : [profile]))
    #expect(await fixture.profiles.removedIdentifiers == (confirmed ? [fixture.config.identifier] : []))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalLeavesLateActiveOrNewSessionProfileUntouched(atMutation: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let cleanup = MacControllerGate()
    await fixture.profiles.pauseRemove(cleanup)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await cleanup.entered }
    if atMutation { await fixture.profiles.setProfiles([try fixture.profile(status: .connected)]) }
    else { fixture.auth.emit(.init(uid: "user-b", email: nil)) }
    await cleanup.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: .localCleanupIncomplete))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
    let retained = try #require(try await fixture.profiles.installedProfiles().first)
    #expect(retained.identifier == fixture.config.identifier)
    #expect(retained.status == (atMutation ? .connected : .disconnected))
    #expect(try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a").selectedIdentifier == nil)
}

@Test(arguments: ["restoring", "settling", "signed-out", "shutdown"])
@MainActor func macControllerRemovalRequiresASettledStartedSession(state: String) async throws {
    let fixture = try MacControllerFixture()
    if state == "restoring" {
        let access = MacControllerGate()
        fixture.inventory.accessGate = access
        fixture.controller.start()
        try await controllerWaitUntil { await access.entered }
        var outcome: CloudGatewayMacCommandOutcome?
        #expect(!fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
        #expect(outcome == .failed(.signInRequired))
        await access.release()
    } else {
        try await fixture.start()
        if state == "settling" { fixture.auth.isCustomTokenSignInSettling = true }
        if state == "signed-out" {
            #expect(fixture.controller.signOut())
            try await controllerWaitUntil { !fixture.controller.hasPendingWork }
        }
        if state == "shutdown" { fixture.controller.shutdown() }
        var outcome: CloudGatewayMacCommandOutcome?
        #expect(!fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
        #expect(outcome == .failed(state == "signed-out" ? .signInRequired : .busy))
    }
    fixture.controller.shutdown()
    #expect(fixture.inventory.removalSession.requests.isEmpty)
}

@Test(arguments: ["access", "options"], [false, true])
@MainActor func macControllerRemovalFencesOriginalSessionDuringFreshInventory(boundary: String, sameAccount: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let gate = MacControllerGate()
    if boundary == "access" { fixture.inventory.accessGate = gate }
    else { fixture.inventory.fetchGate = gate }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await gate.entered }
    #expect(fixture.controller.signOut())
    fixture.auth.emit(.init(uid: sameAccount ? "user-a" : "user-b", email: nil))
    fixture.inventory.accessGate = nil
    fixture.inventory.fetchGate = nil
    await gate.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.signInRequired))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.count == 1)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalPreservesSuccessWhenFinalAuthorizationFails(cleanupFails: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    fixture.inventory.accessError = CloudGatewayMacInventoryError.accessDenied
    if cleanupFails { await fixture.profiles.failReads() }
    response.resume()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: .localCleanupIncomplete))
    #expect(fixture.domainSnapshot.domain.access == .denied)
    #expect(!(try await fixture.cache.load(accountId: "user-a").accessAllowed))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalGenericDenialAfterHandoffStaysUnknown(genericInventoryError: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.inventory.removalSession.error = genericInventoryError
        ? CloudGatewayMacInventoryError.accessDenied : CloudGatewayAppError.accessDenied("fixture error")
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .unknown)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(fixture.domainSnapshot.domain.accountId == "user-a")
    #expect(try await fixture.cache.load(accountId: "user-a").accessAllowed)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerRemovalPostResponseSettlementCannotRestoreStaleTarget() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    fixture.auth.isCustomTokenSignInSettling = true
    response.resume()
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .completed(warning: .localCleanupIncomplete))
    fixture.auth.isCustomTokenSignInSettling = false
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test @MainActor func macControllerRemovalUncertainTargetOnlyReturnsThroughFreshInventory() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    fixture.inventory.removalSession.error = URLError(.timedOut)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .unknown)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.domainSnapshot.domain.clients.map(\.identifier) == [fixture.config.identifier])
    #expect(fixture.domainSnapshot.domain.installedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalSuccessDuringFinalRefreshCannotMutateNewSession(sameAccount: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    let fetch = MacControllerGate()
    fixture.inventory.fetchGate = fetch
    response.resume()
    try await controllerWaitUntil { await fetch.entered }
    #expect(await fixture.profiles.removedIdentifiers == [fixture.config.identifier])
    #expect(fixture.controller.signOut())
    fixture.auth.emit(.init(uid: sameAccount ? "user-a" : "user-b", email: nil))
    fixture.inventory.fetchGate = nil
    await fetch.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: .localCleanupIncomplete))
    #expect(fixture.domainSnapshot.domain.accountId == (sameAccount ? "user-a" : "user-b"))
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerRemovalConfirmedTargetCannotBeDeletedAgainFromStaleCloudCopy() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .completed(warning: nil))
    outcome = nil
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.configUnavailable))
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test @MainActor func macControllerRemovalCompletionCannotCleanUpTheNextAccountsSelectionOrProfile() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let nextConfig = CloudGatewayMacInstalledConfig(
        accountId: "user-b", identifier: "user-b/region/client",
        snapshot: fixture.config.snapshot
    )
    let nextOption = fixture.option(ownerUid: "user-b")
    try await fixture.cache.authorize(accountId: "user-b", role: .user, options: [nextOption])
    try await fixture.cache.save(nextConfig)
    try await fixture.cache.select(identifier: nextConfig.identifier, accountId: "user-b")
    await fixture.profiles.setProfiles([
        try fixture.profile(status: .disconnected),
        .init(identifier: nextConfig.identifier, reference: try nextConfig.reference, status: .connected),
    ])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { response.entered }
    fixture.inventory.options = [nextOption]
    fixture.auth.emit(.init(uid: "user-b", email: nil))
    var rejected: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.removeClient(identifier: nextConfig.identifier) { rejected = $0 })
    #expect(rejected == .failed(.busy))
    response.resume()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: .localCleanupIncomplete))
    #expect(fixture.domainSnapshot.domain.accountId == "user-b")
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nextConfig.identifier)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == [nextConfig.identifier])
    #expect(try await fixture.cache.load(accountId: "user-b").selectedIdentifier == nextConfig.identifier)
    #expect(try await fixture.cache.load(accountId: "user-b").configs.map(\.identifier) == [nextConfig.identifier])
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(try await fixture.profiles.installedProfiles().count == 2)
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test @MainActor func macControllerRemovalRejectsManagedStopWhileItDrainsAReconnect() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let authorization = MacControllerGate()
    await fixture.secrets.pauseAuthorization(authorization)
    var connected: CloudGatewayMacCommandOutcome?
    var stopped: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { connected = $0 })
    try await controllerWaitUntil { await authorization.entered }
    #expect(fixture.controller.disconnectClient(identifier: fixture.config.identifier) { stopped = $0 })
    var removal: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.removeClient(identifier: fixture.config.identifier) { removal = $0 })
    #expect(removal == .failed(.busy))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    await authorization.release()
    try await controllerWaitUntil { connected != nil && stopped != nil }
    #expect(stopped == .completed(warning: nil))
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@MainActor
private final class MacControllerRemovalIPC {
    let identity = CloudGatewayMacBuildIdentity(version: "1.0", build: "2", codeHash: String(repeating: "a", count: 64))
    private let instanceId = UUID()
    private(set) var data: Data?
    private(set) var performed: [CloudGatewayMacControllerRequest.Action] = []
    private(set) var received: [CloudGatewayMacControllerRequest] = []
    var actions: [CloudGatewayMacControllerRequest.Action] { received.map(\.action) }
    private(set) var cliOutput = ""
    private(set) var cliDiagnostics = ""
    var onCLIOutput: ((String) throws -> Void)?
    var confirmationGate: ClientRemovalGate?
    var confirmationReply: ClientRemovalGate?
    var losesConfirmationReply = false
    private(set) var requests: CloudGatewayMacControllerRequests!
    private(set) var orchestrator: CloudGatewayMacControllerOrchestrator!

    init(_ fixture: MacControllerFixture, data: Data? = nil) throws {
        self.data = data
        requests = try .init(data: data, now: { fixture.clock.now }) { self.data = $0 }
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { setup, canUpdate in
                .init(snapshot: fixture.controller.snapshot(), setupState: setup, canUpdateExtension: canUpdate)
            },
            hasPendingWork: { fixture.controller.hasPendingWork },
            perform: { request, complete in
                self.performed.append(request.action)
                switch request.action {
                case .removeClient:
                    guard let identifier = request.identifier else { return false }
                    return fixture.controller.removeClient(identifier: identifier, onCompletion: complete)
                case .connect: return fixture.controller.connectClient(identifier: request.identifier, onCompletion: complete)
                case .turnOff: return fixture.controller.turnOff(onCompletion: complete)
                case .disconnectClient:
                    guard let identifier = request.identifier else { return false }
                    return fixture.controller.disconnectClient(identifier: identifier, onCompletion: complete)
                case .signOut:
                    complete(fixture.controller.signOut() ? .completed(warning: nil) : .failed(.credentialsUnavailable))
                    return true
                default: return false
                }
            },
            session: { fixture.controller.session },
            refresh: { await fixture.controller.awaitRefresh() },
            prepareClient: {
                guard let context = fixture.controller.clientCreationContext() else {
                    throw CloudGatewayMacControllerFailure.busy
                }
                let regions = try await fixture.controller.loadCreateRegions(context: context)
                return CloudGatewayMacPreparedClient(regions: regions) { region, name, complete in
                    fixture.controller.createClient(regionId: region, clientName: name, context: context, onCompletion: complete)
                }
            },
            setSetupState: { fixture.controller.setSetupState($0) },
            hasAnyActiveTunnel: { fixture.snapshot.hasActiveTunnel },
            installedIdentity: { self.identity }, extensionIdentity: { self.identity },
            ping: { identity in
                CloudGatewayMacExtensionVersion(infoDictionary: [
                    "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version
                ], codeHash: identity.codeHash)
            }, registrationReadiness: { .ready },
            userActivity: { fixture.controller.recordUserActivity(refreshIfStale: $0) },
            setAutomaticInventoryRefreshAllowed: { fixture.controller.setAutomaticInventoryRefreshAllowed($0, discardDeferred: $1) },
            now: { fixture.clock.now }
        )
        orchestrator = .init(identity: identity, effects: effects, requests: requests,
                             extensionUpdates: try .init(bootSession: { "boot" }, persist: { _ in }))
    }

    func client() async throws -> CloudGatewayMacFrontendClient {
        let client = CloudGatewayMacFrontendClient(identity: identity, transport: { try await self.send($0) }, bootstrap: {})
        _ = try await client.handshake()
        return client
    }

    func runCLI(_ arguments: [String]) async -> Int32 {
        let cli = CloudGatewayMacCLI(
            version: identity.version, build: identity.build,
            terminal: .init(isOutputTerminal: false, variables: [:]), clock: .continuous,
            output: {
                try self.onCLIOutput?($0)
                self.cliOutput += $0
            }, diagnostics: { self.cliDiagnostics += $0 },
            connect: { try await self.client() }
        )
        return await cli.run(arguments)
    }

    func cliRecords() throws -> [[String: Any]] {
        try cliOutput.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func acceptedCLIId(isJSON: Bool) throws -> UUID {
        let value: String
        if isJSON { value = try #require(cliRecords().first?["operationId"] as? String) }
        else {
            let line = try #require(cliOutput.split(separator: "\n").first)
            #expect(line.hasPrefix("Accepted operation "))
            value = String(line.dropFirst("Accepted operation ".count))
        }
        return try #require(UUID(uuidString: value))
    }

    private func send(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        received.append(request)
        let encoded = try CloudGatewayMacControllerProtocol.encodeRequest(
            request, appVersion: identity.version, appBuild: identity.build, buildIdentity: identity
        )
        let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(
            encoded, appVersion: identity.version, appBuild: identity.build, buildIdentity: identity
        )
        if request.action == .confirmOperation { await confirmationGate?.wait() }
        let reply = await orchestrator.handle(decoded)
        if request.action == .confirmOperation {
            await confirmationReply?.wait()
            if losesConfirmationReply { throw CloudGatewayMacControllerFailure.timeout }
        }
        return try CloudGatewayMacControllerProtocol.decodeReply(
            CloudGatewayMacControllerProtocol.encodeReply(reply, appVersion: identity.version, appBuild: identity.build,
                                                           instanceId: instanceId, action: request.action),
            appVersion: identity.version, appBuild: identity.build, action: request.action
        )
    }
}

@Test(arguments: [401, 403, 409, 500, 503], [false, true])
@MainActor func macControllerCreationHTTPFailuresReachTheCLIWithoutFalseAuthDenial(status: Int, json: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let session = MacClientRemovalSession()
    session.statusCode = status
    session.body = #"{"error":{"code":"LIMIT_REACHED","message":"fixture API failure"}}"#
    fixture.inventory.creationSession = session
    let ipc = try MacControllerRemovalIPC(fixture)
    let originalSession = fixture.controller.session
    var output = ""
    var diagnostics = ""
    let cli = CloudGatewayMacCLI(
        version: ipc.identity.version, build: ipc.identity.build,
        terminal: .init(isOutputTerminal: false, variables: [:]), clock: .continuous,
        output: { output += $0 }, diagnostics: { diagnostics += $0 }, connect: { try await ipc.client() }
    )
    let denied = status == 401 || status == 403
    #expect(await cli.run(["add", "region", "Mac mini"] + (json ? ["--json"] : [])) == (denied ? 9 : 10))
    let operation = try #require(ipc.requests.latest)
    let expected: CloudGatewayMacCommandOutcome = denied ? .failed(.accessDenied) : .unknown
    #expect(operation.state == (denied ? .failed : .unknown))
    #expect(ipc.requests.outcome(id: operation.id, session: originalSession) == expected)
    #expect(try await ipc.client().request(.operation, contextId: operation.id).outcome == (denied ? nil : expected))
    #expect(output.contains(denied ? "command_failed" : "operation_unknown") == json)
    #expect((json ? output : diagnostics).contains("cloudgateway status"))
    #expect(!output.contains("access_denied"))
    #expect(output.contains(operation.id.uuidString.lowercased()))
    if !denied {
        #expect(!output.contains("Account access was denied"))
        #expect(!output.contains("Sign in again"))
    }
    #expect(fixture.domainSnapshot.domain.accountId == (denied ? nil : "user-a"))
    #expect(fixture.domainSnapshot.domain.accessAuthorized == !denied)
    #expect(try await fixture.cache.load(accountId: "user-a").accessAllowed == !denied)
    #expect(session.requests.count == 1)
    #expect(session.requests.first?.httpMethod == "POST")
    #expect(session.requests.first?.url?.absoluteString == "https://region.gocloudlaunch.com/api/clients")
}

@Test(arguments: ["region", "Region"], [false, true])
@MainActor func macControllerCLIRemovalAcceptsBeforeExecutionAndSendsTheCanonicalTarget(region: String, isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    var acceptedBeforeExecution = false
    ipc.onCLIOutput = { _ in
        guard ipc.cliOutput.isEmpty else { return }
        let reservation = try #require(ipc.received.last)
        #expect(reservation.action == .removeClient)
        #expect(reservation.identifier == "user-a/region/client")
        #expect(ipc.requests.operation(id: reservation.id).state == .accepted)
        #expect(ipc.performed.isEmpty)
        #expect(fixture.inventory.removalSession.requests.isEmpty)
        #expect(!fixture.controller.hasPendingWork)
        acceptedBeforeExecution = true
    }
    fixture.inventory.removalSession.onRequest = { _ in
        #expect(acceptedBeforeExecution)
        #expect(ipc.cliOutput.split(separator: "\n").count == 1)
    }
    #expect(await ipc.runCLI(["remove", region, "01", "--yes", "--non-interactive"] + (isJSON ? ["--json"] : [])) == 0)
    #expect(acceptedBeforeExecution)
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    #expect(ipc.requests.outcome(id: id, session: fixture.controller.session) == .completed(warning: nil))
    #expect(ipc.received.filter { $0.action == .removeClient }.map(\.identifier) == ["user-a/region/client"])
    #expect(ipc.received.filter { $0.action == .confirmOperation }.map(\.contextId) == [id])
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.map(\.httpMethod) == ["DELETE"])
    #expect(fixture.inventory.removalSession.requests.first?.url?.absoluteString == "https://region.gocloudlaunch.com/api/clients/client")
    if isJSON {
        let records = try ipc.cliRecords()
        #expect(records.count == 2)
        #expect(records.first?["type"] as? String == "accepted")
        #expect(records.last?["type"] as? String == "result")
        #expect(records.last?["operationId"] as? String == id.uuidString.lowercased())
    } else { #expect(ipc.cliOutput.contains("Client removed\n")) }
    #expect(ipc.cliDiagnostics.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func macControllerCLIRemovalRefusesAnActiveTargetWithoutStoppingIt(isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    #expect(await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) == 4)
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    #expect(ipc.requests.outcome(id: id, session: fixture.controller.session) == .failed(.clientActive))
    #expect((ipc.cliOutput + ipc.cliDiagnostics).contains("Disconnect that client and wait for it to stop before removing it"))
    if isJSON {
        let record = try #require(ipc.cliRecords().last)
        #expect((record["error"] as? [String: Any])?["code"] as? String == "client_active")
    }
    #expect(!ipc.cliOutput.contains("Client removed"))
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerCLIRemovalWarningsRemainSuccessful(cleanupFails: Bool, isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    let caller = Task { await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) }
    try await controllerWaitUntil { response.entered }
    if cleanupFails { await fixture.profiles.setRemoveError(.profileInstallationFailed) }
    else { fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline }
    response.resume()
    #expect(await caller.value == 0)
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    #expect(ipc.requests.outcome(id: id, session: fixture.controller.session)
        == .completed(warning: cleanupFails ? .localCleanupIncomplete : .inventoryNotRefreshed))
    if isJSON {
        let record = try #require(ipc.cliRecords().last)
        let data = try #require(record["data"] as? [String: Any])
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(record["error"] is NSNull)
        #expect(operation["result"] as? String == "completed")
        #expect(operation["warning"] as? String == (cleanupFails ? "local_cleanup_incomplete" : "inventory_not_refreshed"))
    } else {
        #expect(ipc.cliOutput.contains("Client removed\n"))
        #expect(ipc.cliOutput.contains(cleanupFails ? "local cleanup incomplete" : "inventory not refreshed"))
    }
    #expect(ipc.cliDiagnostics.isEmpty)
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerCLIRemovalCallerLossLeavesConfirmedWorkRunning(cancel: Bool, isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    if cancel { ipc.confirmationReply = ClientRemovalGate() }
    else { ipc.losesConfirmationReply = true }
    let caller = Task { await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) }
    try await controllerWaitUntil { response.entered }
    if cancel {
        try await controllerWaitUntil { ipc.confirmationReply?.entered == true }
        caller.cancel()
    }
    #expect(await caller.value == (cancel ? 130 : 10))
    ipc.confirmationReply?.resume()
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    #expect((ipc.cliOutput + ipc.cliDiagnostics).contains("cloudgateway status --operation \(id.uuidString.lowercased())"))
    #expect((ipc.cliOutput + ipc.cliDiagnostics).contains("original client UUID"))
    let observer = try await ipc.client()
    #expect(try await observer.send(.operation, contextId: id).operation?.state == .running)
    #expect(fixture.controller.hasPendingWork)
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    #expect(try await observer.send(.operation, contextId: id).outcome == .completed(warning: nil))
    #expect(!ipc.cliOutput.contains("Client removed"))
    #expect(ipc.actions.filter { $0 == .removeClient }.count == 1)
    #expect(ipc.actions.filter { $0 == .confirmOperation }.count == 1)
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerCLIRemovalRejectsSessionChangesBeforeConfirmation(sameAccount: Bool, isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let confirmation = ClientRemovalGate()
    ipc.confirmationGate = confirmation
    let originalSession = fixture.controller.session
    let caller = Task { await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) }
    try await controllerWaitUntil { confirmation.entered }
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    if sameAccount { fixture.auth.emit(nil) }
    fixture.auth.emit(.init(uid: sameAccount ? "user-a" : "user-b", email: nil))
    try await controllerWaitUntil { fixture.controller.session != originalSession }
    confirmation.resume()
    #expect(await caller.value == 4)
    #expect(ipc.requests.outcome(id: id, session: originalSession) == .failed(.signInRequired))
    #expect(ipc.received.filter { $0.action == .removeClient }.map(\.identifier) == [fixture.config.identifier])
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(!ipc.cliOutput.contains("Client removed"))
    #expect(!(ipc.cliOutput + ipc.cliDiagnostics).contains(fixture.config.identifier))
    if isJSON {
        let record = try #require(ipc.cliRecords().last)
        #expect((record["error"] as? [String: Any])?["code"] as? String == "controller_rejected")
    }
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerCLIRemovalRedactsSuccessAndWarningsAfterSessionChanges(logout: Bool, isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    ipc.confirmationReply = ClientRemovalGate()
    let originalSession = fixture.controller.session
    let caller = Task { await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) }
    try await controllerWaitUntil { response.entered && ipc.confirmationReply?.entered == true }
    let id = try ipc.acceptedCLIId(isJSON: isJSON)
    if logout { #expect(fixture.controller.signOut()) }
    else { fixture.auth.emit(.init(uid: "user-b", email: nil)) }
    try await controllerWaitUntil { fixture.controller.session != originalSession }
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    #expect(ipc.requests.outcome(id: id, session: originalSession) == .completed(warning: .localCleanupIncomplete))
    ipc.confirmationReply?.resume()
    #expect(await caller.value == 0)
    if isJSON {
        let record = try #require(ipc.cliRecords().last)
        let data = try #require(record["data"] as? [String: Any])
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(record["type"] as? String == "result")
        #expect(record["operationId"] as? String == id.uuidString.lowercased())
        #expect(operation["state"] as? String == "completed")
        for key in ["result", "configId", "warning", "error"] { #expect(operation[key] is NSNull) }
        #expect(data["choices"] is NSNull)
    } else { #expect(ipc.cliOutput.contains("Command completed\n")) }
    for hidden in [fixture.config.identifier, "user-a", "Mac", "Client removed", "local_cleanup_incomplete", "local cleanup incomplete"] {
        #expect(!ipc.cliOutput.contains(hidden))
    }
    #expect(ipc.cliDiagnostics.isEmpty)
    #expect(ipc.received.filter { $0.action == .removeClient }.map(\.identifier) == [fixture.config.identifier])
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [false, true])
@MainActor func macControllerCLIRemovalOutputFailureLeavesRealReservationUnconfirmed(isJSON: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    ipc.onCLIOutput = { _ in throw CocoaError(.fileWriteUnknown) }
    #expect(await ipc.runCLI(["remove", "region", "1", "--yes"] + (isJSON ? ["--json"] : [])) == 1)
    let reservations = ipc.received.filter { $0.action == .removeClient }
    #expect(reservations.count == 1)
    let id = try #require(reservations.first?.id)
    #expect(ipc.requests.operation(id: id).state == .accepted)
    #expect(!ipc.actions.contains(.confirmOperation))
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(ipc.cliOutput.isEmpty)
}

@Test @MainActor func macControllerRemovalIPCTwoFrontendsReserveOneSideEffectFreeOperation() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let first = try await ipc.client()
    let second = try await ipc.client()
    let id = UUID()
    #expect(try await first.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .accepted)
    await #expect(throws: CloudGatewayMacControllerFailure.busy) {
        try await second.send(.removeClient, identifier: fixture.config.identifier)
    }
    for action in [CloudGatewayMacControllerRequest.Action.connect, .turnOff, .disconnectClient, .signOut] {
        await #expect(throws: CloudGatewayMacControllerFailure.busy) {
            try await second.send(action, identifier: [.connect, .disconnectClient].contains(action) ? fixture.config.identifier : nil)
        }
    }
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(try await fixture.cache.load(accountId: "user-a").configs.map(\.identifier) == [fixture.config.identifier])
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == fixture.config.identifier)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)

    #expect(try await second.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .accepted)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    #expect(try await first.confirm(id).operation?.state == .running)
    try await controllerWaitUntil { response.entered }
    #expect(try await second.confirm(id).operation?.state == .running)
    await #expect(throws: CloudGatewayMacControllerFailure.busy) {
        try await second.send(.connect, identifier: fixture.config.identifier)
    }
    #expect(fixture.inventory.removalSession.requests.count == 1)
    let request = try #require(fixture.inventory.removalSession.requests.first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "https://region.gocloudlaunch.com/api/clients/client")
    #expect(try JSONDecoder().decode([String: String].self, from: #require(request.httpBody)) == ["userId": "user-a", "regionId": "region"])
    #expect(try await fixture.cache.load(accountId: "user-a").configs.isEmpty)
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    #expect(try await second.request(.operation, contextId: id).outcome == .completed(warning: nil))
    #expect(ipc.performed == [.removeClient])
    #expect(await fixture.profiles.removedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
}

@Test(arguments: ["detach", "cancel", "lost-reply"])
@MainActor func macControllerRemovalIPCExecutionOutlivesTheConfirmingFrontend(ending: String) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let caller = try await ipc.client()
    let observer = try await ipc.client()
    let id = UUID()
    _ = try await caller.send(.removeClient, id: id, identifier: fixture.config.identifier)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    if ending == "cancel" { ipc.confirmationReply = ClientRemovalGate() }
    ipc.losesConfirmationReply = ending == "lost-reply"
    let confirmation = Task { try await caller.confirm(id) }
    try await controllerWaitUntil { response.entered }
    if ending == "cancel" {
        try await controllerWaitUntil { ipc.confirmationReply?.entered == true }
        confirmation.cancel()
        ipc.confirmationReply?.resume()
        await #expect(throws: CancellationError.self) { try await confirmation.value }
    } else if ending == "lost-reply" {
        await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) { try await confirmation.value }
    } else {
        #expect(try await confirmation.value.operation?.state == .running)
    }
    caller.shutdown()
    _ = try await observer.handshake()
    #expect(try await observer.request(.operation, contextId: id).operation?.state == .running)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    #expect(try await observer.awaitOutcome(of: id, timeout: .seconds(1)).outcome == .completed(warning: nil))
    #expect(ipc.actions.filter { $0 == .confirmOperation }.count == 1)
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [false, true])
@MainActor func macControllerRemovalIPCRechecksSessionAtConfirmation(sameAccount: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    let originalSession = fixture.controller.session
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    if sameAccount { fixture.auth.emit(nil) }
    fixture.auth.emit(AuthenticatedUser(uid: sameAccount ? "user-a" : "user-b", email: nil))
    try await controllerWaitUntil { fixture.controller.session != originalSession }
    let result = try await client.confirm(id)
    #expect(result.operation?.state == .failed)
    #expect(result.outcome == nil)
    #expect(ipc.requests.outcome(id: id, session: originalSession) == .failed(.signInRequired))
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerRemovalIPCUsesFreshDomainValidationAfterReservation() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    fixture.inventory.options = []
    _ = try await client.confirm(id)
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .failed }
    #expect(try await client.request(.operation, contextId: id).outcome == .failed(.configUnavailable))
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerRemovalIPCExpiresUnconfirmedAndRejectsChangedPayload() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    for action in [CloudGatewayMacControllerRequest.Action.removeClient, .connect] {
        await #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try await client.send(action, id: id, identifier: "user-a/region/other")
        }
    }
    fixture.clock.now += 31
    #expect(try await client.confirm(id).outcome == .expired)
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .unknown)
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
}

@Test(arguments: [599.0, 601.0])
@MainActor func macControllerRemovalIPCRestartHonorsOnlyUnexpiredReceipts(elapsed: TimeInterval) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    fixture.inventory.removalSession.error = URLError(.networkConnectionLost)
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    _ = try await client.confirm(id)
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .unknown }
    #expect(fixture.inventory.removalSession.requests.count == 1)
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    fixture.clock.now += elapsed
    let persisted = try #require(ipc.data)
    let restarted = try MacControllerRemovalIPC(fixture, data: persisted)
    let reconnected = try await restarted.client()
    let replay = try await reconnected.send(.removeClient, id: id, identifier: fixture.config.identifier)
    #expect(replay.operation?.state == (elapsed < 600 ? .unknown : .accepted))
    #expect(replay.outcome == nil)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    if elapsed < 600 {
        #expect(try await reconnected.confirm(id).operation?.state == .unknown)
        #expect(restarted.performed.isEmpty)
        await #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try await reconnected.send(.removeClient, id: id, identifier: "user-a/region/other")
        }
    } else {
        fixture.inventory.removalSession.error = nil
        _ = try await reconnected.confirm(id)
        try await controllerWaitUntil { restarted.requests.operation(id: id).state == .completed }
        #expect(fixture.inventory.removalSession.requests.count == 2)
        #expect(restarted.performed == [.removeClient])
    }
}

@Test(arguments: [false, true], [false, true])
@MainActor func macControllerRemovalIPCSessionChangeRedactsEvenVerifiedSuccess(duringExecution: Bool, logout: Bool) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    let originalSession = fixture.controller.session
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    _ = try await client.confirm(id)
    try await controllerWaitUntil { response.entered }
    if !duringExecution {
        response.resume()
        try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
        #expect(try await client.request(.operation, contextId: id).outcome == .completed(warning: nil))
    }
    if logout { #expect(fixture.controller.signOut()) }
    else { fixture.auth.emit(AuthenticatedUser(uid: "user-b", email: nil)) }
    try await controllerWaitUntil { fixture.controller.session != originalSession }
    if duringExecution { response.resume() }
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    let result = try await client.request(.operation, contextId: id)
    #expect(result.operation?.state == .completed)
    #expect(result.outcome == nil)
    #expect(ipc.requests.outcome(id: id, session: originalSession) == .completed(warning: duringExecution ? .localCleanupIncomplete : nil))
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).outcome == nil)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerRemovalIPCRefusesWhileAnotherFrontendStartsATunnel() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let first = try await ipc.client()
    let second = try await ipc.client()
    let start = MacControllerGate()
    await fixture.secrets.pauseAuthorization(start)
    let connect = try await first.send(.connect, identifier: fixture.config.identifier)
    _ = try await first.confirm(#require(connect.operationId))
    try await controllerWaitUntil { await start.entered }
    await #expect(throws: CloudGatewayMacControllerFailure.busy) {
        try await second.send(.removeClient, identifier: fixture.config.identifier)
    }
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    await start.release()
    try await controllerWaitUntil { ipc.requests.operation(id: connect.operationId!).state == .completed }
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
}

@Test @MainActor func macControllerRemovalIPCConcurrentReservationsHaveOneWinner() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let first = try await ipc.client()
    let second = try await ipc.client()
    let firstRequest = Task { try await first.send(.removeClient, identifier: fixture.config.identifier) }
    let secondRequest = Task { try await second.send(.removeClient, identifier: fixture.config.identifier) }
    let results = await [firstRequest.result, secondRequest.result]
    var accepted = 0
    var busy = 0
    for result in results {
        switch result {
        case .success(let reply):
            #expect(reply.operation?.state == .accepted)
            accepted += 1
        case .failure(let error):
            #expect(error as? CloudGatewayMacControllerFailure == .busy)
            busy += 1
        }
    }
    #expect(accepted == 1)
    #expect(busy == 1)
    #expect(ipc.performed.isEmpty)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
}

@Test @MainActor func macControllerRemovalIPCRunningAndCompletedResultsKeepTheirOwnLifetime() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let id = UUID()
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    _ = try await client.confirm(id)
    try await controllerWaitUntil { response.entered }
    fixture.clock.now += 601
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .running)
    #expect(try await client.confirm(id).operation?.state == .running)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .completed }
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    fixture.clock.now += 599
    #expect(try await client.send(.operation, contextId: id).outcome == .completed(warning: nil))
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .completed)
    fixture.clock.now += 1
    #expect(try await client.send(.operation, contextId: id).operation?.state == .unknown)
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .accepted)
    #expect(ipc.performed == [.removeClient])
    #expect(fixture.inventory.removalSession.requests.count == 1)
}

@Test(arguments: [nil, "user-a", "user-b"] as [String?])
@MainActor func macControllerRemovalFencesSessionAfterDurableEviction(nextAccount: String?) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let nextConfig = CloudGatewayMacInstalledConfig(
        accountId: "user-b", identifier: "user-b/region/client", snapshot: fixture.config.snapshot
    )
    let nextOption = fixture.option(ownerUid: "user-b")
    try await fixture.cache.authorize(accountId: "user-b", role: .user, options: [nextOption])
    try await fixture.cache.save(nextConfig)
    try await fixture.cache.select(identifier: nextConfig.identifier, accountId: "user-b")
    let profiles = [try fixture.profile(status: .disconnected),
                    CloudGatewayMacInstalledProfile(identifier: nextConfig.identifier, reference: try nextConfig.reference, status: .connected)]
    await fixture.profiles.setProfiles(profiles)
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let eviction = MacControllerGate()
    fixture.evictionProbe.gate = eviction
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await eviction.entered }
    let reloaded = CloudGatewayMacAccountCache(directory: fixture.directory)
    #expect(try await reloaded.load(accountId: "user-a").configs.isEmpty)
    #expect(try await reloaded.load(accountId: "user-a").selectedIdentifier == nil)
    // Persistence has finished, but the command has not crossed its session fence
    #expect(fixture.domainSnapshot.domain.installedIdentifiers == [fixture.config.identifier])
    #expect(outcome == nil)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(fixture.controller.signOut())
    if let nextAccount {
        fixture.inventory.options = [nextAccount == "user-b" ? nextOption : fixture.option()]
        fixture.auth.emit(.init(uid: nextAccount, email: nil))
    }
    await eviction.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.signInRequired))
    #expect(fixture.domainSnapshot.domain.accountId == nextAccount)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == (nextAccount == "user-b" ? nextConfig.identifier : nil))
    #expect(try await reloaded.load(accountId: "user-a").configs.isEmpty)
    let nextCache = try await reloaded.load(accountId: "user-b")
    #expect(nextCache.configs.map(\.identifier) == [nextConfig.identifier])
    #expect(nextCache.configs.first?.snapshot.secretReference == nextConfig.snapshot.secretReference)
    #expect(nextCache.configs.first?.snapshot.configHash == nextConfig.snapshot.configHash)
    #expect(try await reloaded.load(accountId: "user-b").selectedIdentifier == nextConfig.identifier)
    #expect(fixture.inventory.removalSession.requests.isEmpty)
    #expect(try await fixture.profiles.installedProfiles() == profiles)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerRemovalLostResponseAfterBackendExecutionRequiresRefreshAndNeverResends() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let profile = try fixture.profile(status: .disconnected)
    await fixture.profiles.setProfiles([profile])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let response = ClientRemovalGate()
    fixture.inventory.removalSession.responseGate = response
    let removedOption = fixture.option(status: .removed)
    fixture.inventory.removalSession.onRequest = { [weak inventory = fixture.inventory] _ in
        inventory?.options = [removedOption]
    }
    fixture.inventory.removalSession.error = URLError(.networkConnectionLost)
    let id = UUID()
    _ = try await client.send(.removeClient, id: id, identifier: fixture.config.identifier)
    _ = try await client.confirm(id)
    try await controllerWaitUntil { response.entered }
    #expect(fixture.inventory.options.first?.client.status == .removed)
    fixture.inventory.fetchError = CloudGatewayMacInventoryError.offline
    fixture.controller.refresh()
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: id).state == .unknown && !fixture.controller.hasPendingWork }
    #expect(try await client.request(.operation, contextId: id).outcome == .unknown)
    #expect(try await client.send(.removeClient, id: id, identifier: fixture.config.identifier).operation?.state == .unknown)
    #expect(try await client.confirm(id).operation?.state == .unknown)
    #expect(try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a").configs.isEmpty)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    fixture.inventory.fetchError = nil
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await fixture.cache.save(fixture.config) }
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(ipc.performed == [.removeClient])
    #expect(try await fixture.profiles.installedProfiles() == [profile])
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test @MainActor func macControllerRemovalFinalPublicationCannotReauthorizeAStaleRemovedRecord() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let publication = MacControllerGate()
    fixture.commitProbe.gate = publication
    let fetches = fixture.inventory.fetchCount
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.removeClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { await publication.entered }
    #expect(outcome == nil)
    #expect(fixture.controller.hasPendingWork)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    #expect(fixture.inventory.options.first?.client.status == .active)
    #expect(try await CloudGatewayMacAccountCache(directory: fixture.directory).load(accountId: "user-a").configs.isEmpty)
    await #expect(throws: CloudGatewayMacCacheError.accessDenied) { try await fixture.cache.save(fixture.config) }
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.domain.installedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    #expect(try await fixture.profiles.installedProfiles().isEmpty)
    fixture.controller.refresh()
    #expect(fixture.inventory.fetchCount == fetches + 2)
    await publication.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: nil))
    #expect(fixture.inventory.fetchCount == fetches + 3)
    #expect(fixture.inventory.removalSession.requests.count == 1)
    #expect(fixture.domainSnapshot.domain.clients.isEmpty)
    #expect(fixture.domainSnapshot.lastSelectedIdentifier == nil)
    #expect(await fixture.profiles.removedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.installCount == 0)
}

@Test(arguments: [CloudGatewayMacControllerRequest.Action.turnOff, .disconnectClient], [false, true])
@MainActor func macControllerCreationIPCAllowsStopDuringPOSTAndFinalInventory(
    action: CloudGatewayMacControllerRequest.Action, finalInventory: Bool
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    let other = CloudGatewayMacInstalledProfile(identifier: "other-account/region/other", reference: try fixture.config.reference,
                                                 status: action == .disconnectClient ? .connected : .disconnected)
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected), other])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let session = MacClientRemovalSession()
    session.body = #"{"clientId":"new","regionId":"region","clientName":"New Mac","status":"active","wireguardConfig":"fixture config"}"#
    fixture.inventory.creationSession = session
    let response = ClientRemovalGate()
    let fetch = MacControllerGate()
    if finalInventory { fixture.inventory.fetchGate = fetch }
    else { session.responseGate = response }
    let ipc = try MacControllerRemovalIPC(fixture)
    let adding = try await ipc.client()
    let stopping = try await ipc.client()
    let preparation = try #require(try await adding.request(.prepareClient).creation)
    let addId = UUID()
    #expect(try await adding.request(.createClient, id: addId, regionId: "region", clientName: "New Mac", contextId: preparation.id).operation?.state == .running)
    if finalInventory { try await controllerWaitUntil { await fetch.entered } }
    else { try await controllerWaitUntil { response.entered } }
    #expect(fixture.snapshot.canTurnOff)
    #expect(!fixture.snapshot.canRefresh)
    #expect(!fixture.snapshot.canCreateClient)
    #expect(!fixture.snapshot.canRemoveClient)
    #expect(fixture.snapshot.groups.allSatisfy { $0.rows.allSatisfy { !$0.isEnabled } })
    let stopId = UUID()
    _ = try await stopping.request(action, id: stopId, identifier: action == .disconnectClient ? fixture.config.identifier : nil)
    try await controllerWaitUntil { ipc.requests.operation(id: stopId).state == .completed }
    #expect(ipc.requests.operation(id: addId).state == .running)
    #expect(try await stopping.request(.operation, contextId: stopId).outcome == .completed(warning: nil))
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(try await fixture.profiles.installedProfiles().first { $0.identifier == other.identifier }?.status == other.status)
    #expect(fixture.controller.hasPendingWork)
    #expect(await ipc.orchestrator.handle(.init(action: .prepareClient, buildIdentity: ipc.identity)).error == .busy)
    let fetches = fixture.inventory.fetchCount
    fixture.controller.refresh()
    #expect(fixture.inventory.fetchCount == fetches)
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier))
    #expect(!fixture.controller.removeClient(identifier: fixture.config.identifier))
    #expect(try await adding.confirm(addId).operation?.state == .running)
    if finalInventory { fixture.inventory.fetchGate = nil; await fetch.release() }
    else { session.responseGate = nil; response.resume() }
    try await controllerWaitUntil { ipc.requests.operation(id: addId).state == .completed && !fixture.controller.hasPendingWork }
    #expect(try await adding.request(.operation, contextId: addId).outcome == .completed(warning: nil))
    #expect(try await stopping.confirm(stopId).outcome == .completed(warning: nil))
    #expect(session.requests.count == 1)
    #expect(session.requests.first?.httpMethod == "POST")
    #expect(fixture.inventory.createdNames == ["New Mac"])
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.removedIdentifiers.isEmpty)
}

@Test(arguments: [CloudGatewayMacControllerRequest.Action.turnOff, .disconnectClient], 0..<4)
@MainActor func macControllerCreationIPCFinishesWhileStopIsHeld(
    action: CloudGatewayMacControllerRequest.Action, order: Int
) async throws {
    let reserveStopFirst = order >= 2
    let confirmStopFirst = order % 2 == 1
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let adding = try await ipc.client()
    let stopping = try await ipc.client()
    let preparation = try #require(try await adding.request(.prepareClient).creation)
    let stop = MacControllerGate()
    await fixture.profiles.pauseStop(stop)
    let addId = UUID()
    let stopId = UUID()
    let session = MacClientRemovalSession()
    session.body = #"{"clientId":"new","regionId":"region","clientName":"New Mac","status":"active","wireguardConfig":"fixture config"}"#
    fixture.inventory.creationSession = session
    let creation = MacControllerGate()
    fixture.inventory.createGate = creation
    if reserveStopFirst {
        #expect(try await stopping.send(action, id: stopId, identifier: action == .disconnectClient ? fixture.config.identifier : nil).operation?.state == .accepted)
    }
    #expect(try await adding.send(.createClient, id: addId, regionId: "region", clientName: "New Mac", contextId: preparation.id).operation?.state == .accepted)
    if !reserveStopFirst {
        #expect(try await stopping.send(action, id: stopId, identifier: action == .disconnectClient ? fixture.config.identifier : nil).operation?.state == .accepted)
    }
    #expect(fixture.inventory.createdNames.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    if confirmStopFirst {
        #expect(try await stopping.confirm(stopId).operation?.state == .running)
        try await controllerWaitUntil { await stop.entered }
        #expect(fixture.controller.clientCreationContext() == nil)
        await #expect(throws: CloudGatewayMacControllerFailure.busy) { try await adding.request(.prepareClient) }
    }
    #expect(try await adding.confirm(addId).operation?.state == .running)
    try await controllerWaitUntil { await creation.entered }
    if !confirmStopFirst {
        #expect(try await stopping.confirm(stopId).operation?.state == .running)
        try await controllerWaitUntil { await stop.entered }
    }
    let fetches = fixture.inventory.fetchCount
    var refreshed: CloudGatewayMacRefreshResult?
    var refreshStarted = false
    let refresh = Task {
        refreshStarted = true
        refreshed = await fixture.controller.awaitRefresh()
    }
    try await controllerWaitUntil { refreshStarted }
    await creation.release()
    try await controllerWaitUntil { ipc.requests.operation(id: addId).state == .completed }
    #expect(fixture.inventory.fetchCount == fetches + 1)
    #expect(refreshed == nil)
    #expect(ipc.requests.operation(id: stopId).state == .running)
    #expect(fixture.controller.hasPendingWork)
    #expect(!fixture.snapshot.canCreateClient)
    #expect(!fixture.snapshot.canTurnOff)
    #expect(!fixture.controller.connectClient(identifier: fixture.config.identifier))
    #expect(try await adding.confirm(addId).outcome == .completed(warning: nil))
    await stop.release()
    try await controllerWaitUntil { ipc.requests.operation(id: stopId).state == .completed && !fixture.controller.hasPendingWork }
    await refresh.value
    #expect(refreshed == .refreshed)
    #expect(fixture.inventory.fetchCount == fetches + 2)
    #expect(try await stopping.confirm(stopId).outcome == .completed(warning: nil))
    #expect(try await adding.request(.operation, contextId: addId).outcome == .completed(warning: nil))
    #expect(fixture.inventory.createdNames == ["New Mac"])
    #expect(session.requests.count == 1)
    #expect(session.requests.first?.httpMethod == "POST")
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
}

@Test(arguments: [CloudGatewayMacControllerRequest.Action.turnOff, .disconnectClient], [false, true])
@MainActor func macControllerCreationIPCSessionChangeCancelsAccountWorkButPreservesGlobalStop(
    action: CloudGatewayMacControllerRequest.Action, loginAgain: Bool
) async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    defer { fixture.controller.shutdown() }
    let ipc = try MacControllerRemovalIPC(fixture)
    let client = try await ipc.client()
    let originalSession = try #require(fixture.controller.session)
    let preparation = try #require(try await client.request(.prepareClient).creation)
    let session = MacClientRemovalSession()
    session.body = #"{"clientId":"new","regionId":"region","clientName":"New Mac","status":"active","wireguardConfig":"fixture config"}"#
    let response = ClientRemovalGate()
    session.responseGate = response
    fixture.inventory.creationSession = session
    let addId = UUID()
    _ = try await client.request(.createClient, id: addId, regionId: "region", clientName: "New Mac", contextId: preparation.id)
    try await controllerWaitUntil { response.entered }
    let stop = MacControllerGate()
    await fixture.profiles.pauseStop(stop)
    let stopId = UUID()
    _ = try await client.request(action, id: stopId, identifier: action == .disconnectClient ? fixture.config.identifier : nil)
    try await controllerWaitUntil { await stop.entered }
    #expect(fixture.controller.signOut())
    if loginAgain { fixture.auth.emit(AuthenticatedUser(uid: "user-b", email: nil)) }
    session.responseGate = nil
    response.resume()
    try await controllerWaitUntil { ipc.requests.operation(id: addId).state == .unknown }
    #expect(ipc.requests.outcome(id: addId, session: originalSession) == .unknown)
    #expect(try await client.request(.operation, contextId: addId).outcome == nil)
    #expect(ipc.requests.operation(id: stopId).state == .running)
    #expect(session.requests.count == 1)
    #expect(fixture.inventory.createdAccountIds == ["user-a"])
    await stop.release()
    try await controllerWaitUntil { ipc.requests.operation(id: stopId).state != .running && !fixture.controller.hasPendingWork }
    let stopped = try await client.request(.operation, contextId: stopId)
    if action == .turnOff {
        #expect(stopped.operation?.state == .completed)
        #expect(stopped.outcome == .completed(warning: nil))
        #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    } else {
        #expect(stopped.operation?.state == .unknown)
        #expect(stopped.outcome == nil)
        #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    }
    #expect(fixture.domainSnapshot.domain.accountId == (loginAgain ? "user-b" : nil))
    #expect(!fixture.domainSnapshot.domain.clients.contains { $0.identifier.hasPrefix("user-a/") })
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerDisconnectedModeIsPreferenceOnlyAndSurvivesRefresh() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .completed(warning: nil))
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.secrets.authorizationCount == 0)
    #expect(await fixture.controller.awaitRefresh() == .refreshed)
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    let reopened = CloudGatewayMacAccountCache(directory: fixture.directory)
    #expect(try await reopened.load(accountId: "user-a").selectedMode == .mesh)
    outcome = nil
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.savedModes == [.mesh])
}

@Test @MainActor func macControllerModeSwitchWaitsForStopBeforeSavingOrGranting() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let stop = MacControllerGate()
    await fixture.profiles.pauseStop(stop)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { await stop.entered }
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.authorizationCount == 0)
    var overlap: CloudGatewayMacCommandOutcome?
    #expect(!fixture.controller.setMode(.full) { overlap = $0 })
    #expect(overlap == .failed(.busy))
    await stop.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
    #expect(await fixture.profiles.savedModes == [.mesh])
    #expect(await fixture.secrets.authorizationCount == 1)
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(fixture.domainSnapshot.domain.observedProfiles.allSatisfy { $0.status != .connected })
}

@Test @MainActor func macControllerAlreadySelectedAndAppliedModeIsIdempotent() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.cache.selectMode(.mesh, accountId: "user-a")
    await fixture.profiles.setProfiles([.init(identifier: fixture.config.identifier, reference: try fixture.config.reference, status: .connected, mode: .mesh)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .alreadyActive(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(await fixture.secrets.authorizationCount == 0)
}

@Test @MainActor func macControllerModeStopTimeoutPreservesActiveEvidenceAndRequestedPreference() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    await fixture.profiles.setStopError(.stopTimedOut)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.stopTimedOut))
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(fixture.domainSnapshot.domain.observedProfiles.first?.mode == .full)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.secrets.authorizationCount == 0)
}

@Test @MainActor func macControllerModeStartFailureNeverFallsBackOrClaimsActiveMode() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    await fixture.profiles.setStartError(.unavailable)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .failed(.configUnavailable))
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(await fixture.profiles.savedModes.allSatisfy { $0 == .mesh })
    #expect(fixture.domainSnapshot.domain.observedProfiles.allSatisfy { $0.status == .disconnected })
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
}

@Test @MainActor func macControllerModeCannotRestartAnotherAccountsTunnel() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([.init(identifier: "other/region/client", reference: try fixture.config.reference, status: .connected, mode: .mesh)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .failed(.configUnavailable))
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.stoppedIdentifiers.isEmpty)
    #expect(fixture.domainSnapshot.domain.selectedMode == .full)
    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    outcome = nil
    #expect(!fixture.controller.setMode(.full) { outcome = $0 })
    #expect(outcome == .failed(.signInRequired))
}

@Test @MainActor func macControllerOfflineAndManagedReconnectUseAccountMode() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.cache.selectMode(.mesh, accountId: "user-a")
    fixture.inventory.accessError = CloudGatewayMacInventoryError.offline
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier, displacingOtherProfiles: false) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.savedModes == [.mesh])
    #expect(await fixture.secrets.installCount == 0)
    #expect(try await fixture.cache.load(accountId: "user-a").selectedMode == .mesh)
}

@Test @MainActor func macControllerUnknownModeCanStopAfterSignOut() async throws {
    let fixture = try MacControllerFixture()
    await fixture.profiles.setProfiles([.init(identifier: fixture.config.identifier, reference: try fixture.config.reference, status: .connected, mode: nil)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    try await controllerWaitUntil { fixture.domainSnapshot.domain.observedProfiles.first?.status == .connected }
    #expect(fixture.domainSnapshot.domain.observedProfiles.first?.mode == nil)
    #expect(fixture.controller.signOut())
    try await controllerWaitUntil { !fixture.controller.hasPendingWork }
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.turnOff { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .completed(warning: nil))
    #expect(await fixture.profiles.stoppedIdentifiers == [fixture.config.identifier])
}

@Test @MainActor func macControllerModeSwitchCancelledBySignOutNeverRestarts() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let stop = MacControllerGate()
    await fixture.profiles.pauseStop(stop)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { await stop.entered }
    #expect(fixture.controller.signOut())
    await stop.release()
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(fixture.domainSnapshot.domain.selectedMode == nil)
    #expect(await fixture.profiles.startedIdentifiers.isEmpty)
    #expect(await fixture.profiles.savedIdentifiers.isEmpty)
    #expect(await fixture.secrets.authorizationCount == 0)
}

@Test @MainActor func macControllerSecretRecoveryPreservesMeshModeAndCanonicalHash() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    try await fixture.cache.selectMode(.mesh, accountId: "user-a")
    await fixture.profiles.setProfiles([try fixture.profile(status: .disconnected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    await fixture.secrets.setAvailable(false)
    await fixture.secrets.setInstallReference(try .init(value: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.connectClient(identifier: fixture.config.identifier) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.savedModes == [.mesh])
    #expect(await fixture.secrets.installedHashes == [fixture.config.snapshot.configHash])
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(try await fixture.cache.load(accountId: "user-a").selectedMode == .mesh)
}

@Test @MainActor func macControllerModeRecoveryUsesNewSecretReferenceForNextSwitchWithoutRefresh() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let recoveredReference = try CloudGatewayMacSecretReference(value: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    await fixture.secrets.setAvailable(false)
    await fixture.secrets.setInstallReference(recoveredReference)
    let fetches = fixture.inventory.fetchCount
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(try await fixture.cache.load(accountId: "user-a").configs.first?.reference == recoveredReference)
    await fixture.profiles.setProfiles([
        .init(identifier: fixture.config.identifier, reference: recoveredReference, status: .connected, mode: .mesh)
    ])
    outcome = nil
    #expect(fixture.controller.setMode(.full) { outcome = $0 })
    try await controllerWaitUntil { outcome != nil && !fixture.controller.hasPendingWork }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: nil))
    #expect(await fixture.profiles.savedModes == [.mesh, .full])
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier, fixture.config.identifier])
    #expect(await fixture.secrets.installCount == 1)
    #expect(fixture.inventory.fetchCount == fetches)
    #expect(fixture.domainSnapshot.domain.selectedMode == .full)
}

@Test @MainActor func macControllerModeMetadataReloadFailurePreservesAcceptedStartWithWarning() async throws {
    let fixture = try MacControllerFixture()
    try await fixture.seedCache()
    await fixture.profiles.setProfiles([try fixture.profile(status: .connected)])
    try await fixture.start()
    defer { fixture.controller.shutdown() }
    let start = MacControllerGate()
    await fixture.profiles.pauseStart(start)
    var outcome: CloudGatewayMacCommandOutcome?
    #expect(fixture.controller.setMode(.mesh) { outcome = $0 })
    try await controllerWaitUntil { await start.entered }
    let accountDirectory = try #require(FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil).first)
    try Data("invalid JSON".utf8).write(to: accountDirectory.appendingPathComponent("inventory.json"), options: .atomic)
    await start.release()
    try await controllerWaitUntil { outcome != nil }
    #expect(outcome == .startRequested(identifier: fixture.config.identifier, warning: .selectionNotSaved))
    #expect(await fixture.profiles.startedIdentifiers == [fixture.config.identifier])
    #expect(fixture.domainSnapshot.domain.selectedMode == .mesh)
    #expect(fixture.domainSnapshot.errorMessage == "VPN connection was accepted, but offline metadata could not refresh. Choose Refresh before trying again")
}
