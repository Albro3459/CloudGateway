import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let refreshConfig = "uid1/us-east-1/mac"

@MainActor
@Test func cliExplicitRefreshWaitsForItsCorrelatedResultAndNeverReconnects() async throws {
    let harness = CLIHarness()
    let current = cliState(clients: [cliClient(refreshConfig, regionName: "East", name: "Mac")])
    var refreshCount = 0
    harness.onRequest = { request in
        guard request.action == .awaitRefresh else { return nil }
        refreshCount += 1
        return .init(state: current, refresh: refreshCount == 1 ? .timedOut : .refreshed)
    }
    #expect(await harness.run("refresh", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    #expect(data["result"] as? String == "refreshed")
    #expect(harness.actions == [.lifecycle, .userActivity, .awaitRefresh, .awaitRefresh])
    #expect(!harness.actions.contains(.connect))
    #expect(!harness.actions.contains(.turnOff))
}

@MainActor
@Test func cliListRefreshFiltersOnlyTheCompletedFreshInventory() async throws {
    let harness = CLIHarness()
    harness.onRequest = { request in
        guard request.action == .awaitRefresh else { return nil }
        return .init(state: cliState(clients: [
            cliClient(refreshConfig, regionName: "East", name: "Mac"),
            cliClient("uid1/us-west-2/laptop", regionName: "West", name: "Laptop"),
        ]), refresh: .refreshed)
    }
    #expect(await harness.run("list", "--refresh", "--region", "us-west-2", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    let regions = try #require(data["regions"] as? [[String: Any]])
    #expect(regions.count == 1)
    #expect(regions.first?["regionId"] as? String == "us-west-2")
    #expect(data["freshness"] as? String == "current")
    #expect(harness.actions == [.lifecycle, .userActivity, .awaitRefresh])
}

@MainActor
@Test func cliRefreshFailureNeverLabelsRetainedInventoryAsCurrent() async throws {
    for command in [["refresh"], ["list", "--refresh"]] {
        let harness = CLIHarness()
        harness.onRequest = { request in
            guard request.action == .awaitRefresh else { return nil }
            return .init(state: cliState(clients: [cliClient(refreshConfig, regionName: "East", name: "Mac")]),
                         refresh: .unavailable)
        }
        #expect(await harness.run(command + ["--json"]) == 6)
        let data = try #require(harness.json?["data"] as? [String: Any])
        let inventory: [String: Any]
        if command.first == "list" { inventory = data }
        else { inventory = try #require(data["inventory"] as? [String: Any]) }
        #expect(inventory["freshness"] as? String == "stale")
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "network_unavailable")
    }
}

@MainActor
@Test func cliRefreshReportsDeniedSignedOutSkippedAndSupersededExplicitly() async throws {
    let scenarios: [(CloudGatewayMacRefreshResult, Int32, String)] = [
        (.denied, 3, "access_denied"), (.signInRequired, 3, "sign_in_required"),
        (.skipped, 6, "refresh_skipped"), (.superseded, 7, "refresh_superseded"),
    ]
    for (result, exit, code) in scenarios {
        let harness = CLIHarness()
        harness.onRequest = { request in
            guard request.action == .awaitRefresh else { return nil }
            return .init(state: cliState(account: nil, retained: false), refresh: result)
        }
        #expect(await harness.run("refresh", "--json") == exit)
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == code)
        let data = try #require(harness.json?["data"] as? [String: Any])
        #expect(data["inventory"] is NSNull)
    }
}

@MainActor
@Test func cliRepeatedControllerRefreshTimeoutsStopAtTheCallerDeadline() async {
    let harness = CLIHarness()
    harness.onRequest = { request in
        guard request.action == .awaitRefresh else { return nil }
        return .init(state: cliState(), refresh: .timedOut)
    }
    #expect(await harness.run("refresh", "--timeout", "1", "--json") == 8)
    #expect(harness.actions == [.lifecycle, .userActivity, .awaitRefresh, .awaitRefresh])
    #expect((harness.json?["data"] as? [String: Any])?["result"] as? String == "timed_out")
}

@MainActor
@Test func cliDeadlineDoesNotWaitForTransportToCooperateWithCancellation() async {
    let harness = CLIHarness()
    var held: CheckedContinuation<Void, Never>?
    harness.onRequest = { request in
        guard request.action == .turnOff else { return nil }
        await withCheckedContinuation { continuation in
            held = continuation
            harness.clock.expire()
        }
        return .init(operation: .init(id: request.id, state: .accepted))
    }
    #expect(await harness.run("down", "--timeout", "0.01") == 8)
    #expect(held != nil)
    #expect(!harness.actions.contains(.confirmOperation))
    held?.resume()
}

@MainActor
@Test func cliListReportsActivityOnceAndWaitsForTheSharedStaleRefresh() async throws {
    let harness = CLIHarness(cliState())
    harness.onRequest = { request in
        guard request.action == .userActivity else { return nil }
        harness.states = [
            cliState(inventory: .refreshing),
            cliState(clients: [cliClient(refreshConfig, regionName: "East", name: "Fresh Mac")]),
        ]
        return .init()
    }
    #expect(await harness.run("list", "--json") == 0)
    #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .snapshot])
    #expect(harness.output.contains("Fresh Mac"))
    #expect(!harness.actions.contains(.awaitRefresh))
}

@MainActor
@Test func cliListActivityUsesTheSameCallerDeadline() async {
    let harness = CLIHarness(cliState())
    harness.hungActions = [.userActivity]
    #expect(await harness.run("list", "--timeout", "1", "--json") == 8)
    #expect(harness.actions == [.lifecycle, .userActivity])
    #expect(!harness.actions.contains(.snapshot))
}
