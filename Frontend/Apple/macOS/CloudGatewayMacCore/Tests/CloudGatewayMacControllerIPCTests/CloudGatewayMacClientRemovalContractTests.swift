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
@Test func removalContractReservesWithoutDispatchAndConfirmsOnce() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    effects.sessions.changeAccount(to: "account")
    let request = CloudGatewayMacControllerRequest(
        action: .removeClient, identifier: removalIdentifier,
        appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(await controller.handle(request).operation?.state == .accepted)
    #expect(effects.performed.isEmpty)
    #expect(effects.writes == 1)
    #expect(effects.activity == [false])
    let confirmation = controllerBoundaryRequest(.confirmOperation, contextId: request.id)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    #expect(await controller.handle(confirmation).operation?.state == .running)
    #expect(effects.performed == [.removeClient])
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

@MainActor
@Test(arguments: ["managed", "startup", "activation", "extension", "draining", "domain", "preparation"])
func removalAdmissionRefusesLifecycleWork(state: String) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    if state == "startup" {
        let attempt = CloudGatewayMacExtensionUpdateOrchestrator.Attempt(id: UUID(), target: controllerBoundaryBuild, bootSession: "boot")
        effects.storedUpdates = .init(state: .approvalPending(attempt))
    }
    let controller = try effects.make(managed: state == "managed")
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    var preparation: Task<CloudGatewayMacControllerReply, Never>?
    switch state {
    case "managed":
        effects.authenticated = false
        effects.registration = .updateRequired
        _ = await controller.handle(controllerBoundaryRequest(.update, allowDisconnect: false))
    case "activation": effects.activationPending = true
    case "extension": _ = await controller.handle(controllerBoundaryRequest(.prepareExtensionUpdate))
    case "draining":
        effects.installed = controllerBoundaryReplacement
        await controller.tick()
    case "domain": effects.hasPendingWork = true
    case "preparation":
        effects.ignorePreparationCancellation = true
        preparation = Task { await controller.handle(controllerBoundaryRequest(.prepareClient)) }
        try #require(await controllerBoundaryEventually { effects.releasePreparation != nil })
    default: break
    }
    let request = CloudGatewayMacControllerRequest(
        action: .removeClient, identifier: removalIdentifier,
        appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(await controller.handle(request).error == .busy)
    #expect(effects.performed.isEmpty)
    effects.releasePreparation?.resume()
    _ = await preparation?.value
}

@MainActor
@Test(arguments: [false, true])
func removalConfirmationRechecksActivationAndSessionSettling(settling: Bool) async throws {
    let effects = ControllerOrchestratorEffects()
    effects.sessions.changeAccount(to: "account")
    let controller = try effects.make()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let request = CloudGatewayMacControllerRequest(
        action: .removeClient, identifier: removalIdentifier,
        appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
        buildIdentity: controllerBoundaryBuild
    )
    #expect(await controller.handle(request).operation?.state == .accepted)
    if settling {
        effects.snapshotState = controllerBoundaryState(authSettling: true)
    } else { effects.activationPending = true }
    let result = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: request.id))
    #expect(result.operation?.state == .failed)
    #expect(result.outcome == .failed(settling ? .signInRequired : .busy))
    #expect(effects.performed.isEmpty)
}

@MainActor
@Test func removalRequiresMatchingBuildAndAccountNamespaceWhileSignedOutStopStaysCompatible() async throws {
    let effects = ControllerOrchestratorEffects()
    let controller = try effects.make()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    for account in [nil, "other", "account"] {
        effects.sessions.changeAccount(to: account)
        let request = CloudGatewayMacControllerRequest(
            action: .removeClient, identifier: account == "account" ? "other/region/client" : removalIdentifier,
            appVersion: controllerBoundaryBuild.version, appBuild: controllerBoundaryBuild.build,
            buildIdentity: controllerBoundaryBuild
        )
        #expect(await controller.handle(request).error == .rejected)
    }
    let request = CloudGatewayMacControllerRequest(
        action: .removeClient, identifier: removalIdentifier,
        appVersion: controllerBoundaryReplacement.version, appBuild: controllerBoundaryReplacement.build,
        buildIdentity: controllerBoundaryReplacement
    )
    #expect(await controller.handle(request).error == .incompatibleVersion)
    #expect(effects.writes == 0)
    effects.sessions.changeAccount(to: nil)
    let stop = controllerBoundaryRequest(.turnOff, build: controllerBoundaryReplacement)
    #expect(await controller.handle(stop).operation?.state == .accepted)
    #expect(await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: stop.id,
                                                              build: controllerBoundaryReplacement)).operation?.state == .running)
    #expect(effects.performed == [.turnOff])
}
