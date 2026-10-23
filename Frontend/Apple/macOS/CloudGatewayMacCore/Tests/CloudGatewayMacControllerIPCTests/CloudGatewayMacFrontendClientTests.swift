import AppKit
import CloudGatewayMacIPC
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

@MainActor
private final class FrontendTransport {
    var instanceId = UUID()
    var installed = controllerBoundaryBuild
    var lifecycleState = CloudGatewayMacControllerLifecycle.State.current
    var active = false
    var state: CloudGatewayMacControllerState?
    var managedUpdate: CloudGatewayMacManagedUpdateStatus?
    var unavailable = false
    var bootstrapMakesAvailable = false
    var suspended: Set<CloudGatewayMacControllerRequest.Action> = []
    var pending: [UUID: CheckedContinuation<CloudGatewayMacControllerReply, any Error>] = [:]
    var requests: [CloudGatewayMacControllerRequest] = []
    var replacement: CloudGatewayMacBuildIdentity?
    var bootstraps = 0

    func make(now: (@Sendable () -> Duration)? = nil,
              sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> CloudGatewayMacFrontendClient {
        let client = CloudGatewayMacFrontendClient(
            identity: controllerBoundaryBuild, transport: { try await self.send($0) },
            bootstrap: {
                self.bootstraps += 1
                if self.bootstrapMakesAvailable { self.unavailable = false }
            }, now: now, sleep: sleep
        )
        client.onReplacement = { self.replacement = $0 }
        return client
    }

    func envelope(_ reply: CloudGatewayMacControllerReply, instance: UUID? = nil) -> CloudGatewayMacControllerReply {
        var reply = reply
        reply.instanceId = instance ?? instanceId
        return reply
    }

    func send(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        requests.append(request)
        if unavailable { throw CloudGatewayMacControllerFailure.unavailable }
        if suspended.contains(request.action) {
            return try await withCheckedThrowingContinuation { pending[request.id] = $0 }
        }
        switch request.action {
        case .lifecycle:
            return envelope(.init(lifecycle: .init(running: controllerBoundaryBuild, installed: installed, state: lifecycleState)))
        case .snapshot, .menuWillOpen, .userActivity, .recordActivity:
            return envelope(.init(state: state ?? controllerBoundaryState(active: active), update: managedUpdate))
        case .status:
            return envelope(.init(status: .init(hasActiveTunnel: active, needsStop: active, observationAvailable: true),
                                  update: managedUpdate))
        case .turnOff, .connect:
            return envelope(.init(operation: .init(id: request.id, state: .accepted), accepted: true, operationId: request.id))
        case .confirmOperation:
            let id = try #require(request.contextId)
            return envelope(.init(operation: .init(id: id, state: .running), accepted: true, operationId: id))
        default: return envelope(.init())
        }
    }

    func resolve(_ id: UUID, with reply: CloudGatewayMacControllerReply) throws {
        let removed = pending.removeValue(forKey: id)
        let continuation = try #require(removed)
        continuation.resume(returning: reply)
    }

    func fail(_ id: UUID) throws {
        let removed = pending.removeValue(forKey: id)
        let continuation = try #require(removed)
        continuation.resume(throwing: CloudGatewayMacControllerFailure.unavailable)
    }
}

@MainActor
@Test func frontendClientDrainingUsesCompatibleStatusAndConfirmsStopAcrossBuilds() async throws {
    let transport = FrontendTransport()
    transport.active = true
    transport.installed = controllerBoundaryReplacement
    transport.lifecycleState = .draining
    let client = transport.make()
    try await client.poll()
    #expect(client.connectionState == .draining)
    #expect(!client.isSnapshotFresh)
    #expect(client.snapshot == nil)
    #expect(client.presentation.statusTitle == "VPN connected")
    #expect(client.presentation.canTurnOff)
    #expect(transport.replacement == controllerBoundaryReplacement)
    #expect(transport.requests.map(\.action) == [.lifecycle, .status])
    await #expect(throws: CloudGatewayMacControllerFailure.busy) { try await client.request(.connect, identifier: "account/region/client") }
    await #expect(throws: CloudGatewayMacControllerFailure.busy) { try await client.request(.prepareExtensionUpdate) }
    let id = UUID()
    #expect(try await client.request(.turnOff, id: id).operation?.state == .running)
    #expect(transport.requests.map(\.action) == [.lifecycle, .status, .turnOff, .confirmOperation])
    #expect(transport.requests.last?.contextId == id)
    #expect(transport.requests.last?.buildIdentity == controllerBoundaryBuild)
    #expect(transport.bootstraps == 0)
    client.shutdown()
}

@MainActor
@Test func frontendClientKeepsLastObservedLabelAndDisablesActionsWhileReconnecting() async throws {
    let transport = FrontendTransport()
    transport.active = true
    let client = transport.make()
    try await client.poll()
    #expect(client.presentation.statusTitle == "VPN connected")
    transport.suspended = [.status]
    let id = UUID()
    let request = Task { try await client.request(.status, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    try transport.fail(id)
    await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await request.value }
    #expect(client.connectionState == .reconnecting)
    #expect(!client.isSnapshotFresh)
    #expect(client.snapshot?.statusTitle == "VPN connected")
    #expect(client.presentation.statusTitle == "VPN connected (last observed)")
    #expect(client.presentation.hasActiveTunnel)
    #expect(!client.presentation.canToggleVPN)
    #expect(!client.presentation.canTurnOff)
    client.shutdown()
}

@MainActor
@Test func frontendClientOldSnapshotCannotReplaceNewerObservation() async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    try await client.poll()
    transport.suspended = [.snapshot]
    let id = UUID()
    let old = Task { try await client.request(.snapshot, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    transport.suspended = []
    transport.active = true
    _ = try await client.request(.snapshot)
    try transport.resolve(id, with: transport.envelope(.init(state: controllerBoundaryState(active: false))))
    _ = try await old.value
    #expect(client.isSnapshotFresh)
    #expect(client.presentation.statusTitle == "VPN connected")
    #expect(client.presentation.hasActiveTunnel)
    #expect(client.errorMessage == nil)
    client.shutdown()
}

@MainActor
@Test func frontendClientOldTransportFailureCannotEraseNewerFreshState() async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    try await client.poll()
    transport.suspended = [.snapshot]
    let id = UUID()
    let old = Task { try await client.request(.snapshot, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    transport.suspended = []
    transport.active = true
    _ = try await client.request(.snapshot)
    try transport.fail(id)
    await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await old.value }
    #expect(client.connectionState == .connected)
    #expect(client.isSnapshotFresh)
    #expect(client.presentation.statusTitle == "VPN connected")
    #expect(client.errorMessage == nil)
    client.shutdown()
}

@MainActor
@Test func frontendClientOldLifecycleCannotUndoNewerDrainingHandshake() async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    try await client.poll()
    transport.suspended = [.lifecycle]
    let id = UUID()
    let old = Task { try await client.request(.lifecycle, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    transport.suspended = []
    transport.installed = controllerBoundaryReplacement
    transport.lifecycleState = .draining
    try await client.poll()
    try transport.resolve(id, with: transport.envelope(.init(lifecycle: .init(
        running: controllerBoundaryBuild, installed: controllerBoundaryBuild, state: .current
    ))))
    _ = try await old.value
    #expect(client.connectionState == .draining)
    #expect(!client.isSnapshotFresh)
    #expect(transport.replacement == controllerBoundaryReplacement)
    client.shutdown()
}

@MainActor
@Test(arguments: [false, true])
func frontendClientPreviousGenerationCannotReplaceOrEraseReplacementState(failure: Bool) async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    try await client.poll()
    transport.suspended = [.snapshot]
    let id = UUID()
    let old = Task { try await client.request(.snapshot, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    let previousInstance = transport.instanceId
    transport.instanceId = UUID()
    transport.suspended = []
    transport.active = true
    try await client.poll()
    if failure {
        try transport.fail(id)
        await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await old.value }
    } else {
        try transport.resolve(id, with: transport.envelope(.init(state: controllerBoundaryState(active: false)), instance: previousInstance))
        await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await old.value }
    }
    #expect(client.connectionState == .connected)
    #expect(client.isSnapshotFresh)
    #expect(client.presentation.statusTitle == "VPN connected")
    #expect(client.errorMessage == nil)
    client.shutdown()
}

@MainActor
@Test func frontendClientReplyFromUnhandshakenInstanceCannotReplaceCurrentSnapshot() async throws {
    let transport = FrontendTransport()
    transport.active = true
    let client = transport.make()
    try await client.poll()
    transport.suspended = [.snapshot]
    let id = UUID()
    let request = Task { try await client.request(.snapshot, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    try transport.resolve(id, with: transport.envelope(.init(state: controllerBoundaryState(active: false)), instance: UUID()))
    await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await request.value }
    #expect(!client.isSnapshotFresh)
    #expect(client.connectionState == .reconnecting)
    #expect(client.presentation.statusTitle == "VPN connected (last observed)")
    #expect(!client.presentation.canToggleVPN)
    client.shutdown()
}

@MainActor
@Test func frontendClientShutdownDiscardsPendingRepliesAndPreventsConfirmation() async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    try await client.poll()
    let previous = client.snapshot
    transport.suspended = [.connect]
    let id = UUID()
    let request = Task { try await client.request(.connect, id: id, identifier: "account/region/client") }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    client.shutdown()
    try transport.resolve(id, with: transport.envelope(.init(operation: .init(id: id, state: .accepted))))
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(client.snapshot == previous)
    #expect(!transport.requests.contains { $0.action == .confirmOperation })
    await #expect(throws: CancellationError.self) { try await client.request(.status) }
}

@MainActor
@Test func frontendClientHandshakeBootstrapsOnlyWhenTheControllerIsUnavailable() async {
    for failure: CloudGatewayMacControllerFailure in [.rejected, .incompatibleVersion, .timeout, .invalidRequest] {
        var bootstraps = 0
        var attempts = 0
        let client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { _ in
            attempts += 1
            throw failure
        }, bootstrap: { bootstraps += 1 }, sleep: { _ in })
        await #expect(throws: failure) { try await client.handshake() }
        #expect(bootstraps == 0)
        #expect(attempts == 1)
    }
}

private final class FrontendClock: Sendable {
    let elapsed = Mutex(Duration.zero)

    func now() -> Duration { elapsed.withLock { $0 } }
    func set(_ value: Duration) { elapsed.withLock { $0 = value } }
    func advance(_ value: Duration) { elapsed.withLock { $0 += value } }
}

@MainActor
private final class FrontendSleeper {
    private struct Wait {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waits: [Wait] = []
    var durations: [Duration] { waits.map(\.duration) }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waits.append(.init(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waits.firstIndex(where: { $0.id == id }) else { return }
                self.waits.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    func resume(_ duration: Duration = .seconds(1)) throws {
        let index = try #require(waits.firstIndex { $0.duration == duration })
        waits.remove(at: index).continuation.resume()
    }
}

@MainActor
@Test func frontendPollingPausesAtFifteenMinutesAndKeepsOnlySafeIdleActions() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    transport.active = true
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    clock.set(.seconds(899))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    #expect(client.isSnapshotFresh)
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(!client.isSnapshotFresh)
    #expect(client.presentation.statusTitle == "VPN connected (last observed)")
    #expect(client.presentation.hasActiveTunnel)
    #expect(client.presentation.canTurnOff)
    #expect(client.presentation.reconnectIdentifier == nil)
    #expect(client.presentation.groups.flatMap(\.rows).allSatisfy { !$0.isEnabled && $0.status == nil })
    #expect(client.presentation.accountId == "account")
    #expect(!client.presentation.canCreateClient)
    #expect(!client.presentation.canUpdateExtension)
    let requests = transport.requests.count
    transport.unavailable = true
    clock.set(.seconds(1_800))
    client.start()
    try await client.poll()
    #expect(transport.requests.count == requests)
    #expect(transport.bootstraps == 0)
}

@MainActor
@Test func frontendMenuInteractionResumesAndBootstrapsBeforeSendingMenuActivityOnce() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    transport.unavailable = true
    transport.bootstrapMakesAvailable = true
    transport.instanceId = UUID()
    let interaction = Task { try await client.userRequest(.menuWillOpen) }
    try #require(await controllerBoundaryEventually { sleeper.durations.contains(.milliseconds(250)) })
    #expect(transport.bootstraps == 1)
    try sleeper.resume(.milliseconds(250))
    _ = try await interaction.value
    #expect(!client.isPollingPaused)
    #expect(client.isSnapshotFresh)
    #expect(transport.requests.filter { $0.action == .menuWillOpen }.count == 1)
    #expect(!transport.requests.contains { $0.action == .userActivity })
}

@MainActor
@Test func frontendAutomaticPollingAndExtensionRequestsDoNotExtendActivityOrRelaunch() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    clock.set(.seconds(899))
    _ = try await client.request(.prepareExtensionUpdate)
    _ = try await client.request(.extensionUpdateFinished, contextId: UUID())
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    transport.unavailable = true
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(2)] })
    #expect(transport.bootstraps == 0)
    clock.set(.seconds(900))
    try sleeper.resume(.seconds(2))
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.bootstraps == 0)
    #expect(!transport.requests.contains { $0.action == .userActivity })
}

@MainActor
@Test func frontendLateAutomaticSnapshotAtIdleIsNeverPresentedAsFresh() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    clock.set(.seconds(899))
    transport.suspended = [.snapshot]
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { !transport.pending.isEmpty })
    let id = try #require(transport.pending.keys.first)
    clock.set(.seconds(900))
    try transport.resolve(id, with: transport.envelope(.init(state: controllerBoundaryState(active: true))))
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(!client.isSnapshotFresh)
    #expect(client.presentation.statusTitle == "VPN connected (last observed)")
    #expect(client.presentation.reconnectIdentifier == nil)
}

@MainActor
@Test(arguments: [CloudGatewayMacSetupState.activating, .awaitingApproval, .awaitingRestart, .checkingConnection])
func frontendActivationProgressStillPausesPollingAtFifteenMinutes(setup: CloudGatewayMacSetupState) async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    transport.state = controllerBoundaryState(setup: setup)
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(!client.isSnapshotFresh)
    #expect(transport.requests.count == requests)
    #expect(sleeper.durations.isEmpty)
    clock.set(.seconds(1_800))
    client.start()
    try await client.poll()
    #expect(transport.requests.count == requests)
}

@MainActor
@Test(arguments: [CloudGatewayMacLoginStatus.Phase.requestingCode, .waitingForApproval, .exchangingToken, .restoring])
func frontendLoginProgressPausesAtFifteenMinutesAndRetainsItsCancellationContext(phase: CloudGatewayMacLoginStatus.Phase) async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let id = UUID()
    let url = try #require(URL(string: "https://gocloudlaunch.com"))
    let browser: CloudGatewayMacBrowserAuthState = switch phase {
    case .requestingCode: .requestingCode
    case .waitingForApproval: .waitingForApproval(userCode: "123456", verificationURL: url)
    case .exchangingToken: .exchangingToken
    default: .signedOut
    }
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(accountId: nil, hasRetainedSession: false, accessAuthorized: false,
                      access: .offline, credentials: .available, inventoryFreshness: .unavailable,
                      installedIdentifiers: [], observedProfiles: [], observationIsFresh: true,
                      profilesObservedAt: nil, commandInFlight: false, clients: []),
        lastSelectedIdentifier: nil, browserState: browser,
        login: .init(attemptId: id, origin: .menu, phase: phase),
        isRestoringSession: phase == .restoring, isAuthSettling: false, canCreateClient: false, errorMessage: nil
    )
    transport.state = .init(snapshot: snapshot, setupState: .ready, canUpdateExtension: false)
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(!client.isSnapshotFresh)
    #expect(transport.requests.count == requests)
    #expect(client.presentation.login?.attemptId == id)
    #expect(client.presentation.browserState == client.snapshot?.browserState)
    clock.set(.seconds(1_800))
    try await client.poll()
    #expect(transport.requests.count == requests)
    _ = try await client.userRequest(.cancelLogin, contextId: id)
    #expect(transport.requests.last?.action == .cancelLogin)
    #expect(transport.requests.last?.contextId == id)
    #expect(!client.isPollingPaused)
}

@MainActor
@Test func frontendPendingUserOperationContinuesAfterPollingPausesAtFifteenMinutes() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    transport.suspended = [.connect]
    let id = UUID()
    let operation = Task { try await client.userRequest(.connect, id: id, identifier: "account/region/client") }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.requests.count == requests)
    try transport.resolve(id, with: transport.envelope(.init(operation: .init(id: id, state: .accepted))))
    #expect(try await operation.value.operation?.state == .running)
    #expect(client.isPollingPaused)
    #expect(!transport.requests.contains { $0.action == .userActivity || $0.action == .recordActivity })
    #expect(transport.requests.filter { $0.action == .confirmOperation }.count == 1)
    #expect(transport.requests.dropFirst(requests).map(\.action) == [.confirmOperation])
    clock.set(.seconds(1_800))
    try await client.poll()
    #expect(transport.requests.count == requests + 1)
}

@MainActor
@Test func frontendInteractionRetriesAreBoundedAndOnlyANewInteractionMayBootstrapAgain() async {
    let clock = FrontendClock()
    let transport = FrontendTransport()
    transport.unavailable = true
    let client = transport.make(now: { clock.now() }, sleep: { clock.advance($0) })
    defer { client.shutdown() }
    await #expect(throws: CloudGatewayMacControllerFailure.timeout) { try await client.userRequest(.menuWillOpen) }
    #expect(transport.bootstraps == 1)
    #expect(transport.requests.count == 40)
    await #expect(throws: CloudGatewayMacControllerFailure.timeout) { try await client.userRequest(.menuWillOpen) }
    #expect(transport.bootstraps == 2)
    #expect(transport.requests.count == 80)
    #expect(transport.requests.allSatisfy { $0.action == .lifecycle })
}

@MainActor
@Test(arguments: [false, true])
func frontendCancelledOrShutdownInteractionCannotSendItsAction(shutdown: Bool) async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    defer { client.shutdown() }
    transport.suspended = [.lifecycle]
    let interaction = Task { try await client.userRequest(.connect, identifier: "account/region/client") }
    try #require(await controllerBoundaryEventually { !transport.pending.isEmpty })
    let id = try #require(transport.pending.keys.first)
    if shutdown { client.shutdown() }
    else { interaction.cancel() }
    try transport.resolve(id, with: transport.envelope(.init(lifecycle: .init(
        running: controllerBoundaryBuild, installed: controllerBoundaryBuild, state: .current
    ))))
    await #expect(throws: CancellationError.self) { try await interaction.value }
    #expect(!transport.requests.contains { $0.action == .connect || $0.action == .userActivity || $0.action == .confirmOperation })
}

@MainActor
@Test func frontendShutdownCancelsThePollSleepAndCannotRestartFromActivity() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    client.shutdown()
    try #require(await controllerBoundaryEventually { sleeper.durations.isEmpty })
    let requests = transport.requests.count
    client.start()
    await #expect(throws: CancellationError.self) { try await client.userRequest(.menuWillOpen) }
    #expect(transport.requests.count == requests)
}

@MainActor
@Test func frontendConcurrentInteractionsShareOneBootstrapAndPreserveStopDuringBuildReplacement() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    transport.unavailable = true
    transport.bootstrapMakesAvailable = true
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    let menu = Task { try await client.userRequest(.menuWillOpen) }
    try #require(await controllerBoundaryEventually { sleeper.durations == [.milliseconds(250)] })
    let stop = Task { try await client.userRequest(.turnOff) }
    await Task.yield()
    transport.installed = controllerBoundaryReplacement
    transport.lifecycleState = .draining
    try sleeper.resume(.milliseconds(250))
    _ = try await menu.value
    #expect(try await stop.value.operation?.state == .running)
    #expect(client.connectionState == .draining)
    #expect(transport.bootstraps == 1)
    #expect(!transport.requests.contains { $0.action == .userActivity || $0.action == .menuWillOpen })
    #expect(transport.requests.filter { $0.action == .turnOff }.count == 1)
    #expect(transport.requests.filter { $0.action == .confirmOperation }.count == 1)
}

@MainActor
@Test func frontendStartupCannotBootstrapAfterItsPassiveHandshakeCrossesIdle() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    transport.suspended = [.lifecycle]
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { !transport.pending.isEmpty })
    let id = try #require(transport.pending.keys.first)
    clock.set(.seconds(900))
    try transport.fail(id)
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.bootstraps == 0)
    #expect(transport.requests.count == 1)
}

@MainActor
@Test func frontendHeldClientPreparationDoesNotKeepPollingAliveAndStillReturnsToItsCaller() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    transport.suspended = [.prepareClient]
    let id = UUID()
    let preparation = Task { try await client.userRequest(.prepareClient, id: id) }
    try #require(await controllerBoundaryEventually { transport.pending[id] != nil })
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.requests.count == requests)
    client.start()
    clock.set(.seconds(1_800))
    try await client.poll()
    #expect(sleeper.durations.isEmpty)
    #expect(transport.requests.count == requests)
    let context = UUID()
    try transport.resolve(id, with: transport.envelope(.init(creation: .init(id: context, regions: []))))
    #expect(try await preparation.value.creation?.id == context)
    #expect(client.isPollingPaused)
    #expect(transport.requests.count == requests)
}

@MainActor
@Test func frontendConfirmedOperationFinishesAfterPassivePollingStops() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    transport.suspended = [.confirmOperation]
    let id = UUID()
    let operation = Task { try await client.userRequest(.connect, id: id, identifier: "account/region/client") }
    try #require(await controllerBoundaryEventually { !transport.pending.isEmpty })
    let confirmation = try #require(transport.pending.keys.first)
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.requests.count == requests)
    #expect(transport.pending[confirmation] != nil)
    try transport.resolve(confirmation, with: transport.envelope(.init(operation: .init(id: id, state: .completed))))
    #expect(try await operation.value.operation?.state == .completed)
    #expect(client.isPollingPaused)
    clock.set(.seconds(1_800))
    try await client.poll()
    #expect(transport.requests.count == requests)
}

@MainActor
@Test func frontendPassiveLifecycleCompletingAtTheCutoffCannotSendASnapshot() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    transport.suspended = [.lifecycle]
    clock.set(.seconds(899))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { !transport.pending.isEmpty })
    let id = try #require(transport.pending.keys.first)
    let requests = transport.requests.count
    clock.set(.seconds(900))
    try transport.resolve(id, with: transport.envelope(.init(lifecycle: .init(
        running: controllerBoundaryBuild, installed: controllerBoundaryBuild, state: .current
    ))))
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    #expect(transport.requests.count == requests)
    clock.set(.seconds(1_800))
    try await client.poll()
    #expect(transport.requests.count == requests)
}

@MainActor
@Test func frontendManualExtensionPreparationRecordsActivityWithoutStartingARefresh() async throws {
    let transport = FrontendTransport()
    let client = transport.make()
    defer { client.shutdown() }
    _ = try await client.userRequest(.prepareExtensionUpdate)
    #expect(transport.requests.map(\.action) == [.lifecycle, .recordActivity, .prepareExtensionUpdate])
    _ = try await client.request(.prepareExtensionUpdate)
    #expect(transport.requests.map(\.action) == [.lifecycle, .recordActivity, .prepareExtensionUpdate, .prepareExtensionUpdate])
}

@MainActor
@Test func frontendStaleInventoryDoesNotStartARefreshBeforeClientPreparationOrSubmission() async throws {
    let clock = FrontendClock()
    var refreshInFlight = false
    var activity: [Bool] = []
    var preparations = 0
    var submissions = 0
    var sessions = CloudGatewayMacSessionFence()
    sessions.changeAccount(to: "account")
    let session = sessions.currentToken
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { setup, canUpdate in controllerBoundaryState(setup: setup, canUpdateExtension: canUpdate) },
        hasPendingWork: { refreshInFlight }, perform: { _, _ in true }, session: { session }, refresh: { .refreshed },
        prepareClient: {
            guard !refreshInFlight else { throw CloudGatewayMacControllerFailure.rejected }
            preparations += 1
            return .init(regions: []) { _, _, completion in
                guard !refreshInFlight else { return false }
                submissions += 1
                completion(.completed(warning: nil))
                return true
            }
        },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false },
        installedIdentity: { controllerBoundaryBuild }, extensionIdentity: { controllerBoundaryBuild },
        ping: { identity in
            CloudGatewayMacExtensionVersion(infoDictionary: [
                "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version
            ], codeHash: identity.codeHash)
        }, userActivity: { refresh in
            activity.append(refresh)
            // Hold the stale fetch so creation cannot slip past it before the assertion
            if refresh { refreshInFlight = true }
        }, monotonicNow: { clock.now() }
    )
    let controller = CloudGatewayMacControllerOrchestrator(
        identity: controllerBoundaryBuild, effects: effects,
        requests: try .init(data: nil, persist: { _ in }),
        extensionUpdates: try .init(bootSession: { "boot" }, persist: { _ in })
    )
    let instanceId = UUID()
    var actions: [CloudGatewayMacControllerRequest.Action] = []
    let client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { request in
        actions.append(request.action)
        var reply = await controller.handle(request)
        reply.instanceId = instanceId
        return reply
    }, bootstrap: {}, now: { clock.now() })
    defer { client.shutdown() }
    clock.set(.seconds(61))
    let preparation = try await client.userRequest(.prepareClient)
    let creation = try #require(preparation.creation)
    #expect(preparations == 1)
    #expect(!refreshInFlight)
    clock.advance(.seconds(61))
    let result = try await client.userRequest(.createClient, regionId: "region", clientName: "Mac", contextId: creation.id)
    #expect(result.operation?.state == .completed)
    #expect(submissions == 1)
    #expect(activity == [false, false])
    #expect(actions == [.lifecycle, .prepareClient, .lifecycle, .createClient, .confirmOperation])
    _ = try await client.request(.userActivity)
    #expect(refreshInFlight)
    await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await client.userRequest(.prepareClient) }
    #expect(preparations == 1)
}

@MainActor
@Test func frontendFirstMenuOpeningAfterIdleEnablesExistingClientItemsInPlace() async throws {
    let clock = FrontendClock()
    let sleeper = FrontendSleeper()
    let transport = FrontendTransport()
    let client = transport.make(now: { clock.now() }, sleep: { try await sleeper.sleep($0) })
    defer { client.shutdown() }
    client.start()
    try #require(await controllerBoundaryEventually { sleeper.durations == [.seconds(1)] })
    clock.set(.seconds(900))
    try sleeper.resume()
    try #require(await controllerBoundaryEventually { client.isPollingPaused })
    let group = try #require(client.presentation.groups.first)
    let row = try #require(group.rows.first)
    let menu = NSMenu()
    menu.autoenablesItems = false
    let region = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let item = NSMenuItem(title: row.title, action: NSSelectorFromString("selectClient:"), keyEquivalent: "")
    item.representedObject = row.identifier
    item.isEnabled = row.isEnabled
    submenu.addItem(item)
    region.submenu = submenu
    menu.addItem(region)
    #expect(!item.isEnabled)
    client.onChange = {
        CloudGatewayMacMenuUpdates.updateClients(in: menu, from: client.presentation,
            isSnapshotFresh: client.isSnapshotFresh && client.isCurrentBuild, canConnect: true)
    }
    transport.active = true
    _ = try await client.userRequest(.menuWillOpen)
    #expect(client.isSnapshotFresh)
    #expect(item.isEnabled)
    #expect(item.state == .on)
    #expect(menu.items.count == 1)
    #expect(menu.items.first === region)
    #expect(region.submenu === submenu)
    #expect(submenu.items.count == 1)
    #expect(submenu.items.first === item)
    #expect(item.title == row.title)
    #expect(item.representedObject as? String == row.identifier)
    #expect(item.action == NSSelectorFromString("selectClient:"))
}


@MainActor
@Test func frontendLostUpdateConfirmationDetachesWithoutCancellingControllerWork() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged(active: true)
    let instanceId = UUID()
    var actions: [CloudGatewayMacControllerRequest] = []
    let client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { request in
        actions.append(request)
        var reply = await controller.handle(request)
        reply.instanceId = instanceId
        if request.action == .confirmOperation { throw CloudGatewayMacControllerFailure.unavailable }
        return reply
    }, bootstrap: {})
    defer { client.shutdown() }
    let id = UUID()
    await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) {
        try await client.userRequest(.update, id: id, allowDisconnect: true)
    }
    client.shutdown()
    #expect(actions.filter { $0.action == .update }.map(\.allowDisconnect) == [true])
    #expect(actions.filter { $0.action == .confirmOperation }.map(\.contextId) == [id])
    try #require(await controllerBoundaryEventually { effects.performed == [.disconnectClient] })
    #expect(effects.managedJournal?.confirmed == true)
    #expect(effects.activationIds.isEmpty)
    effects.active = false
    effects.completion?(.completed(warning: nil))
    try #require(await controllerBoundaryEventually { effects.activationIds == [id] })
    effects.sendActivation(.approvalRequired)
    #expect(effects.reconnects.isEmpty)
    effects.sendActivation(.completed)
    effects.authenticated = true
    await controller.tick()
    try #require(await controllerBoundaryEventually { effects.reconnects == ["account/region/client"] })
    effects.reconnectCompletion?(.startRequested(identifier: "account/region/client", warning: nil))
    let completed = await controller.handle(controllerBoundaryRequest(.operation, contextId: id))
    #expect(completed.operation == .init(id: id, state: .completed))
    #expect(completed.update?.phase == .completed)
    #expect(effects.activationIds == [id])
    #expect(effects.performed == [.disconnectClient])
}

@MainActor
@Test func frontendMenuUpdateUsesControllerActivationAndPublishesPendingApprovalAndRestart() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    let instanceId = UUID()
    var actions: [CloudGatewayMacControllerRequest] = []
    let client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { request in
        actions.append(request)
        var reply = await controller.handle(request)
        reply.instanceId = instanceId
        return reply
    }, bootstrap: {})
    defer { client.shutdown() }
    let id = UUID()
    #expect(try await client.userRequest(.update, id: id, allowDisconnect: false).operation?.state == .running)
    try #require(await controllerBoundaryEventually { effects.activationIds == [id] })
    #expect(actions.filter { $0.action == .update }.map(\.allowDisconnect) == [false])
    #expect(actions.filter { $0.action == .confirmOperation }.map(\.contextId) == [id])
    #expect(!actions.contains { $0.action == .extensionUpdateStarted })
    effects.sendActivation(.approvalRequired)
    _ = try await client.request(.snapshot)
    #expect(client.managedUpdate?.id == id)
    #expect(client.managedUpdate?.phase == .approvalRequired)
    #expect(client.presentation.setupState == .awaitingApproval)
    #expect(!client.presentation.canUpdateExtension)
    #expect(!client.presentation.hasActiveTunnel)
    await #expect(throws: CloudGatewayMacControllerFailure.busy) { try await client.userRequest(.prepareExtensionUpdate) }
    #expect(effects.activationIds == [id])
    effects.sendActivation(.restartRequired)
    _ = try await client.request(.snapshot)
    #expect(client.managedUpdate?.phase == .restartRequired)
    #expect(client.presentation.setupState == .awaitingRestart)
    #expect(effects.reconnects.isEmpty)
    client.shutdown()
    #expect(client.managedUpdate == nil)
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: id)).update?.phase == .restartRequired)
}

@MainActor
@Test func frontendOlderManagedStatusCannotUndoANewerUpdatePhase() async throws {
    let transport = FrontendTransport()
    let id = UUID()
    let approval = CloudGatewayMacManagedUpdateStatus(id: id, phase: .approvalRequired, target: controllerBoundaryBuild)
    let restart = CloudGatewayMacManagedUpdateStatus(id: id, phase: .restartRequired, target: controllerBoundaryBuild)
    transport.managedUpdate = approval
    let client = transport.make()
    defer { client.shutdown() }
    try await client.poll()
    #expect(client.managedUpdate == approval)
    transport.suspended = [.snapshot]
    let oldId = UUID()
    let old = Task { try await client.request(.snapshot, id: oldId) }
    try #require(await controllerBoundaryEventually { transport.pending[oldId] != nil })
    transport.suspended = []
    transport.managedUpdate = restart
    _ = try await client.request(.snapshot)
    try transport.resolve(oldId, with: transport.envelope(.init(state: controllerBoundaryState(), update: approval)))
    _ = try await old.value
    #expect(client.managedUpdate == restart)
    #expect(client.isSnapshotFresh)
}

@MainActor
@Test(arguments: [false, true])
func frontendManagedStatusIsClearedWhenTheControllerFailsOrHandsOff(draining: Bool) async throws {
    let transport = FrontendTransport()
    transport.managedUpdate = .init(id: UUID(), phase: .approvalRequired, target: controllerBoundaryBuild)
    let client = transport.make()
    defer { client.shutdown() }
    try await client.poll()
    #expect(client.managedUpdate?.phase == .approvalRequired)
    if draining {
        transport.installed = controllerBoundaryReplacement
        transport.lifecycleState = .draining
        try await client.poll()
        #expect(client.connectionState == .draining)
    } else {
        transport.unavailable = true
        await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await client.request(.snapshot) }
        #expect(client.connectionState == .reconnecting)
    }
    #expect(client.managedUpdate == nil)
    #expect(!client.isSnapshotFresh)
}


@MainActor
@Test func frontendOrdinaryOperationLookupDoesNotExposeARetainedManagedUpdate() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.makeManaged()
    effects.authenticated = true
    effects.performHandler = { _, done in done(.completed(warning: nil)); return true }
    let instanceId = UUID()
    let client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { request in
        var reply = await controller.handle(request)
        reply.instanceId = instanceId
        return reply
    }, bootstrap: {})
    defer { client.shutdown() }
    let updateId = UUID()
    #expect(try await client.userRequest(.update, id: updateId, allowDisconnect: false).update?.phase == .completed)
    #expect(client.managedUpdate?.id == updateId)
    let stopId = UUID()
    let stop = try await client.userRequest(.turnOff, id: stopId)
    #expect(stop.operation == .init(id: stopId, state: .completed))
    #expect(stop.update == nil)
    let ordinary = try await client.request(.operation, contextId: stopId)
    #expect(ordinary.operation?.id == stopId)
    #expect(ordinary.update == nil)
    #expect(client.managedUpdate == nil)
    let unknownId = UUID()
    let unknown = try await client.request(.operation, contextId: unknownId)
    #expect(unknown.operation == .init(id: unknownId, state: .unknown))
    #expect(unknown.update == nil)
    _ = try await client.request(.snapshot)
    #expect(client.managedUpdate?.id == updateId)
    let matching = try await client.request(.operation, contextId: updateId)
    #expect(matching.operation == .init(id: updateId, state: .completed))
    #expect(matching.update?.id == updateId)
}
