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
                             canUpdateExtension: Bool = false, authSettling: Bool = false) -> CloudGatewayMacControllerState {
    let identifier = "account/region/client"
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(accountId: "account", hasRetainedSession: true, accessAuthorized: true,
                      access: .online, credentials: .available,
                      inventoryFreshness: .current, installedIdentifiers: [identifier],
                      observedProfiles: [.init(identifier: identifier, status: active ? .connected : .disconnected)],
                      observationIsFresh: true, profilesObservedAt: nil, commandInFlight: false,
                      clients: [.init(identifier: identifier, regionId: "region", regionName: "Region", regionOrder: 0,
                                      clientName: "Mac", ownerLabel: nil, internalIp: nil, cloudState: .active,
                                      eligibility: .eligible, isInstalled: true, source: .cloud,
                                      readAt: Date(timeIntervalSince1970: 0), updatedAt: nil,
                                      status: active ? .connected : .disconnected)]),
        lastSelectedIdentifier: identifier,
        browserState: .signedIn(AuthenticatedUser(uid: "account", email: nil)),
        isRestoringSession: false, isAuthSettling: authSettling, canCreateClient: true, errorMessage: nil
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
final class ControllerOrchestratorEffects {
    enum Failure: Error { case persistence }

    var now = Date(timeIntervalSince1970: 1_000)
    var installed: CloudGatewayMacBuildIdentity? = controllerBoundaryBuild
    var extensionTarget = controllerBoundaryBuild
    var failExtensionWrites = false
    var active = false
    var snapshotState: CloudGatewayMacControllerState?
    var authenticated = true
    var setup = CloudGatewayMacSetupState.required
    var failWrites = false
    var writes = 0
    var data: Data?
    var performed: [CloudGatewayMacControllerRequest.Action] = []
    var performedRequests: [CloudGatewayMacControllerRequest] = []
    var completion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)?
    var performHandler: ((CloudGatewayMacControllerRequest, @MainActor (CloudGatewayMacCommandOutcome) -> Void) -> Bool)?
    var sessions = CloudGatewayMacSessionFence()
    var refreshResult = CloudGatewayMacRefreshResult.refreshed
    var refreshTimeout = Duration.seconds(25)
    var refreshes = 0
    var holdRefresh: CheckedContinuation<Void, Never>?
    var holdsRefresh = false
    var preparationEvents: AsyncStream<Void>?
    var preparations = 0
    var submissions = 0
    var ignorePreparationCancellation = false
    var releasePreparation: CheckedContinuation<Void, Never>?
    var storedUpdates = CloudGatewayMacExtensionUpdateOrchestrator.StoredState()
    var holdsPing = false
    var releasePing: CheckedContinuation<Void, Never>?
    var hasPendingWork = false
    var activity: [Bool] = []
    var automaticRefreshes = 0
    var pings = 0
    var inventoryAdmission = false
    var discardsDeferredInventory = false
    var registration = CloudGatewayMacSetupState.required
    var managedData: Data?
    var revocationData: Data?
    var failManagedWrites = false
    var failRevocationWrites = false
    var observationAccountId: String? = "account"
    var authorizedIdentifiers = ["account/region/client"]
    var runtimeInitialized = true
    var runtimeInitializations = 0
    var activationIds: [UUID] = []
    var activationTargets: [CloudGatewayMacBuildIdentity] = []
    var activationPending = false
    var activationEvent: (@MainActor (CloudGatewayMacExtensionActivationEvent) -> Void)?
    var reconnects: [String] = []
    var reconnectCompletion: (@MainActor (CloudGatewayMacCommandOutcome) -> Void)?

    var managedJournal: CloudGatewayMacManagedUpdateWorkflow.Journal? {
        managedData.flatMap { try? JSONDecoder().decode(CloudGatewayMacManagedUpdateWorkflow.Journal.self, from: $0) }
    }

    func makeRequests() throws -> CloudGatewayMacControllerRequests {
        try .init(data: data, now: { self.now }) { data in
            self.writes += 1
            if self.failWrites { throw Failure.persistence }
            self.data = data
        }
    }

    func make(requests: CloudGatewayMacControllerRequests? = nil,
              managed: Bool = false,
              identity: CloudGatewayMacBuildIdentity = controllerBoundaryBuild) throws -> CloudGatewayMacControllerOrchestrator {
        let updates = try CloudGatewayMacExtensionUpdateOrchestrator(
            stored: storedUpdates, now: { self.now }, bootSession: { "boot" }, persist: {
                if self.failExtensionWrites { throw Failure.persistence }
                self.storedUpdates = $0
            }
        )
        let workflow = managed ? CloudGatewayMacManagedUpdateWorkflow(load: { self.managedData }, persist: {
            if self.failManagedWrites { throw Failure.persistence }
            self.managedData = $0
        }, loadRevocation: { self.revocationData }, persistRevocation: {
            if self.failRevocationWrites { throw Failure.persistence }
            self.revocationData = $0
        }) : nil
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { setup, canUpdate in
                self.snapshotState ?? controllerBoundaryState(active: self.active, setup: setup, canUpdateExtension: canUpdate)
            },
            hasPendingWork: { self.hasPendingWork },
            perform: { request, completion in
                self.performed.append(request.action)
                self.performedRequests.append(request)
                self.completion = completion
                return self.performHandler?(request, completion) ?? true
            },
            session: { self.sessions.currentToken },
            refresh: {
                self.refreshes += 1
                if self.holdsRefresh { await withCheckedContinuation { self.holdRefresh = $0 } }
                return self.refreshResult
            },
            refreshTimeout: refreshTimeout,
            prepareClient: {
                self.preparations += 1
                if self.ignorePreparationCancellation {
                    await withCheckedContinuation { self.releasePreparation = $0 }
                } else if let events = self.preparationEvents { for await _ in events { } }
                try Task.checkCancellation()
                return .init(regions: []) { _, _, completion in
                    self.submissions += 1
                    completion(.completed(warning: nil))
                    return true
                }
            },
            setSetupState: { self.setup = $0 }, hasAnyActiveTunnel: { self.active },
            installedIdentity: { self.installed }, extensionIdentity: { self.extensionTarget },
            ping: { identity in
                self.pings += 1
                if self.holdsPing { await withCheckedContinuation { self.releasePing = $0 } }
                guard self.authenticated else { throw CloudGatewayMacControllerFailure.unavailable }
                return CloudGatewayMacExtensionVersion(infoDictionary: [
                    "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version,
                ], codeHash: identity.codeHash)
            }, registrationReadiness: { self.registration },
            initializeRuntime: {
                if !self.runtimeInitialized { self.runtimeInitializations += 1; self.runtimeInitialized = true }
            },
            isRuntimeInitialized: { self.runtimeInitialized },
            diagnostics: { .init(runtimeInitialized: self.runtimeInitialized,
                                 extensionState: self.authenticated ? .ready : .enabled) },
            userActivity: { self.activity.append($0) },
            refreshInventoryIfDue: { self.automaticRefreshes += 1 },
            setAutomaticInventoryRefreshAllowed: { self.inventoryAdmission = $0; self.discardsDeferredInventory = $1 },
            monotonicNow: { .seconds(self.now.timeIntervalSince1970) }, now: { self.now },
            managedUpdateObservation: {
                .init(accountId: self.observationAccountId,
                      profiles: [.init(identifier: "account/region/client", status: self.active ? .connected : .disconnected)],
                      authorizedIdentifiers: self.authorizedIdentifiers)
            },
            reconnectClient: { identifier, complete in
                self.reconnects.append(identifier)
                self.reconnectCompletion = complete
                return true
            },
            activateExtension: { id, target, event in
                self.activationIds.append(id)
                self.activationTargets.append(target)
                self.activationPending = true
                self.activationEvent = event
                return true
            },
            activationIsPending: { self.activationPending }
        )
        return try .init(identity: identity, effects: effects,
                         requests: requests ?? makeRequests(), extensionUpdates: updates, managedUpdates: workflow)
    }

    func makeManaged(active: Bool = false,
                     identity: CloudGatewayMacBuildIdentity = controllerBoundaryBuild) throws -> CloudGatewayMacControllerOrchestrator {
        self.active = active
        authenticated = false
        registration = .updateRequired
        sessions.changeAccount(to: "account")
        return try make(managed: true, identity: identity)
    }

    func sendActivation(_ event: CloudGatewayMacExtensionActivationEvent) {
        switch event {
        case .approvalRequired: break
        case .completed, .restartRequired, .failed: activationPending = false
        }
        activationEvent?(event)
    }

    func ready(_ controller: CloudGatewayMacControllerOrchestrator) async throws {
        setup = .required
        await controller.tick()
        try #require(await controllerBoundaryEventually { self.setup == .ready })
    }
}

func controllerBoundaryRequest(_ action: CloudGatewayMacControllerRequest.Action,
                                       id: UUID = UUID(), contextId: UUID? = nil,
                                       build: CloudGatewayMacBuildIdentity = controllerBoundaryBuild,
                                       allowDisconnect: Bool? = nil) -> CloudGatewayMacControllerRequest {
    .init(action: action, id: id, identifier: action == .connect || action == .disconnectClient ? "account/region/client" : nil,
          contextId: contextId, allowDisconnect: allowDisconnect,
          appVersion: build.version, appBuild: build.build, buildIdentity: build)
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
    effects.completion?(.completed(warning: nil))
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
    effects.completion?(.completed(warning: nil))
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
    effects.completion?(.completed(warning: nil))
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
    effects.completion?(.completed(warning: nil))
}

@MainActor
@Test func controllerOrchestratorConfirmedConnectKeepsKnownOutcomeWithoutMoreReceiptWrites() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    effects.failWrites = true
    let writes = effects.writes
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: connect.id)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    #expect(effects.performed == [.connect])
    effects.completion?(.completed(warning: nil))
    #expect(await controller.handle(confirmation).operation?.state == .completed)
    #expect(await controller.handle(connect).operation?.state == .completed)
    #expect(effects.performed == [.connect])
    #expect(effects.writes == writes)
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
@Test func controllerOrchestratorMatchingExtensionWaitsForTheActivationCallback() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.authenticated = false
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(prepared.operationId)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateStarted, contextId: id)).accepted == true)
    effects.authenticated = true
    await controller.tick()
    #expect(effects.setup == .activating)
    #expect(effects.storedUpdates.receipts.isEmpty)
    let finished = controllerBoundaryRequest(.extensionUpdateFinished, contextId: id)
    #expect(await controller.handle(finished).accepted == true)
    try #require(await controllerBoundaryEventually { effects.setup == .ready })
    #expect(effects.storedUpdates.receipts.contains { $0.id == id && $0.outcome == .activationFinished })
    let restored = try effects.make()
    try await effects.ready(restored)
    #expect(await restored.handle(finished).accepted == true)
    #expect(await restored.handle(finished).accepted == true)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerOrchestratorLiveActivationCannotHideALateRebootCallback() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(prepared.operationId)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateStarted, contextId: id)).accepted == true)
    for elapsed in [0.0, 120.0] {
        effects.now.addTimeInterval(elapsed)
        await controller.tick()
        #expect(effects.setup != .ready)
        #expect(effects.storedUpdates.state.attempt?.id == id)
        #expect(effects.storedUpdates.receipts.isEmpty)
    }
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateRestart, contextId: id)).accepted == true)
    #expect(effects.setup == .awaitingRestart)
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerOrchestratorDoesNotOfferExtensionPreparationDuringReadiness() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.holdsPing = true
    effects.setup = .checkingConnection
    effects.now.addTimeInterval(60)
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.releasePing != nil })
    #expect(await controller.handle(controllerBoundaryRequest(.snapshot)).state?.canUpdateExtension == false)
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    effects.holdsPing = false
    effects.releasePing?.resume()
    effects.releasePing = nil
    try #require(await controllerBoundaryEventually { effects.setup == .ready })
    #expect(await controller.handle(controllerBoundaryRequest(.snapshot)).state?.canUpdateExtension == true)
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).accepted == true)
}

@MainActor
@Test func controllerOrchestratorIdleTickAllowsExitBeforeSchedulingAnotherProbe() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.now.addTimeInterval(900)
    await controller.tick()
    #expect(controller.canExit)
    #expect(effects.setup == .ready)
}

@MainActor
@Test func controllerOrchestratorPassivePollsAndAnActiveVPNDoNotExtendIdle() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.active = true
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.now.addTimeInterval(899)
    for action in [CloudGatewayMacControllerRequest.Action.lifecycle, .diagnostics, .snapshot,
                   .status, .operation, .loginStatus, .confirmOperation] {
        _ = await controller.handle(controllerBoundaryRequest(action, contextId: UUID()))
    }
    #expect(!controller.canExit)
    #expect(effects.activity.isEmpty)
    effects.now.addTimeInterval(1)
    await controller.tick()
    #expect(controller.canExit)
}

@MainActor
@Test(arguments: [CloudGatewayMacControllerRequest.Action.userActivity, .recordActivity, .menuWillOpen, .awaitRefresh, .beginLogin])
func controllerOrchestratorRealActionsRenewIdle(action: CloudGatewayMacControllerRequest.Action) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.now.addTimeInterval(899)
    _ = await controller.handle(controllerBoundaryRequest(action))
    #expect(effects.activity == [action == .userActivity])
    try #require(await controllerBoundaryEventually { effects.setup == .ready })
    effects.now.addTimeInterval(899)
    #expect(!controller.canExit)
    effects.now.addTimeInterval(1)
    #expect(await controllerBoundaryEventually { controller.canExit })
}

@MainActor
@Test func controllerOrchestratorRecordsActivityWithoutRequestingAStaleRefresh() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let refreshes = effects.automaticRefreshes
    let reply = await controller.handle(controllerBoundaryRequest(.recordActivity))
    #expect(reply.error == nil)
    #expect(reply.state != nil)
    #expect(effects.activity == [false])
    #expect(effects.automaticRefreshes == refreshes)
    #expect(effects.refreshes == 0)
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func controllerOrchestratorPendingWorkDoesNotCreateAnotherIdleWindow() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.hasPendingWork = true
    effects.setup = .checkingConnection
    effects.now.addTimeInterval(900)
    await controller.tick()
    #expect(!controller.canExit)
    try #require(await controllerBoundaryEventually { effects.pings == 2 && effects.setup == .ready })
    effects.hasPendingWork = false
    #expect(controller.canExit)
    #expect(effects.activity.isEmpty)
}

@MainActor
@Test func controllerOrchestratorRetainsLateCommandResultsForRecoveryWithoutRenewingActivity() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(.connect)
    _ = await controller.handle(request)
    #expect(!effects.inventoryAdmission)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    effects.now.addTimeInterval(900)
    #expect(!controller.canExit)
    effects.completion?(.completed(warning: nil))
    #expect(effects.inventoryAdmission)
    effects.now.addTimeInterval(599)
    #expect(!controller.canExit)
    _ = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    effects.now.addTimeInterval(1)
    #expect(controller.canExit)
    #expect(effects.activity == [false])
}

@MainActor
@Test func controllerOrchestratorActiveRefreshRequestHoldsExitUntilItsReplyCompletes() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.holdsRefresh = true
    let refresh = Task { await controller.handle(controllerBoundaryRequest(.awaitRefresh)) }
    try #require(await controllerBoundaryEventually { effects.holdRefresh != nil })
    effects.now.addTimeInterval(900)
    #expect(!controller.canExit)
    effects.holdRefresh?.resume()
    effects.holdRefresh = nil
    #expect(await refresh.value.refresh == .refreshed)
    #expect(controller.canExit)
}

@MainActor
@Test func controllerOrchestratorAutomaticInventorySkipsReservationsDrainAndExtensionWork() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let initial = effects.automaticRefreshes
    let request = controllerBoundaryRequest(.connect)
    _ = await controller.handle(request)
    await controller.tick()
    #expect(effects.automaticRefreshes == initial)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    await controller.tick()
    #expect(effects.automaticRefreshes == initial)
    effects.completion?(.completed(warning: nil))
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    #expect(prepared.accepted == true)
    await controller.tick()
    #expect(effects.automaticRefreshes == initial)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    #expect(effects.automaticRefreshes == initial)
    #expect(!effects.inventoryAdmission)
    #expect(effects.discardsDeferredInventory)
    #expect(await controller.handle(controllerBoundaryRequest(.userActivity)).error == .busy)
}

@MainActor
@Test func controllerOrchestratorRoutineReadinessRunsAtMostOnceAMinute() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    #expect(effects.pings == 1)
    for _ in 0..<11 {
        effects.now.addTimeInterval(5)
        await controller.tick()
    }
    #expect(effects.pings == 1)
    effects.now.addTimeInterval(5)
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.pings == 2 })
}

@MainActor
@Test func controllerOrchestratorPreparedUpdateSurvivesHandoffWithoutHoldingOwnership() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let prepared = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(prepared.operationId)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    #expect(controller.canExit)
    #expect(effects.storedUpdates.state.attempt?.id == id)
    effects.now.addTimeInterval(30)
    await controller.tick()
    #expect(controller.canExit)
    let successor = try effects.make()
    #expect(effects.storedUpdates.receipts.contains { $0.id == id && $0.outcome == .expired })
    #expect(!successor.canExit)
}

@MainActor
@Test func controllerOrchestratorSupersededOutcomeIsUnknownWithoutReplayingItsRequest() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let first = controllerBoundaryRequest(.connect)
    let second = controllerBoundaryRequest(.connect)
    for request in [first, second] {
        #expect(await controller.handle(request).operation?.state == .accepted)
        #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id)).operation?.state == .running)
        effects.completion?(.completed(warning: nil))
    }
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: first.id)).operation?.state == .unknown)
    #expect(await controller.handle(first).operation?.state == .unknown)
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: second.id)).operation?.state == .completed)
    #expect(effects.performed == [.connect, .connect])
}

@MainActor
@Test(arguments: [(CloudGatewayMacControllerRequest.Action.connect, CloudGatewayMacControllerFailure.commandFailed),
                  (.signOut, .authCleanupFailed)])
func controllerOrchestratorRetainsSpecificDomainFailureForOperationLookup(
    action: CloudGatewayMacControllerRequest.Action, failure: CloudGatewayMacControllerFailure
) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.active = true
    let controller = try effects.make()
    try await effects.ready(controller)
    let request = controllerBoundaryRequest(action)
    #expect(await controller.handle(request).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id)).operation?.state == .running)
    effects.completion?(.failed(.vpnFailed))
    let result = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(result.operation?.state == .failed)
    #expect(result.operation?.failure == failure)
    #expect(result.status?.hasActiveTunnel == true)
}

@MainActor
@Test func controllerOrchestratorReservationAloneNeverReportsAStartRequest() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    let accepted = await controller.handle(connect)
    #expect(accepted.operation?.state == .accepted)
    #expect(accepted.outcome == nil)
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: connect.id)
    let running = await controller.handle(confirmation)
    #expect(running.operation?.state == .running)
    #expect(running.outcome == nil)
    let started = CloudGatewayMacCommandOutcome.startRequested(identifier: "account/region/client", warning: .selectionNotSaved)
    effects.completion?(started)
    let lookup = await controller.handle(controllerBoundaryRequest(.operation, contextId: connect.id))
    #expect(lookup.operation?.state == .completed)
    #expect(lookup.outcome == started)
    #expect(lookup.status != nil)
    #expect(await controller.handle(controllerBoundaryRequest(.snapshot)).outcome == started)
}

@MainActor
@Test func controllerOrchestratorRedactsAccountOutcomesAfterLogoutButKeepsStopResults() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.active = true
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: connect.id))
    effects.completion?(.alreadyActive(identifier: "account/region/client", warning: nil))
    let lookup = controllerBoundaryRequest(.operation, contextId: connect.id)
    #expect(await controller.handle(lookup).outcome == .alreadyActive(identifier: "account/region/client", warning: nil))
    for account in [nil, "account"] as [String?] {
        effects.sessions.changeAccount(to: account)
        let redacted = await controller.handle(lookup)
        #expect(redacted.outcome == nil)
        #expect(redacted.operation?.state == .completed)
        #expect(redacted.status?.hasActiveTunnel == true)
        #expect(await controller.handle(connect).outcome == nil)
    }

    let stop = controllerBoundaryRequest(.turnOff)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id))
    effects.completion?(.completed(warning: nil))
    effects.sessions.changeAccount(to: nil)
    let stopped = await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id))
    #expect(stopped.operation?.state == .completed)
    #expect(stopped.outcome == .completed(warning: nil))
}

@MainActor
@Test func controllerOrchestratorOmitsTypedOutcomesForOtherBuildControlRequests() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let stop = controllerBoundaryRequest(.turnOff, build: controllerBoundaryReplacement)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id, build: controllerBoundaryReplacement))
    effects.completion?(.failed(.stopTimedOut))
    let other = await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id, build: controllerBoundaryReplacement))
    #expect(other.operation == .init(id: stop.id, state: .unknown))
    #expect(other.outcome == nil)
    #expect(await controller.handle(controllerBoundaryRequest(.status, build: controllerBoundaryReplacement)).outcome == nil)
    #expect(await controller.handle(controllerBoundaryRequest(.status)).outcome == .failed(.stopTimedOut))
}

@MainActor
@Test func controllerOrchestratorTypesExpiredReservationsAndBusyFailures() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    let expired = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(expired).operation?.state == .accepted)
    effects.now.addTimeInterval(30)
    let lookup = await controller.handle(controllerBoundaryRequest(.operation, contextId: expired.id))
    #expect(lookup.operation?.state == .unknown)
    #expect(lookup.outcome == .expired)
    #expect(effects.performed.isEmpty)

    let busy = controllerBoundaryRequest(.signIn)
    #expect(await controller.handle(busy).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: busy.id))
    effects.completion?(.failed(.busy))
    let result = await controller.handle(controllerBoundaryRequest(.operation, contextId: busy.id))
    #expect(result.operation?.failure == .busy)
    #expect(result.outcome == .failed(.busy))

    let next = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(next).operation?.state == .accepted)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    let rejected = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: next.id))
    #expect(rejected.operation?.failure == .incompatibleVersion)
    #expect(rejected.outcome == .failed(.incompatibleVersion))
}

@MainActor
@Test(arguments: [true, false])
func controllerOrchestratorKeepsSignOutOutcomeAfterTheSessionEnds(cleanupSucceeds: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let expected: CloudGatewayMacCommandOutcome = cleanupSucceeds ? .completed(warning: nil) : .failed(.credentialsUnavailable)
    effects.performHandler = { _, complete in
        effects.sessions.changeAccount(to: nil)
        complete(expected)
        return true
    }
    let controller = try effects.make()
    try await effects.ready(controller)
    let signOut = controllerBoundaryRequest(.signOut)
    #expect(await controller.handle(signOut).operation?.state == .accepted)
    let confirmed = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: signOut.id))
    #expect(confirmed.outcome == expected)
    #expect(confirmed.operation?.failure == (cleanupSucceeds ? nil : .authCleanupFailed))
    effects.sessions.changeAccount(to: "other")
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: signOut.id)).outcome == expected)
}

@MainActor
@Test func controllerOrchestratorKeepsRejectedLegacyFailureForRefusedCommands() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    effects.performHandler = { _, complete in
        complete(.failed(.configUnavailable))
        return false
    }
    let controller = try effects.make()
    try await effects.ready(controller)
    let connect = controllerBoundaryRequest(.connect)
    #expect(await controller.handle(connect).operation?.state == .accepted)
    let confirmed = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: connect.id))
    #expect(confirmed.operation == .init(id: connect.id, state: .failed, failure: .rejected))
    #expect(confirmed.outcome == .failed(.configUnavailable))
    let lookup = await controller.handle(controllerBoundaryRequest(.operation, contextId: connect.id))
    #expect(lookup.operation?.failure == .rejected)
    #expect(lookup.outcome == .failed(.configUnavailable))
    #expect(effects.performed == [.connect])
}


@MainActor
@Test(arguments: [false, true])
func controllerManagedUpdateConfirmsBeforeEffectsAndRestoresOnlyTheCapturedConnection(active: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: active)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let request = controllerBoundaryRequest(.update, allowDisconnect: active)
    let prepared = await controller.handle(request)
    #expect(prepared.operation?.state == .accepted)
    #expect(prepared.update?.phase == .prepared)
    #expect(prepared.update?.reconnect == active)
    #expect(effects.managedJournal?.confirmed == false)
    #expect(effects.performed.isEmpty)
    #expect(effects.activationIds.isEmpty)
    #expect(await controller.handle(request).operation?.id == request.id)

    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: request.id)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    if active {
        try #require(await controllerBoundaryEventually { effects.performed == [.disconnectClient] })
        #expect(effects.managedJournal?.confirmed == true)
        #expect(effects.managedJournal?.phase == .stopping)
        #expect(effects.performedRequests.first?.identifier == "account/region/client")
        #expect(effects.activationIds.isEmpty)
        effects.active = false
        effects.completion?(.completed(warning: nil))
    }
    try #require(await controllerBoundaryEventually { effects.activationIds == [request.id] })
    #expect(effects.activationTargets == [controllerBoundaryBuild])
    #expect(effects.reconnects.isEmpty)
    effects.sendActivation(.approvalRequired)
    let approval = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(approval.update?.phase == .approvalRequired)
    #expect(approval.operation?.state == .running)
    #expect(approval.status?.hasActiveTunnel == false)
    #expect(!controller.canExit)
    #expect(await controller.handle(controllerBoundaryRequest(.diagnostics)).diagnostics?.setupState == .awaitingApproval)
    #expect(await controller.handle(controllerBoundaryRequest(.snapshot)).state?.setup == .awaitingApproval)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    #expect(effects.activationIds == [request.id])

    effects.sendActivation(.completed)
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.managedJournal?.phase == .checkingReadiness })
    #expect(effects.reconnects.isEmpty)
    effects.authenticated = true
    await controller.tick()
    if active {
        try #require(await controllerBoundaryEventually { effects.reconnects == ["account/region/client"] })
        effects.reconnectCompletion?(.startRequested(identifier: "account/region/client", warning: nil))
    }
    try #require(await controllerBoundaryEventually { effects.managedJournal?.phase == .completed })
    let completed = await controller.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(completed.operation == .init(id: request.id, state: .completed))
    #expect(completed.update?.identifier == (active ? "account/region/client" : nil))
    #expect(completed.status?.hasActiveTunnel == false)
    #expect(effects.performed == (active ? [.disconnectClient] : []))
    #expect(effects.reconnects == (active ? ["account/region/client"] : []))
}

@MainActor
@Test func controllerManagedUpdateRejectsDisconnectWithoutConsentAndKeepsTheMatchingBuildANoOp() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let denied = await controller.handle(controllerBoundaryRequest(.update, allowDisconnect: false))
    #expect(denied.update?.error == .disconnectRequired)
    #expect(denied.accepted == false)
    #expect(effects.managedData == nil)
    #expect(effects.performed.isEmpty)
    #expect(effects.activationIds.isEmpty)

    effects.authenticated = true
    effects.sessions.changeAccount(to: nil)
    effects.observationAccountId = nil
    let unchanged = await controller.handle(controllerBoundaryRequest(.update, allowDisconnect: false))
    #expect(unchanged.operation?.state == .completed)
    #expect(unchanged.update?.phase == .completed)
    #expect(unchanged.update?.reconnect == false)
    #expect(effects.active)
    #expect(effects.performed.isEmpty)
    #expect(effects.activationIds.isEmpty)
    #expect(effects.reconnects.isEmpty)
}

@MainActor
@Test func controllerManagedUpdateAndInitialMenuSetupShareOneActivationGate() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let initial = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let initialId = try #require(initial.operationId)
    #expect(initial.accepted == true)
    #expect(effects.activationIds == [initialId])
    effects.sendActivation(.approvalRequired)
    await controller.bootstrapManagedUpdate()
    #expect(effects.storedUpdates.state.attempt?.id == initialId)
    #expect(effects.activationIds == [initialId])
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    let blocked = await controller.handle(controllerBoundaryRequest(.update, allowDisconnect: false))
    #expect(blocked.update?.error == .busy)
    #expect(effects.managedData == nil)
    #expect(effects.activationIds == [initialId])

    effects.sendActivation(.failed(17))
    try #require(await controllerBoundaryEventually { effects.storedUpdates.state.attempt == nil })
    let request = controllerBoundaryRequest(.update, allowDisconnect: false)
    #expect(await controller.handle(request).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    try #require(await controllerBoundaryEventually { effects.activationIds == [initialId, request.id] })
    for action in [CloudGatewayMacControllerRequest.Action.connect, .refresh, .prepareClient, .prepareExtensionUpdate, .beginLogin] {
        #expect(await controller.handle(controllerBoundaryRequest(action)).error == .busy)
    }
    #expect(await controller.handle(controllerBoundaryRequest(.update)).update?.error == .busy)
    #expect(await controller.handle(controllerBoundaryRequest(.extensionUpdateFinished, contextId: request.id)).error == .extensionAttemptChanged)
    #expect(effects.activationIds == [initialId, request.id])
    #expect(effects.performed.isEmpty)
    effects.sendActivation(.failed(18))
}

@MainActor
@Test func controllerManagedUpdateBootstrapRecoversDurableLookupWithoutAFrontend() async throws {
    let previous = ControllerOrchestratorEffects()
    let oldController = try previous.makeManaged()
    _ = await oldController.handle(controllerBoundaryRequest(.lifecycle))
    let request = controllerBoundaryRequest(.update, allowDisconnect: false)
    #expect(await oldController.handle(request).operation?.state == .accepted)
    _ = await oldController.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    try #require(await controllerBoundaryEventually { previous.activationIds == [request.id] })
    previous.sendActivation(.approvalRequired)

    let effects = ControllerOrchestratorEffects()
    effects.now = previous.now
    effects.managedData = previous.managedData
    effects.storedUpdates = previous.storedUpdates
    let restored = try effects.makeManaged()
    effects.runtimeInitialized = false
    await restored.bootstrapManagedUpdate()
    #expect(effects.runtimeInitializations == 1)
    try #require(await controllerBoundaryEventually { effects.activationIds == [request.id] })
    let lookup = await restored.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(lookup.operation?.id == request.id)
    #expect(lookup.operation?.state == .running)
    #expect(lookup.update?.target == controllerBoundaryBuild)
    #expect(lookup.update?.reconnect == false)
    #expect(effects.performed.isEmpty)
    #expect(effects.reconnects.isEmpty)

    effects.sendActivation(.restartRequired)
    #expect(await restored.handle(controllerBoundaryRequest(.diagnostics)).diagnostics?.setupState == .awaitingRestart)
    #expect(await restored.handle(controllerBoundaryRequest(.operation, contextId: request.id)).update?.phase == .restartRequired)
    #expect(!restored.canExit)
    previous.sendActivation(.failed(1))
}

@MainActor
@Test func controllerManagedBootstrapLeavesColdRuntimeAloneAndExpiresUnconfirmedWorkWithoutEffects() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    effects.runtimeInitialized = false
    await controller.bootstrapManagedUpdate()
    #expect(effects.runtimeInitializations == 0)
    #expect(await controller.handle(controllerBoundaryRequest(.diagnostics)).diagnostics?.runtimeInitialized == false)
    #expect(effects.runtimeInitializations == 0)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let request = controllerBoundaryRequest(.update, allowDisconnect: false)
    #expect(await controller.handle(request).operation?.state == .accepted)
    effects.now.addTimeInterval(31)
    let restored = try effects.make(managed: true)
    await restored.bootstrapManagedUpdate()
    let expired = await restored.handle(controllerBoundaryRequest(.operation, contextId: request.id))
    #expect(expired.update?.error == .confirmationExpired)
    #expect(effects.performed.isEmpty)
    #expect(effects.activationIds.isEmpty)
    #expect(effects.reconnects.isEmpty)
}

@MainActor
@Test(arguments: [CloudGatewayMacControllerRequest.Action.turnOff, .disconnectClient, .signOut])
func controllerManagedUpdateExplicitStopOrLogoutSuppressesReconnectBeforeTheEffect(action: CloudGatewayMacControllerRequest.Action) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let update = controllerBoundaryRequest(.update, allowDisconnect: true)
    #expect(await controller.handle(update).operation?.state == .accepted)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: update.id))
    try #require(await controllerBoundaryEventually { effects.performed == [.disconnectClient] })
    effects.active = false
    effects.completion?(.completed(warning: nil))
    try #require(await controllerBoundaryEventually { effects.activationIds == [update.id] })
    effects.sendActivation(.approvalRequired)
    let stop = controllerBoundaryRequest(action)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    #expect(effects.managedJournal?.reconnect == true)
    effects.performHandler = { _, complete in
        #expect(effects.managedJournal?.reconnect == false)
        #expect(effects.managedJournal?.warning == .reconnectSuppressed)
        if action == .signOut {
            effects.sessions.changeAccount(to: nil)
            effects.observationAccountId = nil
        }
        complete(.completed(warning: nil))
        return true
    }
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id)).operation?.state == .completed)
    #expect(effects.activationPending)
    #expect(!controller.canExit)
    effects.sessions.changeAccount(to: "account")
    effects.observationAccountId = "account"
    effects.sendActivation(.completed)
    effects.authenticated = true
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.managedJournal?.phase == .completed })
    #expect(effects.reconnects.isEmpty)
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: update.id)).update?.warning == .reconnectSuppressed)
}

@MainActor
@Test func controllerManagedAuthenticationHookIrreversiblyRevokesReconnectAcrossSameAccountLogin() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let update = controllerBoundaryRequest(.update, allowDisconnect: true)
    _ = await controller.handle(update)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: update.id))
    try #require(await controllerBoundaryEventually { effects.performed == [.disconnectClient] })
    effects.active = false
    effects.completion?(.completed(warning: nil))
    try #require(await controllerBoundaryEventually { effects.activationIds == [update.id] })
    effects.sendActivation(.approvalRequired)
    effects.sessions.changeAccount(to: nil)
    effects.observationAccountId = nil
    controller.authenticationDidChange()
    #expect(effects.managedJournal?.reconnect == false)
    let redacted = await controller.handle(controllerBoundaryRequest(.operation, contextId: update.id))
    #expect(redacted.update?.identifier == nil)
    #expect(redacted.update?.reconnect == false)
    #expect(redacted.update?.warning == nil)
    effects.sessions.changeAccount(to: "account")
    effects.observationAccountId = "account"
    controller.authenticationDidChange()
    effects.sendActivation(.completed)
    effects.authenticated = true
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.managedJournal?.phase == .completed })
    #expect(effects.reconnects.isEmpty)
    #expect(effects.performed == [.disconnectClient])
}


@MainActor
@Test(arguments: [false, true])
func controllerHandoffReconcilesSupersededApprovalInTheSameBootAfterTheOldOwnerExits(extensionChanged: Bool) async throws {
    let nextTarget = extensionChanged ? controllerBoundaryReplacement : controllerBoundaryBuild
    let previous = ControllerOrchestratorEffects()
    let oldController = try previous.makeManaged()
    _ = await oldController.handle(controllerBoundaryRequest(.lifecycle))
    let oldUpdate = controllerBoundaryRequest(.update, allowDisconnect: false)
    _ = await oldController.handle(oldUpdate)
    _ = await oldController.handle(controllerBoundaryRequest(.confirmOperation, contextId: oldUpdate.id))
    try #require(await controllerBoundaryEventually { previous.activationIds == [oldUpdate.id] })
    previous.sendActivation(.approvalRequired)
    previous.installed = controllerBoundaryReplacement
    previous.extensionTarget = nextTarget
    await oldController.tick()
    #expect(previous.managedJournal?.phase == .superseded)
    #expect(previous.activationPending)
    #expect(previous.storedUpdates.state.attempt?.id == oldUpdate.id)
    await oldController.bootstrapManagedUpdate()
    #expect(previous.storedUpdates.state.attempt?.id == oldUpdate.id)
    #expect(oldController.canExit)

    let effects = ControllerOrchestratorEffects()
    effects.managedData = previous.managedData
    effects.storedUpdates = previous.storedUpdates
    effects.installed = controllerBoundaryReplacement
    effects.extensionTarget = nextTarget
    effects.runtimeInitialized = false
    let restored = try effects.makeManaged(identity: controllerBoundaryReplacement)
    effects.failExtensionWrites = true
    await restored.bootstrapManagedUpdate()
    #expect(effects.storedUpdates.state.attempt?.id == oldUpdate.id)
    #expect(effects.activationIds.isEmpty)
    await restored.tick()
    #expect(effects.storedUpdates.state.attempt?.id == oldUpdate.id)
    #expect(!restored.canExit)
    effects.failExtensionWrites = false
    await restored.tick()
    #expect(effects.runtimeInitializations == 0)
    #expect(effects.storedUpdates.state.attempt == nil)
    #expect(effects.storedUpdates.receipts.contains { $0.id == oldUpdate.id && $0.outcome == .superseded })
    let oldResult = await restored.handle(controllerBoundaryRequest(.operation, contextId: oldUpdate.id,
                                                                    build: controllerBoundaryReplacement))
    #expect(oldResult.update?.phase == .superseded)
    let newUpdate = controllerBoundaryRequest(.update, build: controllerBoundaryReplacement, allowDisconnect: false)
    #expect(await restored.handle(newUpdate).operation?.state == .accepted)
    _ = await restored.handle(controllerBoundaryRequest(.confirmOperation, contextId: newUpdate.id,
                                                        build: controllerBoundaryReplacement))
    try #require(await controllerBoundaryEventually { effects.activationIds == [newUpdate.id] })
    #expect(effects.activationTargets == [nextTarget])
    #expect(effects.reconnects.isEmpty)
    #expect(effects.performed.isEmpty)
    effects.sendActivation(.failed(1))
    previous.sendActivation(.failed(1))
}

@MainActor
@Test(arguments: [false, true])
func controllerBootstrapReconcilesAnOrphanAttemptWithoutBorrowingItsReconnectAuthority(confirmedOwner: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    let original = try effects.makeManaged()
    _ = await original.handle(controllerBoundaryRequest(.lifecycle))
    let update = controllerBoundaryRequest(.update, allowDisconnect: false)
    if confirmedOwner {
        #expect(await original.handle(update).operation?.state == .accepted)
        var journal = try #require(effects.managedJournal)
        journal.confirmed = true
        journal.phase = .activating
        effects.managedData = try JSONEncoder().encode(journal)
    }
    let orphan = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(
        id: UUID(), target: controllerBoundaryBuild, bootSession: "boot"
    )
    effects.storedUpdates = .init(state: .approvalPending(orphan))
    let restored = try effects.make(managed: true)
    await restored.bootstrapManagedUpdate()
    #expect(effects.storedUpdates.receipts.contains { $0.id == orphan.id && $0.outcome == .superseded })
    if confirmedOwner {
        try #require(await controllerBoundaryEventually { effects.activationIds == [update.id] })
        #expect(effects.managedJournal?.id == update.id)
        effects.sendActivation(.failed(1))
    } else {
        #expect(effects.activationIds.isEmpty)
        #expect(effects.managedData == nil)
        #expect(await restored.handle(update).operation?.state == .accepted)
        #expect(effects.activationIds.isEmpty)
    }
    #expect(effects.performed.isEmpty)
    #expect(effects.reconnects.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func controllerOperationLookupIncludesOnlyTheRequestedManagedUpdate(pending: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    effects.authenticated = !pending
    let update = controllerBoundaryRequest(.update, allowDisconnect: false)
    _ = await controller.handle(update)
    if pending {
        _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: update.id))
        try #require(await controllerBoundaryEventually { effects.activationIds == [update.id] })
        effects.sendActivation(.approvalRequired)
    }
    effects.performHandler = { _, done in done(.completed(warning: nil)); return true }
    let stop = controllerBoundaryRequest(.turnOff)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    let confirmed = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id))
    #expect(confirmed.operation?.id == stop.id)
    #expect(confirmed.update == nil)
    let ordinary = await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id))
    #expect(ordinary.operation == .init(id: stop.id, state: .completed))
    #expect(ordinary.update == nil)
    let unknownId = UUID()
    let unknown = await controller.handle(controllerBoundaryRequest(.operation, contextId: unknownId))
    #expect(unknown.operation == .init(id: unknownId, state: .unknown))
    #expect(unknown.update == nil)
    let managed = await controller.handle(controllerBoundaryRequest(.operation, contextId: update.id))
    #expect(managed.operation?.id == update.id)
    #expect(managed.update?.id == update.id)
    #expect(await controller.handle(controllerBoundaryRequest(.status)).update?.id == update.id)
    #expect(await controller.handle(controllerBoundaryRequest(.snapshot)).update?.id == update.id)
    if pending { effects.sendActivation(.failed(1)) }
}


@MainActor
@Test(arguments: [false, true])
func controllerBootstrapExpiresPreparedOrphansAndPreservesAnActualRestartRequirement(restartRequired: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(
        id: UUID(), target: controllerBoundaryBuild, bootSession: "boot"
    )
    effects.storedUpdates = .init(state: restartRequired ? .rebootRequired(attempt)
        : .prepared(attempt, deadline: effects.now.addingTimeInterval(30)))
    let controller = try effects.makeManaged()
    await controller.bootstrapManagedUpdate()
    if restartRequired {
        #expect(effects.storedUpdates.state == .rebootRequired(attempt))
        #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    } else {
        #expect(effects.storedUpdates.state.attempt == nil)
        #expect(effects.storedUpdates.receipts.contains { $0.id == attempt.id && $0.outcome == .expired })
    }
    #expect(effects.activationIds.isEmpty)
    #expect(effects.performed.isEmpty)
    #expect(effects.reconnects.isEmpty)
}


@MainActor
@Test(arguments: [CloudGatewayMacControllerRequest.Action.turnOff, .signOut])
func controllerStopRetainsDurabilityWarningWithoutAttachingAnotherOperationUpdate(action: CloudGatewayMacControllerRequest.Action) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let update = controllerBoundaryRequest(.update, allowDisconnect: true)
    _ = await controller.handle(update)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: update.id))
    try #require(await controllerBoundaryEventually { effects.performed == [.disconnectClient] })
    effects.active = false
    effects.completion?(.completed(warning: nil))
    try #require(await controllerBoundaryEventually { effects.activationIds == [update.id] })
    effects.sendActivation(.approvalRequired)
    let stop = controllerBoundaryRequest(action)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    effects.failWrites = true
    effects.failManagedWrites = true
    effects.failRevocationWrites = true
    effects.performHandler = { _, complete in
        if action == .signOut {
            effects.sessions.changeAccount(to: nil)
            effects.observationAccountId = nil
            controller.authenticationDidChange()
        }
        complete(.completed(warning: nil))
        return true
    }
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: stop.id)
    let confirmed = await controller.handle(confirmation)
    #expect(confirmed.operation == .init(id: stop.id, state: .completed))
    #expect(confirmed.outcome == .completed(warning: .reconnectSuppressionNotPersisted))
    #expect(confirmed.update == nil)
    #expect(effects.managedJournal?.reconnect == true)
    #expect(effects.revocationData == nil)
    let lookup = await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id))
    #expect(lookup.outcome == .completed(warning: .reconnectSuppressionNotPersisted))
    #expect(lookup.update == nil)
    #expect(await controller.handle(confirmation).outcome == lookup.outcome)
    let olderBuild = await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id,
                                                                       build: controllerBoundaryReplacement))
    #expect(olderBuild.operation?.state == .completed)
    #expect(olderBuild.outcome == nil)
    #expect(olderBuild.update == nil)
    #expect(effects.performed == [.disconnectClient, action])
    #expect(effects.reconnects.isEmpty)
    effects.sendActivation(.failed(1))
}


@MainActor
@Test(arguments: [CloudGatewayMacExtensionActivationEvent.completed, .restartRequired, .failed(7)])
func controllerLegacyActivationRetriesItsTerminalCallbackAfterStorageRecovers(event: CloudGatewayMacExtensionActivationEvent) async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let initial = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    let id = try #require(initial.operationId)
    #expect(effects.activationIds == [id])
    effects.sendActivation(.approvalRequired)
    effects.failExtensionWrites = true
    effects.sendActivation(event)
    #expect(!effects.activationPending)
    #expect(effects.storedUpdates.state.attempt?.id == id)
    // A late approval cannot replace the terminal callback waiting for persistence
    effects.sendActivation(.approvalRequired)
    effects.now.addTimeInterval(900)
    await controller.tick()
    #expect(!controller.canExit)
    #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    #expect(await controller.handle(controllerBoundaryRequest(.connect)).error == .busy)
    #expect(await controller.handle(controllerBoundaryRequest(.update)).error == .busy)
    #expect(effects.activationIds == [id])
    #expect(effects.performed.isEmpty)
    effects.now.addTimeInterval(900)
    effects.failExtensionWrites = false
    effects.authenticated = event == .completed
    await controller.tick()
    switch event {
    case .completed:
        try #require(await controllerBoundaryEventually { effects.setup == .ready })
        #expect(effects.storedUpdates.receipts.contains { $0.id == id && $0.outcome == .activationFinished })
        #expect(effects.storedUpdates.state.attempt == nil)
        try #require(await controllerBoundaryEventually { controller.canExit })
    case .restartRequired:
        #expect(effects.setup == .awaitingRestart)
        #expect(effects.storedUpdates.state.attempt?.id == id)
        #expect(!controller.canExit)
        #expect(await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate)).error == .busy)
    case .failed:
        try #require(await controllerBoundaryEventually { effects.setup == .updateRequired })
        #expect(effects.storedUpdates.receipts.contains { $0.id == id && $0.outcome == .failed })
        #expect(effects.storedUpdates.state.attempt == nil)
        try #require(await controllerBoundaryEventually { controller.canExit })
    case .approvalRequired:
        Issue.record("Expected a terminal adapter callback")
    }
    #expect(effects.activationIds == [id])
    #expect(effects.managedData == nil)
    #expect(effects.reconnects.isEmpty)
}

@MainActor
@Test func controllerAppReplacementCannotResumeReconnectAfterTheOldOwnerCrashes() async throws {
    let previous = ControllerOrchestratorEffects()
    let old = try previous.makeManaged(active: true)
    _ = await old.handle(controllerBoundaryRequest(.lifecycle))
    let request = controllerBoundaryRequest(.update, allowDisconnect: true)
    _ = await old.handle(request)
    _ = await old.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    try #require(await controllerBoundaryEventually { previous.performed == [.disconnectClient] })
    previous.active = false
    previous.completion?(.completed(warning: nil))
    try #require(await controllerBoundaryEventually { previous.activationIds == [request.id] })
    previous.sendActivation(.approvalRequired)
    #expect(previous.managedJournal?.appIdentity == controllerBoundaryBuild)

    let effects = ControllerOrchestratorEffects()
    effects.managedData = previous.managedData
    effects.storedUpdates = previous.storedUpdates
    effects.installed = controllerBoundaryReplacement
    effects.extensionTarget = controllerBoundaryBuild
    let replacement = try effects.makeManaged(identity: controllerBoundaryReplacement)
    await replacement.bootstrapManagedUpdate()
    try #require(await controllerBoundaryEventually { effects.managedJournal?.phase == .superseded })
    #expect(effects.managedJournal?.reconnect == false)
    #expect(effects.activationIds.isEmpty)
    #expect(effects.reconnects.isEmpty)
    #expect(effects.performed.isEmpty)
    #expect(effects.storedUpdates.state.attempt == nil)
    previous.sendActivation(.failed(1))
}

@MainActor
@Test func controllerUpdateChecksAuthenticatedNoopBeforeColdRuntimeWork() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    effects.hasPendingWork = true
    effects.authenticated = true
    let request = controllerBoundaryRequest(.update, allowDisconnect: false)
    let reply = await controller.handle(request)
    #expect(reply.operation?.state == .completed)
    #expect(reply.update?.phase == .completed)
    #expect(reply.update?.reconnect == false)
    #expect(effects.performed.isEmpty)
    #expect(effects.activationIds.isEmpty)
    #expect(effects.reconnects.isEmpty)
    #expect(effects.pings > 0)
}
