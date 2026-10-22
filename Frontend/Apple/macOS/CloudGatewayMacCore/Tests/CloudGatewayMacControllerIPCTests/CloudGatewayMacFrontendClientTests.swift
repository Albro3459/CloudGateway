import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

@MainActor
private final class FrontendTransport {
    var instanceId = UUID()
    var installed = controllerBoundaryBuild
    var lifecycleState = CloudGatewayMacControllerLifecycle.State.current
    var active = false
    var suspended: Set<CloudGatewayMacControllerRequest.Action> = []
    var pending: [UUID: CheckedContinuation<CloudGatewayMacControllerReply, any Error>] = [:]
    var requests: [CloudGatewayMacControllerRequest] = []
    var replacement: CloudGatewayMacBuildIdentity?
    var bootstraps = 0

    func make() -> CloudGatewayMacFrontendClient {
        let client = CloudGatewayMacFrontendClient(
            identity: controllerBoundaryBuild, transport: { try await self.send($0) },
            bootstrap: { self.bootstraps += 1 }
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
        if suspended.contains(request.action) {
            return try await withCheckedThrowingContinuation { pending[request.id] = $0 }
        }
        switch request.action {
        case .lifecycle:
            return envelope(.init(lifecycle: .init(running: controllerBoundaryBuild, installed: installed, state: lifecycleState)))
        case .snapshot: return envelope(.init(state: controllerBoundaryState(active: active)))
        case .status:
            return envelope(.init(status: .init(hasActiveTunnel: active, needsStop: active, observationAvailable: true)))
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
        await #expect(throws: CancellationError.self) { try await old.value }
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
