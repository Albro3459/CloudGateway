import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

private let appVersion = "1.2.0"
private let appBuild = "42"
private let identifier = "account/region/client"

// CLI exits 2 and 130 come from parsing and interruption in the frontend, so they have no domain outcome
private let outcomesByExit: [(exit: Int, outcomes: [CloudGatewayMacCommandOutcome])] = [
    (0, [.startRequested(identifier: identifier, warning: nil),
         .alreadyActive(identifier: identifier, warning: .selectionNotSaved),
         .completed(warning: nil), .completed(warning: .inventoryNotRefreshed), .completed(warning: .localCleanupIncomplete)]),
    (1, [.failed(.internalError)]),
    (3, [.failed(.signInRequired), .failed(.accessDenied)]),
    (4, [.failed(.setupRequired), .failed(.credentialsUnavailable), .failed(.incompatibleVersion), .failed(.clientActive)]),
    (5, [.failed(.configUnavailable)]),
    (6, [.failed(.networkUnavailable)]),
    (7, [.failed(.busy)]),
    (8, [.failed(.stopTimedOut)]),
    (9, [.failed(.vpnFailed)]),
    (10, [.unknown, .expired])
]

@Test func commandOutcomesCoverEveryCLIExitCategoryAcrossBothReplyKinds() throws {
    var encoded = Set<String>()
    for (exit, outcomes) in outcomesByExit {
        for outcome in outcomes {
            let operation = CloudGatewayMacControllerOperation(id: UUID(), state: outcome.state)
            #expect(operation.state == (exit == 0 ? .completed : exit == 8 || exit == 10 ? .unknown : .failed))
            for (reply, action) in [
                (CloudGatewayMacControllerReply(operation: operation, outcome: outcome), CloudGatewayMacControllerRequest.Action.operation),
                (.init(operation: operation, outcome: outcome), .removeClient),
                (.init(state: controllerContractState(), operation: operation, outcome: outcome), .snapshot)
            ] {
                let decoded = try outcomeRoundTrip(reply, action: action)
                #expect(decoded.error == nil)
                #expect(decoded.outcome == outcome)
                #expect(decoded.operation == operation)
            }
            encoded.insert(String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self))
        }
    }
    #expect(encoded.count == outcomesByExit.flatMap(\.outcomes).count)
    // Usage errors and malformed controller replies are typed before any domain outcome exists
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.encodeRequest(
            .init(action: .connect, identifier: "account/region"), appVersion: appVersion, appBuild: appBuild
        )
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(Data("{".utf8), appVersion: appVersion, appBuild: appBuild)
    }
}

@Test func commandOutcomesRequireMatchingOperationBuildAndAccount() throws {
    let started = CloudGatewayMacCommandOutcome.startRequested(identifier: identifier, warning: nil)
    let completed = CloudGatewayMacControllerOperation(id: UUID(), state: .completed)
    for (reply, action) in [
        (CloudGatewayMacControllerReply(outcome: started), CloudGatewayMacControllerRequest.Action.operation),
        (.init(operation: .init(id: UUID(), state: .failed), outcome: started), .operation),
        (.init(operation: .init(id: UUID(), state: .running), outcome: .unknown), .operation),
        (.init(operation: completed, outcome: .startRequested(identifier: "account/region", warning: nil)), .operation),
        (.init(state: controllerContractState(), operation: completed,
               outcome: .alreadyActive(identifier: "other/region/client", warning: nil)), .snapshot),
        (.init(operation: completed, outcome: started, lifecycle: nil), .lifecycle)
    ] {
        let decoded = try outcomeRoundTrip(reply, action: action)
        #expect(decoded.error == .invalidRequest)
        #expect(decoded.outcome == nil)
    }
    var raw = CloudGatewayMacControllerReply(error: .busy)
    raw.appVersion = appVersion
    raw.appBuild = appBuild
    raw.instanceId = UUID()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
    object["outcome"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudGatewayMacCommandOutcome.unknown))
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            JSONSerialization.data(withJSONObject: object), appVersion: appVersion, appBuild: appBuild
        )
    }

    // Compatible control replies from another build keep the operation but cannot carry outcomes
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(operation: completed, outcome: started), appVersion: appVersion, appBuild: appBuild,
        instanceId: UUID(), action: .operation
    )
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: "43", action: .operation)
    }
    let compatible = CloudGatewayMacControllerProtocol.encodeReply(
        .init(operation: completed), appVersion: appVersion, appBuild: appBuild, instanceId: UUID(), action: .operation
    )
    let decoded = try CloudGatewayMacControllerProtocol.decodeReply(compatible, appVersion: appVersion, appBuild: "43", action: .operation)
    #expect(decoded.operation == completed)
    #expect(decoded.protocolVersion == CloudGatewayMacControllerProtocol.compatibleProtocolVersion)
}

@Test func controllerStateCarriesInventoryFreshnessAndInstallationMetadata() throws {
    let state = controllerContractState()
    let reply = try outcomeRoundTrip(.init(state: state), action: .snapshot)
    let decoded = try #require(reply.state)
    #expect(decoded == state)
    #expect(decoded.access == .online)
    #expect(decoded.credentials == .available)
    #expect(decoded.profilesObservedAt == Date(timeIntervalSince1970: 1_000))
    let client = try #require(decoded.clients.first)
    #expect(client.internalIp == "10.0.0.2")
    #expect(client.clientId == "client")
    #expect(client.connectionUrl == nil)
    #expect(CloudGatewayMacControllerProtocol.validIPv4("0.0.0.0"))
    #expect(CloudGatewayMacControllerProtocol.validIPv4("100.64.10.255"))
    #expect(client.cloudState == .active)
    #expect(client.eligibility == .eligible)
    #expect(client.isEligible)
    #expect(client.isInstalled)
    #expect(client.source == .cloud)
    #expect(client.readAt == Date(timeIntervalSince1970: 900))
    #expect(client.updatedAt == Date(timeIntervalSince1970: 800))
    #expect(reply.protocolVersion == CloudGatewayMacControllerProtocol.protocolVersion)

    for address in ["10.0.0.256", "fd00::1", "10.0.0", " 10.0.0.2", "010.000.000.001", "10.0.0.02",
                    "10.0.0.2/", "10.0.0.2/33", "10.0.0.2/-1", "10.0.0.2/+1", "10.0.0.2/1.0",
                    "10.0.0.2/ 1", "10.0.0.2/32/1", "10.0.0.2/３２", "10.0.0.256/32", "10.0.0.2/032"] {
        let snapshot = outcomeSnapshot(internalIp: address)
        #expect(CloudGatewayMacControllerState(snapshot: snapshot, setupState: .ready, canUpdateExtension: false)
            .clients.first?.internalIp == nil)
        try outcomeExpectRejectedClient { $0["internalIp"] = address }
    }
    try outcomeExpectRejectedClient { $0["isInstalled"] = false }
    try outcomeExpectRejectedClient { $0["eligibility"] = "maybe" }
    try outcomeExpectRejectedClient { $0["cloudState"] = "deleted" }
    try outcomeExpectRejectedClient { $0["source"] = "disk" }
    try outcomeExpectRejectedClient { $0.removeValue(forKey: "readAt") }
    try outcomeExpectRejectedClient { $0["clientId"] = "another-client" }
    for endpoint in ["", "wg.example.com\n", String(repeating: "x", count: 1025)] {
        try outcomeExpectRejectedClient { $0["connectionUrl"] = endpoint }
    }
    try outcomeExpectRejectedState { object in
        object["installedIdentifiers"] = []
        var clients = try #require(object["clients"] as? [[String: Any]])
        clients[0]["isInstalled"] = false
        clients[0]["source"] = "cache"
        object["clients"] = clients
    }
    try outcomeExpectRejectedState { $0["access"] = "authorized" }
    try outcomeExpectRejectedState { $0["credentials"] = "unavailable" }
}

@Test func controllerMapsValidTunnelCIDRToBareIPv4WithoutRelaxingWireValidation() throws {
    for prefix in 0...32 {
        let address = "10.0.0.2/\(prefix)"
        let state = CloudGatewayMacControllerState(
            snapshot: outcomeSnapshot(internalIp: address), setupState: .ready, canUpdateExtension: false
        )
        let reply = try outcomeRoundTrip(.init(state: state), action: .snapshot)
        #expect(reply.state?.clients.first?.internalIp == "10.0.0.2")
        #expect(!CloudGatewayMacControllerProtocol.validIPv4(address))
        try outcomeExpectRejectedClient { $0["internalIp"] = address }
    }
}

@Test func fullInventoryWithRowMetadataFitsTheReplyBound() throws {
    let accountId = String(repeating: "U", count: 28)
    let clients = (0..<4096).map { index in
        CloudGatewayMacClientMetadata(
            identifier: "\(accountId)/us-central1/\(String(format: "00000000-0000-4000-8000-%012d", index))", regionId: "us-central1",
            regionName: "US Central", regionOrder: 1, clientName: "Work MacBook Pro \(index)",
            ownerLabel: "someone@example.com", internalIp: "10.100.200.250",
            connectionUrl: Array(repeating: String(repeating: "a", count: 63), count: 3).joined(separator: ".") + "." + String(repeating: "b", count: 61),
            cloudState: .active, eligibility: .eligible,
            isInstalled: false, source: .cloud, readAt: Date(timeIntervalSinceReferenceDate: 782_000_000.123456),
            updatedAt: Date(timeIntervalSinceReferenceDate: 782_000_000.123456), status: .disconnected
        )
    }
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(
            accountId: accountId, hasRetainedSession: true, accessAuthorized: true, access: .online, credentials: .available,
            inventoryFreshness: .current, installedIdentifiers: [], observedProfiles: [], observationIsFresh: true,
            profilesObservedAt: Date(), commandInFlight: false, clients: clients
        ),
        lastSelectedIdentifier: nil, browserState: .signedIn(AuthenticatedUser(uid: accountId, email: nil)),
        isRestoringSession: false, isAuthSettling: false, canCreateClient: true, errorMessage: nil
    )
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(state: .init(snapshot: snapshot, setupState: .ready, canUpdateExtension: false)),
        appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    #expect(data.count > 2 * 1024 * 1024)
    #expect(data.count <= CloudGatewayMacControllerProtocol.replyBytes)
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild).state?.clients.count == 4096)
}

@Test func controllerEndpointMetadataIsBoundedAndSafeForDisplay() throws {
    for (raw, expected) in [
        ("wg.\nregion\u{1B}.example.com", "wg. region .example.com"),
        (String(repeating: "🙂", count: 300), String(repeating: "🙂", count: 256)),
        ("192.0.2.7", "192.0.2.7")
    ] {
        let state = CloudGatewayMacControllerState(
            snapshot: outcomeSnapshot(internalIp: "10.0.0.2", connectionUrl: raw),
            setupState: .ready, canUpdateExtension: false
        )
        let reply = try outcomeRoundTrip(.init(state: state), action: .snapshot)
        #expect(reply.error == nil)
        #expect(reply.state?.clients.first?.connectionUrl == expected)
    }
}

@Test func operationDetailsRequireMatchingBuildAndOneConsistentObservation() throws {
    let state = controllerContractState()
    let operation = CloudGatewayMacControllerOperation(id: UUID(), state: .unknown)
    let reply = CloudGatewayMacControllerReply(state: state, status: state.status, operation: operation)
    let decoded = try outcomeRoundTrip(reply, action: .operation)
    #expect(decoded.state == state)
    #expect(decoded.status == state.status)
    #expect(decoded.operation == operation)
    #expect(decoded.state?.profilesObservedAt == Date(timeIntervalSince1970: 1_000))
    #expect(decoded.state?.observedProfiles.first?.identifier == identifier)
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        reply, appVersion: appVersion, appBuild: appBuild, instanceId: UUID(), action: .operation
    )
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: "43", action: .operation)
    }
    for (invalid, action) in [
        (CloudGatewayMacControllerReply(state: state, operation: operation), CloudGatewayMacControllerRequest.Action.operation),
        (.init(state: state, status: .init(hasActiveTunnel: false, needsStop: false, observationAvailable: true, phase: .disconnected)), .operation),
        (reply, .status), (reply, .confirmOperation), (reply, .turnOff)
    ] {
        #expect(try outcomeRoundTrip(invalid, action: action).error == .invalidRequest)
    }
}

private func outcomeRoundTrip(
    _ reply: CloudGatewayMacControllerReply, action: CloudGatewayMacControllerRequest.Action
) throws -> CloudGatewayMacControllerReply {
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        reply, appVersion: appVersion, appBuild: appBuild, instanceId: UUID(), action: action
    )
    return try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild, action: action)
}

private func outcomeSnapshot(internalIp: String, connectionUrl: String? = nil) -> CloudGatewayMacControllerSnapshot {
    let state = controllerContractState()
    let client = state.clients[0]
    return CloudGatewayMacControllerSnapshot(
        domain: .init(
            accountId: state.accountId, hasRetainedSession: true, accessAuthorized: true, access: .online,
            credentials: .available, inventoryFreshness: .current, installedIdentifiers: state.installedIdentifiers,
            observedProfiles: [], observationIsFresh: true, profilesObservedAt: nil, commandInFlight: false,
            clients: [.init(identifier: client.identifier, regionId: client.regionId, regionName: client.regionName,
                            regionOrder: client.regionOrder, clientName: client.clientName, ownerLabel: nil,
                            internalIp: internalIp, connectionUrl: connectionUrl, cloudState: .active, eligibility: .eligible, isInstalled: true,
                            source: .cloud, readAt: client.readAt, updatedAt: nil, status: nil)]
        ),
        lastSelectedIdentifier: nil, browserState: .signedIn(AuthenticatedUser(uid: "account", email: nil)),
        isRestoringSession: false, isAuthSettling: false, canCreateClient: false, errorMessage: nil
    )
}

private func outcomeExpectRejectedClient(_ change: (inout [String: Any]) -> Void) throws {
    try outcomeExpectRejectedState { object in
        var clients = try #require(object["clients"] as? [[String: Any]])
        change(&clients[0])
        object["clients"] = clients
    }
}

private func outcomeExpectRejectedState(_ change: (inout [String: Any]) throws -> Void) throws {
    var state = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(controllerContractState())) as? [String: Any])
    try change(&state)
    var reply = CloudGatewayMacControllerReply()
    reply.appVersion = appVersion
    reply.appBuild = appBuild
    reply.instanceId = UUID()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
    object["state"] = state
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            JSONSerialization.data(withJSONObject: object), appVersion: appVersion, appBuild: appBuild
        )
    }
}
