import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

private let currentBuild = CloudGatewayMacBuildIdentity(version: "2.0", build: "43", codeHash: String(repeating: "a", count: 40))
private let previousBuild = CloudGatewayMacBuildIdentity(version: "1.2", build: "42", codeHash: String(repeating: "b", count: 64))

@Test func controllerLifecycleWorksAcrossAppVersionsAndExecutableIdentities() throws {
    let request = CloudGatewayMacControllerRequest(action: .lifecycle, appVersion: "other", appBuild: "other")
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(
        request, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild
    )
    let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(
        data, appVersion: previousBuild.version, appBuild: previousBuild.build, buildIdentity: previousBuild
    )
    #expect(decoded.id == request.id)
    #expect(decoded.appVersion == currentBuild.version)
    #expect(decoded.appBuild == currentBuild.build)
    #expect(decoded.buildIdentity == currentBuild)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.protocolVersion == 1)

    let lifecycle = CloudGatewayMacControllerLifecycle(running: previousBuild, installed: currentBuild, state: .draining)
    let instanceId = UUID()
    let response = CloudGatewayMacControllerProtocol.encodeReply(
        .init(lifecycle: lifecycle), appVersion: previousBuild.version, appBuild: previousBuild.build,
        instanceId: instanceId, action: .lifecycle
    )
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(
        response, appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
    )
    #expect(reply.lifecycle == lifecycle)
    #expect(reply.instanceId == instanceId)
    #expect(reply.state == nil)
    #expect(reply.error == nil)
    #expect(reply.schemaVersion == 1)
    #expect(reply.protocolVersion == 1)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            response, appVersion: currentBuild.version, appBuild: currentBuild.build
        )
    }
}

@Test func controllerLifecycleDoesNotRequireClientBuildIdentity() throws {
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(
        .init(action: .lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build
    )
    let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(
        data, appVersion: previousBuild.version, appBuild: previousBuild.build, buildIdentity: previousBuild
    )
    #expect(decoded.buildIdentity == nil)
    for state in [CloudGatewayMacControllerLifecycle.State.current, .draining, .invalidInstallation] {
        let lifecycle = CloudGatewayMacControllerLifecycle(running: previousBuild, installed: nil, state: state)
        let response = CloudGatewayMacControllerProtocol.encodeReply(
            .init(lifecycle: lifecycle), appVersion: previousBuild.version, appBuild: previousBuild.build,
            instanceId: UUID(), action: .lifecycle
        )
        #expect(try CloudGatewayMacControllerProtocol.decodeReply(
            response, appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
        ).lifecycle == lifecycle)
    }
}

@Test func controllerRequestEncodingStampsConfiguredIdentityForNormalAndLifecycleActions() throws {
    for action in [CloudGatewayMacControllerRequest.Action.snapshot, .lifecycle] {
        let request = CloudGatewayMacControllerRequest(action: action, buildIdentity: previousBuild)
        let data = try CloudGatewayMacControllerProtocol.encodeRequest(
            request, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild
        )
        #expect(try CloudGatewayMacControllerProtocol.decodeRequest(
            data, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild
        ).buildIdentity == currentBuild)
    }
}

@Test func controllerBuildIdentityAcceptsOnlySupportedHashLengthsWithinTextBounds() throws {
    for hash in [String(repeating: "ABCDEF0123456789", count: 4), String(repeating: "a", count: 40)] {
        let identity = CloudGatewayMacBuildIdentity(
            version: String(repeating: "v", count: 128), build: String(repeating: "b", count: 128), codeHash: hash
        )
        let lifecycle = CloudGatewayMacControllerLifecycle(running: identity, installed: identity, state: .current)
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            .init(lifecycle: lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build,
            instanceId: UUID(), action: .lifecycle
        )
        #expect(try CloudGatewayMacControllerProtocol.decodeReply(
            data, appVersion: previousBuild.version, appBuild: previousBuild.build, action: .lifecycle
        ).lifecycle == lifecycle)
    }
}

@Test(arguments: CloudGatewayMacControllerRequest.Action.allCases.filter { !$0.isCompatibleControl })
func controllerNormalCommandsRequireExactConfiguredBuildIdentity(action: CloudGatewayMacControllerRequest.Action) throws {
    let rebuilt = CloudGatewayMacBuildIdentity(
        version: currentBuild.version, build: currentBuild.build, codeHash: String(repeating: "c", count: 40)
    )
    for identity in [nil, rebuilt, currentBuild] {
        let request = CloudGatewayMacControllerRequest(
            action: action, identifier: action == .connect ? "account/region/client" : nil,
            regionId: action == .createClient ? "region" : nil,
            clientName: action == .createClient ? "Work Mac" : nil,
            contextId: [.createClient, .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart,
                        .extensionUpdateFinished, .extensionUpdateFailed].contains(action) ? UUID() : nil,
            buildIdentity: identity
        )
        let data = try CloudGatewayMacControllerProtocol.encodeRequest(
            request, appVersion: currentBuild.version, appBuild: currentBuild.build
        )
        if identity == currentBuild {
            #expect(try CloudGatewayMacControllerProtocol.decodeRequest(
                data, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild
            ).buildIdentity == currentBuild)
        } else {
            #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
                try CloudGatewayMacControllerProtocol.decodeRequest(
                    data, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild
                )
            }
        }
        #expect(try CloudGatewayMacControllerProtocol.decodeRequest(
            data, appVersion: currentBuild.version, appBuild: currentBuild.build
        ).buildIdentity == identity)
    }
}

@Test func controllerLifecycleRejectsAllMutationArguments() throws {
    for request in [
        CloudGatewayMacControllerRequest(action: .lifecycle, identifier: "account/region/client"),
        CloudGatewayMacControllerRequest(action: .lifecycle, regionId: "region"),
        CloudGatewayMacControllerRequest(action: .lifecycle, clientName: "Work Mac"),
        CloudGatewayMacControllerRequest(action: .lifecycle, contextId: UUID())
    ] {
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(
                request, appVersion: currentBuild.version, appBuild: currentBuild.build
            )
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["appVersion"] = previousBuild.version
        object["appBuild"] = previousBuild.build
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeRequest(
                data, appVersion: currentBuild.version, appBuild: currentBuild.build
            )
        }
    }
}

@Test func controllerLifecycleRejectsMalformedBuildIdentityAtBothBoundaries() throws {
    let invalidIdentities = [
        CloudGatewayMacBuildIdentity(version: "", build: "1", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: "2\n0", build: "1", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: String(repeating: "x", count: 129), build: "1", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: String(repeating: "é", count: 65), build: "1", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: "2", build: "", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: "2", build: "1\u{7f}", codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: "2", build: String(repeating: "x", count: 129), codeHash: currentBuild.codeHash),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "g", count: 40)),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "a", count: 39)),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "a", count: 41)),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "a", count: 63)),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "a", count: 65)),
        CloudGatewayMacBuildIdentity(version: "2", build: "1", codeHash: String(repeating: "é", count: 20))
    ]
    for identity in invalidIdentities {
        let request = CloudGatewayMacControllerRequest(
            action: .lifecycle, appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: identity
        )
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(
                request, appVersion: currentBuild.version, appBuild: currentBuild.build
            )
        }
        let data = try JSONEncoder().encode(request)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeRequest(
                data, appVersion: currentBuild.version, appBuild: currentBuild.build
            )
        }
        for lifecycle in [
            CloudGatewayMacControllerLifecycle(running: identity, installed: nil, state: .invalidInstallation),
            CloudGatewayMacControllerLifecycle(running: currentBuild, installed: identity, state: .draining)
        ] {
            let response = CloudGatewayMacControllerProtocol.encodeReply(
                .init(lifecycle: lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build,
                instanceId: UUID(), action: .lifecycle
            )
            #expect(try CloudGatewayMacControllerProtocol.decodeReply(
                response, appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
            ).error == .invalidRequest)
            var raw = CloudGatewayMacControllerReply(lifecycle: lifecycle)
            raw.appVersion = currentBuild.version
            raw.appBuild = currentBuild.build
            raw.instanceId = UUID()
            let malformed = try JSONEncoder().encode(raw)
            #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
                try CloudGatewayMacControllerProtocol.decodeReply(
                    malformed, appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
                )
            }
        }
    }
}

@Test func controllerLifecycleNeverAcceptsAccountOrOperationReplyFields() throws {
    let lifecycle = CloudGatewayMacControllerLifecycle(running: currentBuild, installed: currentBuild, state: .current)
    for var reply in [
        CloudGatewayMacControllerReply(state: controllerContractState(), lifecycle: lifecycle),
        CloudGatewayMacControllerReply(accepted: true, lifecycle: lifecycle),
        CloudGatewayMacControllerReply(creation: .init(id: UUID(), regions: []), lifecycle: lifecycle),
        CloudGatewayMacControllerReply(operationId: UUID(), lifecycle: lifecycle),
        CloudGatewayMacControllerReply(error: .unavailable, lifecycle: lifecycle),
        CloudGatewayMacControllerReply(state: controllerContractState()),
        CloudGatewayMacControllerReply()
    ] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            reply, appVersion: currentBuild.version, appBuild: currentBuild.build, instanceId: UUID(), action: .lifecycle
        )
        let decoded = try CloudGatewayMacControllerProtocol.decodeReply(
            data, appVersion: previousBuild.version, appBuild: previousBuild.build, action: .lifecycle
        )
        #expect(decoded.error == .invalidRequest)
        #expect(decoded.lifecycle == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("account"))
        reply.appVersion = currentBuild.version
        reply.appBuild = currentBuild.build
        reply.instanceId = UUID()
        let malformed = try JSONEncoder().encode(reply)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeReply(
                malformed, appVersion: previousBuild.version, appBuild: previousBuild.build, action: .lifecycle
            )
        }
    }
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(lifecycle: lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build,
        instanceId: UUID(), action: .lifecycle
    )
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: currentBuild.version, appBuild: currentBuild.build)
    }
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = CloudGatewayMacControllerProtocol.protocolVersion
    object["protocolVersion"] = CloudGatewayMacControllerProtocol.protocolVersion
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            JSONSerialization.data(withJSONObject: object), appVersion: currentBuild.version, appBuild: currentBuild.build
        )
    }
}

@Test func controllerLifecyclePreservesSchemaInstanceAndEnvelopeBounds() throws {
    let lifecycle = CloudGatewayMacControllerLifecycle(running: currentBuild, installed: nil, state: .invalidInstallation)
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(lifecycle: lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build,
        instanceId: UUID(), action: .lifecycle
    )
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for field in ["schemaVersion", "protocolVersion"] {
        var object = original
        object[field] = 2
        object.removeValue(forKey: "controlVersion")
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
            try CloudGatewayMacControllerProtocol.decodeReply(
                unsupported, appVersion: previousBuild.version, appBuild: previousBuild.build, action: .lifecycle
            )
        }
    }
    for field in ["instanceId", "appVersion", "appBuild"] {
        var object = original
        object[field] = field == "instanceId" ? nil : String(repeating: "x", count: 129)
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeReply(
                malformed, appVersion: previousBuild.version, appBuild: previousBuild.build, action: .lifecycle
            )
        }
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            Data(repeating: 32, count: CloudGatewayMacControllerProtocol.replyBytes + 1),
            appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
        )
    }
}

@Test func controllerLifecycleRequestsPreserveSchemaAndVersionBounds() throws {
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(
        .init(action: .lifecycle), appVersion: currentBuild.version, appBuild: currentBuild.build
    )
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for field in ["schemaVersion", "protocolVersion"] {
        var object = original
        object[field] = 2
        object.removeValue(forKey: "controlVersion")
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
            try CloudGatewayMacControllerProtocol.decodeRequest(
                unsupported, appVersion: previousBuild.version, appBuild: previousBuild.build
            )
        }
    }
    for field in ["appVersion", "appBuild"] {
        for value in ["", "1\n2", String(repeating: "x", count: 129)] {
            var object = original
            object[field] = value
            let malformed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
                try CloudGatewayMacControllerProtocol.decodeRequest(
                    malformed, appVersion: previousBuild.version, appBuild: previousBuild.build
                )
            }
        }
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.decodeRequest(
            Data(repeating: 32, count: CloudGatewayMacControllerProtocol.requestBytes + 1),
            appVersion: currentBuild.version, appBuild: currentBuild.build
        )
    }
}

@Test func controllerLifecycleCanDecodeOldServerInvalidRequestAcrossVersions() throws {
    let data = CloudGatewayMacControllerProtocol.encodeReply(
        .init(error: .invalidRequest), appVersion: previousBuild.version, appBuild: previousBuild.build, instanceId: UUID()
    )
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(
        data, appVersion: currentBuild.version, appBuild: currentBuild.build, action: .lifecycle
    ).error == .invalidRequest)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeReply(
            data, appVersion: currentBuild.version, appBuild: currentBuild.build
        )
    }
}

@Test func stableControlContractWorksAcrossNormalProtocolVersions() throws {
    for action in [CloudGatewayMacControllerRequest.Action.lifecycle, .status, .turnOff, .operation, .confirmOperation] {
        let request = CloudGatewayMacControllerRequest(
            action: action, contextId: action == .operation || action == .confirmOperation ? UUID() : nil,
            appVersion: previousBuild.version, appBuild: previousBuild.build, buildIdentity: previousBuild
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["schemaVersion"] = 12
        object["protocolVersion"] = 9
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try CloudGatewayMacControllerProtocol.decodeRequest(data, appVersion: currentBuild.version,
            appBuild: currentBuild.build, buildIdentity: currentBuild).action == action)
        object["controlVersion"] = 2
        #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
            try CloudGatewayMacControllerProtocol.decodeRequest(try JSONSerialization.data(withJSONObject: object),
                appVersion: currentBuild.version, appBuild: currentBuild.build, buildIdentity: currentBuild)
        }
    }
    let response = CloudGatewayMacControllerProtocol.encodeReply(
        .init(status: .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true)),
        appVersion: previousBuild.version, appBuild: previousBuild.build, instanceId: UUID(), action: .status
    )
    var object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    object["schemaVersion"] = 12
    object["protocolVersion"] = 9
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: currentBuild.version,
        appBuild: currentBuild.build, action: .status).status?.hasActiveTunnel == true)
    #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
        try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: currentBuild.version, appBuild: currentBuild.build)
    }
}
