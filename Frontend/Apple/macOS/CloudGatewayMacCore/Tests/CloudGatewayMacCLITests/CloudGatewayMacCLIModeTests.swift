import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let modeConfig = "uid1/us-chicago-1/78ab8633-ae25-4287-885f-57bbbf6e7f63"

@MainActor
@Test func cliModeHelpAndInvalidModesStayLocal() async throws {
    for arguments in [["mode", "--help"], ["help", "mode", "--json"], ["mode", "status", "--help", "--json"]] {
        let harness = CLIHarness()
        #expect(await harness.run(arguments) == 0)
        #expect(harness.connects == 0)
    }
    for mode in ["bogus", "Mesh", "mesh-only", "FULL"] {
        let harness = CLIHarness()
        #expect(await harness.run("mode", mode, "--json") == 2)
        #expect(harness.json?["command"] as? String == "mode")
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "usage")
        #expect(harness.connects == 0)
    }
    let harness = CLIHarness()
    #expect(await harness.run("help", "mode", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    let commands = try #require(data["commands"] as? [[String: Any]])
    #expect(commands.compactMap { $0["name"] as? String } == ["mode status", "mode full", "mode mesh"])
    #expect(!harness.output.contains("auth login"))
}

@MainActor
@Test func cliFocusedModeReportsSelectedAndAppliedModesWithoutAuthOrOperation() async throws {
    let state = cliState(profiles: [.init(identifier: modeConfig, status: .connected, mode: .full)], selectedMode: .mesh)
    for arguments in [["mode"], ["mode", "status"]] {
        let harness = CLIHarness(state)
        #expect(await harness.run(arguments + ["--json"]) == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        #expect(data["selectedMode"] as? String == "mesh")
        #expect(data["activeMode"] as? String == "full")
        #expect(data["tunnelState"] as? String == "connected")
        #expect(data["observation"] as? String == "current")
        #expect(data["observedAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(data["auth"] == nil)
        #expect(data["operation"] == nil)
        #expect(!harness.output.contains(modeConfig))
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot])
    }
}

@MainActor
@Test func cliFocusedModeDistinguishesNoActiveTunnelFromUnknownMode() async throws {
    let disconnected = CLIHarness(cliState(selectedMode: .mesh))
    #expect(await disconnected.run("mode") == 0)
    #expect(disconnected.output.contains("Selected mode:     mesh\n"))
    #expect(disconnected.output.contains("Active mode:       none\n"))

    for (profiles, observed, timestamp) in [
        ([CloudGatewayMacObservedProfile(identifier: modeConfig, status: .connected, mode: nil)], true, Optional(cliObservedAt)),
        ([], false, Optional(cliObservedAt)),
        ([], false, nil),
    ] {
        let state = cliState(profiles: profiles, isObserved: observed, observedAt: timestamp, selectedMode: .mesh)
        let harness = CLIHarness(state)
        #expect(await harness.run("mode", "status") == 0)
        #expect(harness.output.contains("Active mode:       unknown\n"))
        #expect(!harness.output.contains("Active mode:       none\n"))
        #expect(harness.clock.now <= CloudGatewayMacCLISession.observationWait)
        harness.output = ""
        #expect(await harness.run("mode", "--json") == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        #expect(data["activeMode"] is NSNull)
        #expect(data["observation"] as? String == (observed ? "current" : timestamp == nil ? "unavailable" : "stale"))
    }
}

@MainActor
@Test func cliSignedOutModeKeepsAppliedEvidenceAndHidesAccountPreference() async throws {
    let state = cliState(account: nil, retained: false, access: .unverified,
                         profiles: [.init(identifier: modeConfig, status: .connected, mode: .mesh)], selectedMode: .full)
    for arguments in [["mode", "status"], ["status"]] {
        let harness = CLIHarness(state)
        #expect(await harness.run(arguments + ["--json"]) == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        let mode = try #require(arguments.first == "mode" ? data : data["mode"] as? [String: Any])
        #expect(mode["selectedMode"] is NSNull)
        #expect(mode["activeMode"] as? String == "mesh")
        #expect(!harness.output.contains("uid1"))
        if arguments.first == "status" {
            #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "connected")
            #expect((data["tunnel"] as? [String: Any])?["configId"] is NSNull)
            #expect((data["auth"] as? [String: Any])?["state"] as? String == "signed_out")
        }
    }
}

@MainActor
@Test func cliCombinedStatusMapsEveryAuthStateFromItsExistingSnapshotWithoutWaiting() async throws {
    let cases: [(CloudGatewayMacControllerState, String)] = [
        (cliState(account: nil, retained: false, access: .unverified), "signed_out"),
        (cliState(account: nil, retained: true, access: .unverified), "retained"),
        (cliState(account: nil, retained: true, restoring: true, access: .checking), "restoring"),
        (cliState(), "online"),
        (cliState(access: .offline, inventory: .cached), "offline"),
        (cliState(account: nil, access: .denied), "denied"),
    ]
    for (state, expected) in cases {
        let harness = CLIHarness(state, cliState())
        #expect(await harness.run("status", "--json") == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        #expect((data["auth"] as? [String: Any])?["state"] as? String == expected)
        #expect(data["mode"] is [String: Any])
        #expect(data["tunnel"] is [String: Any])
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot])
        #expect(harness.clock.now == .zero)
        #expect(harness.json?["schemaVersion"] as? Int == 1)
    }
}

@MainActor
@Test func cliCombinedOperationStatusRetainsDetailsAndAddsModeAuthFromTheSameReply() async throws {
    let state = cliState(access: .offline, inventory: .cached,
                         profiles: [.init(identifier: modeConfig, status: .connected, mode: .mesh)], selectedMode: .full)
    let id = UUID()
    let harness = CLIHarness(state)
    harness.onRequest = { request in
        guard request.action == .operation else { return nil }
        #expect(request.contextId == id)
        return .init(state: state, status: .init(hasActiveTunnel: false, needsStop: false, observationAvailable: true),
                     operation: .init(id: id, state: .completed), outcome: .alreadyActive(identifier: modeConfig, warning: .selectionNotSaved),
                     update: .init(id: id, phase: .completed, target: cliBuild, identifier: modeConfig, reconnect: true))
    }
    #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    #expect((data["tunnel"] as? [String: Any])?["configId"] as? String == modeConfig)
    #expect((data["mode"] as? [String: Any])?["selectedMode"] as? String == "full")
    #expect((data["mode"] as? [String: Any])?["activeMode"] as? String == "mesh")
    #expect((data["auth"] as? [String: Any])?["state"] as? String == "offline")
    #expect((data["operation"] as? [String: Any])?["warning"] as? String == "selection_not_saved")
    #expect((data["update"] as? [String: Any])?["reconnect"] as? Bool == true)
    #expect(harness.actions == [.lifecycle, .userActivity, .operation])
    harness.output = ""
    #expect(await harness.run("status", "--operation", id.uuidString) == 0)
    for detail in ["VPN:", "Observation:", "Config:", "Operation:", "selection not saved", "Update:", "Target:",
                   "Update config:", "Reconnect:", "Selected mode:", "Active mode:", "Auth:", "Signed in (offline"] {
        #expect(harness.output.contains(detail))
    }
}

@MainActor
@Test func cliMixedBuildStatusAndOperationsLeaveModeAndAuthUnavailable() async throws {
    let state = cliState(profiles: [.init(identifier: modeConfig, status: .connected, mode: .mesh)], selectedMode: .mesh)
    for lookup in [false, true] {
        let id = UUID()
        let harness = CLIHarness(state)
        harness.lifecycle = .draining
        harness.status = .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true, phase: .connected)
        harness.onRequest = { request in
            guard request.action == .operation else { return nil }
            return .init(state: state, status: harness.status, operation: .init(id: id, state: .completed))
        }
        let arguments = lookup ? ["status", "--operation", id.uuidString] : ["status"]
        #expect(await harness.run(arguments + ["--json"]) == 0)
        let data = try #require(harness.json?["data"] as? [String: Any])
        #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "connected")
        #expect(data["mode"] is NSNull)
        #expect(data["auth"] is NSNull)
        #expect(!harness.output.contains("uid1"))
        #expect(!harness.actions.contains(.snapshot))
        harness.output = ""
        #expect(await harness.run(arguments) == 0)
        #expect(harness.output.contains("Mode:  unavailable\n"))
        #expect(harness.output.contains("Auth:  unavailable\n"))
        harness.output = ""
        #expect(await harness.run("mode", "status", "--json") == 4)
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "incompatible_version")
    }
}

@MainActor
@Test func cliModeMutationForwardsTypedModeAndUsesExistingConfirmationAndPolling() async throws {
    for mode in CloudGatewayRoutingMode.allCases {
        let state = cliState(selectedMode: mode)
        let harness = CLIHarness(state)
        var operationId: UUID?
        harness.onRequest = { request in
            switch request.action {
            case .setMode:
                #expect(request.mode == mode)
                #expect(request.identifier == nil)
                operationId = request.id
                return .init(operation: .init(id: request.id, state: .accepted))
            case .confirmOperation:
                #expect(request.contextId == operationId)
                let id = try #require(request.contextId)
                #expect(harness.output.contains(id.uuidString.lowercased()))
                return .init(state: state, operation: .init(id: id, state: .running))
            case .operation:
                #expect(request.contextId == operationId)
                return .init(state: state, operation: .init(id: try #require(request.contextId), state: .completed), outcome: .completed(warning: nil))
            default: return nil
            }
        }
        #expect(await harness.run("mode", mode.rawValue, "--json") == 0)
        let records = try harness.output.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(records.count == 2)
        #expect(records.first?["type"] as? String == "accepted")
        #expect(records.first?["operationId"] as? String == records.last?["operationId"] as? String)
        let data = try #require(records.last?["data"] as? [String: Any])
        #expect(data["command"] as? String == "mode")
        #expect(data["requestedMode"] as? String == mode.rawValue)
        #expect((data["mode"] as? [String: Any])?["selectedMode"] as? String == mode.rawValue)
        #expect((data["mode"] as? [String: Any])?["activeMode"] is NSNull)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .setMode, .confirmOperation, .operation])
    }
}

@MainActor
@Test func cliModeMutationReportsControllerFailureAndObservedStateWithoutRetrying() async throws {
    let state = cliState(selectedMode: .mesh)
    for failure in [CloudGatewayMacCommandFailure.signInRequired, .busy, .stopTimedOut, .vpnFailed] {
        let harness = CLIHarness(state)
        harness.onRequest = { request in
            switch request.action {
            case .setMode: return .init(operation: .init(id: request.id, state: .accepted))
            case .confirmOperation:
                return .init(state: state, operation: .init(id: try #require(request.contextId), state: .failed), outcome: .failed(failure))
            default: return nil
            }
        }
        #expect(await harness.run("mode", "mesh", "--json") == CloudGatewayMacCLIError(commandFailure: failure).code.exitCode)
        let line = try #require(harness.output.split(separator: "\n").last)
        let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let data = try #require(record["data"] as? [String: Any])
        #expect((data["operation"] as? [String: Any])?["state"] as? String == "failed")
        #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "disconnected")
        #expect((data["mode"] as? [String: Any])?["activeMode"] is NSNull)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .setMode, .confirmOperation])
    }
}

@MainActor
@Test func cliModeMutationHumanOutputSeparatesPreferenceFromAppliedMode() async {
    let state = cliState(selectedMode: .mesh)
    let harness = CLIHarness(state)
    harness.onRequest = { request in
        switch request.action {
        case .setMode: return .init(operation: .init(id: request.id, state: .accepted))
        case .confirmOperation:
            return .init(state: state, operation: .init(id: try #require(request.contextId), state: .completed), outcome: .completed(warning: nil))
        default: return nil
        }
    }
    #expect(await harness.run("mode", "mesh") == 0)
    #expect(harness.output.contains("Routing mode selected: mesh\n"))
    #expect(harness.output.contains("Active mode:       none\n"))
    #expect(!harness.output.contains("VPN start requested"))
    #expect(!harness.actions.contains(.connect))
}

@MainActor
@Test func cliModeOutputFailureLeavesReservationUnconfirmedAndTimeoutDetaches() async throws {
    for failsOutput in [true, false] {
        let harness = CLIHarness(cliState())
        harness.failsOutput = failsOutput
        var id: UUID?
        harness.onRequest = { request in
            guard request.action == .setMode else { return nil }
            id = request.id
            return .init(operation: .init(id: request.id, state: .accepted))
        }
        harness.hungActions = [.confirmOperation]
        #expect(await harness.run("mode", "mesh", "--timeout", "1", "--json") == (failsOutput ? 1 : 8))
        #expect(harness.actions.filter { $0 == .setMode }.count == 1)
        #expect(harness.actions.contains(.confirmOperation) == !failsOutput)
        if !failsOutput {
            let line = try #require(harness.output.split(separator: "\n").last)
            let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(record["operationId"] as? String == id?.uuidString.lowercased())
            #expect(((record["error"] as? [String: Any])?["suggestion"] as? String)?.contains("cloudgateway status --operation") == true)
        }
    }
}

@MainActor
@Test func cliModeMutationPreflightReportsAuthFailuresBeforeReservingWork() async throws {
    let cases: [(CloudGatewayMacControllerState, Int32, String)] = [
        (cliState(account: nil, retained: false, access: .unverified), 3, "sign_in_required"),
        (cliState(account: nil, retained: true, access: .denied), 3, "access_denied"),
        (cliState(account: nil, retained: true, access: .unreachable), 6, "network_unavailable"),
    ]
    for (state, exitCode, errorCode) in cases {
        let harness = CLIHarness(state)
        #expect(await harness.run("mode", "mesh", "--json") == exitCode)
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == errorCode)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot])
        #expect(!harness.actions.contains(.setMode))
    }
}
