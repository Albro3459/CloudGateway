import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let east = "uid1/us-east-1/mac"
private let west = "uid1/us-west-2/laptop"

private func onlineState(access: CloudGatewayMacAccessState = .online,
                         inventory: CloudGatewayMacInventoryFreshness = .current,
                         source: CloudGatewayMacInventorySource = .cloud, isObserved: Bool = true,
                         observedAt: Date? = cliObservedAt) -> CloudGatewayMacControllerState {
    cliState(access: access, inventory: inventory, clients: [
        cliClient(west, regionName: "US West", order: 2, name: "Laptop", installed: source == .cache, source: source, status: nil),
        cliClient(east, regionName: "US East", order: 1, name: "Mac", source: source, status: .connected),
        cliClient("uid1/us-east-1/old", regionName: "US East", order: 1, name: "Old", ip: nil, installed: false,
                  eligibility: .inactive, cloudState: .removed, status: nil),
    ], profiles: [.init(identifier: east, status: .connected)], isObserved: isObserved, observedAt: observedAt, selected: east)
}

@MainActor
@Test func cliHelpAndVersionNeverReachTheController() async {
    let harness = CLIHarness()
    #expect(await harness.run() == 0)
    #expect(harness.output.hasPrefix("Control the CloudGateway VPN on this Mac\n\nUsage: cloudgateway <command> [options]\n"))
    #expect(harness.output.contains("  up [config-id]"))
    #expect(!harness.output.contains("--controller"))
    #expect(!harness.output.contains("--cli"))
    #expect(await harness.run("auth", "login", "--help") == 0)
    #expect(await harness.run("--version") == 0)
    #expect(harness.output.hasSuffix("CloudGateway 1.2.0 (7)\n"))
    #expect(await harness.run("bogus") == 2)
    #expect(harness.diagnostics == "Error: Unknown command 'bogus'\nRun: cloudgateway help\n")
    #expect(harness.connects == 0)
    #expect(harness.actions.isEmpty)
}

@MainActor
@Test func cliUnconfiguredDoctorFailsBeforeConnecting() async {
    let harness = CLIHarness()
    #expect(await harness.run("doctor", "--json") == 1)
    #expect(harness.json?["type"] as? String == "error")
    #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "not_implemented")
    #expect(harness.connects == 0)
}

@MainActor
@Test func cliSignedOutStatusHidesAccountDetails() async {
    let harness = CLIHarness(cliState(account: nil, retained: false, access: .unverified, inventory: .unavailable,
                                      profiles: [.init(identifier: "other/region/client", status: .connected)]))
    #expect(await harness.run("auth", "status") == 0)
    #expect(harness.output == """
        Auth:         Signed out
        Account:      none
        Access:       unverified
        Credentials:  unknown

        """)
    harness.output = ""
    #expect(await harness.run("status", "--json") == 0)
    let tunnel = (harness.json?["data"] as? [String: Any])?["tunnel"] as? [String: Any]
    #expect(tunnel?["state"] as? String == "connected")
    #expect(tunnel?["configId"] is NSNull)
    #expect(!harness.output.contains("other/"))
    #expect(await harness.run("list") == 3)
    #expect(harness.diagnostics == "Error: Sign-in required\nRun: cloudgateway auth login\n")
}

@MainActor
@Test func cliWaitsForStartupRestorationWithinTheDeadline() async {
    let restoring = cliState(account: nil, restoring: true, access: .checking, inventory: .unavailable)
    let harness = CLIHarness(restoring, restoring, onlineState())
    #expect(await harness.run("auth", "status", "--json") == 0)
    #expect((harness.json?["data"] as? [String: Any])?["state"] as? String == "online")
    #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, .snapshot, .snapshot])
    #expect(harness.clock.now == .seconds(1))

    // Read commands default to a 30 second deadline when --timeout is absent
    let defaulted = CLIHarness(restoring)
    #expect(await defaulted.run("list") == 8)
    #expect(defaulted.clock.now == .milliseconds(29_500))

    let stuck = CLIHarness(restoring)
    #expect(await stuck.run("auth", "status", "--timeout", "2", "--json") == 0)
    #expect((stuck.json?["data"] as? [String: Any])?["state"] as? String == "restoring")
    #expect(stuck.clock.now < .seconds(2))
    stuck.output = ""
    #expect(await stuck.run("list", "--timeout", "2", "--json") == 8)
    #expect((stuck.json?["error"] as? [String: Any])?["message"] as? String == "CloudGateway is still restoring this session")
}

@MainActor
@Test func cliListsAuthorizedOnlineInventoryByRegion() async {
    let harness = CLIHarness(onlineState())
    #expect(await harness.run("list") == 0)
    #expect(harness.output == """
        US East (us-east-1)
          Mac  uid1/us-east-1/mac  10.0.0.2  installed, connected, selected
          Old  uid1/us-east-1/old  -         not installed, removed, inactive

        US West (us-west-2)
          Laptop  uid1/us-west-2/laptop  10.0.0.2  not installed

        Tunnel observation: current at 2027-01-15T08:00:00Z
        Inventory: current

        """)
    harness.output = ""
    #expect(await harness.run("list", "--region", "us-west-2", "--json") == 0)
    #expect(harness.output == #"""
        {"command":"list","data":{"accountId":"uid1","freshness":"current","profileObservation":"current","profilesObservedAt":"2027-01-15T08:00:00Z","regionId":"us-west-2","regions":[{"configs":[{"cloudState":"active","configId":"uid1/us-west-2/laptop","eligibility":"eligible","installed":false,"internalIp":"10.0.0.2","name":"Laptop","owner":null,"readAt":"1970-01-01T00:00:00Z","selected":false,"source":"cloud","tunnel":null,"updatedAt":null}],"name":"US West","regionId":"us-west-2"}],"scope":"authorized"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}

        """#)
    harness.output = ""
    #expect(await harness.run("list", "--region", "eu-west-1") == 0)
    #expect(harness.output.hasPrefix("No configs in region eu-west-1\n"))
}

@MainActor
@Test func cliListLabelsRetainedTunnelStateAfterAProfileReadFails() async throws {
    let harness = CLIHarness(onlineState())
    #expect(await harness.run("list", "--json") == 0)
    let current = try #require(harness.json?["data"] as? [String: Any])
    #expect(current["profileObservation"] as? String == "current")
    #expect(current["profilesObservedAt"] as? String == "2027-01-15T08:00:00Z")

    harness.states = [onlineState(isObserved: false)]
    harness.output = ""
    #expect(await harness.run("list") == 0)
    #expect(harness.output.contains("installed, connected (stale), selected"))
    #expect(harness.output.hasSuffix("Tunnel observation: stale, last observed at 2027-01-15T08:00:00Z\nInventory: current\n"))

    harness.output = ""
    #expect(await harness.run("list", "--json") == 0)
    let stale = try #require(harness.json?["data"] as? [String: Any])
    #expect(stale["freshness"] as? String == "current")
    #expect(stale["profileObservation"] as? String == "stale")
    #expect(stale["profilesObservedAt"] as? String == current["profilesObservedAt"] as? String)
    let regions = try #require(stale["regions"] as? [[String: Any]])
    let configs = try #require(regions.first?["configs"] as? [[String: Any]])
    #expect(configs.first?["tunnel"] as? String == "connected")
}

@MainActor
@Test func cliListWithoutAProfileObservationKeepsTunnelStateUnknown() async throws {
    let harness = CLIHarness(onlineState(isObserved: false, observedAt: nil))
    #expect(await harness.run("list", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    #expect(data["freshness"] as? String == "current")
    #expect(data["profileObservation"] as? String == "unavailable")
    #expect(data["profilesObservedAt"] is NSNull)
    let regions = try #require(data["regions"] as? [[String: Any]])
    let configs = try #require(regions.first?["configs"] as? [[String: Any]])
    #expect(configs.first?["tunnel"] is NSNull)

    harness.output = ""
    #expect(await harness.run("list") == 0)
    #expect(!harness.output.contains("connected"))
    #expect(harness.output.hasSuffix("Tunnel observation: unavailable\nInventory: current\n"))
}

@MainActor
@Test func cliOfflineListShowsReducedCachedScope() async {
    let harness = CLIHarness(onlineState(access: .offline, inventory: .cached, source: .cache))
    #expect(await harness.run("auth", "status", "--json") == 0)
    #expect((harness.json?["data"] as? [String: Any])?["state"] as? String == "offline")
    harness.output = ""
    #expect(await harness.run("list", "--json") == 0)
    let data = harness.json?["data"] as? [String: Any]
    #expect(data?["scope"] as? String == "installed")
    #expect(data?["freshness"] as? String == "cached")
    harness.output = ""
    #expect(await harness.run("list") == 0)
    #expect(harness.output.hasSuffix("\nOffline: showing this account's installed configs from cached authorization\n"))
}

@MainActor
@Test func cliDeniedAndUnavailableInventoryFailWithStableCodes() async {
    let denied = CLIHarness(cliState(account: nil, retained: false, access: .denied, inventory: .unavailable))
    #expect(await denied.run("auth", "status", "--json") == 0)
    #expect((denied.json?["data"] as? [String: Any])?["state"] as? String == "denied")
    #expect(await denied.run("list") == 3)
    #expect(denied.diagnostics.hasPrefix("Error: Account access was denied\n"))

    let unreachable = CLIHarness(cliState(account: nil, access: .unreachable, inventory: .unavailable))
    #expect(await unreachable.run("auth", "status", "--json") == 0)
    #expect((unreachable.json?["data"] as? [String: Any])?["state"] as? String == "retained")
    #expect(await unreachable.run("list") == 6)

    let stale = CLIHarness(cliState(inventory: .unavailable))
    #expect(await stale.run("list", "--json") == 6)
    #expect((stale.json?["error"] as? [String: Any])?["code"] as? String == "network_unavailable")

    let refreshing = CLIHarness(cliState(inventory: .refreshing))
    #expect(await refreshing.run("list", "--timeout", "1") == 8)
    #expect(refreshing.diagnostics.hasPrefix("Error: CloudGateway is still loading inventory\n"))
}

@MainActor
@Test func cliStatusLabelsStaleAndMissingObservations() async {
    let stale = CLIHarness(cliState(profiles: [.init(identifier: east, status: .connected)], isObserved: false))
    #expect(await stale.run("status") == 0)
    #expect(stale.output.hasPrefix("VPN:          connected\nObservation:  stale, last observed at 2027-01-15T08:00:00Z\nConfig:       \(east)\n"))
    #expect(stale.clock.now <= CloudGatewayMacCLISession.observationWait)

    let missing = CLIHarness(cliState(isObserved: false, observedAt: nil))
    #expect(await missing.run("status", "--json") == 0)
    let tunnel = (missing.json?["data"] as? [String: Any])?["tunnel"] as? [String: Any]
    #expect(tunnel?["state"] as? String == "unknown")
    #expect(tunnel?["observation"] as? String == "unavailable")
}

@MainActor
@Test func cliStatusReportsTheLatestOperation() async {
    let id = UUID()
    let harness = CLIHarness(onlineState())
    harness.operation = .init(id: id, state: .completed)
    harness.outcome = .startRequested(identifier: east, warning: .selectionNotSaved)
    #expect(await harness.run("status") == 0)
    #expect(harness.output.contains("Operation:    \(id.uuidString.lowercased()) completed, start requested for \(east) (selection not saved)\n"))
}

@MainActor
@Test func cliStartsTheControllerOnceThenRetriesTheHandshake() async {
    let harness = CLIHarness(onlineState())
    harness.unavailableHandshakes = 3
    #expect(await harness.run("auth", "status") == 0)
    #expect(harness.bootstraps == 1)
    #expect(harness.actions == [.lifecycle, .lifecycle, .lifecycle, .lifecycle, .userActivity, .snapshot])
}

@MainActor
@Test func cliOtherBuildsUseCompatibleStatusOnly() async {
    let harness = CLIHarness(onlineState())
    harness.lifecycle = .draining
    harness.status = .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true)
    #expect(await harness.run("auth", "status", "--json") == 4)
    #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "incompatible_version")
    #expect(await harness.run("status") == 0)
    #expect(harness.output.contains("VPN:          connected\n"))
    #expect(!harness.actions.contains(.snapshot))

    let invalid = CLIHarness(onlineState())
    invalid.lifecycle = .invalidInstallation
    invalid.installed = nil
    #expect(await invalid.run("list", "--json") == 4)
    #expect((invalid.json?["error"] as? [String: Any])?["code"] as? String == "installation_required")
}

@MainActor
@Test func cliUntrustedBuildAndHungControllerFailWithinTheirCategories() async {
    let untrusted = CLIHarness(onlineState())
    untrusted.isUntrusted = true
    #expect(await untrusted.run("status") == 4)
    #expect(untrusted.diagnostics.hasPrefix("Error: CloudGateway could not verify its running build\n"))

    let hung = CLIHarness(onlineState())
    hung.hungActions = [.snapshot]
    #expect(await hung.run("list", "--json") == 8)
    #expect((hung.json?["error"] as? [String: Any])?["code"] as? String == "timeout")
}

@MainActor
@Test func cliOperationLookupMapsTheRetainedOutcome() async {
    let id = UUID()
    let harness = CLIHarness()
    harness.operation = .init(id: id, state: .completed)
    harness.outcome = .startRequested(identifier: east, warning: nil)
    #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
    #expect(harness.json?["operationId"] as? String == id.uuidString.lowercased())
    #expect(harness.actions == [.lifecycle, .userActivity, .operation])

    harness.outcome = .failed(.vpnFailed)
    harness.operation = .init(id: id, state: .failed, failure: .commandFailed)
    #expect(await harness.run("status", "--operation", id.uuidString) == 9)
    #expect(harness.diagnostics.hasSuffix("Error: The VPN operation failed\nRun: cloudgateway status\n"))

    harness.outcome = .failed(.stopTimedOut)
    harness.operation = .init(id: id, state: .unknown)
    #expect(await harness.run("status", "--operation", id.uuidString) == 8)

    // Another session's connect result keeps only its coarse state
    harness.outcome = nil
    harness.operation = .init(id: id, state: .completed)
    harness.output = ""
    #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 0)
    let operation = (harness.json?["data"] as? [String: Any])?["operation"] as? [String: Any]
    #expect(operation?["result"] is NSNull)
    #expect(operation?["configId"] is NSNull)
}

@MainActor
@Test func cliUnknownOperationReportsObservedState() async throws {
    let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    let harness = CLIHarness()
    harness.status = .init(hasActiveTunnel: true, needsStop: true, observationAvailable: true)
    #expect(await harness.run("status", "--operation", id.uuidString, "--json") == 10)
    #expect(harness.output == #"""
        {"command":"status","data":{"operation":{"configId":null,"error":{"code":"operation_unknown","message":"The operation result is unknown or no longer retained","suggestion":"Run cloudgateway status before trying again"},"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","result":null,"state":"unknown","warning":null},"tunnel":{"configId":null,"observation":"current","observedAt":null,"state":"connected"}},"error":{"code":"operation_unknown","message":"The operation result is unknown or no longer retained","suggestion":"Run cloudgateway status before trying again"},"operationId":"6f9619ff-8b86-d011-b42d-00c04fc964ff","schemaVersion":1,"type":"error"}

        """#)
    #expect(harness.diagnostics.isEmpty)
}

@MainActor
@Test func cliOutputFailureExitsAsInternal() async {
    let harness = CLIHarness()
    harness.failsOutput = true
    #expect(await harness.run("--version") == 1)
}
