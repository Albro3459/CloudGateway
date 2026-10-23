import Foundation

enum CloudGatewayMacCLIOption: CaseIterable {
    case help, json, nonInteractive, timeout, version, noQR, region, refresh, operation, long

    static let common: [Self] = [.help, .json, .nonInteractive, .timeout]

    var flags: [String] {
        switch self {
        case .help: ["-h", "--help"]
        case .json: ["--json"]
        case .nonInteractive: ["--non-interactive"]
        case .timeout: ["--timeout"]
        case .version: ["-v", "--version"]
        case .noQR: ["--no-qr"]
        case .region: ["--region"]
        case .refresh: ["--refresh"]
        case .operation: ["--operation"]
        case .long: ["-l", "--long"]
        }
    }

    var valueName: String? {
        switch self {
        case .timeout: "seconds"
        case .region: "region"
        case .operation: "operation-id"
        default: nil
        }
    }

    var summary: String {
        switch self {
        case .help: "Show help for the current command"
        case .json: "Print versioned JSON records, one per line, without decoration or shortcuts"
        case .nonInteractive: "Disable keyboard shortcuts and prompts, even in a terminal"
        case .timeout: "Stop waiting after this many seconds (default 30). Accepted VPN work keeps running"
        case .version: "Show the app version and build"
        case .noQR: "Hide the QR code. The approval link and code still print"
        case .region: "Show only configs in this region"
        case .refresh: "Fetch current inventory before listing"
        case .operation: "Look up a retained operation by ID"
        case .long: "Show VPN details for each config"
        }
    }
}

struct CloudGatewayMacCLITopic {
    enum Kind {
        case root, auth, authLogin, authStatus, authLogout, list, status, up, down, refresh, doctor, help, version
    }

    let kind: Kind
    let path: [String]
    let arguments: String?
    let options: [CloudGatewayMacCLIOption]
    let summary: String
    let notes: [String]
    let examples: [String]

    var name: String { path.joined(separator: " ") }

    var usage: String {
        let words = ["cloudgateway"] + path + (arguments.map { [$0] } ?? [])
        if kind == .root || kind == .auth { return (words + ["<command>", "[options]"]).joined(separator: " ") }
        let options = options.map { option in
            "[\(option.flags.last ?? "")\(option.valueName.map { " <\($0)>" } ?? "")]"
        }
        return (words + options + ["[options]"]).joined(separator: " ")
    }

    var subtopics: [Self] {
        switch kind {
        case .root: Self.all.filter { $0.path.count > 0 && $0.kind != .auth }
        case .auth: Self.all.filter { $0.path.count == 2 }
        default: []
        }
    }

    static let all: [Self] = [
        .init(kind: .root, path: [], arguments: nil, options: [.version],
              summary: "Control the CloudGateway VPN on this Mac",
              notes: [
                  "Use a client UUID or a region and row index to select a config. `ls` is an alias of `list`",
                  "Request acceptance reserves work. `up` succeeds after start submission or if already active. "
                      + "`down` succeeds only after a confirmed stop. Check `status` for the observed tunnel state",
                  "Exit codes: 0 success, 1 internal failure, 2 usage, 3 sign-in or access denied, 4 setup, permissions, or version, "
                      + "5 config or selection, 6 network or service, 7 busy, 8 deadline, 9 VPN operation failed, "
                      + "10 operation result unknown, 130 interrupted"
              ],
              examples: ["cloudgateway auth status", "cloudgateway list --json", "cloudgateway help up"]),
        .init(kind: .auth, path: ["auth"], arguments: nil, options: [],
              summary: "Sign in, check, or sign out of the shared CloudGateway session",
              notes: [], examples: ["cloudgateway auth status"]),
        .init(kind: .authLogin, path: ["auth", "login"], arguments: nil, options: [.noQR],
              summary: "Sign in with device approval on any browser",
              notes: ["The approval link and code print right away. Approve on this Mac or another device"],
              examples: ["cloudgateway auth login", "cloudgateway auth login --no-qr"]),
        .init(kind: .authStatus, path: ["auth", "status"], arguments: nil, options: [],
              summary: "Show sign-in, access verification, and credential state",
              notes: ["A retained identity does not mean access is currently verified"],
              examples: ["cloudgateway auth status --json"]),
        .init(kind: .authLogout, path: ["auth", "logout"], arguments: nil, options: [],
              summary: "Sign out, keeping the running VPN and saved configs",
              notes: ["Logout does not disconnect. Run `cloudgateway down` to stop the VPN"],
              examples: ["cloudgateway auth logout"]),
        .init(kind: .list, path: ["list"], arguments: nil, options: [.region, .refresh, .long],
              summary: "Show authorized configs grouped by region",
              notes: ["Waits for stale controller inventory to refresh",
                      "Offline, only this account's saved configs are listed",
                      "Regions accept a full ID, display name, or city alias such as sanjose",
                      "Indices restart at 1 in each region. Rerun `ls` after inventory changes. Use a UUID in scripts"],
              examples: ["cloudgateway ls", "cloudgateway ls -l", "cloudgateway list --region sanjose --json"]),
        .init(kind: .status, path: ["status"], arguments: nil, options: [.operation],
              summary: "Show the observed VPN state and the latest command result",
              notes: ["A successful status read does not mean the VPN is connected"],
              examples: ["cloudgateway status", "cloudgateway status --operation <operation-id>"]),
        .init(kind: .up, path: ["up"], arguments: "[<client-uuid> | <region> <index>]", options: [],
              summary: "Request a VPN start for an authorized config",
              notes: [
                  "Without a selector, `up` uses this account's last selection",
                  "Regions accept a full ID, display name, or city alias. Quote names containing spaces",
                  "Success means macOS accepted the start request, not that the tunnel connected"
              ],
              examples: ["cloudgateway up", "cloudgateway up <client-uuid>", "cloudgateway up chicago 1"]),
        .init(kind: .down, path: ["down"], arguments: "[<client-uuid> | <region> <index>]", options: [],
              summary: "Stop the CloudGateway VPN, even while signed out",
              notes: ["Saved configs stay on this Mac", "A selector stops only that config and requires sign-in"],
              examples: ["cloudgateway down", "cloudgateway down chicago 1"]),
        .init(kind: .refresh, path: ["refresh"], arguments: nil, options: [],
              summary: "Recheck access and fetch current inventory without reconnecting",
              notes: [], examples: ["cloudgateway refresh"]),
        .init(kind: .doctor, path: ["doctor"], arguments: nil, options: [],
              summary: "Inspect setup, permissions, auth, and service reachability",
              notes: [], examples: ["cloudgateway doctor --json"]),
        .init(kind: .version, path: ["version"], arguments: nil, options: [],
              summary: "Show the app version and build",
              notes: ["Aliases: --version, -v. Completes locally without connecting to the controller"],
              examples: ["cloudgateway version", "cloudgateway -v --json"]),
        .init(kind: .help, path: ["help"], arguments: "[command...]", options: [],
              summary: "Show help for a command", notes: [],
              examples: ["cloudgateway help auth login"]),
    ]
}

enum CloudGatewayMacCLICommand: Equatable {
    case authLogin(showsQR: Bool), authStatus, authLogout
    case list(regionId: String?, refresh: Bool, long: Bool = false)
    case status(operationId: UUID?)
    case up(selector: CloudGatewayMacCLISelector?)
    case downTarget(CloudGatewayMacCLISelector)
    case down, refresh, doctor

    var name: String {
        switch self {
        case .authLogin: "auth login"
        case .authStatus: "auth status"
        case .authLogout: "auth logout"
        case .list: "list"
        case .status: "status"
        case .up: "up"
        case .down, .downTarget: "down"
        case .refresh: "refresh"
        case .doctor: "doctor"
        }
    }
}

struct CloudGatewayMacCLIInvocation {
    enum Action {
        case help(CloudGatewayMacCLITopic), version, run(CloudGatewayMacCLICommand)
    }

    let action: Action
    let isJSON: Bool
    let isNonInteractive: Bool
    // Nil means the command's own default, since login waits for the server's code expiry
    let timeout: Duration?
}

struct CloudGatewayMacCLIUsageFailure: Error {
    let message: String
    let command: String?
}

enum CloudGatewayMacCLIParser {
    static let maximumTimeout = 86_400.0

    static func parse(_ arguments: [String]) throws -> CloudGatewayMacCLIInvocation {
        let named = namedWords(arguments)
        var words: [String] = []
        var flags = Set<CloudGatewayMacCLIOption>()
        var values: [CloudGatewayMacCLIOption: String] = [:]
        var remaining = arguments[...]
        while let token = remaining.popFirst() {
            guard token.count > 1, token.hasPrefix("-") else {
                words.append(token)
                continue
            }
            var name = token
            var inline: String?
            if token.hasPrefix("--"), let equals = token.firstIndex(of: "=") {
                name = String(token[..<equals])
                inline = String(token[token.index(after: equals)...])
            }
            guard let option = CloudGatewayMacCLIOption.allCases.first(where: { $0.flags.contains(name) }) else {
                throw failure("Unknown option \(quoted(token))", words: named)
            }
            guard option.valueName != nil else {
                guard inline == nil else { throw failure("\(name) does not take a value", words: named) }
                flags.insert(option)
                continue
            }
            guard let value = inline ?? remaining.popFirst(), !value.isEmpty, !value.hasPrefix("-") else {
                throw failure("\(name) needs a value", words: named)
            }
            guard values.updateValue(value, forKey: option) == nil else {
                throw failure("\(name) can only be given once", words: named)
            }
        }

        let isHelpCommand = words.first == "help"
        var commandWords = isHelpCommand ? Array(words.dropFirst()) : words
        if commandWords.first == "ls" { commandWords[0] = "list" }
        guard let topic = CloudGatewayMacCLITopic.all.filter({ commandWords.starts(with: $0.path) })
            .max(by: { $0.path.count < $1.path.count }) else {
            throw failure("Unknown command", words: named)
        }
        let operands = commandWords.dropFirst(topic.path.count)
        if isHelpCommand {
            guard operands.isEmpty else {
                throw failure("Unknown help topic \(quoted(commandWords.joined(separator: " ")))", words: named)
            }
        } else {
            try validate(operands: operands, for: topic)
        }

        let allowed = CloudGatewayMacCLIOption.common + (isHelpCommand ? [] : topic.options)
        if let extra = flags.union(values.keys).first(where: { !allowed.contains($0) }) {
            let name = extra.flags.last ?? ""
            let message = extra == .version ? "--version is only valid without a command"
                : isHelpCommand ? "\(name) is not valid for help"
                : topic.kind == .root ? "\(name) needs a command" : "\(name) is not valid for \(topic.name)"
            throw failure(message, words: named)
        }
        let timeout = try values[.timeout].map { try parseTimeout($0, words: named) }
        let isJSON = flags.contains(.json)
        let isNonInteractive = flags.contains(.nonInteractive)
        func invocation(_ action: CloudGatewayMacCLIInvocation.Action) -> CloudGatewayMacCLIInvocation {
            .init(action: action, isJSON: isJSON, isNonInteractive: isNonInteractive, timeout: timeout)
        }

        if isHelpCommand || flags.contains(.help) { return invocation(.help(topic)) }
        if flags.contains(.version) { return invocation(.version) }
        let command: CloudGatewayMacCLICommand
        switch topic.kind {
        case .root, .help: return invocation(.help(topic))
        case .auth: throw failure("Missing auth command. Use login, status, or logout", words: named)
        case .authLogin: command = .authLogin(showsQR: !flags.contains(.noQR))
        case .authStatus: command = .authStatus
        case .authLogout: command = .authLogout
        case .list:
            let regionId = try values[.region].map { value in
                guard validRegion(value) else { throw failure("Invalid region '\(CloudGatewayMacCLIText.sanitize(value))'", words: named) }
                return value
            }
            command = .list(regionId: regionId, refresh: flags.contains(.refresh), long: flags.contains(.long))
        case .status:
            let operationId = try values[.operation].map { value in
                guard let id = UUID(uuidString: value) else {
                    throw failure("Invalid operation ID \(quoted(value))", words: named)
                }
                return id
            }
            command = .status(operationId: operationId)
        case .up: command = .up(selector: try selector(operands, topic: topic))
        case .down: command = try selector(operands, topic: topic).map(CloudGatewayMacCLICommand.downTarget) ?? .down
        case .version: return invocation(.version)
        case .refresh: command = .refresh
        case .doctor: command = .doctor
        }
        return invocation(.run(command))
    }

    private static func validate(operands: ArraySlice<String>, for topic: CloudGatewayMacCLITopic) throws {
        guard let operand = operands.first else { return }
        switch topic.kind {
        case .root: throw failure("Unknown command \(quoted(operand))", words: [])
        case .auth: throw failure("Unknown auth command \(quoted(operand))", words: topic.path)
        case .up, .down:
            _ = try selector(operands, topic: topic)
        default: throw failure("Unexpected argument \(quoted(operand))", words: topic.path)
        }
    }

    private static func validRegion(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
            && value == CloudGatewayMacCLIText.sanitize(value) && !value.contains("/")
    }

    private static func selector(_ operands: ArraySlice<String>, topic: CloudGatewayMacCLITopic) throws -> CloudGatewayMacCLISelector? {
        guard let first = operands.first else { return nil }
        if operands.count == 1, let id = UUID(uuidString: first) { return .client(id) }
        if operands.count == 2, validRegion(first), let value = operands.last,
           !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let index = Int(value), index > 0 {
            return .region(first, index: index)
        }
        throw failure("Use a client UUID or <region> <positive index> from `cloudgateway ls`", words: topic.path)
    }

    private static func parseTimeout(_ value: String, words: [String]) throws -> Duration {
        guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= maximumTimeout else {
            throw failure("--timeout needs a positive number of seconds, up to \(Int(maximumTimeout))", words: words)
        }
        return .seconds(seconds)
    }

    // Finds command words up front so an early usage error still names its command
    private static func namedWords(_ arguments: [String]) -> [String] {
        var words: [String] = []
        var remaining = arguments[...]
        while let token = remaining.popFirst() {
            guard token.count > 1, token.hasPrefix("-") else {
                words.append(token)
                continue
            }
            if CloudGatewayMacCLIOption.allCases.contains(where: { $0.valueName != nil && $0.flags.contains(token) }) {
                _ = remaining.popFirst()
            }
        }
        return words
    }

    private static func failure(_ message: String, words: [String]) -> CloudGatewayMacCLIUsageFailure {
        var words = words.first == "help" ? ["help"] : words
        if words.first == "ls" { words[0] = "list" }
        let topic = CloudGatewayMacCLITopic.all.filter { words.starts(with: $0.path) && !$0.path.isEmpty }
            .max { $0.path.count < $1.path.count }
        return .init(message: message, command: topic?.name)
    }

    private static func quoted(_ value: String) -> String {
        "'\(CloudGatewayMacCLIText.sanitize(value))'"
    }
}
