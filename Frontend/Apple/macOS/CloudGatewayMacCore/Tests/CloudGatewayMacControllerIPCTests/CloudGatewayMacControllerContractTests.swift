import CloudGatewayKit
import Foundation
import Testing
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
    object["schemaVersion"] = 2
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

@Test func controllerRepliesPreserveOnlyCurrentAccountMenuMetadata() throws {
    let view = CloudGatewayMacControllerView(
        groups: [.init(title: "US Central", rows: [
            .init(identifier: "account/region/client", title: "Work Mac", status: .connected, isEnabled: true)
        ])],
        statusTitle: "VPN connected", canToggleVPN: true, canTurnOff: true, hasActiveTunnel: true,
        reconnectIdentifier: "account/region/client", accountId: "account",
        lastSelectedIdentifier: "account/region/client", browserState: .signedIn, setupState: .ready
    )
    let instanceId = UUID()
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(snapshot: view), appVersion: appVersion, appBuild: appBuild, instanceId: instanceId
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild)
    #expect(reply.snapshot == view)
    #expect(reply.instanceId == instanceId)
    let text = String(decoding: data, as: UTF8.self)
    for field in ["wireGuardConfig", "privateKey", "customToken", "deviceSecret", "ownerUid", "email"] {
        #expect(!text.contains(field))
    }
}

@Test func crossAccountAndSignedOutSnapshotsFailClosed() throws {
    let rows = [CloudGatewayMacControllerView.Region(title: "Region", rows: [
        .init(identifier: "other/region/client", title: "Other account client", status: .connected, isEnabled: true)
    ])]
    for view in [
        CloudGatewayMacControllerView(groups: rows, accountId: "account"),
        CloudGatewayMacControllerView(groups: rows),
        CloudGatewayMacControllerView(lastSelectedIdentifier: "other/region/client"),
        CloudGatewayMacControllerView(accountId: "account", lastSelectedIdentifier: "other/region/client"),
        CloudGatewayMacControllerView(browserState: .signedIn)
    ] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            CloudGatewayMacControllerReply(snapshot: view), appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
        )
        let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild)
        #expect(reply.error == .invalidRequest)
        #expect(reply.snapshot == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("other/region/client"))
    }
}

@Test func controllerChallengeOnlyAllowsExistingApprovalOriginAndShape() throws {
    let code = "123456"
    let fragment = "/auth/code?deviceRequestId=0123456789abcdef0123456789abcdef&userCode=\(code)"
    let url = try #require(URL(string: "https://gocloudlaunch.com/#\(fragment)"))
    #expect(CloudGatewayMacControllerProtocol.validChallenge(code: code, url: url))
    let view = CloudGatewayMacControllerView(browserState: .waitingForApproval(userCode: code, verificationURL: url))
    try view.validate()
    for rawURL in [
        "https://example.com/#\(fragment)", "http://gocloudlaunch.com/#\(fragment)",
        "https://user@gocloudlaunch.com/#\(fragment)", "https://gocloudlaunch.com:444/#\(fragment)",
        "https://gocloudlaunch.com/?token=secret#\(fragment)", "https://gocloudlaunch.com/#\(fragment)&token=secret"
    ] {
        let invalidURL = try #require(URL(string: rawURL))
        #expect(!CloudGatewayMacControllerProtocol.validChallenge(code: code, url: invalidURL))
    }
    #expect(!CloudGatewayMacControllerProtocol.validChallenge(code: "654321", url: url))
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
    let sanitized = try #require(ControllerVisibleError.sanitize(unsafe))
    #expect(!sanitized.contains("secret"))
    #expect(ControllerVisibleError.sanitize("Unable to refresh inventory. Try Refresh again") == "Unable to refresh inventory. Try Refresh again")
    #expect(ControllerVisibleError.sanitize(nil) == nil)
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        CloudGatewayMacControllerReply(snapshot: .init(errorMessage: unsafe)),
        appVersion: appVersion, appBuild: appBuild, instanceId: UUID()
    )
    #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: appVersion, appBuild: appBuild).error == .invalidRequest)
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
