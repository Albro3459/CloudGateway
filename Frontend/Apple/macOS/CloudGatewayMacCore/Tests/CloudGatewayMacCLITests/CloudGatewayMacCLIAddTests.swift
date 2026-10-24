import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let addRegion = CloudGatewayRegion(regionId: "us-sanjose-1", displayName: "California", enabled: true,
                                           capacity: .known(limit: 10, allocated: 1))

@MainActor
private func addHarness(regions: [CloudGatewayRegion] = [addRegion],
                        outcome: CloudGatewayMacCommandOutcome = .completed(warning: nil)) -> CLIHarness {
    let harness = CLIHarness(cliState(canCreate: true))
    let contextId = UUID()
    harness.onRequest = { request in
        switch request.action {
        case .prepareClient:
            return .init(creation: .init(id: contextId, regions: regions))
        case .createClient:
            #expect(request.contextId == contextId)
            #expect(request.clientName == "Mac mini")
            #expect(request.regionId == addRegion.regionId)
            #expect(request.identifier == nil)
            harness.operation = .init(id: request.id, state: .accepted)
            return .init(operation: harness.operation)
        case .confirmOperation:
            let id = try #require(harness.operation?.id)
            #expect(request.contextId == id)
            #expect(harness.output.contains(id.uuidString.lowercased()))
            let state: CloudGatewayMacControllerOperation.State = switch outcome {
            case .failed: .failed
            case .unknown, .expired: .unknown
            default: .completed
            }
            return .init(status: harness.status, operation: .init(id: id, state: state), outcome: outcome)
        default: return nil
        }
    }
    return harness
}

@Test @MainActor func cliAddAcceptsCreationRegionIdDisplayNameAndCityWithoutExistingClients() async throws {
    for region in ["us-sanjose-1", "sanjose", "California", "CALIFORNIA"] {
        let harness = addHarness()
        #expect(await harness.run("add", region, "  Mac mini  ", "--json") == 0)
        let records = try harness.output.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        try #require(records.count == 2)
        #expect(records[0]["type"] as? String == "accepted")
        #expect(records[0]["command"] as? String == "add")
        #expect(records[0]["operationId"] as? String == records[1]["operationId"] as? String)
        let data = try #require(records[1]["data"] as? [String: Any])
        #expect(data["command"] as? String == "add")
        let creation = try #require(data["creation"] as? [String: String])
        #expect(creation == ["regionId": "us-sanjose-1", "name": "Mac mini"])
        #expect((data["operation"] as? [String: Any])?["result"] as? String == "completed")
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .prepareClient, .createClient, .confirmOperation])
    }
}

@Test @MainActor func cliAddReportsCreatedNameAndRetainsVPNAndInventoryWarning() async {
    let harness = addHarness(outcome: .completed(warning: .inventoryNotRefreshed))
    harness.status = .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true, phase: .connected)
    #expect(await harness.run("add", "sanjose", "Mac mini") == 0)
    #expect(harness.output.contains("Client created: Mac mini (us-sanjose-1)"))
    #expect(harness.output.contains("inventory not refreshed"))
    #expect(harness.output.contains("connected"))
    #expect(!harness.actions.contains(.connect))
    #expect(!harness.actions.contains(.turnOff))
    #expect(!harness.actions.contains(.disconnectClient))
}

@Test @MainActor func cliAddRejectsUnknownAmbiguousAndDisabledRegionsWithoutReservation() async {
    let second = CloudGatewayRegion(regionId: "us-sanjose-2", displayName: "California", enabled: true,
                                   capacity: .known(limit: 10, allocated: 1))
    let disabled = CloudGatewayRegion(regionId: "us-disabled-1", displayName: "Disabled", enabled: false,
                                     capacity: .known(limit: 10, allocated: 1))
    for region in ["missing", "sanjose", "California", disabled.regionId] {
        let harness = addHarness(regions: [addRegion, second, disabled])
        #expect(await harness.run("add", region, "Mac mini", "--json") == 2)
        #expect(!harness.actions.contains(.createClient))
        #expect(!harness.actions.contains(.confirmOperation))
        #expect(harness.output.contains("us-sanjose-1"))
    }
    let exact = addHarness(regions: [addRegion, second])
    #expect(await exact.run("add", "us-sanjose-1", "Mac mini") == 0)
}

@Test @MainActor func cliAddRequiresKnownAvailableCapacityBeforeReserving() async {
    let cases: [(CloudGatewayRegionCapacity, Int32)] = [(.unknown, 6), (.known(limit: 1, allocated: 1), 5)]
    for (capacity, exit) in cases {
        let region = CloudGatewayRegion(regionId: addRegion.regionId, displayName: addRegion.displayName,
                                        enabled: true, capacity: capacity)
        let harness = addHarness(regions: [region])
        #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == exit)
        #expect(!harness.actions.contains(.createClient))
    }
}

@Test @MainActor func cliAddWaitsForRestorationAndInventoryBeforePreparing() async {
    let harness = addHarness()
    harness.states = [cliState(account: nil, restoring: true), cliState(inventory: .refreshing), cliState(canCreate: true)]
    #expect(await harness.run("add", "sanjose", "Mac mini") == 0)
    #expect(harness.actions.filter { $0 == .snapshot }.count == 3)
}

@Test @MainActor func cliAddRejectsInvalidNamesBeforeConnecting() async {
    for arguments in [["add"], ["add", "sanjose"], ["add", "sanjose", "  "], ["add", "sanjose", "Mac\nmini"]] {
        let harness = CLIHarness()
        #expect(await harness.run(arguments + ["--json"]) == 2)
        #expect(harness.connects == 0)
        #expect(harness.actions.isEmpty)
    }
}

@Test @MainActor func cliAddChecksAccountAndControllerAvailabilityBeforePreparing() async {
    let cases: [(CloudGatewayMacControllerState, Int32)] = [
        (cliState(account: nil, retained: false), 3),
        (cliState(account: nil, access: .denied), 3),
        (cliState(account: nil, access: .unreachable), 6),
        (cliState(), 7),
    ]
    for (state, exit) in cases {
        let harness = CLIHarness(state)
        #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == exit)
        #expect(!harness.actions.contains(.prepareClient))
    }
    let stale = CLIHarness()
    stale.lifecycle = .draining
    #expect(await stale.run("add", "sanjose", "Mac mini", "--json") == 4)
    #expect(!stale.actions.contains(.prepareClient))
}

@Test @MainActor func cliAddPreparationFailuresNeverReserveAndRespectCallerDeadline() async {
    let failed = addHarness()
    failed.onRequest = { request in
        if request.action == .prepareClient { throw CloudGatewayMacControllerFailure.unavailable }
        return nil
    }
    #expect(await failed.run("add", "sanjose", "Mac mini", "--json") == 6)
    #expect(!failed.actions.contains(.createClient))
    let stalled = addHarness()
    stalled.hungActions = [.prepareClient]
    #expect(await stalled.run("add", "sanjose", "Mac mini", "--timeout", "1", "--json") == 8)
    #expect(!stalled.actions.contains(.createClient))
}

@Test @MainActor func cliAddDoesNotConfirmWhenAcceptanceOutputFails() async {
    let harness = addHarness()
    harness.failsOutput = true
    #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == 1)
    #expect(harness.actions.contains(.createClient))
    #expect(!harness.actions.contains(.confirmOperation))
}

@Test @MainActor func cliAddReportsAccountChangesAndUnknownOutcomesWithoutRetrying() async {
    let cases: [(CloudGatewayMacCommandOutcome, Int32)] = [(.failed(.signInRequired), 3), (.unknown, 10)]
    for (outcome, exit) in cases {
        let harness = addHarness(outcome: outcome)
        #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == exit)
        #expect(harness.actions.filter { $0 == .createClient }.count == 1)
    }
    let harness = addHarness()
    let original = harness.onRequest
    harness.onRequest = { request in
        if request.action == .confirmOperation { throw CloudGatewayMacControllerFailure.unavailable }
        return try await original?(request)
    }
    #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == 10)
    #expect(harness.actions.filter { $0 == .createClient }.count == 1)
    #expect(harness.output.contains("Check this operation before retrying"))
}

@Test @MainActor func cliAddPreservesAuthFailuresObservedDuringPreparation() async throws {
    let cases: [(CloudGatewayMacControllerState, String, Int32)] = [
        (cliState(account: nil, retained: false, access: .denied), "access_denied", 3),
        (cliState(account: nil, retained: false), "sign_in_required", 3),
        (cliState(account: nil, access: .unreachable), "network_unavailable", 6),
        (cliState(canCreate: true), "network_unavailable", 6),
    ]
    for (state, code, exit) in cases {
        let harness = addHarness()
        harness.onRequest = { request in
            if request.action == .prepareClient {
                harness.states = [state]
                return .init(error: .unavailable)
            }
            return nil
        }
        #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == exit)
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == code)
        #expect(harness.actions.filter { $0 == .snapshot }.count == 2)
        #expect(!harness.actions.contains(.createClient))
        #expect(!harness.actions.contains(.confirmOperation))
    }
}

@Test @MainActor func cliAddKeepsPreparationNetworkFailureWhenFollowupSnapshotFails() async {
    let harness = addHarness()
    var preparationFailed = false
    harness.onRequest = { request in
        if request.action == .prepareClient {
            preparationFailed = true
            return .init(error: .unavailable)
        }
        if request.action == .snapshot, preparationFailed { throw CloudGatewayMacControllerFailure.unavailable }
        return nil
    }
    #expect(await harness.run("add", "sanjose", "Mac mini", "--json") == 6)
    #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "network_unavailable")
    #expect(!harness.actions.contains(.createClient))
}
