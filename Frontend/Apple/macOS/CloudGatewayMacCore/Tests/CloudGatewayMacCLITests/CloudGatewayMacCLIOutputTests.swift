import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

@MainActor
@Test func cliJSONGoldenLinesAreCompleteAndVersioned() async {
    let harness = CLIHarness(cliState())
    #expect(await harness.run("--version", "--json") == 0)
    #expect(await harness.run("list", "--bogus", "--json") == 2)
    #expect(await harness.run("auth", "status", "--json") == 0)
    #expect(harness.output == #"""
        {"command":"version","data":{"build":"7","version":"1.2.0"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}
        {"command":"list","data":null,"error":{"code":"usage","message":"Unknown option '--bogus'","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}
        {"command":"auth status","data":{"access":"online","accountId":"uid1","credentials":"available","loginPending":false,"retainedSession":true,"state":"online"},"error":null,"operationId":null,"schemaVersion":1,"type":"result"}

        """#)
    #expect(harness.diagnostics.isEmpty)
}

@MainActor
@Test func cliUsageErrorsKeepJSONAndTheirCommand() async {
    let harness = CLIHarness()
    #expect(await harness.run("--bogus", "list", "--json") == 2)
    #expect(await harness.run("--json=yes", "status") == 2)
    #expect(harness.output == #"""
        {"command":"list","data":null,"error":{"code":"usage","message":"Unknown option '--bogus'","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}
        {"command":"status","data":null,"error":{"code":"usage","message":"--json does not take a value","suggestion":"Run: cloudgateway help"},"operationId":null,"schemaVersion":1,"type":"error"}

        """#)
    #expect(harness.diagnostics.isEmpty)
}

@MainActor
@Test func cliVersionStringsAreSanitized() async {
    let harness = CLIHarness()
    harness.version = ("1.2\u{1B}[31m", "7\u{202E}")
    #expect(await harness.run("--version") == 0)
    #expect(harness.output == "CloudGateway 1.2 [31m (7 )\n")
}

@MainActor
@Test func cliHelpJSONUsesTheSharedDefinitions() async throws {
    let harness = CLIHarness()
    #expect(await harness.run("help", "list", "--json") == 0)
    let data = try #require(harness.json?["data"] as? [String: Any])
    #expect(harness.json?["command"] as? String == "help")
    #expect(data["topic"] as? String == "list")
    #expect(data["usage"] as? String == "cloudgateway list [--region <region>] [--refresh] [--long] [options]")
    let options = try #require(data["options"] as? [[String: Any]])
    #expect(options.map { $0["flags"] as? [String] } == [["--region"], ["--refresh"], ["-l", "--long"]])
    #expect(options.map { $0["value"] as? String } == ["region", nil, nil])
    let common = try #require(data["commonOptions"] as? [[String: Any]])
    #expect(common.compactMap { ($0["flags"] as? [String])?.last } == ["--help", "--json", "--non-interactive", "--timeout"])

    harness.output = ""
    #expect(await harness.run("--json") == 0)
    let root = try #require(harness.json?["data"] as? [String: Any])
    #expect(root["topic"] is NSNull)
    let notes = try #require(root["notes"] as? [String])
    #expect(notes.contains("Request acceptance reserves work. `up` succeeds after start submission or if already active. "
        + "`down` succeeds only after a confirmed stop. Check `status` for the observed tunnel state"))
    let commands = try #require(root["commands"] as? [[String: Any]])
    #expect(commands.compactMap { $0["name"] as? String } == [
        "auth login", "auth status", "auth logout", "list", "status", "up", "down", "add", "remove", "update", "refresh", "doctor", "version", "help"
    ])
    #expect(harness.connects == 0)
}

@Test func cliExitCodesCoverEveryTypedFailure() {
    let commands: [(CloudGatewayMacCommandFailure, String, Int32)] = [
        (.signInRequired, "sign_in_required", 3), (.accessDenied, "access_denied", 3),
        (.setupRequired, "setup_required", 4), (.credentialsUnavailable, "credentials_unavailable", 4),
        (.incompatibleVersion, "incompatible_version", 4), (.configUnavailable, "config_unavailable", 5),
        (.selectionUnavailable, "selection_unavailable", 5), (.networkUnavailable, "network_unavailable", 6),
        (.clientActive, "client_active", 4),
        (.busy, "busy", 7), (.stopTimedOut, "stop_timed_out", 8), (.vpnFailed, "vpn_failed", 9),
        (.internalError, "internal_error", 1),
    ]
    for (failure, code, exit) in commands {
        let error = CloudGatewayMacCLIError(commandFailure: failure)
        #expect(error.code.rawValue == code)
        #expect(error.code.exitCode == exit)
    }
    let controller: [(CloudGatewayMacControllerFailure, String, Int32)] = [
        (.invalidRequest, "invalid_response", 1), (.incompatibleVersion, "incompatible_version", 4),
        (.unavailable, "controller_unavailable", 4), (.timeout, "timeout", 8), (.busy, "busy", 7),
        (.rejected, "controller_rejected", 4), (.outcomeUnknown, "operation_unknown", 10),
        (.extensionAttemptChanged, "setup_required", 4), (.preparationExpired, "operation_expired", 10),
        (.commandFailed, "command_failed", 9), (.authCleanupFailed, "credentials_unavailable", 4),
    ]
    for (failure, code, exit) in controller {
        let error = CloudGatewayMacCLIError(failure as any Error)
        #expect(error.code.rawValue == code)
        #expect(error.code.exitCode == exit)
    }
    let launch: [(any Error, CloudGatewayMacCLIError.Code)] = [
        (CloudGatewayMacControllerLaunchError.installationRequired, .installationRequired),
        (CloudGatewayMacControllerLaunchError.unsafeLocation, .installationRequired),
        (CloudGatewayMacControllerLaunchError.bootstrapFailed(category: .timedOut, exitStatus: nil), .controllerUnavailable),
        (CloudGatewayMacControllerLaunchError.busy, .controllerUnavailable),
        (CocoaError(.fileReadUnknown), .internalError),
    ]
    for (error, code) in launch { #expect(CloudGatewayMacCLIError(error).code == code) }
    let id = UUID()
    let outcomes: [(CloudGatewayMacCommandOutcome?, CloudGatewayMacControllerOperation.State, CloudGatewayMacCLIError.Code?)] = [
        (.startRequested(identifier: "uid1/r/c", warning: nil), .completed, nil),
        (.alreadyActive(identifier: "uid1/r/c", warning: .inventoryNotRefreshed), .completed, nil),
        (.completed(warning: nil), .completed, nil),
        (.unknown, .unknown, .operationUnknown), (.expired, .unknown, .operationExpired),
        (.failed(.stopTimedOut), .unknown, .stopTimedOut), (nil, .running, nil),
        (nil, .failed, .commandFailed), (nil, .unknown, .operationUnknown),
    ]
    for (outcome, state, code) in outcomes {
        #expect(CloudGatewayMacCLIOperation(.init(id: id, state: state), outcome: outcome).failure?.code == code)
    }
    #expect(CloudGatewayMacCLIError.Code.usage.exitCode == 2)
    #expect(CloudGatewayMacCLIError.Code.notImplemented.exitCode == 1)
    #expect(CloudGatewayMacCLIError.Code.untrustedBuild.exitCode == 4)
}

@MainActor
@Test func cliSanitizesTerminalLabelsAndEchoedArguments() async {
    #expect(CloudGatewayMacCLIText.sanitize("a\u{1B}[31mb\u{9B}c\u{202E}d\u{200B}e\nf") == "a [31mb c d e f")
    let harness = CLIHarness(cliState(clients: [
        cliClient("uid1/r1/c1", regionName: "Region\u{1B}]0;title\u{07}", name: "Mac\u{1B}[2J\u{202E}", owner: "Ann\r\n")
    ]))
    #expect(await harness.run("list") == 0)
    #expect(await harness.run("list", "--json") == 0)
    #expect(await harness.run("--\u{1B}[31m") == 2)
    for text in [harness.output, harness.diagnostics] {
        #expect(!text.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{202E}" || $0 == "\u{07}" || $0 == "\r" })
    }
    #expect(harness.output.contains("uid1/r1/c1"))
    #expect(harness.output.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { !$0.contains("\u{1B}") })
}

@MainActor
@Test func cliStylesOnlyInteractiveTerminalsWithoutNoColor() async {
    func styled(_ terminal: CloudGatewayMacCLITerminal, _ arguments: [String] = []) async -> Bool {
        let harness = CLIHarness()
        harness.terminal = terminal
        _ = await harness.run(arguments)
        return harness.output.contains("\u{1B}[")
    }
    #expect(await styled(.init(isOutputTerminal: true, variables: ["TERM": "xterm-256color"])))
    #expect(await styled(.init(isOutputTerminal: true, variables: ["NO_COLOR": ""])))
    #expect(await !styled(.init(isOutputTerminal: true, variables: ["NO_COLOR": "1"])))
    #expect(await !styled(.init(isOutputTerminal: true, variables: ["TERM": "dumb"])))
    #expect(await !styled(.init(isOutputTerminal: false, variables: [:])))
    #expect(await !styled(.init(isOutputTerminal: true, variables: [:]), ["--non-interactive"]))
    #expect(await !styled(.init(isOutputTerminal: true, variables: [:]), ["--json"]))
}
