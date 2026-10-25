import Darwin
import Foundation

enum CloudGatewayMacCLIText {
    // Replaces C0/C1 controls, ESC, and bidi or zero-width format characters so labels cannot drive the terminal
    static func sanitize(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 })
        return String(scalars)
    }
}

struct CloudGatewayMacCLITerminal {
    let isOutputTerminal: Bool
    let variables: [String: String]

    static var current: Self {
        .init(isOutputTerminal: isatty(STDOUT_FILENO) == 1, variables: ProcessInfo.processInfo.environment)
    }

    func allowsStyle(for invocation: CloudGatewayMacCLIInvocation) -> Bool {
        isOutputTerminal && !invocation.isJSON && !invocation.isNonInteractive
            && (variables["NO_COLOR"] ?? "").isEmpty && variables["TERM"] != "dumb"
    }
}

struct CloudGatewayMacCLIRenderer {
    let isStyled: Bool

    func render(_ data: CloudGatewayMacCLIData) -> String {
        let lines: [String]
        switch data {
        case .help(let help): lines = render(help)
        case .version(let version): lines = ["CloudGateway \(version.version) (\(version.build))"]
        case .auth(let auth): lines = render(auth)
        case .status(let status): lines = render(status)
        case .inventory(let inventory): lines = render(inventory)
        case .mutation(let mutation):
            let summary = switch mutation.operation.result {
            case .startRequested: "VPN start requested"
            case .alreadyActive: "VPN already active"
            case .completed where mutation.command == .down: "VPN stopped"
            case .completed where mutation.command == .logout: "Signed out (VPN retained)"
            case .completed where mutation.command == .add:
                mutation.creation.map { "Client created: \($0.name) (\($0.regionId))" } ?? "Client created"
            case .completed where mutation.command == .update: "VPN extension update completed"
            case .completed where mutation.command == .remove: "Client removed"
            case _ where mutation.command == .update: "VPN extension update \(mutation.operation.state.rawValue)"
            default: "Command \(mutation.operation.state.rawValue)"
            }
            lines = [summary] + render(.init(tunnel: mutation.tunnel, operation: mutation.operation, update: mutation.update))
                + (mutation.choices.map { ["", "Available configs:"] + render($0) } ?? [])
        case .refresh(let refresh):
            lines = ["Inventory refresh: \(label(refresh.result.rawValue))"]
                + (refresh.inventory.map { [""] + render($0) } ?? [])
        case .doctor(let report): return report.render()
        }
        return lines.map { $0 + "\n" }.joined()
    }

    func render(_ error: CloudGatewayMacCLIError) -> String {
        if error.code == .networkUnavailable { return "Waiting for network… Try again soon.\n" }
        let message = CloudGatewayMacCLIText.sanitize(error.message)
        return "Error: \(message)\n" + (error.suggestion.map { "\($0)\n" } ?? "")
    }

    private func render(_ help: CloudGatewayMacCLIHelp) -> [String] {
        var lines = [help.summary, "", "Usage: \(help.usage)"]
        func section(_ title: String, _ rows: [(String, String)]) {
            guard !rows.isEmpty else { return }
            let width = rows.map(\.0.count).max() ?? 0
            lines += ["", "\(bold(title)):"] + rows.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
        }
        func options(_ options: [CloudGatewayMacCLIHelp.Option]) -> [(String, String)] {
            options.map { option in
                (option.flags.joined(separator: ", ") + (option.value.map { " <\($0)>" } ?? ""), option.summary)
            }
        }
        section("Commands", help.commands.map { ([$0.name, $0.arguments].compactMap { $0 }.joined(separator: " "), $0.summary) })
        section("Options", options(help.options))
        section("Common options", options(help.commonOptions))
        if !help.notes.isEmpty { lines += ["", "\(bold("Notes")):"] + help.notes.map { "  \($0)" } }
        if !help.examples.isEmpty { lines += ["", "\(bold("Examples")):"] + help.examples.map { "  \($0)" } }
        return lines
    }

    private func render(_ auth: CloudGatewayMacCLIAuthStatus) -> [String] {
        let summary = switch auth.state {
        case .signedOut: "Signed out"
        case .retained: "Session retained, access not verified"
        case .restoring: "Restoring session (pending)"
        case .online: "Signed in (online)"
        case .offline: "Signed in (offline, using cached authorization)"
        case .denied: "Access denied"
        }
        var rows = [("Auth", summary), ("Account", auth.accountId ?? "none"), ("Access", auth.access.rawValue),
                    ("Credentials", auth.credentials.rawValue)]
        if auth.loginPending { rows.append(("Login", "in progress")) }
        return table(rows)
    }

    private func render(_ status: CloudGatewayMacCLIStatus) -> [String] {
        let tunnel = status.tunnel
        let observation = observationLabel(tunnel.observation, observedAt: tunnel.observedAt)
        var rows = [("VPN", tunnel.state.rawValue), ("Observation", observation)]
        if let configId = tunnel.configId { rows.append(("Config", configId)) }
        if let operation = status.operation {
            var detail = "\(operation.id) \(operation.state.rawValue)"
            if let result = operation.result { detail += ", \(label(result.rawValue))" }
            if let configId = operation.configId { detail += " for \(configId)" }
            if let warning = operation.warning {
                let message = warning == .reconnectSuppressionNotPersisted
                    ? "Reconnect suppression cannot be guaranteed after controller restart because it could not be saved"
                    : label(warning.rawValue)
                detail += " (\(message))"
            }
            rows.append(("Operation", detail))
            if let error = operation.error { rows.append(("Result", error.message)) }
        } else {
            rows.append(("Operation", "none retained"))
        }
        if let update = status.update {
            let phase = switch update.phase {
            case .prepared: "prepared, awaiting execution confirmation"
            case .stopping: "stopping the captured VPN and waiting for confirmed stop"
            case .activating: "activating the installed VPN extension"
            case .approvalRequired: "macOS approval required (operation still running)"
            case .restartRequired: "Mac restart required (operation still running)"
            case .checkingReadiness: "checking authenticated extension readiness"
            case .reconnecting: "requesting a start of the captured config"
            case .completed: "completed"
            case .failed: "failed"
            case .superseded: "superseded by a changed installed app"
            }
            rows.append(("Update", "\(update.id) \(phase)"))
            rows.append(("Target", "\(update.target.version) (\(update.target.build))"))
            if let configId = update.configId { rows.append(("Update config", configId)) }
            if update.reconnect {
                rows.append(("Reconnect", update.phase == .completed
                    ? "start submitted or same config already active. See observed VPN state above"
                    : "captured config, subject to readiness and current authorization"))
            } else {
                rows.append(("Reconnect", "disabled"))
            }
            if let error = update.error { rows.append(("Update error", error.message)) }
            if let warning = update.warning { rows.append(("Update warning", warning.message)) }
        }
        return table(rows)
    }

    private func render(_ inventory: CloudGatewayMacCLIInventory) -> [String] {
        var lines: [String] = []
        if inventory.regions.isEmpty {
            lines.append(inventory.regionId.map { "No configs in region \($0)" } ?? "No configs")
        }
        for region in inventory.regions {
            if !lines.isEmpty { lines.append("") }
            lines.append(bold("\(region.name) (\(region.regionId))"))
            let names = region.configs.map { config in config.owner.map { "\(config.name) (\($0))" } ?? config.name }
            let nameWidth = names.map(\.count).max() ?? 0
            let idWidth = region.configs.map(\.clientId.count).max() ?? 0
            let indexWidth = region.configs.map { String($0.index).count }.max() ?? 0
            for (config, name) in zip(region.configs, names) {
                var labels: [String] = []
                if let tunnel = config.tunnel, tunnel != .disconnected || inventory.profileObservation == .stale {
                    labels.append(tunnel.rawValue + (inventory.profileObservation == .stale ? " (stale)" : ""))
                }
                if config.cloudState != .active { labels.append(config.cloudState.rawValue) }
                if config.eligibility != .eligible { labels.append(label(config.eligibility.rawValue)) }
                if config.selected { labels.append("selected") }
                let prefix = "  " + String(config.index).padding(toLength: indexWidth, withPad: " ", startingAt: 0)
                if inventory.isLong {
                    lines.append(prefix + "  " + config.name + (labels.isEmpty ? "" : "  " + labels.joined(separator: ", ")))
                    let ip = config.internalIp?.split(separator: "/").first.map(String.init)
                    lines += table([("VPN id", config.clientId), ("Tunnel IP", ip ?? "Unavailable"),
                                    ("Connection URL", config.connectionUrl ?? "Unavailable"),
                                    ("Owner email", config.owner ?? "Unknown")]).map { "     " + $0 }
                } else {
                    var columns = [prefix, name.padding(toLength: nameWidth, withPad: " ", startingAt: 0),
                                   config.clientId.padding(toLength: idWidth, withPad: " ", startingAt: 0)]
                    if !labels.isEmpty { columns.append(labels.joined(separator: ", ")) }
                    lines.append(columns.joined(separator: "  "))
                }
            }
        }
        lines.append("")
        lines.append("Tunnel observation: \(observationLabel(inventory.profileObservation, observedAt: inventory.profilesObservedAt))")
        lines.append(inventory.scope == .installed
            ? "Offline: showing this account's saved configs from cached authorization"
            : "Inventory: \(inventory.freshness.rawValue)")
        return lines
    }

    private func table(_ rows: [(String, String)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "\(($0.0 + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0))  \($0.1)" }
    }

    private func bold(_ text: String) -> String {
        isStyled ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    private func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }

    private func observationLabel(_ observation: CloudGatewayMacCLIStatus.Tunnel.Observation, observedAt: Date?) -> String {
        let observed = observedAt.map { " at \(timestamp($0))" } ?? ""
        return switch observation {
        case .current: "current\(observed)"
        case .stale: "stale, last observed\(observed)"
        case .unavailable: "unavailable"
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
