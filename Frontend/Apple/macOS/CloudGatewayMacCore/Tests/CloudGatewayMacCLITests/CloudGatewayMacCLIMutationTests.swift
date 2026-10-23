import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let mutationConfig = "uid1/us-east-1/mac"

@MainActor
private func mutationHarness(_ outcome: CloudGatewayMacCommandOutcome, state: CloudGatewayMacControllerState? = nil) -> CLIHarness {
    let harness = CLIHarness(state ?? cliState(selected: mutationConfig))
    var operationId: UUID?
    harness.onRequest = { request in
        switch request.action {
        case .connect, .turnOff, .signOut:
            operationId = request.id
            return .init(operation: .init(id: request.id, state: .accepted))
        case .confirmOperation:
            let id = try #require(operationId)
            #expect(request.contextId == id)
            #expect(harness.output.contains(id.uuidString.lowercased()))
            let failed: Bool = if case .failed = outcome { true } else { false }
            return .init(status: harness.status,
                         operation: .init(id: id, state: failed ? .failed : .completed), outcome: outcome)
        default: return nil
        }
    }
    return harness
}

@MainActor
@Test func cliStartFlushesAcceptanceBeforeConfirmAndReportsSubmissionSeparately() async throws {
    let harness = mutationHarness(.startRequested(identifier: mutationConfig, warning: nil))
    #expect(await harness.run("up", mutationConfig, "--json") == 0)
    let records = try harness.output.split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    try #require(records.count == 2)
    #expect(records[0]["type"] as? String == "accepted")
    #expect(records[0]["operationId"] as? String == records[1]["operationId"] as? String)
    let data = try #require(records[1]["data"] as? [String: Any])
    #expect((data["operation"] as? [String: Any])?["result"] as? String == "start_requested")
    #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "disconnected")
    #expect(!harness.actions.contains(.status))
    #expect(!harness.actions.contains(.operation))
    #expect(harness.actions == [.lifecycle, .snapshot, .connect, .confirmOperation])
}

@MainActor
@Test func cliFailedAcceptanceOutputNeverConfirmsOrRunsReservedWork() async {
    let harness = mutationHarness(.completed(warning: nil))
    harness.failsOutput = true
    #expect(await harness.run("down", "--json") == 1)
    #expect(harness.actions == [.lifecycle, .turnOff])
}

@MainActor
@Test func cliStartWaitsForColdExtensionReadinessBeforeReserving() async {
    let harness = mutationHarness(.startRequested(identifier: mutationConfig, warning: nil),
                                  state: cliState(selected: mutationConfig, setup: .checkingConnection))
    harness.states.append(cliState(selected: mutationConfig))
    #expect(await harness.run("up", mutationConfig, "--json") == 0)
    #expect(harness.actions == [.lifecycle, .snapshot, .snapshot, .connect, .confirmOperation])
}

@MainActor
@Test func cliStartWaitsForUnresolvedStartupInventoryButUsesAvailableConfigs() async {
    let row = cliClient(mutationConfig, regionName: "Region", name: "Mac", installed: false)
    let cold = mutationHarness(.startRequested(identifier: mutationConfig, warning: nil),
                               state: cliState(inventory: .refreshing, selected: mutationConfig))
    cold.states.append(cliState(clients: [row], selected: mutationConfig))
    #expect(await cold.run("up", mutationConfig, "--json") == 0)
    #expect(cold.actions == [.lifecycle, .snapshot, .snapshot, .connect, .confirmOperation])

    let available = mutationHarness(.startRequested(identifier: mutationConfig, warning: nil),
        state: cliState(inventory: .refreshing, clients: [row], selected: mutationConfig))
    #expect(await available.run("up", mutationConfig, "--json") == 0)
    #expect(available.actions == [.lifecycle, .snapshot, .connect, .confirmOperation])
    #expect(!available.actions.contains(.awaitRefresh))
}

@MainActor
@Test func cliIdentityFactoryCannotOutlastCallerDeadline() async {
    for command in [["up"], ["down"], ["auth", "logout"], ["refresh"], ["auth", "login"]] {
        let harness = CLIHarness()
        harness.holdsClientCreation = true
        #expect(await harness.run(command + ["--timeout", "1", "--json"]) == 8)
        #expect(harness.actions.isEmpty)
    }
}

@MainActor
@Test func cliUncertainConfirmationPreservesOperationIdAndNeverRetriesDown() async throws {
    let harness = CLIHarness()
    var id: UUID?
    harness.onRequest = { request in
        if request.action == .turnOff {
            id = request.id
            return .init(operation: .init(id: request.id, state: .accepted))
        }
        if request.action == .confirmOperation { throw CloudGatewayMacControllerFailure.unavailable }
        return nil
    }
    #expect(await harness.run("down", "--json") == 10)
    let operationId = try #require(id).uuidString.lowercased()
    let line = try #require(harness.output.split(separator: "\n").last)
    let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(record["operationId"] as? String == operationId)
    #expect((record["error"] as? [String: Any])?["suggestion"] as? String
        == "Check this operation before retrying: cloudgateway status --operation \(operationId)")
    #expect(harness.actions == [.lifecycle, .turnOff, .confirmOperation])
}

@MainActor
@Test func cliDownIsAvailableWhileSignedOutAndOnCompatibleUpdatingBuilds() async {
    let harness = mutationHarness(.completed(warning: nil), state: cliState(account: nil, retained: false))
    harness.lifecycle = .draining
    #expect(await harness.run("down") == 0)
    #expect(harness.output.contains("VPN stopped\n"))
    #expect(!harness.actions.contains(.snapshot))
    #expect(!harness.actions.contains(.connect))
}

@MainActor
@Test func cliLogoutReportsCleanupFailureAndNeverChangesVPN() async {
    let success = mutationHarness(.completed(warning: nil))
    #expect(await success.run("auth", "logout") == 0)
    #expect(success.output.contains("Signed out (VPN retained)\n"))
    #expect(success.actions == [.lifecycle, .signOut, .confirmOperation])

    let failed = CLIHarness()
    failed.onRequest = { request in
        if request.action == .signOut { return .init(operation: .init(id: request.id, state: .accepted)) }
        if request.action == .confirmOperation {
            return .init(status: failed.status,
                         operation: .init(id: request.contextId!, state: .failed, failure: .authCleanupFailed))
        }
        return nil
    }
    #expect(await failed.run("auth", "logout") == 4)
    #expect(failed.diagnostics.contains("Sign-out cleanup did not finish"))
    #expect(!failed.actions.contains(.turnOff))
}

@MainActor
@Test func cliStartUsesControllerInventoryAndPreservesTypedPolicyFailures() async {
    let scenarios: [(CloudGatewayMacCommandOutcome, Int32)] = [
        (.startRequested(identifier: mutationConfig, warning: nil), 0),
        (.alreadyActive(identifier: mutationConfig, warning: nil), 0),
        (.failed(.configUnavailable), 5),
        (.failed(.credentialsUnavailable), 4),
        (.failed(.networkUnavailable), 6),
        (.failed(.stopTimedOut), 8),
    ]
    // Installation, changed-config comparison, secret recovery, and account checks remain controller-owned
    for (outcome, exit) in scenarios {
        let state = cliState(clients: [cliClient(mutationConfig, regionName: "East", name: "Mac", installed: false)],
                             selected: mutationConfig)
        let harness = mutationHarness(outcome, state: state)
        #expect(await harness.run("up", mutationConfig) == exit)
        #expect(!harness.actions.contains(.refresh))
        #expect(!harness.actions.contains(.awaitRefresh))
    }
}

@MainActor
@Test func cliForeignAccountIdsRemainControllerAuthorizedAndCannotTriggerRefresh() async {
    let foreign = "other/us-east-1/mac"
    let harness = mutationHarness(.failed(.configUnavailable))
    let policy = harness.onRequest
    harness.onRequest = { request in
        if request.action == .connect { #expect(request.identifier == foreign) }
        return try await policy?(request)
    }
    #expect(await harness.run("up", foreign) == 5)
    #expect(!harness.actions.contains(.awaitRefresh))
    #expect(!harness.output.contains("VPN start requested"))
}

@MainActor
@Test func cliOfflineStartDelegatesMissingProfileRecoveryToAuthorizedControllerCache() async {
    let state = cliState(access: .offline, inventory: .cached, clients: [
        cliClient(mutationConfig, regionName: "East", name: "Mac", source: .cache, status: nil),
    ], profiles: [], selected: mutationConfig)
    let harness = mutationHarness(.startRequested(identifier: mutationConfig, warning: nil), state: state)
    #expect(await harness.run("up") == 0)
    #expect(harness.output.contains("VPN start requested\n"))
    #expect(harness.actions == [.lifecycle, .snapshot, .connect, .confirmOperation])
}

@MainActor
@Test func cliMissingSelectionShowsOnlyCurrentAuthorizedEligibleChoices() async throws {
    let eligible = cliClient(mutationConfig, regionName: "East", name: "Mac")
    let removed = cliClient("uid1/us-east-1/old", regionName: "East", name: "Old", eligibility: .inactive)
    let harness = mutationHarness(.failed(.selectionUnavailable), state: cliState(clients: [eligible, removed]))
    #expect(await harness.run("up", "--json") == 5)
    let line = try #require(harness.output.split(separator: "\n").last)
    let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let data = try #require(record["data"] as? [String: Any])
    let choices = try #require(data["choices"] as? [String: Any])
    let regions = try #require(choices["regions"] as? [[String: Any]])
    let configs = try #require(regions.first?["configs"] as? [[String: Any]])
    #expect(configs.count == 1)
    #expect(configs.first?["configId"] as? String == mutationConfig)
    #expect(harness.actions.filter { $0 == .snapshot }.count == 2)
}

@MainActor
@Test func cliStartWaitsThroughTheRestorationVerificationEdgeWithoutRefreshing() async {
    let harness = mutationHarness(.alreadyActive(identifier: mutationConfig, warning: nil))
    harness.states = [cliState(account: nil, access: .unverified), cliState(selected: mutationConfig)]
    #expect(await harness.run("up") == 0)
    #expect(harness.output.contains("VPN already active\n"))
    #expect(harness.actions == [.lifecycle, .snapshot, .snapshot, .connect, .confirmOperation])
}

@MainActor
@Test func cliCallerDeadlineCoversBootstrapAndEveryMutationPhase() async {
    let bootstrap = CLIHarness()
    bootstrap.unavailableHandshakes = 1
    bootstrap.onBootstrap = {
        bootstrap.clock.expire()
        try await cliSuspendUntilCancelled()
    }
    #expect(await bootstrap.run("down", "--timeout", "0.01") == 8)
    #expect(bootstrap.actions == [.lifecycle])

    for action in [CloudGatewayMacControllerRequest.Action.turnOff, .confirmOperation, .operation] {
        let harness = mutationHarness(.completed(warning: nil))
        if action == .operation {
            harness.onRequest = { request in
                if request.action == .turnOff { return .init(operation: .init(id: request.id, state: .accepted)) }
                if request.action == .confirmOperation {
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
                }
                return nil
            }
        }
        harness.hungActions = [action]
        #expect(await harness.run("down", "--timeout", "1") == 8)
        #expect(harness.actions.filter { $0 == .turnOff }.count == 1)
        if action != .turnOff { #expect(harness.diagnostics.contains("cloudgateway status --operation")) }
    }
}
