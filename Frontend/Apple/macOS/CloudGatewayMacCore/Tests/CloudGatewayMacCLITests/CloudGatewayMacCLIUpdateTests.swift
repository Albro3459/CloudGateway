import Foundation
import CloudGatewayMacIPC
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let updateConfig = "uid1/us-sanjose-1/78ab8633-ae25-4287-885f-57bbbf6e7f63"

@MainActor
@Test(arguments: [false, true])
func cliRealControllerUpdateWaitsForColdStartupWithinItsCallerDeadline(settles: Bool) async throws {
    let harness = CLIHarness(cliState())
    var restoring = true
    var snapshots = 0
    var authenticated = false
    var activationCount = 0
    var journal: Data?
    let workflow = CloudGatewayMacManagedUpdateWorkflow(load: { journal }, persist: { journal = $0 })
    let requests = try CloudGatewayMacControllerRequests(data: nil, persist: { _ in })
    let gate = try CloudGatewayMacExtensionUpdateOrchestrator(bootSession: { "cold-boot" }, persist: { _ in })
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in
            snapshots += 1
            if settles && snapshots >= 3 { restoring = false }
            return cliState(account: restoring ? nil : "uid1", restoring: restoring,
                            access: restoring ? .unverified : .online, inventory: restoring ? .refreshing : .current)
        }, hasPendingWork: { restoring },
        perform: { _, _ in Issue.record("A disconnected update must not stop or start a VPN"); return false },
        refresh: { .refreshed }, prepareClient: { throw CloudGatewayMacControllerFailure.invalidRequest },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false }, installedIdentity: { cliBuild },
        extensionIdentity: { cliBuild }, ping: { target in
            guard authenticated else { return nil }
            return CloudGatewayMacExtensionVersion(infoDictionary: [
                "CFBundleVersion": target.build, "CFBundleShortVersionString": target.version
            ], codeHash: target.codeHash)
        }, registrationReadiness: { .updateRequired },
        managedUpdateObservation: { .init(accountId: "uid1", profiles: [], authorizedIdentifiers: []) },
        activateExtension: { _, _, event in
            activationCount += 1
            authenticated = true
            event(.completed)
            return true
        }
    )
    let controller = CloudGatewayMacControllerOrchestrator(identity: cliBuild, effects: effects, requests: requests,
                                                          extensionUpdates: gate, managedUpdates: workflow)
    var submitted: [UUID] = []
    harness.onRequest = { request in
        if request.action == .update { submitted.append(request.id) }
        let reply = await controller.handle(request)
        if request.action == .confirmOperation || request.action == .operation { await controller.tick() }
        return reply
    }
    #expect(await harness.run("update", "--timeout", "2", "--json") == (settles ? 0 : 8))
    #expect(submitted.count == (settles ? 2 : 1))
    #expect(Set(submitted).count == 1)
    #expect(activationCount == (settles ? 1 : 0))
    #expect(workflow.journal?.phase == (settles ? .completed : nil))
    if !settles { #expect(!harness.actions.contains(.confirmOperation)) }
}

@MainActor
private func updateRecords(_ harness: CLIHarness) throws -> [[String: Any]] {
    try harness.output.split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@MainActor
private func updateHarness(reconnect: Bool = true,
                           phases: [CloudGatewayMacManagedUpdateStatus.Phase] = [.stopping, .activating, .checkingReadiness, .reconnecting, .completed]) -> CLIHarness {
    let harness = CLIHarness(cliState())
    var operationId: UUID?
    var phases = phases
    harness.onRequest = { request in
        switch request.action {
        case .update:
            #expect(request.identifier == nil)
            operationId = request.id
            return .init(state: cliState(), operation: .init(id: request.id, state: .accepted),
                         update: .init(id: request.id, phase: .prepared, target: cliBuild,
                                       identifier: reconnect ? updateConfig : nil, reconnect: reconnect))
        case .confirmOperation, .operation:
            let id = try #require(operationId)
            #expect(request.contextId == id)
            #expect(harness.output.contains(id.uuidString.lowercased()))
            let phase = phases.count > 1 ? phases.removeFirst() : try #require(phases.first)
            return .init(state: cliState(), status: harness.status,
                         operation: .init(id: id, state: phase == .completed ? .completed : .running),
                         update: .init(id: id, phase: phase, target: cliBuild,
                                       identifier: reconnect ? updateConfig : nil, reconnect: reconnect))
        default: return nil
        }
    }
    return harness
}

@MainActor
@Test func cliUpdateFlushesAcceptanceAndObservesCapturedTargetWithoutIssuingVPNActions() async throws {
    let harness = updateHarness()
    let previous = harness.onRequest
    harness.onRequest = { request in
        if request.action == .update { #expect(request.allowDisconnect == true) }
        return try await previous?(request)
    }
    #expect(await harness.run("update", "--allow-disconnect", "--json") == 0)
    let records = try updateRecords(harness)
    try #require(records.count == 2)
    #expect(records[0]["type"] as? String == "accepted")
    #expect(records[1]["type"] as? String == "result")
    #expect(records[0]["operationId"] as? String == records[1]["operationId"] as? String)
    let data = try #require(records[1]["data"] as? [String: Any])
    let update = try #require(data["update"] as? [String: Any])
    #expect(update["phase"] as? String == "completed")
    #expect(update["configId"] as? String == updateConfig)
    #expect(update["reconnect"] as? Bool == true)
    #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "disconnected")
    #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation, .operation, .operation, .operation, .operation])
}

@MainActor
@Test func cliUpdateLeavesPreparedWorkUnconfirmedWhenAcceptanceCannotPrint() async {
    let harness = updateHarness()
    harness.failsOutput = true
    #expect(await harness.run("update", "--allow-disconnect", "--json") == 1)
    #expect(harness.actions == [.lifecycle, .userActivity, .update])
}

@MainActor
@Test func cliUpdateRejectsActiveVPNWithoutConsentAndPreservesPreciseFailure() async throws {
    let state = cliState(profiles: [.init(identifier: updateConfig, status: .connected)])
    let harness = CLIHarness(state)
    harness.onRequest = { request in
        guard request.action == .update else { return nil }
        #expect(request.allowDisconnect == false)
        return .init(state: state, operation: .init(id: request.id, state: .failed, failure: .commandFailed),
                     update: .init(id: request.id, phase: .failed, target: cliBuild, error: .disconnectRequired))
    }
    #expect(await harness.run("update", "--json") == 4)
    let record = try #require(try updateRecords(harness).last)
    #expect(record["type"] as? String == "error")
    #expect((record["error"] as? [String: Any])?["code"] as? String == "disconnect_required")
    #expect((record["error"] as? [String: Any])?["suggestion"] as? String != nil)
    #expect(harness.output.contains("--allow-disconnect"))
    #expect(harness.actions == [.lifecycle, .userActivity, .update])
}

@MainActor
@Test func cliUpdateAllowsNoOpAndInitiallyOffWithoutInventingReconnect() async throws {
    for consent in [false, true] {
        let harness = updateHarness(reconnect: false, phases: [.completed])
        let previous = harness.onRequest
        harness.onRequest = { request in
            if request.action == .update { #expect(request.allowDisconnect == consent) }
            return try await previous?(request)
        }
        #expect(await harness.run(["update", "--json"] + (consent ? ["--allow-disconnect"] : [])) == 0)
        let record = try #require(try updateRecords(harness).last)
        let data = try #require(record["data"] as? [String: Any])
        let update = try #require(data["update"] as? [String: Any])
        #expect(update["configId"] is NSNull)
        #expect(update["reconnect"] as? Bool == false)
        #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation])
    }
}

@MainActor
@Test func cliUpdateApprovalAndRestartDetachImmediatelyWithRunningOperationAndLookup() async throws {
    for (phase, code) in [(CloudGatewayMacManagedUpdateStatus.Phase.approvalRequired, "approval_required"),
                          (.restartRequired, "restart_required")] {
        let harness = updateHarness(phases: [phase])
        #expect(await harness.run("update", "--allow-disconnect", "--json") == 4)
        let records = try updateRecords(harness)
        let record = try #require(records.last)
        let id = try #require(record["operationId"] as? String)
        let data = try #require(record["data"] as? [String: Any])
        #expect((data["operation"] as? [String: Any])?["state"] as? String == "running")
        #expect((data["update"] as? [String: Any])?["phase"] as? String == code)
        #expect((data["update"] as? [String: Any])?["error"] is NSNull)
        #expect((record["error"] as? [String: Any])?["code"] as? String == code)
        #expect(((record["error"] as? [String: Any])?["suggestion"] as? String)?.contains("cloudgateway status --operation \(id)") == true)
        #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation])
        #expect(harness.clock.now == .zero)

        let lookup = CLIHarness()
        let operationId = try #require(UUID(uuidString: id))
        lookup.operation = .init(id: operationId, state: .running)
        lookup.update = .init(id: operationId, phase: phase, target: cliBuild)
        #expect(await lookup.run("status", "--operation", id, "--json") == 4)
        let pending = try #require(lookup.json?["data"] as? [String: Any])
        #expect((pending["operation"] as? [String: Any])?["state"] as? String == "running")
        #expect((pending["update"] as? [String: Any])?["phase"] as? String == code)
        #expect(lookup.actions == [.lifecycle, .userActivity, .operation])
    }
}

@MainActor
@Test func cliUpdateCallerLossAfterConfirmationNeverResubmitsAndKeepsRecoveryID() async throws {
    for failure in [CloudGatewayMacControllerFailure.unavailable, .rejected] {
        let harness = updateHarness()
        let previous = harness.onRequest
        harness.onRequest = { request in
            if request.action == .operation { throw failure }
            return try await previous?(request)
        }
        #expect(await harness.run("update", "--allow-disconnect", "--json") == 4)
        let records = try updateRecords(harness)
        let accepted = try #require(records.first?["operationId"] as? String)
        #expect(records.last?["operationId"] as? String == accepted)
        let error = try #require(records.last?["error"] as? [String: Any])
        #expect((error["suggestion"] as? String)?.contains("cloudgateway status --operation \(accepted)") == true)
        #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation, .operation])
    }
}

@MainActor
@Test func cliUpdateTimeoutUsesOneDeadlineAndDetachesWithoutCancellingWork() async throws {
    let harness = updateHarness(phases: [.checkingReadiness])
    #expect(await harness.run("update", "--allow-disconnect", "--timeout", "1", "--json") == 8)
    #expect(harness.clock.now == .seconds(1))
    let record = try #require(try updateRecords(harness).last)
    let id = try #require(record["operationId"] as? String)
    #expect(((record["error"] as? [String: Any])?["suggestion"] as? String)?.contains("cloudgateway status --operation \(id)") == true)
    #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation, .operation])
}

@MainActor
@Test func cliUpdateUncertainConfirmationNeverResendsAndCanBeLookedUpByAnotherFrontend() async throws {
    let harness = updateHarness()
    let previous = harness.onRequest
    harness.onRequest = { request in
        if request.action == .confirmOperation { throw CloudGatewayMacControllerFailure.unavailable }
        return try await previous?(request)
    }
    #expect(await harness.run("update", "--allow-disconnect", "--json") == 10)
    let record = try #require(try updateRecords(harness).last)
    let id = try #require((record["operationId"] as? String).flatMap(UUID.init(uuidString:)))
    let lookup = CLIHarness(cliState())
    lookup.operation = .init(id: id, state: .completed)
    lookup.update = .init(id: id, phase: .completed, target: cliBuild, identifier: updateConfig, reconnect: true)
    #expect(await lookup.run("status", "--operation", id.uuidString, "--json") == 0)
    let data = try #require(lookup.json?["data"] as? [String: Any])
    #expect((data["update"] as? [String: Any])?["id"] as? String == id.uuidString.lowercased())
    #expect(lookup.actions == [.lifecycle, .userActivity, .operation])
    #expect(harness.actions == [.lifecycle, .userActivity, .update, .confirmOperation])
}

@MainActor
@Test func cliStatusShowsPendingUpdateAlongsideIndependentObservedTunnel() async throws {
    let harness = CLIHarness(cliState(profiles: [.init(identifier: updateConfig, status: .connected)]))
    let id = UUID()
    harness.operation = .init(id: id, state: .running)
    harness.update = .init(id: id, phase: .checkingReadiness, target: cliBuild, identifier: updateConfig, reconnect: true)
    #expect(await harness.run("status", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "connected")
    #expect((data["update"] as? [String: Any])?["phase"] as? String == "checking_readiness")
    #expect((data["operation"] as? [String: Any])?["state"] as? String == "running")
}

@MainActor
@Test func cliUpdateLookupPreservesRedactionAndOldBuildCoarseFallback() async throws {
    for oldBuild in [false, true] {
        let harness = CLIHarness(cliState(account: nil, retained: false))
        let id = UUID()
        if oldBuild { harness.lifecycle = .draining }
        harness.onRequest = { request in
            guard request.action == .operation else { return nil }
            return .init(state: cliState(account: nil, retained: false), status: harness.status,
                         operation: .init(id: id, state: .running),
                         update: .init(id: id, phase: .activating, target: cliBuild))
        }
        #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
        #expect(!harness.output.contains(updateConfig))
        let data = try #require(harness.json?["data"] as? [String: Any])
        if oldBuild { #expect(data["update"] == nil) }
        else {
            let update = try #require(data["update"] as? [String: Any])
            #expect(update["configId"] is NSNull)
            #expect(update["reconnect"] as? Bool == false)
        }
    }
}

@MainActor
@Test func cliUpdateUsageAndHelpNeverInitializeController() async throws {
    for arguments in [["update", "client"], ["update", "--allow-disconnect=yes"],
                      ["up", "--allow-disconnect"], ["doctor", "--allow-disconnect"],
                      ["help", "update", "--allow-disconnect"], ["--allow-disconnect"]] {
        let harness = CLIHarness()
        #expect(await harness.run(arguments + ["--json"]) == 2)
        #expect(harness.connects == 0)
        #expect(harness.actions.isEmpty)
    }
    for arguments in [["update", "--help"], ["help", "update"], ["--json", "update", "--help"]] {
        let harness = CLIHarness()
        #expect(await harness.run(arguments) == 0)
        #expect(harness.output.contains("--allow-disconnect"))
        #expect(harness.output.contains("SSH"))
        #expect(harness.connects == 0)
    }
}

@MainActor
@Test func cliUpdateAlreadyReadyResponseDoesNotNeedConfirmationOrDisconnectConsent() async throws {
    let harness = CLIHarness()
    harness.onRequest = { request in
        guard request.action == .update else { return nil }
        #expect(request.allowDisconnect == false)
        return .init(state: cliState(profiles: [.init(identifier: updateConfig, status: .connected)]),
                     operation: .init(id: request.id, state: .completed),
                     update: .init(id: request.id, phase: .completed, target: cliBuild))
    }
    #expect(await harness.run("update", "--json") == 0)
    let record = try #require(try updateRecords(harness).last)
    #expect(record["type"] as? String == "result")
    let data = try #require(record["data"] as? [String: Any])
    #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "connected")
    #expect(harness.actions == [.lifecycle, .userActivity, .update])
}

@MainActor
@Test func cliUpdateInterruptionAndFinalOutputFailureOnlyDetachConfirmedWork() async throws {
    let interrupted = updateHarness()
    let previous = interrupted.onRequest
    interrupted.onRequest = { request in
        if request.action == .operation { throw CancellationError() }
        return try await previous?(request)
    }
    #expect(await interrupted.run("update", "--allow-disconnect", "--json") == 130)
    let records = try updateRecords(interrupted)
    #expect(records.first?["operationId"] as? String == records.last?["operationId"] as? String)
    #expect(interrupted.actions == [.lifecycle, .userActivity, .update, .confirmOperation, .operation])

    let outputLost = updateHarness(phases: [.checkingReadiness, .completed])
    let send = outputLost.onRequest
    outputLost.onRequest = { request in
        if request.action == .operation { outputLost.failsOutput = true }
        return try await send?(request)
    }
    #expect(await outputLost.run("update", "--allow-disconnect", "--json") == 1)
    #expect(outputLost.actions == [.lifecycle, .userActivity, .update, .confirmOperation, .operation])
}

@MainActor
@Test func cliUpdateTransportErrorsNeverExposeRawTokensOrConfigs() async {
    struct PrivateTransportFailure: Error, CustomStringConvertible {
        let description = "auth-token-private WireGuard-private-key raw-config-private"
    }
    let harness = updateHarness()
    let previous = harness.onRequest
    harness.onRequest = { request in
        if request.action == .operation { throw PrivateTransportFailure() }
        return try await previous?(request)
    }
    #expect(await harness.run("update", "--allow-disconnect", "--json") == 1)
    #expect(!harness.output.contains("auth-token-private"))
    #expect(!harness.output.contains("WireGuard-private-key"))
    #expect(!harness.output.contains("raw-config-private"))
    #expect(harness.actions.filter { $0 == .update }.count == 1)
}

@MainActor
@Test func cliUpReportsActualExtensionSetupFailureAndAction() async throws {
    for (failure, code, suggestion) in [
        (CloudGatewayMacCommandFailure.extensionMismatch, "extension_mismatch", "cloudgateway update"),
        (.initialSetupRequired, "initial_setup_required", "initial setup"),
        (.approvalRequired, "approval_required", "System Settings"),
        (.restartRequired, "restart_required", "Restart"),
        (.invalidBundle, "invalid_bundle", "Reinstall"),
        (.checkingReadiness, "checking_readiness", "cloudgateway status"),
        (.activationFailed, "activation_failed", "cloudgateway doctor")
    ] {
        let harness = CLIHarness(cliState(selected: updateConfig))
        harness.onRequest = { request in
            if request.action == .connect { return .init(operation: .init(id: request.id, state: .accepted)) }
            if request.action == .confirmOperation {
                return .init(status: harness.status, operation: .init(id: request.contextId!, state: .failed),
                             outcome: .failed(failure))
            }
            return nil
        }
        #expect(await harness.run("up", "--json") == (failure == .activationFailed ? 9 : 4))
        let record = try #require(try updateRecords(harness).last)
        let error = try #require(record["error"] as? [String: Any])
        #expect(error["code"] as? String == code)
        #expect((error["suggestion"] as? String)?.contains(suggestion) == true)
        #expect(!harness.actions.contains(.update))
    }
}
