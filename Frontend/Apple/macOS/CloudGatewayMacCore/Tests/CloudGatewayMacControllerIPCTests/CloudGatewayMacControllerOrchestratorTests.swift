import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

let controllerBoundaryBuild = CloudGatewayMacBuildIdentity(version: "1.0", build: "2", codeHash: String(repeating: "a", count: 64))
let controllerBoundaryReplacement = CloudGatewayMacBuildIdentity(version: "1.0", build: "3", codeHash: String(repeating: "b", count: 64))

func controllerBoundaryState(active: Bool = false, setup: CloudGatewayMacSetupState = .ready,
                             canUpdateExtension: Bool = false) -> CloudGatewayMacControllerState {
    let identifier = "account/region/client"
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(accountId: "account", hasRetainedSession: true, accessAuthorized: true,
                      inventoryFreshness: .current, installedIdentifiers: [identifier],
                      observedProfiles: [.init(identifier: identifier, status: active ? .connected : .disconnected)],
                      observationIsFresh: true, commandInFlight: false,
                      clients: [.init(identifier: identifier, regionId: "region", regionName: "Region", regionOrder: 0,
                                      clientName: "Mac", ownerLabel: nil, isEligible: true,
                                      status: active ? .connected : .disconnected)]),
        lastSelectedIdentifier: identifier,
        browserState: .signedIn(AuthenticatedUser(uid: "account", email: nil)),
        isRestoringSession: false, isAuthSettling: false, canCreateClient: true, errorMessage: nil
    )
    return .init(snapshot: snapshot, setupState: setup, canUpdateExtension: canUpdateExtension)
}

@MainActor
func controllerBoundaryEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private final class ControllerOrchestratorEffects {
    enum Failure: Error { case persistence }

    var now = Date(timeIntervalSince1970: 1_000)
    var installed: CloudGatewayMacBuildIdentity? = controllerBoundaryBuild
    var active = false
    var authenticated = true
    var setup = CloudGatewayMacSetupState.required
    var failWrites = false
    var writes = 0
    var data: Data?
    var performed: [CloudGatewayMacControllerRequest.Action] = []
    var completion: ((CloudGatewayMacControllerOperation.State) -> Void)?
    var preparationEvents: AsyncStream<Void>?
    var preparations = 0
    var submissions = 0
    var ignorePreparationCancellation = false
    var releasePreparation: CheckedContinuation<Void, Never>?
    var storedUpdates = CloudGatewayMacExtensionUpdateOrchestrator.StoredState()

    func makeRequests() throws -> CloudGatewayMacControllerRequests {
        try .init(data: data, now: { self.now }) { data in
            self.writes += 1
            if self.failWrites { throw Failure.persistence }
            self.data = data
        }
    }

    func make(requests: CloudGatewayMacControllerRequests? = nil) throws -> CloudGatewayMacControllerOrchestrator {
        let updates = try CloudGatewayMacExtensionUpdateOrchestrator(
            stored: storedUpdates, now: { self.now }, bootSession: { "boot" }, persist: { self.storedUpdates = $0 }
        )
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { setup, canUpdate in controllerBoundaryState(active: self.active, setup: setup, canUpdateExtension: canUpdate) },
            hasPendingWork: { false },
            perform: { request, completion in
                self.performed.append(request.action)
                self.completion = completion
                return true
            },
            prepareClient: {
                self.preparations += 1
                if self.ignorePreparationCancellation {
                    await withCheckedContinuation { self.releasePreparation = $0 }
                } else if let events = self.preparationEvents { for await _ in events { } }
                try Task.checkCancellation()
                return .init(regions: []) { _, _, completion in
                    self.submissions += 1
                    completion(.completed)
                    return true
                }
            },
            setSetupState: { self.setup = $0 }, hasAnyActiveTunnel: { self.active },
            installedIdentity: { self.installed }, extensionIdentity: { controllerBoundaryBuild },
            ping: { identity in
                guard self.authenticated else { throw CloudGatewayMacControllerFailure.unavailable }
                return CloudGatewayMacExtensionVersion(infoDictionary: [
                    "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version,
                ], codeHash: identity.codeHash)
            }, now: { self.now }
        )
        return try .init(identity: controllerBoundaryBuild, effects: effects,
                         requests: requests ?? makeRequests(), extensionUpdates: updates)
    }

    func ready(_ controller: CloudGatewayMacControllerOrchestrator) async throws {
        setup = .required
        await controller.tick()
        try #require(await controllerBoundaryEventually { self.setup == .ready })
    }
}

private func controllerBoundaryRequest(_ action: CloudGatewayMacControllerRequest.Action,
                                       id: UUID = UUID(), contextId: UUID? = nil,
                                       build: CloudGatewayMacBuildIdentity = controllerBoundaryBuild) -> CloudGatewayMacControllerRequest {
    .init(action: action, id: id, identifier: action == .connect ? "account/region/client" : nil,
          contextId: contextId, appVersion: build.version, appBuild: build.build, buildIdentity: build)
}

@MainActor
@Test func controllerOrchestratorConnectWaitsForConfirmationAndNeverReplaysIt() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    #expect(effects.performed.isEmpty)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    let confirm = controllerBoundaryRequest(.confirmOperation, contextId: connect.id)
    #expect(await controller.handle(confirm).operation?.state == .running)
    #expect(effects.performed == [.connect])
    #expect(await controller.handle(confirm).operation?.state == .running)
    effects.completion?(.completed)
    #expect(await controller.handle(confirm).operation?.state == .completed)
    #expect(await controller.handle(connect).operation?.state == .completed)
    #expect(effects.performed == [.connect])
}

@MainActor
@Test(arguments: [false, true])
func controllerOrchestratorReconstructionDoesNotReplayUnfinishedConnect(running: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    let original = try effects.make()
    try await effects.ready(original)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await original.handle(connect).operation?.state == .accepted)
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: connect.id)
    if running { #expect(await original.handle(confirmation).operation?.state == .running) }
    let performed = effects.performed
    let restored = try effects.make()
    try await effects.ready(restored)
    #expect(await restored.handle(connect).operation?.state == .unknown)
    #expect(await restored.handle(confirmation).operation?.state == .unknown)
    #expect(effects.performed == performed)
    effects.completion?(.completed)
}

@MainActor
@Test func controllerOrchestratorStopRemainsAvailableWhileDrainingWithFullReceiptsAndBrokenStorage() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.active = true
    let requests = try effects.makeRequests()
    for _ in 0..<64 {
        let operation = try requests.accept(controllerBoundaryRequest(.signIn))
        requests.finish(id: operation.id, state: .completed)
    }
    let controller = try effects.make(requests: requests)
    try await effects.ready(controller)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    effects.failWrites = true
    let writes = effects.writes
    let status = await controller.handle(controllerBoundaryRequest(.status, build: controllerBoundaryReplacement))
    #expect(status.status == .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true))
    #expect(status.state == nil)
    #expect(await controller.handle(controllerBoundaryRequest(.connect)).error == .busy)
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    let stop = controllerBoundaryRequest(.turnOff, build: controllerBoundaryReplacement)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    #expect(effects.performed.isEmpty)
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: stop.id, build: controllerBoundaryReplacement)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    #expect(effects.performed == [.turnOff])
    effects.completion?(.completed)
    #expect(await controller.handle(confirmation).operation?.state == .completed)
    #expect(effects.performed == [.turnOff])
    #expect(effects.writes == writes)
    #expect(controller.canExit)
}

@MainActor
@Test func controllerOrchestratorAdmissionWriteFailureLeavesMutationSlotAvailable() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    effects.failWrites = true
    #expect(await controller.handle(connect).error == .unavailable)
    #expect(effects.performed.isEmpty)
    effects.failWrites = false
    #expect(await controller.handle(connect).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: connect.id)).operation?.state == .running)
    #expect(effects.performed == [.connect])
    effects.completion?(.completed)
}

@MainActor
@Test func controllerOrchestratorRunningWriteFailurePreventsConnectEffects() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    effects.failWrites = true
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: connect.id)
    #expect(await controller.handle(confirmation).operation?.state == .unknown)
    #expect(await controller.handle(confirmation).operation?.state == .unknown)
    #expect(effects.performed.isEmpty)
    let stop = controllerBoundaryRequest(.turnOff)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id)).operation?.state == .running)
    #expect(effects.performed == [.turnOff])
    effects.completion?(.completed)
}

@MainActor
@Test func controllerOrchestratorUnconfirmedConnectExpiresAndCannotRunAfterReplacement() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    effects.now.addTimeInterval(30)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: connect.id)).operation?.state == .unknown)
    #expect(effects.performed.isEmpty)
    let next = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(next).operation?.state == .accepted)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    let rejected = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: next.id))
    #expect(rejected.operation?.state == .failed)
    #expect(rejected.operation?.failure == .incompatibleVersion)
    #expect(effects.performed.isEmpty)
    #expect(controller.canExit)
}

@MainActor
@Test func controllerOrchestratorPreparationCancellationReleasesRequestAndCreationHandoff() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let events = AsyncStream<Void>.makeStream()
    effects.preparationEvents = events.stream
    let preparation = Task { await controller.handle(controllerBoundaryRequest(.prepareClient)) }
    try #require(await controllerBoundaryEventually { effects.preparations == 1 })
    effects.now.addTimeInterval(60)
    #expect(!controller.canExit)
    preparation.cancel()
    let cancelled = await preparation.value
    #expect(cancelled.error == .preparationExpired)
    #expect(cancelled.creation == nil)
    effects.preparationEvents = nil
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareClient))
    let creation = try #require(prepared.creation)
    #expect(effects.preparations == 2)
    let request = CloudGatewayMacControllerRequest(action: .createClient, regionId: "region", clientName: "Mac",
                                                   contextId: creation.id, buildIdentity: controllerBoundaryBuild)
    #expect(await controller.handle(request).operation?.state == .accepted)
    #expect(effects.submissions == 0)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id)).operation?.state == .completed)
    #expect(effects.submissions == 1)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    #expect(controller.canExit)
    events.continuation.finish()
}

@MainActor
@Test func controllerOrchestratorDrainingCancelsPreparationAndAllowsExit() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let events = AsyncStream<Void>.makeStream()
    effects.preparationEvents = events.stream
    let preparation = Task { await controller.handle(controllerBoundaryRequest(.prepareClient)) }
    try #require(await controllerBoundaryEventually { effects.preparations == 1 })
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    let cancelled = await preparation.value
    #expect(cancelled.error == .preparationExpired)
    #expect(cancelled.creation == nil)
    #expect(controller.canExit)
    #expect(effects.submissions == 0)
    events.continuation.finish()
}

@MainActor
@Test func controllerOrchestratorDispatchPreservesRestartAcrossLateExtensionCallbacks() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.authenticated = false
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(prepared.operationId)
    #expect(prepared.extensionTarget == controllerBoundaryBuild)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateStarted, contextId: id)).accepted == true)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateRestart, contextId: id)).accepted == true)
    for action in [CloudGatewayMacControllerRequest.Action.extensionUpdateFinished, .extensionUpdateFailed, .extensionUpdateApproval] {
        #expect(await controller.handle(controllerBoundaryRequest(action, contextId: id)).accepted == true)
        #expect(effects.setup == .awaitingRestart)
    }
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerOrchestratorCancelsWaitingEvenWhenPreparationEffectIgnoresCancellation() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.ignorePreparationCancellation = true
    var reply: CloudGatewayMacControllerReply?
    let pending = Task { reply = await controller.handle(controllerBoundaryRequest(.prepareClient)) }
    try #require(await controllerBoundaryEventually { effects.releasePreparation != nil })
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    let released = await controllerBoundaryEventually { reply != nil }
    let canExit = controller.canExit
    effects.releasePreparation?.resume()
    effects.releasePreparation = nil
    await pending.value
    #expect(released)
    #expect(canExit)
    #expect(reply?.error == .preparationExpired)
}

@MainActor
@Test func controllerOrchestratorRestoresSubmittedUpdateThroughAuthenticatedReadiness() async throws {
    let effects = ControllerOrchestratorEffects()
    let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(id: UUID(), target: controllerBoundaryBuild, bootSession: "boot")
    effects.storedUpdates = .init(state: .submitted(attempt, deadline: effects.now.addingTimeInterval(120)))
    let controller = try effects.make()
    #expect(effects.storedUpdates.state == .outcomeUnknown(attempt))
    try await effects.ready(controller)
    #expect(effects.setup == .ready)
    #expect(effects.storedUpdates.receipts.contains { $0.id == attempt.id && $0.outcome == .ready })
}

@MainActor
@Test func controllerOrchestratorReadinessWinsBeforeDelayedReportAndReconstruction() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.authenticated = false
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(prepared.operationId)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateStarted, contextId: id)).accepted == true)
    effects.authenticated = true
    try #require(await controllerBoundaryEventually { effects.setup == .ready })
    #expect(effects.storedUpdates.receipts.contains { $0.id == id && $0.outcome == .ready })
    let finished = controllerBoundaryRequest(.extensionUpdateFinished, contextId: id)
    #expect(await controller.handle(finished).accepted == true)
    let restored = try effects.make()
    try await effects.ready(restored)
    #expect(await restored.handle(finished).accepted == true)
    #expect(await restored.handle(finished).accepted == true)
    #expect(effects.performed.isEmpty)
}
