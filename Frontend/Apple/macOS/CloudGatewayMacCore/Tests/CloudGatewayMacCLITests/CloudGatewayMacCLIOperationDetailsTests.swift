import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let activeConfig = "uid1/us-chicago-1/d1482e58-5202-4771-82ae-bb34a313c537"
private let operationConfig = "uid1/us-sanjose-1/78ab8633-ae25-4287-885f-57bbbf6e7f63"

@MainActor
@Test func cliRemovalOutcomesUseExistingOperationLookup() async throws {
    for outcome in [CloudGatewayMacCommandOutcome.completed(warning: .localCleanupIncomplete), .failed(.clientActive), .unknown] {
        let harness = CLIHarness(cliState())
        let id = UUID()
        harness.operation = .init(id: id, state: outcome.state)
        harness.outcome = outcome
        let exit = await harness.run("status", "--operation", id.uuidString, "--json")
        let data = try #require(harness.json?["data"] as? [String: Any])
        let operation = try #require(data["operation"] as? [String: Any])
        switch outcome {
        case .completed:
            #expect(exit == 0)
            #expect(operation["state"] as? String == "completed")
            #expect(operation["warning"] as? String == "local_cleanup_incomplete")
        case .failed:
            #expect(exit == 4)
            #expect((operation["error"] as? [String: Any])?["code"] as? String == "client_active")
        default:
            #expect(exit == 10)
            #expect(operation["state"] as? String == "unknown")
        }
        #expect(!harness.actions.contains(.removeClient))
    }
}

@MainActor
@Test func cliOperationLookupUsesTheSameDetailedObservationAsOrdinaryStatus() async throws {
    for (observed, timestamp) in [(true, Optional(cliObservedAt)), (false, Optional(cliObservedAt)), (false, nil)] {
        let state = cliState(profiles: timestamp == nil ? [] : [.init(identifier: activeConfig, status: .connected)],
                             isObserved: observed, observedAt: timestamp)
        let id = UUID()
        let operation = CloudGatewayMacControllerOperation(id: id, state: .completed)
        let outcome = CloudGatewayMacCommandOutcome.startRequested(identifier: operationConfig, warning: nil)
        let ordinary = CLIHarness(state)
        ordinary.operation = operation
        ordinary.outcome = outcome
        #expect(await ordinary.run("status", "--json") == 0)
        let expected = try #require((ordinary.json?["data"] as? [String: Any])?["tunnel"] as? NSDictionary)
        let lookup = CLIHarness(state)
        lookup.onRequest = { request in
            guard request.action == .operation else { return nil }
            #expect(request.contextId == id)
            // Coarse status deliberately differs so all details must come from the snapshot
            return .init(state: state, status: .init(hasActiveTunnel: false, needsStop: false, observationAvailable: true),
                         operation: operation, outcome: outcome)
        }
        #expect(await lookup.run("status", "--operation", id.uuidString, "--json") == 0)
        let data = try #require(lookup.json?["data"] as? [String: Any])
        let tunnel = try #require(data["tunnel"] as? NSDictionary)
        #expect(tunnel == expected)
        if timestamp != nil {
            #expect(tunnel["configId"] as? String == activeConfig)
            #expect(tunnel["observedAt"] as? String == "2027-01-15T08:00:00Z")
        } else {
            #expect(tunnel["configId"] is NSNull)
            #expect(tunnel["observedAt"] is NSNull)
        }
        let result = try #require(data["operation"] as? [String: Any])
        #expect(result["configId"] as? String == operationConfig)
        #expect(result["id"] as? String == id.uuidString.lowercased())
        #expect(lookup.actions == [.lifecycle, .userActivity, .operation])
    }
}

@MainActor
@Test func cliOperationDetailsRemainFilteredAcrossLogoutAndAccountChanges() async throws {
    for account in [Optional<String>.none, "uid2"] {
        let state = cliState(account: account, retained: account != nil,
                             profiles: [.init(identifier: activeConfig, status: .connected)])
        let id = UUID()
        let harness = CLIHarness(state)
        harness.onRequest = { request in
            guard request.action == .operation else { return nil }
            return .init(state: state, operation: .init(id: id, state: .completed))
        }
        #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        let tunnel = try #require(data["tunnel"] as? [String: Any])
        #expect(tunnel["state"] as? String == "connected")
        #expect(tunnel["configId"] is NSNull)
        #expect(tunnel["observedAt"] as? String == "2027-01-15T08:00:00Z")
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(operation["configId"] is NSNull)
        #expect(operation["result"] is NSNull)
        #expect(!harness.output.contains("uid1/"))
    }
}

@MainActor
@Test func cliUnknownAndFailedOperationLookupsKeepTheirOwnResultAndCurrentTunnel() async throws {
    let state = cliState(profiles: [.init(identifier: activeConfig, status: .connected)], isObserved: false)
    for isUnknown in [false, true] {
        let requested = UUID()
        let harness = CLIHarness(state)
        harness.operation = .init(id: UUID(), state: .completed)
        harness.outcome = .startRequested(identifier: operationConfig, warning: nil)
        harness.onRequest = { request in
            guard request.action == .operation else { return nil }
            #expect(request.contextId == requested)
            return .init(state: state,
                         operation: .init(id: requested, state: isUnknown ? .unknown : .failed),
                         outcome: isUnknown ? nil : .failed(.vpnFailed))
        }
        #expect(await harness.run("status", "--operation", requested.uuidString, "--json") == (isUnknown ? 10 : 9))
        let data = try #require(harness.json?["data"] as? [String: Any])
        let tunnel = try #require(data["tunnel"] as? [String: Any])
        #expect(tunnel["configId"] as? String == activeConfig)
        #expect(tunnel["observedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(tunnel["observation"] as? String == "stale")
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(operation["id"] as? String == requested.uuidString.lowercased())
        #expect(operation["state"] as? String == (isUnknown ? "unknown" : "failed"))
        #expect(!harness.output.contains(operationConfig))
    }
    let wrong = CLIHarness(state)
    wrong.onRequest = { request in
        guard request.action == .operation else { return nil }
        return .init(state: state, operation: .init(id: UUID(), state: .completed))
    }
    #expect(await wrong.run("status", "--operation", UUID().uuidString, "--json") == 1)
    #expect((wrong.json?["error"] as? [String: Any])?["code"] as? String == "invalid_response")
}

@MainActor
@Test func cliDifferentBuildOperationLookupUsesOnlyCompatibleCoarseStatus() async throws {
    let state = cliState(profiles: [.init(identifier: activeConfig, status: .connected)])
    let id = UUID()
    let harness = CLIHarness(state)
    harness.lifecycle = .draining
    harness.onRequest = { request in
        guard request.action == .operation else { return nil }
        // Even an unexpected detailed payload cannot expose account metadata on another build
        return .init(state: state, status: .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true),
                     operation: .init(id: id, state: .completed))
    }
    #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
    let tunnel = try #require((harness.json?["data"] as? [String: Any])?["tunnel"] as? [String: Any])
    #expect(tunnel["state"] as? String == "connected")
    #expect(tunnel["configId"] is NSNull)
    #expect(tunnel["observedAt"] is NSNull)
    #expect(harness.actions == [.lifecycle, .operation])
    #expect(!harness.output.contains("uid1/"))
}

@MainActor
@Test func cliRealControllerOperationLookupKeepsOrdinaryAndUnknownIDsSeparateFromRetainedUpdate() async throws {
    let harness = CLIHarness(cliState())
    let now = cliObservedAt
    var journalData: Data?
    let workflow = CloudGatewayMacManagedUpdateWorkflow(load: { journalData }, persist: { journalData = $0 })
    let requests = try CloudGatewayMacControllerRequests(data: nil, now: { now }, persist: { _ in })
    let gate = try CloudGatewayMacExtensionUpdateOrchestrator(now: { now }, bootSession: { "lookup-boot" }, persist: { _ in })
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in cliState() }, hasPendingWork: { false },
        perform: { request, completion in
            #expect(request.action == .turnOff)
            completion(.completed(warning: nil))
            return true
        }, refresh: { .refreshed }, prepareClient: { throw CloudGatewayMacControllerFailure.invalidRequest },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false }, installedIdentity: { cliBuild },
        extensionIdentity: { cliBuild }, ping: { identity in
            CloudGatewayMacExtensionVersion(
                infoDictionary: ["CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version],
                codeHash: identity.codeHash
            )
        }, now: { now }
    )
    let controller = CloudGatewayMacControllerOrchestrator(identity: cliBuild, effects: effects, requests: requests,
                                                          extensionUpdates: gate, managedUpdates: workflow)
    harness.onRequest = { await controller.handle($0) }
    #expect(await harness.run("update", "--json") == 0)
    let updateId = try #require(workflow.journal?.id)
    #expect(workflow.journal?.phase == .completed)

    harness.output = ""
    #expect(await harness.run("down", "--json") == 0)
    let ordinaryIdText = try #require(harness.json?["operationId"] as? String)
    let ordinaryId = try #require(UUID(uuidString: ordinaryIdText))
    #expect(ordinaryId != updateId)
    for requested in [ordinaryId, UUID()] {
        harness.output = ""
        let isUnknown = requested != ordinaryId
        #expect(await harness.run("status", "--operation", requested.uuidString, "--json") == (isUnknown ? 10 : 0))
        let record = try #require(harness.json)
        let data = try #require(record["data"] as? [String: Any])
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(operation["id"] as? String == requested.uuidString.lowercased())
        #expect(operation["state"] as? String == (isUnknown ? "unknown" : "completed"))
        #expect(data["update"] == nil)
        if isUnknown {
            #expect((record["error"] as? [String: Any])?["code"] as? String == "operation_unknown")
        } else {
            #expect(record["error"] is NSNull)
            #expect(operation["result"] as? String == "completed")
        }
    }

    harness.output = ""
    #expect(await harness.run("status", "--operation", updateId.uuidString, "--json") == 0)
    let updateData = try #require(harness.json?["data"] as? [String: Any])
    #expect((updateData["update"] as? [String: Any])?["id"] as? String == updateId.uuidString.lowercased())
    #expect(harness.diagnostics.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func cliRealControllerRevokingCommandAndLookupRetainFailedSuppressionWarningWithoutUnrelatedUpdate(fails: Bool) async throws {
    for arguments in [["down"], ["auth", "logout"]] {
        let harness = CLIHarness(cliState())
        let now = cliObservedAt
        let updateId = UUID()
        let journalData = try JSONEncoder().encode(CloudGatewayMacManagedUpdateWorkflow.Journal(
            id: updateId, target: cliBuild, appIdentity: cliBuild, allowDisconnect: true, accountId: "uid1", identifier: operationConfig,
            reconnect: true, phase: .activating, confirmed: true, created: now, deadline: now.addingTimeInterval(30)
        ))
        var journalWrites = 0
        var markerWrites = 0
        let workflow = CloudGatewayMacManagedUpdateWorkflow(load: { journalData }, persist: { _ in
            journalWrites += 1
            throw CocoaError(.fileWriteUnknown)
        }, persistRevocation: { _ in
            markerWrites += 1
            throw CocoaError(.fileWriteUnknown)
        })
        let requests = try CloudGatewayMacControllerRequests(data: nil, now: { now }, persist: { _ in })
        let gate = try CloudGatewayMacExtensionUpdateOrchestrator(now: { now }, bootSession: { "warning-boot" }, persist: { _ in })
        var fence = CloudGatewayMacSessionFence()
        fence.changeAccount(to: "uid1")
        let session = fence.currentToken
        var performed: [CloudGatewayMacControllerRequest.Action] = []
        let effects = CloudGatewayMacControllerEffects(
            snapshot: { _, _ in cliState() }, hasPendingWork: { false },
            perform: { request, completion in
                performed.append(request.action)
                completion(fails ? .failed(.vpnFailed) : .completed(warning: nil))
                return true
            }, session: { session }, refresh: { .refreshed },
            prepareClient: { throw CloudGatewayMacControllerFailure.invalidRequest },
            setSetupState: { _ in }, hasAnyActiveTunnel: { false }, installedIdentity: { cliBuild },
            extensionIdentity: { cliBuild }, ping: { _ in nil }, now: { now }
        )
        let controller = CloudGatewayMacControllerOrchestrator(identity: cliBuild, effects: effects, requests: requests,
                                                              extensionUpdates: gate, managedUpdates: workflow)
        harness.onRequest = { await controller.handle($0) }
        #expect(await harness.run(arguments + ["--json"]) == (fails ? 9 : 0))
        let line = try #require(harness.output.split(separator: "\n").last)
        let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let id = try #require(record["operationId"] as? String)
        #expect(id != updateId.uuidString.lowercased())
        #expect(record["type"] as? String == (fails ? "error" : "result"))
        #expect((record["error"] is NSNull) == !fails)
        let data = try #require(record["data"] as? [String: Any])
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(operation["state"] as? String == (fails ? "failed" : "completed"))
        #expect(operation["warning"] as? String == "reconnect_suppression_not_persisted")
        #expect(data["update"] == nil)
        #expect(journalWrites > 0)
        #expect(markerWrites > 0)
        #expect(performed == [arguments == ["down"] ? .turnOff : .signOut])

        harness.output = ""
        #expect(await harness.run("status", "--operation", id, "--json") == (fails ? 9 : 0))
        let retained = try #require(harness.json?["data"] as? [String: Any])
        #expect((retained["operation"] as? [String: Any])?["warning"] as? String == "reconnect_suppression_not_persisted")
        #expect(retained["update"] == nil)
        harness.output = ""
        #expect(await harness.run("status", "--operation", id) == (fails ? 9 : 0))
        #expect(harness.output.contains("Reconnect suppression cannot be guaranteed after controller restart"))
        #expect(!harness.output.contains(updateId.uuidString.lowercased()))
        #expect(harness.diagnostics.isEmpty == !fails)
    }
}
