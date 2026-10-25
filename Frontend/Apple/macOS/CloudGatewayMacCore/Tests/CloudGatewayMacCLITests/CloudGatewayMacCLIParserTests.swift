import Foundation
import Testing
@testable import CloudGatewayMacCLI

private func parse(_ arguments: [String]) throws -> CloudGatewayMacCLIInvocation {
    try CloudGatewayMacCLIParser.parse(arguments)
}

private func command(_ arguments: [String]) throws -> CloudGatewayMacCLICommand? {
    guard case .run(let command) = try parse(arguments).action else { return nil }
    return command
}

private func topic(_ arguments: [String]) throws -> String? {
    guard case .help(let topic) = try parse(arguments).action else { return nil }
    return topic.name
}

private func usageFailure(_ arguments: [String]) -> CloudGatewayMacCLIUsageFailure? {
    do {
        _ = try parse(arguments)
        return nil
    } catch { return error as? CloudGatewayMacCLIUsageFailure }
}

@Test func cliParserShowsHelpForEveryDocumentedHelpForm() throws {
    #expect(try topic([]) == "")
    #expect(try topic(["help"]) == "")
    #expect(try topic(["-h"]) == "")
    #expect(try topic(["--help"]) == "")
    #expect(try topic(["help", "auth", "login"]) == "auth login")
    #expect(try topic(["auth", "login", "--help"]) == "auth login")
    #expect(try topic(["help", "auth"]) == "auth")
    #expect(try topic(["auth", "-h"]) == "auth")
    #expect(try topic(["up", "--help"]) == "up")
    #expect(try topic(["add", "--help"]) == "add")
    #expect(try topic(["help", "add", "--json"]) == "add")
    #expect(try topic(["--json", "help", "status"]) == "status")
    #expect(try topic(["mode", "--help"]) == "mode")
    #expect(try topic(["help", "mode", "--json"]) == "mode")
    #expect(try topic(["mode", "status", "--help", "--json"]) == "mode status")
}

@Test func cliParserAcceptsCommandsWithFlagsBeforeOrAfterWords() throws {
    let clientId = "78ab8633-ae25-4287-885f-57bbbf6e7f63"
    let operationId = UUID()
    #expect(try command(["auth", "status"]) == .authStatus)
    #expect(try command(["--json", "auth", "status"]) == .authStatus)
    #expect(try command(["auth", "--json", "status"]) == .authStatus)
    #expect(try command(["auth", "login", "--no-qr"]) == .authLogin(showsQR: false))
    #expect(try command(["auth", "login"]) == .authLogin(showsQR: true))
    #expect(try command(["auth", "logout"]) == .authLogout)
    #expect(try command(["mode"]) == .modeStatus)
    #expect(try command(["mode", "status"]) == .modeStatus)
    #expect(try command(["mode", "mesh", "--json"]) == .setMode(.mesh))
    #expect(try command(["--non-interactive", "mode", "full"]) == .setMode(.full))
    #expect(try command(["list"]) == .list(regionId: nil, refresh: false))
    #expect(try command(["list", "--region", "us-east-1", "--refresh"]) == .list(regionId: "us-east-1", refresh: true))
    #expect(try command(["--region=eu_west.2", "list"]) == .list(regionId: "eu_west.2", refresh: false))
    #expect(try command(["status"]) == .status(operationId: nil))
    #expect(try command(["status", "--operation", operationId.uuidString.lowercased()]) == .status(operationId: operationId))
    #expect(try command(["up"]) == .up(selector: nil))
    #expect(try command(["up", clientId]) == .up(selector: .client(UUID(uuidString: clientId)!)))
    #expect(try command(["down"]) == .down)
    #expect(try command(["refresh"]) == .refresh)
    #expect(try command(["doctor", "--non-interactive"]) == .doctor)
}

@Test func cliParserReadsCommonOptions() throws {
    let invocation = try parse(["--timeout", "2.5", "status", "--json", "--non-interactive"])
    #expect(invocation.timeout == .seconds(2.5))
    #expect(invocation.isJSON)
    #expect(invocation.isNonInteractive)
    #expect(try parse(["status"]).timeout == nil)
    #expect(try parse(["auth", "login"]).timeout == nil)
    #expect(try parse(["--timeout=86400", "status"]).timeout == .seconds(86_400))
    guard case .version = try parse(["--version", "--json"]).action else {
        Issue.record("Expected version")
        return
    }
}

@Test func cliParserRejectsMalformedInvocations() {
    let cases: [([String], String)] = [
        (["bogus"], "Unknown command 'bogus'"),
        (["mode", "bogus"], "Unknown mode 'bogus'. Use status, full, or mesh"),
        (["mode", "Mesh"], "Unknown mode 'Mesh'. Use status, full, or mesh"),
        (["mode", "full", "extra"], "Unexpected argument 'extra'"),
        (["mode", "status", "--operation", UUID().uuidString], "--operation is not valid for mode status"),
        (["list", "--bogus"], "Unknown option '--bogus'"),
        (["--controller"], "Unknown option '--controller'"),
        (["list", "--region"], "--region needs a value"),
        (["--region", "--json", "list"], "--region needs a value"),
        (["list", "--region", "a", "--region", "b"], "--region can only be given once"),
        (["--timeout", "5", "status", "--timeout=6"], "--timeout can only be given once"),
        (["status", "--operation", "not-a-uuid"], "Invalid operation ID 'not-a-uuid'"),
        (["list", "--region", "us/east"], "Invalid region 'us/east'"),
        (["up", "uid1/region"], "Use a client UUID or <region> <positive index> from `cloudgateway ls`"),
        (["up", "uid1/region/client", "extra"], "Use a client UUID or <region> <positive index> from `cloudgateway ls`"),
        (["list", "extra"], "Unexpected argument 'extra'"),
        (["--timeout", "0", "status"], "--timeout needs a positive number of seconds, up to 86400"),
        (["--timeout", "nan", "status"], "--timeout needs a positive number of seconds, up to 86400"),
        (["--timeout", "inf", "status"], "--timeout needs a positive number of seconds, up to 86400"),
        (["--timeout", "86401", "status"], "--timeout needs a positive number of seconds, up to 86400"),
        (["--timeout", "-1", "status"], "--timeout needs a value"),
        (["status", "--region", "x"], "--region is not valid for status"),
        (["--refresh"], "--refresh needs a command"),
        (["list", "--version"], "--version is only valid without a command"),
        (["help", "--version"], "--version is only valid without a command"),
        (["help", "list", "--refresh"], "--refresh is not valid for help"),
        (["--json=yes", "status"], "--json does not take a value"),
        (["auth"], "Missing auth command. Use login, status, or logout"),
        (["auth", "bogus"], "Unknown auth command 'bogus'"),
        (["help", "bogus"], "Unknown help topic 'bogus'"),
        (["help", "auth", "status", "extra"], "Unknown help topic 'auth status extra'"),
    ]
    for (arguments, message) in cases {
        #expect(usageFailure(arguments)?.message == message, "\(arguments)")
    }
    #expect(usageFailure(["list", "--bogus"])?.command == "list")
    #expect(usageFailure(["auth", "status", "extra"])?.command == "auth status")
    #expect(usageFailure(["--bogus", "list"])?.command == "list")
    #expect(usageFailure(["--timeout", "0", "auth", "status"])?.command == "auth status")
    #expect(usageFailure(["--region", "list", "bogus"])?.command == nil)
    #expect(usageFailure(["--bogus"])?.command == nil)
}

@Test func cliLaunchModeUsesExactPrivateFlagsAndInvocationName() {
    let app = "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway"
    let link = "/Users/me/.local/bin/cloudgateway"
    #expect(CloudGatewayMacLaunchMode(arguments: [app]) == .menu)
    #expect(CloudGatewayMacLaunchMode(arguments: []) == .menu)
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "--controller"]) == .controller)
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "--controller", "status"]) == .conflict)
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "--cli"]) == .cli([]))
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "--cli", "status", "--json"]) == .cli(["status", "--json"]))
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "status", "--cli"]) == .conflict)
    #expect(CloudGatewayMacLaunchMode(arguments: [app, "--json", "--controller"]) == .conflict)
    #expect(CloudGatewayMacLaunchMode(arguments: [link]) == .cli([]))
    #expect(CloudGatewayMacLaunchMode(arguments: ["cloudgateway", "list"]) == .cli(["list"]))
    #expect(CloudGatewayMacLaunchMode(arguments: [link, "--cli", "list"]) == .cli(["list"]))
    #expect(CloudGatewayMacLaunchMode(arguments: [link, "--cli", "--cli"]) == .cli(["--cli"]))
    #expect(CloudGatewayMacLaunchMode(arguments: [link, "--controller"]) == .conflict)
    #expect(CloudGatewayMacLaunchMode(arguments: ["/tmp/CloudGateway", "status"]) == .menu)
}

@Test func cliAddParserRequiresRegionAndNameAndNormalizesNames() throws {
    #expect(try command(["add", "sanjose", "Mac mini"]) == .add(region: "sanjose", name: "Mac mini"))
    #expect(try command(["--json", "add", "us-sanjose-1", "  Work Mac  ", "--timeout", "60"])
        == .add(region: "us-sanjose-1", name: "Work Mac"))
    #expect(try command(["add", "California", String(repeating: "é", count: 80)])
        == .add(region: "California", name: String(repeating: "é", count: 80)))
    for arguments in [
        ["add"], ["add", "sanjose"], ["add", "sanjose", ""], ["add", "sanjose", "   "],
        ["add", "sanjose", "Mac", "extra"], ["add", "us/sanjose", "Mac"],
        ["add", "sanjose", String(repeating: "a", count: 81)], ["add", "sanjose", "Mac\u{1B}[31m"],
        ["add", "sanjose", "Mac\nmini"], ["add", "sanjose", "Mac", "--allow-disconnect"],
    ] {
        #expect(usageFailure(arguments)?.command == "add", "\(arguments)")
    }
}

@Test func cliRemoveParserRequiresExplicitSelectorAndConsentWithCommonOptions() throws {
    let uuid = "78ab8633-ae25-4287-885f-57bbbf6e7f63"
    #expect(try command(["remove", uuid.uppercased(), "--yes"]) == .remove(.client(UUID(uuidString: uuid)!)))
    for region in ["us-sanjose-1", "sanjose", "San Jose"] {
        let invocation = try parse(["--json", "--yes", "remove", region, "02", "--timeout=2.5", "--non-interactive"])
        guard case .run(let command) = invocation.action else { Issue.record("Expected remove"); return }
        #expect(command == .remove(.region(region, index: 2)))
        #expect(command.name == "remove")
        #expect(invocation.isJSON)
        #expect(invocation.isNonInteractive)
        #expect(invocation.timeout == .seconds(2.5))
    }
    for arguments in [["remove", "--help"], ["help", "remove"], ["remove", uuid, "-h"],
                      ["remove", "--yes", "--help"]] {
        #expect(try topic(arguments) == "remove")
    }
    for arguments in [
        ["remove"], ["remove", "--yes"], ["remove", uuid], ["remove", "chicago", "1"],
        ["remove", "chicago", "--yes"], ["remove", uuid, "extra", "--yes"],
        ["remove", "uid1/us-east-1/" + uuid, "--yes"], ["remove", "chicago", "0", "--yes"],
        ["remove", "chicago", "1.0", "--yes"], ["remove", "chicago", "+1", "--yes"],
        ["remove", "chicago", "١", "--yes"], ["remove", "chicago", String(repeating: "9", count: 40), "--yes"],
        ["remove", uuid, "--yes=false"], ["remove", uuid, "--yes=true"], ["remove", uuid, "--yes="],
        ["remove", uuid, "--yes", "--allow-disconnect"], ["remove", uuid, "--yes", "--refresh"],
    ] {
        #expect(usageFailure(arguments)?.command == "remove", "\(arguments)")
    }
    for arguments in [["up", uuid], ["down", uuid], ["add", "chicago", "Mac"], ["auth", "logout"],
                      ["auth", "login"], ["list"], ["status"], ["update"], ["refresh"], ["doctor"],
                      ["version"], [], ["help", "remove"]] {
        #expect(usageFailure(arguments + ["--yes"]) != nil, "\(arguments)")
    }
}
