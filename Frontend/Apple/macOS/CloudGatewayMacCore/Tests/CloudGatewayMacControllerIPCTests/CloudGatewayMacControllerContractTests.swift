import CloudGatewayAppCore
import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

private let appVersion = "1.2.0"
private let appBuild = "42"

@Test func controllerRequestsStampVersionWithoutChangingAdmissionIdentity() throws {
    let request = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
    let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: appBuild)
    #expect(decoded.id == request.id)
    #expect(decoded.action == .connect)
    #expect(decoded.identifier == request.identifier)
    #expect(decoded.appVersion == appVersion)
    #expect(decoded.appBuild == appBuild)
}

@Test func controllerRequestsRejectVersionMismatchBeforeDispatch() throws {
    let request = CloudGatewayMacControllerRequest(action: .snapshot, appVersion: "old", appBuild: appBuild)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
    }
    let data = try JSONEncoder().encode(request)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: appBuild)
    }
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["appVersion"] = appVersion
    for version in [CloudGatewayMacControllerProtocol.compatibleProtocolVersion, CloudGatewayMacControllerProtocol.protocolVersion + 1] {
        object["schemaVersion"] = version
        object["protocolVersion"] = version
        #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
            try CloudGatewayMacControllerProtocol.decodeRequest(
                JSONSerialization.data(withJSONObject: object), appVersion: appVersion, appBuild: appBuild
            )
        }
    }
    object["schemaVersion"] = CloudGatewayMacControllerProtocol.protocolVersion
    object["protocolVersion"] = CloudGatewayMacControllerProtocol.protocolVersion
    #expect(try CloudGatewayMacControllerProtocol.decodeRequest(
        JSONSerialization.data(withJSONObject: object), appVersion: appVersion, appBuild: appBuild
    ).action == .snapshot)
    object["schemaVersion"] = 3
    let unsupported = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeRequest(unsupported, appVersion: appVersion, appBuild: appBuild)
    }
}

@Test func controllerRequestsRejectOversizeAndUnexpectedActionArguments() throws {
    let extra = CloudGatewayMacControllerRequest(action: .snapshot, identifier: "account/region/client")
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.encodeRequest(extra, appVersion: appVersion, appBuild: appBuild)
    }
    let oversize = Data(repeating: 32, count: CloudGatewayMacControllerProtocol.requestBytes + 1)
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeRequest(oversize, appVersion: appVersion, appBuild: appBuild)
    }
    for identifier in ["account/region", "account/region/client/extra", "account/../client", "account/region/cli\nent"] {
        #expect(!CloudGatewayMacControllerProtocol.validIdentifier(identifier))
    }
}

@Test func scopedStopRequiresAnExactTargetAndCurrentBuildWithoutChangingBareStop() throws {
    let request = CloudGatewayMacControllerRequest(action: .disconnectClient, identifier: "account/region/client")
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
    #expect(try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: appBuild).identifier == request.identifier)
    #expect(!request.action.isCompatibleControl)
    #expect(request.action.requiresConfirmation)
    #expect(request.action.hasAccountBoundOutcome)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: "43")
    }
    for invalid in [
        CloudGatewayMacControllerRequest(action: .disconnectClient),
        .init(action: .disconnectClient, identifier: "account/region"),
        .init(action: .disconnectClient, identifier: "account/region/client", contextId: UUID()),
        .init(action: .turnOff, identifier: "account/region/client")
    ] {
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(invalid, appVersion: appVersion, appBuild: appBuild)
        }
    }
    let stop = try CloudGatewayMacControllerProtocol.encodeRequest(.init(action: .turnOff), appVersion: appVersion, appBuild: appBuild)
    #expect(try CloudGatewayMacControllerProtocol.decodeRequest(stop, appVersion: appVersion, appBuild: "43").action == .turnOff)
}

@Test func clientCreationRequiresBoundedNameAndOpaqueAccountFencedContext() throws {
    let contextId = UUID()
    let request = CloudGatewayMacControllerRequest(
        action: .createClient, regionId: "us-central", clientName: "Work Mac", contextId: contextId
    )
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
    #expect(try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: appBuild).contextId == contextId)
    for name in ["", " Work Mac", "Work Mac ", "Work\nMac", String(repeating: "x", count: 81)] {
        let invalid = CloudGatewayMacControllerRequest(
            action: .createClient, regionId: "us-central", clientName: name, contextId: contextId
        )
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(invalid, appVersion: appVersion, appBuild: appBuild)
        }
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.encodeRequest(
            CloudGatewayMacControllerRequest(action: .createClient, regionId: "us-central", clientName: "Work Mac"),
            appVersion: appVersion, appBuild: appBuild
        )
    }
}

@Test func controllerRepliesPreserveOnlyCurrentAccountDomainMetadata() throws {
    let state = controllerContractState()
    let instanceId = UUID()
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(state: state), appVersion: appVersion, appBuild: appBuild, instanceId: instanceId
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild)
    #expect(reply.state == state)
    #expect(reply.instanceId == instanceId)
    #expect(reply.state?.status.hasActiveTunnel == true)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["snapshot"] == nil)
    let text = String(decoding: data, as: UTF8.self)
    for field in ["wireGuardConfig", "privateKey", "customToken", "deviceSecret", "ownerUid", "email", "private-account@example.com", "secretReference", "configHash"] {
        #expect(!text.contains(field))
    }
}

@Test func crossAccountAndSignedOutStatesFailClosed() throws {
    for field in ["clients", "installedIdentifiers", "observedProfiles", "selectedIdentifier", "accountId"] {
        let state = try controllerInvalidState { object in
            switch field {
            case "clients":
                var clients = try #require(object[field] as? [[String: Any]])
                clients[0]["identifier"] = "other/region/client"
                object[field] = clients
            case "installedIdentifiers": object[field] = ["other/region/client"]
            case "observedProfiles": object[field] = [["identifier": "other/region/client", "status": "connected"]]
            case "selectedIdentifier": object[field] = "other/region/client"
            default: object.removeValue(forKey: field)
            }
        }
        try controllerExpectRejectedState(state)
    }
    let signedOut = try controllerInvalidState { object in
        object.removeValue(forKey: "accountId")
        object["auth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudGatewayMacControllerView.BrowserState.signedOut))
    }
    try controllerExpectRejectedState(signedOut)
}

@Test func controllerStateBoundsClientMetadataAndProfileCollections() throws {
    for (field, value) in [
        ("clientName", String(repeating: "x", count: 2049)), ("regionName", String(repeating: "x", count: 1025)),
        ("ownerLabel", String(repeating: "x", count: 1025)), ("clientName", "Work\nMac"),
        ("regionName", ""), ("ownerLabel", "Owner\tLabel"), ("regionId", "other-region")
    ] {
        let state = try controllerInvalidState { object in
            var clients = try #require(object["clients"] as? [[String: Any]])
            clients[0][field] = value
            object["clients"] = clients
        }
        try controllerExpectRejectedState(state)
    }
    for field in ["clients", "installedIdentifiers", "observedProfiles"] {
        let state = try controllerInvalidState { object in
            if field == "clients" {
                let client = try #require((object[field] as? [[String: Any]])?.first)
                object[field] = (0...4096).map { index in
                    var value = client
                    value["identifier"] = "account/region/client-\(index)"
                    return value
                }
            } else if field == "installedIdentifiers" {
                object[field] = (0...4096).map { "account/region/client-\($0)" }
            } else {
                object[field] = Array(repeating: ["status": "connected"], count: 4097)
            }
        }
        try controllerExpectRejectedState(state)
    }
    for field in ["clients", "installedIdentifiers"] {
        let duplicate = try controllerInvalidState { object in
            let values = try #require(object[field] as? [Any])
            object[field] = values + values
        }
        try controllerExpectRejectedState(duplicate)
    }
    let tooManyRegions = try controllerInvalidState { object in
        let client = try #require((object["clients"] as? [[String: Any]])?.first)
        object["clients"] = (0...256).map { index in
            var value = client
            value["identifier"] = "account/region-\(index)/client"
            value["regionId"] = "region-\(index)"
            return value
        }
    }
    try controllerExpectRejectedState(tooManyRegions)
}

@Test func controllerChallengeOnlyAllowsExistingApprovalOriginAndShape() throws {
    let code = "123456"
    let fragment = "/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=\(code)"
    let url = try #require(URL(string: "https://gocloudlaunch.com/#\(fragment)"))
    let state = controllerContractState(accountId: nil, auth: .waitingForApproval(userCode: code, verificationURL: url))
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(state: state), appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild).state == state)
    for rawURL in [
        "https://example.com/#\(fragment)", "http://gocloudlaunch.com/#\(fragment)",
        "https://user@gocloudlaunch.com/#\(fragment)", "https://gocloudlaunch.com:444/#\(fragment)",
        "https://gocloudlaunch.com/?token=secret#\(fragment)", "https://gocloudlaunch.com/#\(fragment)&token=secret"
    ] {
        let invalidURL = try #require(URL(string: rawURL))
        try controllerExpectRejectedState(controllerContractState(
            accountId: nil, auth: .waitingForApproval(userCode: code, verificationURL: invalidURL)
        ))
    }
    for invalidCode in ["654321", "12345", "abc123"] {
        try controllerExpectRejectedState(controllerContractState(
            accountId: nil, auth: .waitingForApproval(userCode: invalidCode, verificationURL: url)
        ))
    }
    try controllerExpectRejectedState(controllerContractState(auth: .waitingForApproval(userCode: code, verificationURL: url)))
    try controllerExpectRejectedState(controllerContractState(accountId: nil, auth: .signedIn(AuthenticatedUser(uid: "account", email: nil))))
}

@Test func controllerRepliesRejectMalformedBoundsVersionsAndMissingInstance() throws {
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            Data(repeating: 32, count: CloudGatewayMacControllerProtocol.replyBytes + 1),
            appVersion: appVersion, appBuild: appBuild
        )
    }
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(accepted: true), appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: "43")
    }
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "instanceId")
    let missingInstance = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(missingInstance, appVersion: appVersion, appBuild: appBuild)
    }
}

@Test func controllerDoesNotExposeArbitraryErrorText() throws {
    let unsafe = "privateKey=secret customToken=secret account=other"
    let state = controllerContractState(errorMessage: unsafe)
    #expect(state.errorMessage == "CloudGateway could not complete the request. Refresh before trying again")
    #expect(ControllerVisibleError.sanitize("Unable to refresh inventory. Try Refresh again") == "Unable to refresh inventory. Try Refresh again")
    #expect(ControllerVisibleError.sanitize(nil) == nil)
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(state: state), appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild).state == state)
    try controllerExpectRejectedState(controllerInvalidState { $0["errorMessage"] = unsafe })
}

@Test func creationRepliesRejectUnboundedRegionsAndInvalidCapacity() throws {
    for regions in [
        [CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true, capacity: .known(limit: -1, allocated: 0))],
        [CloudGatewayRegion(regionId: "region", displayName: "Region", enabled: true),
         CloudGatewayRegion(regionId: "region", displayName: "Duplicate", enabled: true)],
        (0...256).map { CloudGatewayRegion(regionId: "region-\($0)", displayName: "Region", enabled: true) }
    ] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            CloudGatewayMacControllerReply(creation: .init(id: UUID(), regions: regions)),
            appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
        )
        #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild).error == .invalidRequest)
    }
}

@Test func creationRepliesNormalizeRegionDisplayTextAndPreserveRegionMetadata() throws {
    let regions = [
        CloudGatewayRegion(regionId: "r_E-1", displayName: "US\tCentral\nRegion", enabled: true,
                           displayOrder: 7, capacity: .known(limit: 10, allocated: 2)),
        CloudGatewayRegion(regionId: "r_E-2", displayName: String(repeating: "🙂", count: 300), enabled: false),
        CloudGatewayRegion(regionId: "r_E-3", displayName: "", enabled: true)
    ]
    let id = UUID()
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(creation: .init(id: id, regions: regions)),
        appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild)
    let creation = try #require(reply.creation)
    #expect(reply.error == nil)
    #expect(creation.id == id)
    #expect(creation.regions.map(\.regionId) == regions.map(\.regionId))
    #expect(creation.regions.map(\.displayName) == ["US Central Region", String(repeating: "🙂", count: 256), "Untitled"])
    #expect(creation.regions.map(\.enabled) == regions.map(\.enabled))
    #expect(creation.regions.map(\.displayOrder) == regions.map(\.displayOrder))
    #expect(creation.regions.map(\.capacity) == regions.map(\.capacity))
}

@Test func controllerPeerRequiresSameNonRootUserAndExactAppSigningIdentity() throws {
    #expect(ControllerPeerIdentity.accepts(peerUserId: 501, ownerUserId: 501))
    let invalidUsers: [(UInt32, UInt32)] = [(0, 0), (0, 501), (501, 0), (502, 501), (.max, .max), (.max, 501)]
    for (peer, owner) in invalidUsers {
        #expect(!ControllerPeerIdentity.accepts(peerUserId: peer, ownerUserId: owner))
    }
    let requirement = try ControllerPeerIdentity.requirement(teamIdentifier: "ABC1234567")
    #expect(requirement == "anchor apple generic and identifier \"com.gocloudlaunch.gateway.macos\" and certificate leaf[subject.OU] = \"ABC1234567\"")
    for team in ["", "ABC", "ABC123456\"", "ABC123456🙂", "ABC12345678"] {
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try ControllerPeerIdentity.requirement(teamIdentifier: team)
        }
    }
}

func controllerContractState(
    accountId: String? = "account", auth: CloudGatewayMacBrowserAuthState? = nil, errorMessage: String? = nil
) -> CloudGatewayMacControllerState {
    let identifier = "\(accountId ?? "account")/region/client"
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(
            accountId: accountId, hasRetainedSession: accountId != nil, accessAuthorized: accountId != nil,
            access: accountId == nil ? .unverified : .online, credentials: accountId == nil ? .unknown : .available,
            inventoryFreshness: accountId == nil ? .unavailable : .current,
            installedIdentifiers: accountId == nil ? [] : [identifier],
            observedProfiles: accountId == nil ? [] : [.init(identifier: identifier, status: .connected)],
            observationIsFresh: true, profilesObservedAt: Date(timeIntervalSince1970: 1_000), commandInFlight: false,
            clients: accountId == nil ? [] : [.init(
                identifier: identifier, regionId: "region", regionName: "US Central", regionOrder: 1000,
                clientName: "Work Mac", ownerLabel: nil, internalIp: "10.0.0.2", cloudState: .active,
                eligibility: .eligible, isInstalled: true, source: .cloud, readAt: Date(timeIntervalSince1970: 900),
                updatedAt: Date(timeIntervalSince1970: 800), status: .connected
            )]
        ),
        lastSelectedIdentifier: accountId == nil ? nil : identifier,
        browserState: auth ?? accountId.map { .signedIn(AuthenticatedUser(uid: $0, email: "private-account@example.com")) } ?? .signedOut,
        isRestoringSession: false, isAuthSettling: false, canCreateClient: false, errorMessage: errorMessage
    )
    return .init(snapshot: snapshot, setupState: .ready, canUpdateExtension: false)
}

private func controllerInvalidState(
    _ change: (inout [String: Any]) throws -> Void
) throws -> CloudGatewayMacControllerState {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(controllerContractState())) as? [String: Any])
    try change(&object)
    return try JSONDecoder().decode(CloudGatewayMacControllerState.self, from: JSONSerialization.data(withJSONObject: object))
}

private func controllerExpectRejectedState(_ state: CloudGatewayMacControllerState) throws {
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(state: state), appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild)
    #expect(reply.error == .invalidRequest)
    #expect(reply.state == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("other/region/client"))
    var raw = CloudGatewayMacControllerReply(state: state)
    raw.appVersion = appVersion
    raw.appBuild = appBuild
    raw.instanceId = UUID()
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            JSONEncoder().encode(raw), appVersion: appVersion, appBuild: appBuild
        )
    }
}

@Test(arguments: [CloudGatewayMacControllerRequest.Action.userActivity, .recordActivity])
func controllerActivityRequiresTheCurrentBuildAndNoArguments(action: CloudGatewayMacControllerRequest.Action) throws {
    let request = CloudGatewayMacControllerRequest(action: action)
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: appVersion, appBuild: appBuild)
    #expect(try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: appBuild).action == action)
    #expect(!request.action.isCompatibleControl)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: appVersion, appBuild: "other")
    }
    for invalid in [
        CloudGatewayMacControllerRequest(action: action, identifier: "account/region/client"),
        CloudGatewayMacControllerRequest(action: action, contextId: UUID()),
    ] {
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(invalid, appVersion: appVersion, appBuild: appBuild)
        }
    }
}
