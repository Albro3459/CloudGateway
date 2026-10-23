import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let activeConfig = "uid1/us-chicago-1/d1482e58-5202-4771-82ae-bb34a313c537"
private let operationConfig = "uid1/us-sanjose-1/78ab8633-ae25-4287-885f-57bbbf6e7f63"

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
