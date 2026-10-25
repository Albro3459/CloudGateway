import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let removeUUID = "78ab8633-ae25-4287-885f-57bbbf6e7f63"
private let otherRemoveUUID = "4830b738-2823-4888-bf37-2918ae356ad5"
private let removeConfig = "uid1/us-sanjose-1/" + removeUUID
private let otherRemoveConfig = "uid1/us-sanjose-1/" + otherRemoveUUID

private func removeState() -> CloudGatewayMacControllerState {
    cliState(clients: [
        cliClient(otherRemoveConfig, regionName: "California", name: "Laptop", owner: "b@example.com"),
        cliClient(removeConfig, regionName: "California", name: "Desktop", owner: "a@example.com",
                  installed: false, eligibility: .configMissing, status: nil),
        cliClient("uid2/us-sanjose-1/" + removeUUID, regionName: "California", name: "Other account"),
    ], selected: otherRemoveConfig, setup: .checkingConnection)
}

@MainActor
private func removeHarness(_ outcome: CloudGatewayMacCommandOutcome? = .completed(warning: nil),
                           state: CloudGatewayMacControllerState? = nil,
                           terminalState: CloudGatewayMacControllerOperation.State? = nil) -> CLIHarness {
    let harness = CLIHarness(state ?? removeState())
    harness.onRequest = { request in
        switch request.action {
        case .removeClient:
            #expect(request.identifier == removeConfig)
            #expect(request.regionId == nil)
            #expect(request.clientName == nil)
            #expect(request.allowDisconnect == nil)
            harness.operation = .init(id: request.id, state: .accepted)
            return .init(operation: harness.operation)
        case .confirmOperation:
            let id = try #require(harness.operation?.id)
            #expect(request.contextId == id)
            #expect(harness.output.contains(id.uuidString.lowercased()))
            let state: CloudGatewayMacControllerOperation.State = terminalState ?? {
                switch outcome {
                case .failed: .failed
                case .unknown, .expired: .unknown
                default: .completed
                }
            }()
            return .init(status: harness.status, operation: .init(id: id, state: state), outcome: outcome)
        default: return nil
        }
    }
    return harness
}

@MainActor
private func removalRecords(_ harness: CLIHarness) throws -> [[String: Any]] {
    try harness.output.split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

@MainActor
private func expectRemovalRecovery(_ harness: CLIHarness, isJSON: Bool) throws {
    let id = try #require(harness.operation?.id).uuidString.lowercased()
    let suggestion: String
    if isJSON {
        let record = try #require(try removalRecords(harness).last)
        #expect(record["operationId"] as? String == id)
        suggestion = try #require((record["error"] as? [String: Any])?["suggestion"] as? String)
    } else {
        #expect(harness.output.contains(id))
        suggestion = harness.diagnostics
    }
    #expect(suggestion.contains("cloudgateway status --operation " + id))
    #expect(suggestion.contains("refresh online inventory with cloudgateway refresh"))
    #expect(suggestion.contains("cloudgateway ls"))
    #expect(suggestion.contains("inspect the original client UUID before another manual removal attempt"))
    #expect(!suggestion.contains(removeConfig))
    #expect(harness.actions.filter { $0 == .removeClient }.count == 1)
    #expect(harness.actions.filter { $0 == .confirmOperation }.count <= 1)
}

@Test @MainActor func cliRemoveHelpAndUsageErrorsStayLocalWithoutImplicitSelection() async {
    for isJSON in [false, true] {
        for arguments in [["remove", "--help"], ["help", "remove"], ["remove", removeUUID, "--help"]] {
            let harness = CLIHarness()
            #expect(await harness.run(arguments + (isJSON ? ["--json"] : [])) == 0)
            #expect(harness.output.contains("--yes"))
            #expect(harness.output.contains("permanent"))
            #expect(harness.connects == 0)
            #expect(harness.actions.isEmpty)
        }
        for arguments in [["remove"], ["remove", "--yes"], ["remove", removeUUID],
                          ["remove", "sanjose", "1"], ["remove", removeUUID, "--yes=false"],
                          ["remove", "sanjose", "0", "--yes"], ["remove", removeConfig, "--yes"]] {
            let harness = CLIHarness(removeState())
            #expect(await harness.run(arguments + ["--non-interactive"] + (isJSON ? ["--json"] : [])) == 2)
            #expect(harness.connects == 0)
            #expect(harness.actions.isEmpty)
            #expect(!harness.output.contains("Accepted operation"))
        }
    }
}

@Test @MainActor func cliRemoveResolvesCanonicalIdentifierOnceFromFullAccountInventory() async throws {
    for selector in [[removeUUID.uppercased()], ["us-sanjose-1", "1"], ["California", "01"], ["sanjose", "1"]] {
        let harness = removeHarness()
        #expect(await harness.run(["remove"] + selector + ["--yes", "--json", "--non-interactive"]) == 0)
        let records = try removalRecords(harness)
        try #require(records.count == 2)
        #expect(records[0]["type"] as? String == "accepted")
        #expect(records[0]["schemaVersion"] as? Int == 1)
        #expect(records[0]["command"] as? String == "remove")
        #expect(records[0]["operationId"] as? String == records[1]["operationId"] as? String)
        #expect(records[1]["type"] as? String == "result")
        #expect(records[1]["error"] is NSNull)
        let data = try #require(records[1]["data"] as? [String: Any])
        #expect(data["command"] as? String == "remove")
        let operation = try #require(data["operation"] as? [String: Any])
        #expect(operation["result"] as? String == "completed")
        #expect(operation["configId"] is NSNull)
        #expect(data["choices"] is NSNull)
        #expect(data["creation"] == nil)
        #expect(!harness.output.contains("uid1/"))
        #expect(!harness.output.contains("uid2/"))
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
    }
}

@Test @MainActor func cliRemoveIncludesDisabledConfiglessInactiveAndCachedRowsWithoutReadinessOrCapacity() async {
    for eligibility in [CloudGatewayMacClientEligibility.regionUnavailable, .configMissing, .inactive, .eligible] {
        for cached in [false, true] {
            let state = cliState(access: cached ? .offline : .online, inventory: cached ? .cached : .current, clients: [
                cliClient(removeConfig, regionName: "California", name: "Mac", installed: false,
                          source: cached ? .cache : .cloud, eligibility: eligibility, status: nil),
            ], selected: otherRemoveConfig, setup: .checkingConnection, canCreate: false)
            let harness = removeHarness(state: state)
            #expect(await harness.run("remove", removeUUID, "--yes") == 0)
            #expect(harness.output.contains("Client removed\n"))
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
        }
    }
}

@Test @MainActor func cliRemoveWaitsForRestorationVerificationAndInventoryBeforeResolving() async {
    let harness = removeHarness()
    harness.states = [
        cliState(account: nil, restoring: true, access: .checking),
        cliState(account: nil, access: .unverified),
        cliState(inventory: .refreshing, clients: [cliClient(removeConfig, regionName: "California", name: "Old")]),
        removeState(),
    ]
    #expect(await harness.run("remove", "sanjose", "1", "--yes") == 0)
    #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .snapshot, .snapshot, .snapshot, .removeClient, .confirmOperation])
    #expect(harness.clock.now == .milliseconds(1_500))
}

@Test @MainActor func cliRemoveRejectsMissingAmbiguousAndOtherAccountTargetsWithoutReserving() async {
    let collision = cliState(clients: [
        cliClient(removeConfig, regionName: "California", name: "A"),
        cliClient("uid1/eu-sanjose-2/" + removeUUID, regionName: "California", name: "B"),
    ])
    let foreign = cliState(clients: [cliClient("uid2/us-sanjose-1/" + removeUUID, regionName: "California", name: "Other")])
    let cases: [(CloudGatewayMacControllerState, [String], Int32)] = [
        (removeState(), ["chicago", "1"], 2), (removeState(), ["sanjose", "3"], 2),
        (removeState(), [UUID().uuidString], 5), (foreign, [removeUUID], 5),
        (collision, ["sanjose", "1"], 2), (collision, ["California", "1"], 2), (collision, [removeUUID], 5),
    ]
    for (state, selector, exit) in cases {
        let harness = CLIHarness(state)
        #expect(await harness.run(["remove"] + selector + ["--yes", "--json"]) == exit)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot])
        #expect(!harness.output.contains("uid2/"))
    }
    let exact = removeHarness(state: collision)
    #expect(await exact.run("remove", "us-sanjose-1", "1", "--yes") == 0)
}

@Test @MainActor func cliRemovePreservesAccountAndInventoryGatesBeforeReservation() async {
    let cases: [(CloudGatewayMacControllerState, String, Int32)] = [
        (cliState(account: nil, retained: false), "sign_in_required", 3),
        (cliState(account: nil, retained: false, access: .denied), "access_denied", 3),
        (cliState(account: nil, access: .unreachable), "network_unavailable", 6),
        (cliState(inventory: .unavailable), "network_unavailable", 6),
    ]
    for (state, code, exit) in cases {
        let harness = CLIHarness(state)
        #expect(await harness.run("remove", removeUUID, "--yes", "--json") == exit)
        #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == code)
        #expect(!harness.actions.contains(.removeClient))
    }
    for state in [cliState(account: nil, restoring: true, access: .checking), cliState(inventory: .refreshing)] {
        let harness = CLIHarness(state)
        #expect(await harness.run("remove", removeUUID, "--yes", "--timeout", "1") == 8)
        #expect(!harness.actions.contains(.removeClient))
    }
}

@Test @MainActor func cliRemoveRequiresMatchingTrustedBuildAndReachableController() async {
    for scenario in ["draining", "mismatch", "untrusted", "unavailable"] {
        let harness = CLIHarness(removeState())
        switch scenario {
        case "draining": harness.lifecycle = .draining
        case "mismatch": harness.installed = .init(version: "1.3.0", build: "8", codeHash: String(repeating: "d", count: 64))
        case "untrusted": harness.isUntrusted = true
        default: harness.onBootstrap = { throw CloudGatewayMacControllerFailure.unavailable }; harness.unavailableHandshakes = 1
        }
        #expect(await harness.run("remove", removeUUID, "--yes", "--json") == 4)
        #expect(!harness.actions.contains(.snapshot))
        #expect(!harness.actions.contains(.removeClient))
    }
}

@Test @MainActor func cliRemoveRetainsSuccessfulWarningsAndUnrelatedTunnelObservation() async throws {
    for warning in [CloudGatewayMacCommandWarning.localCleanupIncomplete, .inventoryNotRefreshed] {
        for isJSON in [false, true] {
            let harness = removeHarness(.completed(warning: warning))
            harness.status = .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true, phase: .connected)
            #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == 0)
            if isJSON {
                let record = try #require(try removalRecords(harness).last)
                let data = try #require(record["data"] as? [String: Any])
                let operation = try #require(data["operation"] as? [String: Any])
                #expect(operation["warning"] as? String == (warning == .localCleanupIncomplete ? "local_cleanup_incomplete" : "inventory_not_refreshed"))
                #expect((data["tunnel"] as? [String: Any])?["state"] as? String == "connected")
            } else {
                #expect(harness.output.contains("Client removed\n"))
                #expect(harness.output.contains(warning == .localCleanupIncomplete ? "local cleanup incomplete" : "inventory not refreshed"))
                #expect(harness.output.contains("connected"))
                #expect(!harness.output.contains("VPN stopped"))
            }
            #expect(harness.diagnostics.isEmpty)
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
        }
    }
}

@Test @MainActor func cliRemovePreservesTypedFailuresAndActiveClientDisconnectGuidance() async throws {
    let cases: [(CloudGatewayMacCommandFailure, String, Int32)] = [
        (.clientActive, "client_active", 4), (.signInRequired, "sign_in_required", 3),
        (.accessDenied, "access_denied", 3), (.networkUnavailable, "network_unavailable", 6),
        (.configUnavailable, "config_unavailable", 5), (.selectionUnavailable, "selection_unavailable", 5),
        (.credentialsUnavailable, "credentials_unavailable", 4), (.busy, "busy", 7), (.internalError, "internal_error", 1),
    ]
    for (failure, code, exit) in cases {
        for isJSON in [false, true] {
            let harness = removeHarness(.failed(failure))
            #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == exit)
            if isJSON {
                let record = try #require(try removalRecords(harness).last)
                #expect((record["error"] as? [String: Any])?["code"] as? String == code)
                #expect(record["operationId"] as? String == harness.operation?.id.uuidString.lowercased())
                #expect(((record["data"] as? [String: Any])?["operation"] as? [String: Any])?["result"] as? String == "failed")
            } else if failure == .networkUnavailable {
                #expect(harness.diagnostics == "Waiting for network… Try again soon.\n")
                let id = try #require(harness.operation?.id).uuidString.lowercased()
                #expect(harness.output == "Accepted operation \(id)\n")
            }
            if failure == .clientActive {
                #expect((harness.output + harness.diagnostics).contains("Disconnect that client and wait for it to stop before removing it"))
            }
            #expect(!harness.output.contains("Client removed"))
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
        }
    }
}

@Test @MainActor func cliRemoveSessionChangesKeepOnlyReturnedRedactedCompletion() async throws {
    for isJSON in [false, true] {
        let harness = removeHarness(nil)
        let original = harness.onRequest
        harness.onRequest = { request in
            guard request.action == .confirmOperation else { return try await original?(request) }
            return .init(state: cliState(account: nil, retained: false),
                         operation: .init(id: request.contextId!, state: .completed))
        }
        #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == 0)
        if isJSON {
            let record = try #require(try removalRecords(harness).last)
            let data = try #require(record["data"] as? [String: Any])
            let operation = try #require(data["operation"] as? [String: Any])
            for key in ["result", "configId", "warning", "error"] { #expect(operation[key] is NSNull) }
            #expect(data["choices"] is NSNull)
            #expect(data["creation"] == nil)
        } else {
            #expect(harness.output.contains("Command completed\n"))
            #expect(!harness.output.contains("Client removed"))
        }
        #expect(!harness.output.contains(removeConfig))
        #expect(!harness.output.contains("Desktop"))
        #expect(!harness.output.contains("a@example.com"))
        #expect(harness.actions.filter { $0 == .removeClient }.count == 1)
    }
}

@Test @MainActor func cliRemoveAccountChangesNeverReinterpretOrResubmitTheOriginalSelector() async {
    let harness = removeHarness()
    let original = harness.onRequest
    harness.onRequest = { request in
        if request.action == .confirmOperation {
            return .init(state: cliState(account: "uid2", clients: [
                cliClient("uid2/us-sanjose-1/" + removeUUID, regionName: "California", name: "Other account"),
            ]), operation: .init(id: request.contextId!, state: .failed), outcome: .failed(.signInRequired))
        }
        return try await original?(request)
    }
    #expect(await harness.run("remove", "sanjose", "1", "--yes", "--json") == 3)
    #expect(!harness.output.contains("uid1/"))
    #expect(!harness.output.contains("uid2/"))
    #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
}

@Test @MainActor func cliRemoveTypedUnknownKeepsRecoveryInTextAndJSONWithoutResend() async throws {
    for isJSON in [false, true] {
        for polled in [false, true] {
            let harness = removeHarness(.unknown)
            let original = harness.onRequest
            harness.onRequest = { request in
                if polled, request.action == .confirmOperation {
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
                }
                if request.action == .operation {
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .unknown), outcome: .unknown)
                }
                return try await original?(request)
            }
            #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == 10)
            try expectRemovalRecovery(harness, isJSON: isJSON)
            if isJSON {
                let record = try #require(try removalRecords(harness).last)
                #expect((record["error"] as? [String: Any])?["code"] as? String == "operation_unknown")
                #expect(((record["data"] as? [String: Any])?["operation"] as? [String: Any])?["result"] as? String == "unknown")
            }
            #expect(harness.actions.filter { $0 == .operation }.count == (polled ? 1 : 0))
        }
    }
}

@Test @MainActor func cliRemoveLostConfirmationKeepsRecoveryInTextAndJSONWithoutResend() async throws {
    for isJSON in [false, true] {
        let harness = removeHarness()
        let original = harness.onRequest
        harness.onRequest = { request in
            if request.action == .confirmOperation { throw CloudGatewayMacControllerFailure.unavailable }
            return try await original?(request)
        }
        #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == 10)
        try expectRemovalRecovery(harness, isJSON: isJSON)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation])
    }
}

@Test @MainActor func cliRemoveUnknownRedactedAndLostLookupRepliesRetainRecoveryWithoutOldTargetData() async throws {
    for scenario in ["redacted", "lost", "restart", "malformed"] {
        for isJSON in [false, true] {
            let harness = removeHarness()
            let original = harness.onRequest
            harness.onRequest = { request in
                if request.action == .confirmOperation {
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
                }
                if request.action == .operation {
                    switch scenario {
                    case "lost": throw CloudGatewayMacControllerFailure.unavailable
                    case "restart":
                        harness.instanceId = UUID()
                        return .init(status: harness.status, operation: .init(id: request.contextId!, state: .completed))
                    case "malformed": return .init(status: harness.status, operation: .init(id: UUID(), state: .completed))
                    default:
                        return .init(state: cliState(account: nil, retained: false),
                                     operation: .init(id: request.contextId!, state: .unknown))
                    }
                }
                return try await original?(request)
            }
            let exit: Int32 = scenario == "lost" ? 4 : scenario == "malformed" ? 1 : 10
            #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == exit)
            try expectRemovalRecovery(harness, isJSON: isJSON)
            #expect(!harness.output.contains(removeConfig))
            #expect(!harness.output.contains("Desktop"))
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation, .operation])
        }
    }
}

@Test @MainActor func cliRemoveDeadlinesCoverEveryPhaseAndRetainAcceptedRecovery() async throws {
    let identity = CLIHarness()
    identity.holdsClientCreation = true
    #expect(await identity.run("remove", removeUUID, "--yes", "--timeout", "1") == 8)
    #expect(identity.actions.isEmpty)

    for action in [CloudGatewayMacControllerRequest.Action.snapshot, .removeClient, .confirmOperation, .operation] {
        let harness = removeHarness()
        let original = harness.onRequest
        harness.onRequest = { request in
            if request.action == action {
                if action == .removeClient { harness.operation = .init(id: request.id, state: .accepted) }
                harness.clock.expire()
                try await cliSuspendUntilCancelled()
            }
            if request.action == .confirmOperation {
                return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
            }
            return try await original?(request)
        }
        #expect(await harness.run("remove", removeUUID, "--yes", "--timeout", "1", "--json") == 8)
        #expect(harness.actions.filter { $0 == .removeClient }.count == (action == .snapshot ? 0 : 1))
        if action != .snapshot { try expectRemovalRecovery(harness, isJSON: true) }
        if action == .removeClient { #expect(!harness.actions.contains(.confirmOperation)) }
    }
    let stuck = CLIHarness(cliState(inventory: .refreshing))
    #expect(await stuck.run("remove", removeUUID, "--yes") == 8)
    #expect(stuck.clock.now == .milliseconds(29_500))
    #expect(!stuck.actions.contains(.removeClient))
}

@Test @MainActor func cliRemoveCancellationAfterConfirmationDetachesWithoutResend() async throws {
    for isJSON in [false, true] {
        for action in [CloudGatewayMacControllerRequest.Action.confirmOperation, .operation] {
            let harness = removeHarness()
            let original = harness.onRequest
            let (started, continuation) = AsyncStream<Void>.makeStream()
            harness.onRequest = { request in
                if request.action == action {
                    continuation.yield(())
                    try await cliSuspendUntilCancelled()
                }
                if request.action == .confirmOperation {
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
                }
                return try await original?(request)
            }
            let caller = Task { await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) }
            for await _ in started { break }
            caller.cancel()
            #expect(await caller.value == 130)
            continuation.finish()
            try expectRemovalRecovery(harness, isJSON: isJSON)
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient, .confirmOperation]
                + (action == .operation ? [.operation] : []))
        }
    }
}

@Test @MainActor func cliRemoveOutputFailureLeavesReservationUnconfirmedWithoutResend() async {
    for isJSON in [false, true] {
        let harness = removeHarness()
        harness.failsOutput = true
        #expect(await harness.run(["remove", removeUUID, "--yes"] + (isJSON ? ["--json"] : [])) == 1)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .removeClient])
        #expect(harness.output.isEmpty)
    }
}
