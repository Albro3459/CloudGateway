import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

@MainActor
private final class RemovalFrontendHarness {
    let effects = ControllerOrchestratorEffects()
    let controller: CloudGatewayMacControllerOrchestrator
    let instanceId = UUID()
    private(set) var requests: [CloudGatewayMacControllerRequest] = []
    private(set) var lookups = 0
    var immediateOutcome: CloudGatewayMacCommandOutcome?
    var delayedOutcome: CloudGatewayMacCommandOutcome?
    var completeAtLookup = 1
    var loseConfirmation = false
    var admissionError: CloudGatewayMacControllerFailure?
    var lookupError = false
    var changeSessionBeforeLookup = false
    var client: CloudGatewayMacFrontendClient!

    init() async throws {
        controller = try effects.make()
        effects.sessions.changeAccount(to: "account")
        try await effects.ready(controller)
        effects.performHandler = { [weak self] _, completion in
            if let outcome = self?.immediateOutcome { completion(outcome) }
            return true
        }
        client = CloudGatewayMacFrontendClient(identity: controllerBoundaryBuild, transport: { [self] request in
            requests.append(request)
            if request.action == .removeClient, let admissionError { return try envelope(.init(error: admissionError), action: request.action) }
            if request.action == .operation {
                lookups += 1
                if lookupError { throw CloudGatewayMacControllerFailure.unavailable }
                if changeSessionBeforeLookup { effects.sessions.changeAccount(to: "other") }
                if lookups == completeAtLookup, let delayedOutcome { effects.completion?(delayedOutcome) }
            }
            let reply = await controller.handle(request)
            if request.action == .confirmOperation, loseConfirmation { throw CloudGatewayMacControllerFailure.unavailable }
            return try envelope(reply, action: request.action)
        }, bootstrap: {})
        try await client.poll()
    }

    private func envelope(_ reply: CloudGatewayMacControllerReply,
                          action: CloudGatewayMacControllerRequest.Action) throws -> CloudGatewayMacControllerReply {
        let build = controllerBoundaryBuild
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            reply, appVersion: build.version, appBuild: build.build, instanceId: instanceId, action: action
        )
        return try CloudGatewayMacControllerProtocol.decodeReply(
            data, appVersion: build.version, appBuild: build.build, action: action
        )
    }

    func remove(id: UUID = UUID(), timeout: Duration = .seconds(5)) async throws -> CloudGatewayMacCommandOutcome {
        try await client.removeClient(identifier: "account/region/client", accountId: "account", id: id, timeout: timeout)
    }
}

@MainActor
@Test func removalFrontendSubmitsTheFullIdentifierAndKeepsImmediateTypedFailure() async throws {
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    harness.immediateOutcome = .failed(.clientActive)
    let id = UUID()
    let outcome = try await harness.remove(id: id)
    #expect(outcome == .failed(.clientActive))
    #expect(harness.client.message(forRemoval: outcome) == "Disconnect this config and wait for it to stop before deleting it")
    let submission = try #require(harness.requests.first { $0.action == .removeClient })
    #expect(submission.identifier == "account/region/client")
    #expect(submission.id == id)
    #expect(submission.regionId == nil)
    #expect(submission.clientName == nil)
    #expect(harness.requests.filter { $0.action == .confirmOperation }.map(\.contextId) == [id])
    #expect(harness.effects.performed == [.removeClient])
    #expect(harness.lookups == 0)
}

@MainActor
@Test func removalFrontendWaitsForDelayedTypedFailureWithTheSameOperation() async throws {
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    harness.delayedOutcome = .failed(.clientActive)
    harness.completeAtLookup = 2
    let id = UUID()
    let task = Task { try await harness.remove(id: id) }
    try #require(await controllerBoundaryEventually { harness.lookups == 1 })
    #expect(harness.effects.performed == [.removeClient])
    #expect(!harness.client.presentation.canRemoveClient)
    let outcome = try await task.value
    #expect(outcome == .failed(.clientActive))
    #expect(harness.lookups == 2)
    #expect(harness.requests.filter { $0.action == .operation }.allSatisfy { $0.contextId == id })
    #expect(harness.requests.filter { $0.action == .removeClient }.count == 1)
    #expect(harness.requests.filter { $0.action == .confirmOperation }.count == 1)
}

@MainActor
@Test func removalFrontendPreservesCompletedRemovalWarnings() async throws {
    for (warning, message) in [
        (nil as CloudGatewayMacCommandWarning?, "Client was removed"),
        (.localCleanupIncomplete, "Client was removed, but its local VPN profile could not be cleaned up. Choose Refresh"),
        (.inventoryNotRefreshed, "Client was removed, but the client list could not refresh. Choose Refresh")
    ] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        harness.immediateOutcome = .completed(warning: warning)
        let outcome = try await harness.remove()
        #expect(outcome == .completed(warning: warning))
        #expect(harness.client.message(forRemoval: outcome) == message)
        #expect(harness.effects.performed == [.removeClient])
    }
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    harness.delayedOutcome = .completed(warning: .localCleanupIncomplete)
    #expect(try await harness.remove() == .completed(warning: .localCleanupIncomplete))
    #expect(harness.lookups == 1)
}

@MainActor
@Test func removalFrontendRecoversLostConfirmationWithoutResendingRemovalOrConfirmation() async throws {
    for outcome in [CloudGatewayMacCommandOutcome.failed(.clientActive), .completed(warning: .inventoryNotRefreshed)] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        harness.loseConfirmation = true
        harness.delayedOutcome = outcome
        let id = UUID()
        #expect(try await harness.remove(id: id) == outcome)
        #expect(harness.requests.filter { $0.action == .removeClient }.map(\.id) == [id])
        #expect(harness.requests.filter { $0.action == .confirmOperation }.map(\.contextId) == [id])
        #expect(harness.requests.filter { $0.action == .operation }.map(\.contextId) == [id])
        #expect(harness.effects.performed == [.removeClient])
    }
}

@MainActor
@Test func removalFrontendPreservesDefiniteAdmissionErrorsWithoutOutcomeLookup() async throws {
    for error in [CloudGatewayMacControllerFailure.busy, .rejected, .invalidRequest, .incompatibleVersion] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        harness.admissionError = error
        await #expect(throws: error) { try await harness.remove() }
        #expect(harness.lookups == 0)
        #expect(harness.requests.filter { $0.action == .confirmOperation }.isEmpty)
        #expect(harness.effects.performed.isEmpty)
    }
}

@MainActor
@Test func removalFrontendTreatsTimeoutUnknownLookupFailureAndChangedSessionAsUncertain() async throws {
    for scenario in ["timeout", "unknown", "lookupFailure", "sessionChanged"] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        switch scenario {
        case "unknown": harness.immediateOutcome = .unknown
        case "lookupFailure": harness.lookupError = true
        case "sessionChanged":
            harness.delayedOutcome = .completed(warning: nil)
            harness.changeSessionBeforeLookup = true
        default: break
        }
        let outcome = try await harness.remove(timeout: .milliseconds(10))
        #expect(outcome == .unknown)
        #expect(harness.client.message(forRemoval: outcome)
            == "Could not confirm whether the client was removed. Refresh the client list before trying again")
        #expect(harness.requests.filter { $0.action == .removeClient }.count == 1)
        #expect(harness.requests.filter { $0.action == .confirmOperation }.count == 1)
        #expect(harness.effects.performed == [.removeClient])
    }
}

@MainActor
@Test func removalFrontendRejectsChangedAccountActiveSelectionStaleSnapshotAndSettlingSession() async throws {
    for scenario in ["account", "active", "stale", "settling"] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        switch scenario {
        case "account":
            await #expect(throws: CloudGatewayMacControllerFailure.rejected) {
                try await harness.client.removeClient(identifier: "account/region/client", accountId: "other")
            }
        case "active":
            harness.effects.active = true
            _ = try await harness.client.request(.snapshot)
            await #expect(throws: CloudGatewayMacControllerFailure.rejected) { try await harness.remove() }
        case "stale":
            _ = try await harness.client.request(.status)
            await #expect(throws: CloudGatewayMacControllerFailure.rejected) { try await harness.remove() }
        default:
            harness.effects.snapshotState = controllerBoundaryState(authSettling: true)
            _ = try await harness.client.request(.snapshot)
            await #expect(throws: CloudGatewayMacControllerFailure.rejected) { try await harness.remove() }
        }
        #expect(harness.requests.filter { $0.action == .removeClient }.isEmpty)
        #expect(harness.effects.performed.isEmpty)
    }
}

@MainActor
@Test func removalFrontendCancellationDetachesWithoutReplayingTheRemoval() async throws {
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    let task = Task { try await harness.remove() }
    try #require(await controllerBoundaryEventually { harness.lookups == 1 })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(harness.requests.filter { $0.action == .removeClient }.count == 1)
    #expect(harness.requests.filter { $0.action == .confirmOperation }.count == 1)
    #expect(harness.effects.performed == [.removeClient])
    harness.effects.completion?(.completed(warning: nil))
}

@MainActor
@Test func removalFrontendShowsFixedSafeAccessNetworkAndGenericFailures() async throws {
    for (failure, message) in [
        (CloudGatewayMacCommandFailure.accessDenied, "Account access was denied. Sign in again after access is restored"),
        (.networkUnavailable, "Unable to reach CloudGateway. Choose Refresh before trying again"),
        (.signInRequired, "Your session changed. Sign in and select the client again"),
        (.busy, "Another operation is in progress. Wait for it to finish and try again"),
        (.configUnavailable, "The client list changed. Choose Refresh and select the client again"),
        (.internalError, "Client could not be removed. Refresh before trying again")
    ] {
        let harness = try await RemovalFrontendHarness()
        defer { harness.client.shutdown() }
        harness.immediateOutcome = .failed(failure)
        let outcome = try await harness.remove()
        #expect(outcome == .failed(failure))
        #expect(harness.client.message(forRemoval: outcome) == message)
    }
}

@MainActor
@Test func removalFrontendBlocksRemovalWhileCreationIsReservedOrRunning() async throws {
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    harness.effects.active = true
    harness.effects.holdCreation = true
    let prepared = try #require(try await harness.client.request(.prepareClient).creation)
    let id = UUID()
    #expect(try await harness.client.send(.createClient, id: id, regionId: "region", clientName: "Mac",
                                         contextId: prepared.id).operation?.state == .accepted)
    for confirmed in [false, true] {
        if confirmed { #expect(try await harness.client.confirm(id).operation?.state == .running) }
        for action in [CloudGatewayMacControllerRequest.Action.snapshot, .operation] {
            _ = try await harness.client.request(action, contextId: action == .operation ? id : nil)
            #expect(!harness.client.presentation.canRemoveClient)
            #expect(harness.client.presentation.canTurnOff)
            await #expect(throws: CloudGatewayMacControllerFailure.rejected) { try await harness.remove() }
        }
    }
    #expect(harness.requests.filter { $0.action == .removeClient }.isEmpty)
    #expect(harness.effects.submissions == 1)
    harness.effects.creationCompletion?(.completed(warning: nil))
    _ = try await harness.client.request(.snapshot)
    #expect(harness.client.presentation.canRemoveClient)
}

@MainActor
@Test func removalAvailabilityFollowsOwnerAdmissionAcrossPendingRunningAndExtensionWork() async throws {
    let harness = try await RemovalFrontendHarness()
    defer { harness.client.shutdown() }
    #expect(harness.client.presentation.canRemoveClient)
    harness.effects.activationPending = true
    _ = try await harness.client.request(.snapshot)
    #expect(!harness.client.presentation.canRemoveClient)
    harness.effects.activationPending = false
    harness.effects.hasPendingWork = true
    _ = try await harness.client.request(.snapshot)
    #expect(!harness.client.presentation.canRemoveClient)
    harness.effects.hasPendingWork = false
    let id = UUID()
    _ = try await harness.client.send(.connect, id: id, identifier: "account/region/client")
    #expect(!harness.client.presentation.canRemoveClient)
    _ = try await harness.client.confirm(id)
    _ = try await harness.client.request(.snapshot)
    #expect(!harness.client.presentation.canRemoveClient)
    harness.effects.completion?(.completed(warning: nil))
    _ = try await harness.client.request(.snapshot)
    #expect(harness.client.presentation.canRemoveClient)
}
