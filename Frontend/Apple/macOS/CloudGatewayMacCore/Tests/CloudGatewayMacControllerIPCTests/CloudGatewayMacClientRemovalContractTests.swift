import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore
@testable import CloudGatewayMacControllerIPC

private let removalIdentifier = "account/region/client"

@Test func removalRequiresAnExplicitCanonicalIdentifierAndNoOtherArguments() throws {
    let request = CloudGatewayMacControllerRequest(action: .removeClient, identifier: removalIdentifier)
    let data = try CloudGatewayMacControllerProtocol.encodeRequest(
        request, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(
        data, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(decoded.id == request.id)
    #expect(decoded.action == .removeClient)
    #expect(decoded.identifier == removalIdentifier)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.protocolVersion == 2)
    #expect(decoded.controlVersion == 1)
    #expect(decoded.action.requiresConfirmation)
    #expect(decoded.action.hasAccountBoundOutcome)
    #expect(!decoded.action.isCompatibleControl)

    for identifier in [nil, "", "account/region", "account//client", "/region/client", "account/../client",
                       "account/region/client/extra", "account/region/client,other", "account/region/cli\nent",
                       "account/region/\(String(repeating: "x", count: 257))"] {
        let invalid = CloudGatewayMacControllerRequest(action: .removeClient, identifier: identifier)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(
                invalid, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build
            )
        }
    }
    for field in ["regionId", "clientName", "contextId", "loginOrigin", "allowDisconnect"] {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[field] = switch field {
        case "contextId": UUID().uuidString
        case "loginOrigin": "cli"
        case "allowDisconnect": false
        default: "unwanted"
        }
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeRequest(
                JSONSerialization.data(withJSONObject: object),
                appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build
            )
        }
    }
}

@Test func removalRejectsOtherProtocolVersions() throws {
    let request = CloudGatewayMacControllerRequest(
        action: .removeClient, identifier: removalIdentifier,
        appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build
    )
    let data = try JSONEncoder().encode(request)
    for field in ["schemaVersion", "protocolVersion"] {
        for version in [1, 3] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[field] = version
            #expect(throws: CloudGatewayMacControllerFailure.incompatibleVersion) {
                try CloudGatewayMacControllerProtocol.decodeRequest(
                    JSONSerialization.data(withJSONObject: object),
                    appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build
                )
            }
        }
    }
}

@MainActor
@Test func removalContractDoesNotDispatchBeforeDomainIntegration() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    let request = CloudGatewayMacControllerRequest(action: .removeClient, identifier: removalIdentifier)
    #expect(await controller.handle(request).error == .unavailable)
    #expect(effects.performed.isEmpty)
    #expect(effects.writes == 0)
}

@MainActor
@Test func removalReceiptsBindTheActionTargetAndOriginalSession() throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let session = try #require(effects.sessions.currentToken)
    let requests = try effects.makeRequests()
    let request = CloudGatewayMacControllerRequest(action: .removeClient, identifier: removalIdentifier)
    #expect(try requests.accept(request).state == .accepted)
    let outcome = CloudGatewayMacCommandOutcome.completed(warning: .localCleanupIncomplete)
    requests.finish(id: request.id, state: .completed, outcome: outcome, session: session)
    #expect(try requests.lookup(request)?.state == .completed)
    #expect(requests.outcome(id: request.id, session: session) == outcome)
    for changed in [
        CloudGatewayMacControllerRequest(action: .removeClient, id: request.id, identifier: "account/region/other"),
        .init(action: .connect, id: request.id, identifier: removalIdentifier)
    ] {
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) { try requests.lookup(changed) }
    }
    for account in [nil, "other", "account"] {
        effects.sessions.changeAccount(to: account)
        #expect(requests.outcome(id: request.id, session: effects.sessions.currentToken) == nil)
        #expect(requests.operation(id: request.id).state == .completed)
    }
    let restored = try effects.makeRequests()
    #expect(try restored.lookup(request)?.state == .unknown)
}

@MainActor
@Test func removalCompatibilityRepliesHideNewTypesFromOtherBuilds() async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let requests = try effects.makeRequests()
    let request = CloudGatewayMacControllerRequest(action: .removeClient, identifier: removalIdentifier)
    _ = try requests.accept(request)
    let controller = try effects.make(requests: requests)
    let rebuilt = CloudGatewayMacBuildIdentity(
        version: controllerBoundaryBuild.version, build: controllerBoundaryBuild.build, codeHash: String(repeating: "c", count: 40)
    )
    for outcome in [CloudGatewayMacCommandOutcome.completed(warning: .localCleanupIncomplete), .failed(.clientActive), .unknown] {
        let operation = requests.finish(
            id: request.id, state: outcome.state, warning: outcome.state == .completed ? .localCleanupIncomplete : nil,
            outcome: outcome, session: effects.sessions.currentToken
        )
        for action in [CloudGatewayMacControllerRequest.Action.operation, .confirmOperation, .status] {
            for build in [controllerBoundaryBuild, controllerBoundaryReplacement, rebuilt] {
                let control = controllerBoundaryRequest(action, contextId: action == .status ? nil : request.id, build: build)
                let reply = await controller.handle(control)
                let sameBuild = build == controllerBoundaryBuild
                #expect(reply.outcome == (sameBuild ? outcome : nil))
                #expect(reply.operation?.state == operation.state)
                #expect(reply.operation?.warning == (sameBuild ? operation.warning : nil))
                #expect(reply.state == nil || (sameBuild && action == .operation))
                let data = CloudGatewayMacControllerProtocol.encodeReply(
                    reply, appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
                    instanceId: UUID(), action: action
                )
                let decoded = try CloudGatewayMacControllerProtocol.decodeReply(
                    data, appVersion: build.version, appBuild: build.build, action: action
                )
                #expect(decoded.operation == reply.operation)
                #expect(decoded.schemaVersion == 1)
                #expect(decoded.protocolVersion == 1)
                #expect(decoded.controlVersion == 1)
                if !sameBuild {
                    let text = String(decoding: data, as: UTF8.self)
                    #expect(!text.contains("clientActive"))
                    #expect(!text.contains("localCleanupIncomplete"))
                }
            }
        }
    }
    #expect(effects.performed.isEmpty)
}

@Test func removalWarningsCannotLeakThroughAnUnfilteredCrossBuildReply() throws {
    for action in [CloudGatewayMacControllerRequest.Action.operation, .confirmOperation, .status] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(
            .init(operation: .init(id: UUID(), state: .completed, warning: .localCleanupIncomplete)),
            appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
            instanceId: UUID(), action: action
        )
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.decodeReply(
                data, appVersion: controllerBoundaryReplacement.version, appBuild: controllerBoundaryReplacement.build,
                action: action
            )
        }
    }
}
