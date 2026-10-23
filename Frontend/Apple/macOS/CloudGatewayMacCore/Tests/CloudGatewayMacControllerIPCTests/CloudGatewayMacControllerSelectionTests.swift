import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

@MainActor
@Test(arguments: [CloudGatewayMacClientEligibility.eligible, .inactive, .configMissing, .regionUnavailable])
func controllerScopedStopReservesAnAuthorizedTargetRegardlessOfEligibility(eligibility: CloudGatewayMacClientEligibility) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    effects.snapshotState = selectionState(eligibility: eligibility)
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.disconnectClient)
    #expect(await controller.handle(request).operation?.state == .accepted)
    #expect(effects.performed.isEmpty)
    var targets: [String?] = []
    effects.performHandler = { request, complete in
        targets.append(request.identifier)
        complete(.completed(warning: nil))
        return true
    }
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: request.id)
    #expect(await controller.handle(confirmation).operation?.state == .completed)
    #expect(targets == ["account/region/client"])
    #expect(await controller.handle(confirmation).operation?.state == .completed)
    #expect(effects.performed == [.disconnectClient])
    effects.sessions.changeAccount(to: nil)
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id)).outcome == nil)
}

@MainActor
@Test(arguments: [false, true])
func controllerScopedStopRejectsUnknownOrAmbiguousTargetsBeforeAcceptance(duplicate: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    effects.snapshotState = selectionState(clientCount: duplicate ? 2 : 0)
    let controller = try effects.make()
    try await effects.ready(controller)
    let reply = await controller.handle(controllerBoundaryRequest(.disconnectClient))
    #expect(reply.error == .rejected)
    #expect(reply.operation == nil)
    #expect(effects.writes == 0)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func controllerScopedStopRejectsAccountAndInventoryChangesBeforeConfirmation(changeAccount: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.disconnectClient)
    #expect(await controller.handle(request).operation?.state == .accepted)
    if changeAccount { effects.sessions.changeAccount(to: "other") }
    else { effects.snapshotState = selectionState(clientCount: 0) }
    let reply = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    #expect(reply.operation?.state == .failed)
    #expect(reply.operation?.failure == .rejected)
    #expect(reply.outcome == (changeAccount ? nil : .failed(.configUnavailable)))
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerExpiredScopedStopStaysBoundToItsReservingSession() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.disconnectClient)
    #expect(await controller.handle(request).operation?.state == .accepted)
    effects.sessions.changeAccount(to: "other")
    effects.now.addTimeInterval(30)
    let reply = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(reply.operation?.id == request.id)
    #expect(reply.operation?.state == .unknown)
    #expect(reply.outcome == nil)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerScopedStopRequiresASessionAndDoesNotBypassUpdateDrain() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    #expect(await controller.handle(controllerBoundaryRequest(.disconnectClient)).error == .rejected)
    effects.sessions.changeAccount(to: "account")
    let request = controllerBoundaryRequest(.disconnectClient)
    #expect(await controller.handle(request).operation?.state == .accepted)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id)).operation?.failure == .incompatibleVersion)
    #expect(await controller.handle(controllerBoundaryRequest(.disconnectClient)).error == .busy)
    let bareStop = controllerBoundaryRequest(.turnOff, build: controllerBoundaryReplacement)
    #expect(await controller.handle(bareStop).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: bareStop.id, build: controllerBoundaryReplacement)).operation?.state == .running)
    #expect(effects.performed == [.turnOff])
}

@MainActor
@Test(arguments: [false, true])
func controllerOperationLookupKeepsTheSnapshotObservationAndRequestedOperation(fresh: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    effects.snapshotState = selectionState(activeIdentifier: "account/region/other", fresh: fresh)
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.connect)
    _ = await controller.handle(request)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    effects.completion?(.startRequested(identifier: "account/region/client", warning: nil))
    let ordinary = try #require(await controller.handle(controllerBoundaryRequest(.snapshot)).state)
    for id in [request.id, UUID()] {
        let reply = await controller.handle(controllerBoundaryRequest(.operation, contextId: id))
        #expect(reply.state == ordinary)
        #expect(reply.status == ordinary.status)
        #expect(reply.state?.profilesObservedAt == Date(timeIntervalSince1970: 123))
        #expect(reply.state?.observedProfiles.first?.identifier == "account/region/other")
        #expect(reply.state?.observationAvailable == fresh)
        #expect(reply.operation?.id == id)
        #expect(reply.operation?.state == (id == request.id ? .completed : .unknown))
        #expect(reply.outcome == (id == request.id ? .startRequested(identifier: "account/region/client", warning: nil) : nil))
    }
    let differentBuild = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id, build: controllerBoundaryReplacement))
    #expect(differentBuild.state == nil)
    #expect(differentBuild.outcome == nil)
    #expect(differentBuild.status == ordinary.status)
    #expect(differentBuild.operation?.id == request.id)
}

@MainActor
@Test(arguments: [nil, "other"] as [String?])
func controllerOperationLookupRedactsProfilesAndOutcomesAcrossAccounts(accountId: String?) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.connect)
    _ = await controller.handle(request)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    effects.completion?(.alreadyActive(identifier: "account/region/client", warning: nil))
    effects.sessions.changeAccount(to: accountId)
    effects.snapshotState = selectionState(accountId: accountId, activeIdentifier: "account/region/client", clientCount: 0)
    let reply = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(reply.state?.accountId == accountId)
    #expect(reply.state?.clients.isEmpty == true)
    #expect(reply.state?.observedProfiles.first?.identifier == nil)
    #expect(reply.state?.profilesObservedAt == Date(timeIntervalSince1970: 123))
    #expect(reply.status?.hasActiveTunnel == true)
    #expect(reply.outcome == nil)
    #expect(reply.operation?.id == request.id)
}

private func selectionState(
    accountId: String? = "account", activeIdentifier: String = "account/region/client", fresh: Bool = true,
    eligibility: CloudGatewayMacClientEligibility = .eligible, clientCount: Int = 1
) -> CloudGatewayMacControllerState {
    let identifier = "account/region/client"
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(
            accountId: accountId, hasRetainedSession: accountId != nil, accessAuthorized: accountId != nil,
            access: accountId == nil ? .unverified : .online, credentials: .available,
            inventoryFreshness: .current, installedIdentifiers: accountId == "account" ? [identifier] : [],
            observedProfiles: [.init(identifier: activeIdentifier, status: .connected)],
            observationIsFresh: fresh, profilesObservedAt: Date(timeIntervalSince1970: 123), commandInFlight: false,
            clients: Array(repeating: .init(
                identifier: identifier, regionId: "region", regionName: "Region", regionOrder: 0,
                clientName: "Mac", ownerLabel: nil, internalIp: nil, cloudState: .active, eligibility: eligibility,
                isInstalled: true, source: .cloud, readAt: Date(timeIntervalSince1970: 0), updatedAt: nil, status: .connected
            ), count: clientCount)
        ), lastSelectedIdentifier: accountId == "account" ? identifier : nil,
        browserState: accountId.map { .signedIn(.init(uid: $0, email: nil)) } ?? .signedOut,
        isRestoringSession: false, isAuthSettling: false, canCreateClient: false, errorMessage: nil
    )
    return .init(snapshot: snapshot, setupState: .ready, canUpdateExtension: false)
}
