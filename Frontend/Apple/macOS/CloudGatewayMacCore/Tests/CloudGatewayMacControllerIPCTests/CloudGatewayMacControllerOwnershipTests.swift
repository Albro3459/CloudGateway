import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacControllerIPC

private final class OwnershipClock: Sendable {
    let elapsed = Mutex(Duration.zero)
}

// Connects a frontend client to a real orchestrator through the wire codec
@MainActor
private final class OwnershipHarness {
    let effects = ControllerOrchestratorEffects()
    let controller: CloudGatewayMacControllerOrchestrator
    var instanceId = UUID()
    let clock = OwnershipClock()
    var lostReplies: Set<CloudGatewayMacControllerRequest.Action> = []
    var sent: [CloudGatewayMacControllerRequest.Action] = []
    var onSleep: ((Duration) -> Void)?
    var heldReplies: Set<CloudGatewayMacControllerRequest.Action> = []
    var waiting: [CheckedContinuation<Void, Never>] = []
    var blocksSleeps = false
    private(set) var client: CloudGatewayMacFrontendClient!

    init() async throws {
        controller = try effects.make()
        try await effects.ready(controller)
        let clock = clock
        client = CloudGatewayMacFrontendClient(
            identity: controllerBoundaryBuild, transport: { try await self.send($0) }, bootstrap: {},
            now: { clock.elapsed.withLock { $0 } },
            sleep: { duration in
                try Task.checkCancellation()
                while await MainActor.run(body: { self.blocksSleeps }) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                clock.elapsed.withLock { $0 += duration }
                await MainActor.run { self.onSleep?(duration) }
            }
        )
        _ = try await client.send(.lifecycle)
    }

    private func send(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        sent.append(request.action)
        let build = controllerBoundaryBuild
        let data = try CloudGatewayMacControllerProtocol.encodeRequest(
            request, appVersion: build.version, appBuild: build.build, buildIdentity: build
        )
        let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(
            data, appVersion: build.version, appBuild: build.build, buildIdentity: build
        )
        let reply = CloudGatewayMacControllerProtocol.encodeReply(
            await controller.handle(decoded), appVersion: build.version, appBuild: build.build,
            instanceId: instanceId, action: decoded.action
        )
        if heldReplies.contains(request.action) { await withCheckedContinuation { waiting.append($0) } }
        if lostReplies.remove(request.action) != nil { throw CloudGatewayMacControllerFailure.timeout }
        return try CloudGatewayMacControllerProtocol.decodeReply(
            reply, appVersion: build.version, appBuild: build.build, action: request.action
        )
    }
}

@MainActor
@Test func ownershipOutputFailureBeforeConfirmationNeverReleasesWork() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    let reserved = try await harness.client.send(.connect, id: id, identifier: "account/region/client")
    #expect(reserved.operation == .init(id: id, state: .accepted))
    #expect(reserved.outcome == nil)
    // The caller could not write the operation ID, so it never confirms
    harness.effects.now.addTimeInterval(30)
    let expired = try await harness.client.send(.operation, contextId: id)
    #expect(expired.operation?.state == .unknown)
    #expect(expired.outcome == .expired)
    #expect(try await harness.client.confirm(id).operation?.state == .unknown)
    #expect(harness.effects.performed.isEmpty)
}

@MainActor
@Test func ownershipLostConfirmationIsUncertainAndNeverReplayed() async throws {
    let harness = try await OwnershipHarness()
    harness.effects.active = true
    for action in [CloudGatewayMacControllerRequest.Action.connect, .turnOff] {
        harness.lostReplies = [.confirmOperation]
        let id = UUID()
        await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) {
            try await harness.client.request(action, id: id, identifier: action == .connect ? "account/region/client" : nil)
        }
        #expect(harness.sent.filter { $0 == action }.count == 1)
        #expect(harness.sent.filter { $0 == .confirmOperation }.count == (action == .connect ? 1 : 2))
        #expect(harness.effects.performed.last == action)
        harness.effects.completion?(action == .connect
            ? .startRequested(identifier: "account/region/client", warning: nil) : .completed(warning: nil))
        let recovered = try await harness.client.awaitOutcome(of: id, timeout: .seconds(1))
        #expect(recovered.operation?.state == .completed)
    }
    #expect(harness.effects.performed == [.connect, .turnOff])
}

@MainActor
@Test func ownershipCallerTimeoutAndCancellationOnlyDetach() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    #expect(try await harness.client.send(.connect, id: id, identifier: "account/region/client").operation?.state == .accepted)
    #expect(try await harness.client.confirm(id).operation?.state == .running)
    await #expect(throws: CloudGatewayMacControllerFailure.timeout) {
        try await harness.client.awaitOutcome(of: id, timeout: .seconds(2))
    }
    #expect(harness.clock.elapsed.withLock { $0 } == .seconds(2))
    let waiting = Task { try await harness.client.awaitOutcome(of: id, timeout: .seconds(60)) }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }

    harness.effects.completion?(.startRequested(identifier: "account/region/client", warning: nil))
    let result = try await harness.client.send(.operation, contextId: id)
    #expect(result.operation?.state == .completed)
    #expect(result.outcome == .startRequested(identifier: "account/region/client", warning: nil))
    #expect(harness.effects.performed == [.connect])
    #expect(Set(harness.sent) == [.lifecycle, .connect, .confirmOperation, .operation])
}

@MainActor
@Test func ownershipAwaitReturnsTheTypedOutcomeOnceWorkFinishes() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id)
    _ = try await harness.client.confirm(id)
    harness.onSleep = { _ in harness.effects.completion?(.failed(.selectionUnavailable)) }
    let reply = try await harness.client.awaitOutcome(of: id, timeout: .seconds(10))
    #expect(reply.operation == .init(id: id, state: .failed, failure: .commandFailed))
    #expect(reply.outcome == .failed(.selectionUnavailable))
    #expect(harness.clock.elapsed.withLock { $0 } == .milliseconds(500))
}

@MainActor
@Test func ownershipUnknownLookupAndUncertainHistoryStillReportObservedStatus() async throws {
    let harness = try await OwnershipHarness()
    harness.effects.active = true
    let unknown = try await harness.client.send(.operation, contextId: UUID())
    #expect(unknown.error == nil)
    #expect(unknown.operation?.state == .unknown)
    #expect(unknown.outcome == nil)
    #expect(unknown.status?.hasActiveTunnel == true)

    let id = UUID()
    _ = try await harness.client.send(.turnOff, id: id)
    _ = try await harness.client.confirm(id)
    harness.effects.completion?(.unknown)
    let status = try await harness.client.send(.status)
    #expect(status.error == nil)
    #expect(status.status?.needsStop == true)
    #expect(status.operation == .init(id: id, state: .unknown))
    #expect(status.outcome == .unknown)
}

@MainActor
@Test func ownershipRestartedControllerMakesConfirmationUncertainWithoutReplay() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id, identifier: "account/region/client")
    harness.instanceId = UUID()
    await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) { try await harness.client.confirm(id) }
    await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) {
        try await harness.client.awaitOutcome(of: id, timeout: .seconds(1))
    }
    await #expect(throws: CloudGatewayMacControllerFailure.unavailable) { try await harness.client.send(.status) }
    #expect(harness.effects.performed == [.connect])
    #expect(harness.sent.filter { $0 == .connect }.count == 1)
    #expect(harness.client.connectionState == .reconnecting)
}

@MainActor
@Test func ownershipGenerationChangeDuringConfirmationIsUncertainNotCancelled() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id, identifier: "account/region/client")
    harness.heldReplies = [.confirmOperation]
    let confirming = Task { try await harness.client.confirm(id) }
    try #require(await controllerBoundaryEventually { harness.waiting.count == 1 })
    harness.heldReplies = []
    harness.instanceId = UUID()
    _ = try await harness.client.send(.lifecycle)
    harness.waiting.removeFirst().resume()
    await #expect(throws: CloudGatewayMacControllerFailure.outcomeUnknown) { try await confirming.value }
    #expect(harness.effects.performed == [.connect])
    #expect(harness.sent.filter { $0 == .confirmOperation }.count == 1)
}

@MainActor
@Test func ownershipCallerDeadlineBoundsAHeldLookup() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id)
    _ = try await harness.client.confirm(id)
    harness.heldReplies = [.operation]
    await #expect(throws: CloudGatewayMacControllerFailure.timeout) {
        try await harness.client.awaitOutcome(of: id, timeout: .seconds(5))
    }
    #expect(harness.clock.elapsed.withLock { $0 } == .seconds(5))

    harness.blocksSleeps = true
    let waiting = Task { try await harness.client.awaitOutcome(of: id, timeout: .seconds(5)) }
    try #require(await controllerBoundaryEventually { harness.waiting.count == 2 })
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(harness.clock.elapsed.withLock { $0 } == .seconds(5))
    harness.blocksSleeps = false
    harness.heldReplies = []
    harness.waiting.forEach { $0.resume() }
    harness.waiting = []
    harness.effects.completion?(.startRequested(identifier: "account/region/client", warning: nil))
    #expect(try await harness.client.awaitOutcome(of: id, timeout: .seconds(5)).operation?.state == .completed)
    #expect(harness.effects.performed == [.connect])
}

@MainActor
@Test func ownershipAwaitingAnUnconfirmedReservationEndsAtItsExpiry() async throws {
    let harness = try await OwnershipHarness()
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id, identifier: "account/region/client")
    harness.onSleep = { duration in
        harness.effects.now.addTimeInterval(Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }
    let reply = try await harness.client.awaitOutcome(of: id, timeout: .seconds(60))
    #expect(reply.operation == .init(id: id, state: .unknown))
    #expect(reply.outcome == .expired)
    #expect(harness.clock.elapsed.withLock { $0 } == .seconds(30))
    #expect(harness.effects.performed.isEmpty)
}

@MainActor
@Test func ownershipMenuRequestKeepsOneReservationAndConfirmation() async throws {
    let harness = try await OwnershipHarness()
    let reply = try await harness.client.request(.connect, identifier: "account/region/client")
    #expect(reply.operation?.state == .running)
    #expect(harness.sent == [.lifecycle, .connect, .confirmOperation])
    #expect(harness.effects.performed == [.connect])
    harness.effects.completion?(.alreadyActive(identifier: "account/region/client", warning: nil))
}

@MainActor
@Test func controllerOrchestratorIdleExitWaitsForTheRetainedResultWindow() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.now.addTimeInterval(900)
    #expect(controller.canExit)
    let stop = controllerBoundaryRequest(.turnOff)
    _ = await controller.handle(stop)
    _ = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id))
    effects.now.addTimeInterval(901)
    #expect(!controller.canExit)
    effects.completion?(.completed(warning: nil))
    let finished = effects.now
    // Completion retains its recovery window even after user activity has expired
    for elapsed in [60.0, 300, 599] {
        effects.now = finished.addingTimeInterval(elapsed)
        #expect(!controller.canExit)
    }
    effects.now = finished.addingTimeInterval(600)
    #expect(controller.canExit)
    // Passive lookup does not renew activity after the result expires
    #expect(await controller.handle(controllerBoundaryRequest(.operation, contextId: stop.id)).operation?.state == .unknown)
    #expect(controller.canExit)
    _ = await controller.handle(controllerBoundaryRequest(.userActivity))
    effects.now = finished.addingTimeInterval(1499)
    #expect(!controller.canExit)
    effects.now = finished.addingTimeInterval(1500)
    #expect(controller.canExit)
}

@MainActor
@Test func controllerOrchestratorBindsReservedAccountWorkToItsSession() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    try await effects.ready(controller)
    let bare = CloudGatewayMacControllerRequest(
        action: .connect, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(await controller.handle(bare).operation?.state == .accepted)
    effects.sessions.changeAccount(to: "account")
    let rejected = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: bare.id))
    #expect(rejected.operation == .init(id: bare.id, state: .failed, failure: .rejected))
    #expect(rejected.outcome == .failed(.signInRequired))
    #expect(effects.performed.isEmpty)

    var executed: [String?] = []
    effects.performHandler = { request, _ in executed.append(request.identifier); return true }
    let next = CloudGatewayMacControllerRequest(
        action: .connect, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(await controller.handle(next).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: next.id)).operation?.state == .running)
    #expect(executed == [nil])
    effects.completion?(.startRequested(identifier: "account/region/client", warning: nil))
}

@MainActor
@Test func controllerOrchestratorAwaitsCorrelatedRefreshWhileStatusAndStopStayAvailable() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.active = true
    effects.holdsRefresh = true
    let controller = try effects.make()
    try await effects.ready(controller)
    let refresh = Task { await controller.handle(controllerBoundaryRequest(.awaitRefresh)) }
    try #require(await controllerBoundaryEventually { effects.holdRefresh != nil })
    #expect(await controller.handle(controllerBoundaryRequest(.status)).status?.hasActiveTunnel == true)
    let stop = controllerBoundaryRequest(.turnOff)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id)).operation?.state == .running)
    #expect(effects.performed == [.turnOff])
    effects.completion?(.completed(warning: nil))
    #expect(!controller.canExit)
    effects.refreshResult = .unavailable
    effects.holdRefresh?.resume()
    let reply = await refresh.value
    #expect(reply.refresh == .unavailable)
    #expect(reply.state != nil)
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        reply, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        instanceId: UUID(), action: .awaitRefresh
    )
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(
        data, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build, action: .awaitRefresh
    ).refresh == .unavailable)
    #expect(effects.refreshes == 1)
}

@MainActor
@Test func controllerOrchestratorRejectsAwaitedRefreshWhileDraining() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    try await effects.ready(controller)
    effects.installed = controllerBoundaryReplacement
    await controller.tick()
    let reply = await controller.handle(controllerBoundaryRequest(.awaitRefresh))
    #expect(reply.error == .busy)
    #expect(reply.refresh == nil)
    #expect(effects.refreshes == 0)
}

@MainActor
@Test func controllerOrchestratorReportsTimedOutRefreshWithoutCancellingIt() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.holdsRefresh = true
    effects.refreshTimeout = .zero
    let controller = try effects.make()
    try await effects.ready(controller)
    let reply = await controller.handle(controllerBoundaryRequest(.awaitRefresh))
    #expect(reply.refresh == .timedOut)
    #expect(reply.state != nil)
    try #require(await controllerBoundaryEventually { effects.holdRefresh != nil })
    effects.holdRefresh?.resume()
}

@Test func refreshResultsOnlyTravelWithAwaitedRefreshState() throws {
    let build = controllerBoundaryBuild
    for (reply, action) in [
        (CloudGatewayMacControllerReply(state: controllerContractState(), refresh: .refreshed), CloudGatewayMacControllerRequest.Action.snapshot),
        (.init(refresh: .refreshed), .awaitRefresh),
        (.init(state: controllerContractState()), .awaitRefresh),
        (.init(status: .init(hasActiveTunnel: false, needsStop: false, observationAvailable: true), refresh: .skipped), .status)
    ] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            reply, appVersion: build.version, appBuild: build.build, instanceId: UUID(), action: action
        )
        let decoded = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: build.version, appBuild: build.build, action: action)
        #expect(decoded.error == .invalidRequest)
        #expect(decoded.refresh == nil)
    }
    for result in [CloudGatewayMacRefreshResult.refreshed, .unavailable, .denied, .signInRequired, .skipped, .superseded, .timedOut] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            .init(state: controllerContractState(), refresh: result), appVersion: build.version, appBuild: build.build,
            instanceId: UUID(), action: .awaitRefresh
        )
        #expect(try CloudGatewayMacControllerProtocol.decodeReply(
            data, appVersion: build.version, appBuild: build.build, action: .awaitRefresh
        ).refresh == result)
    }
}
