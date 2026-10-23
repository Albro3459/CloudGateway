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
    #expect(try topic(["--json", "help", "status"]) == "status")
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
