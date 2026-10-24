import CloudGatewayKit
import CloudGatewayMacCore
import Foundation

// Menu wording stays at the frontend boundary
extension CloudGatewayMacControllerView {
    public init(state: CloudGatewayMacControllerState) {
        let status = state.status
        let canStop = (state.stopAllowed ?? !state.commandInFlight) && status.needsStop
        let isTransitioning = state.observedProfiles.contains { $0.status == .connecting || $0.status == .disconnecting }
        let canConnect = state.accountId != nil && state.accessAuthorized && !state.commandInFlight
            && !state.isRestoringSession && !state.isAuthSettling && state.setup == .ready
        let selected = state.clients.first {
            $0.identifier == state.selectedIdentifier && $0.isEligible && canConnect
        }
        let regions = Dictionary(grouping: state.clients, by: \.regionId).values.sorted { lhs, rhs in
            let left = lhs[0]
            let right = rhs[0]
            if left.regionOrder != right.regionOrder { return left.regionOrder < right.regionOrder }
            let comparison = left.regionName.localizedCaseInsensitiveCompare(right.regionName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.regionId.localizedCaseInsensitiveCompare(right.regionId) == .orderedAscending
        }
        let groups = regions.map { clients in
            let rows = clients.sorted { lhs, rhs in
                let ownerComparison = (lhs.ownerLabel ?? "").localizedCaseInsensitiveCompare(rhs.ownerLabel ?? "")
                if ownerComparison != .orderedSame { return ownerComparison == .orderedAscending }
                let comparison = lhs.clientName.localizedCaseInsensitiveCompare(rhs.clientName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.identifier < rhs.identifier
            }.map { client in
                let title = client.ownerLabel.map { "\(client.clientName) (\($0))" } ?? client.clientName
                return Client(identifier: client.identifier, title: ControllerDisplayText.normalize(title, bytes: 2048),
                              status: client.status, isEnabled: canConnect && client.isEligible)
            }
            return Region(title: clients[0].regionName, rows: rows)
        }
        var title: String
        if state.observedProfiles.contains(where: { $0.status == .connecting }) { title = "VPN connecting…" }
        else if state.observedProfiles.contains(where: { $0.status == .disconnecting }) { title = "VPN disconnecting…" }
        else if status.hasActiveTunnel { title = "VPN connected" }
        else if state.accountId == nil { title = "Signed out" }
        else if state.setup != .ready { title = state.setup.title }
        else { title = "VPN off" }
        if !state.observationAvailable {
            if state.observedProfiles.isEmpty, state.accountId != nil, state.setup == .ready {
                title = "VPN status unavailable"
            } else if status.needsStop || (state.accountId != nil && state.setup == .ready) {
                title += " (last observed)"
            }
        }
        self.init(
            groups: groups, statusTitle: title,
            canToggleVPN: !isTransitioning && (canStop || selected != nil), canTurnOff: canStop, hasActiveTunnel: status.hasActiveTunnel,
            reconnectIdentifier: selected?.identifier,
            canRefresh: state.accountId != nil && !state.commandInFlight && state.inventory != .refreshing,
            canSignOut: state.accountId != nil || state.hasRetainedSession,
            accountId: state.accountId, lastSelectedIdentifier: state.selectedIdentifier,
            browserState: state.auth, login: state.login, setupState: state.setup,
            isRestoringSession: state.isRestoringSession, isAuthSettling: state.isAuthSettling,
            hasRetainedSession: state.hasRetainedSession, inventoryInFlight: state.inventory == .refreshing,
            canCreateClient: state.creationAllowed, errorMessage: state.errorMessage,
            hasUnlistedActiveProfile: state.observedProfiles.contains { profile in
                profile.status != .invalid && profile.status != .disconnected
                    && !state.clients.contains { $0.identifier == profile.identifier }
            }, canUpdateExtension: state.canUpdateExtension
        )
    }
}

extension CloudGatewayMacControllerView.SetupState {
    var title: String {
        switch self {
        case .required: "VPN setup required"
        case .updateRequired: "VPN extension update required"
        case .invalidBundle: "The bundled VPN extension is missing or invalid. Reinstall CloudGateway"
        case .activating: "Setting up VPN…"
        case .awaitingApproval: "Approve CloudGateway in System Settings → Login Items & Extensions"
        case .awaitingRestart: "Restart your Mac to finish VPN setup"
        case .checkingConnection: "Checking VPN extension…"
        case .ready: "VPN extension ready"
        case .unavailable: "Move CloudGateway to /Applications, then set up VPN"
        case .failed(let code): "VPN setup failed (error \(code)); check approval and signing"
        }
    }
}

enum ControllerDisplayText {
    static func normalize(_ value: String, bytes: Int) -> String {
        var text = ""
        var count = 0
        for scalar in value.unicodeScalars {
            let safe = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            guard count + safe.utf8.count <= bytes else { break }
            text += safe
            count += safe.utf8.count
        }
        return text.isEmpty ? "Untitled" : text
    }
}

enum ControllerVisibleError {
    private static let messages: Set<String> = [
        "Unable to reach CloudGateway to restore this account",
        "Account access was denied. Sign in again after access is restored",
        "Unable to restore your session. Refresh to try again",
        "Unable to reach CloudGateway. No saved configs are available for this account",
        "Unable to refresh inventory. Try Refresh again",
        "Unable to read VPN preferences. Try Refresh again",
        "Unable to save the VPN profile. Refresh before trying again",
        "The VPN profile was saved, but secure storage did not finish. Refresh before retrying",
        "The VPN profile was saved, but offline metadata could not be saved. Refresh before retrying",
        "VPN command could not finish. Refresh preferences before trying again",
        "VPN connection was accepted, but offline metadata could not refresh. Choose Refresh before trying again",
        "Saved VPN configuration is unavailable. Refresh and try again",
        "Unable to access secure VPN storage",
        "Unable to load available regions. Refresh and try again",
        "Could not confirm whether the client was created. Refresh the client list before trying again",
        "Client was created, but the client list could not refresh. Choose Refresh before trying again",
        "VPN has not confirmed stop. Try again after checking System Settings",
        "CloudGateway returned an invalid sign-in response. Start sign-in again.",
        "Sign-in was denied in the browser.",
        "The sign-in code expired. Start sign-in again.",
        "This sign-in request was already used. Start sign-in again.",
        "This sign-in request is invalid. Start sign-in again.",
        "Sign-in is temporarily limited. Wait before trying again.",
        "Sign-in was interrupted by a network failure. Start sign-in again when online.",
        "Sign-in is unavailable. Start sign-in again later.",
        "CloudGateway could not complete the request. Refresh before trying again"
    ]

    static func sanitize(_ message: String?) -> String? {
        guard let message else { return nil }
        return messages.contains(message) ? message : "CloudGateway could not complete the request. Refresh before trying again"
    }
}

extension CloudGatewayMacControllerView.TunnelStatus {
    init(_ status: CloudGatewayTunnelStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        }
    }
}

extension CloudGatewayMacControllerView.BrowserState {
    init(_ state: CloudGatewayMacBrowserAuthState) {
        switch state {
        case .signedOut: self = .signedOut
        case .requestingCode: self = .requestingCode
        case .waitingForApproval(let code, let url): self = .waitingForApproval(userCode: code, verificationURL: url)
        case .exchangingToken: self = .exchangingToken
        case .signedIn: self = .signedIn
        case .failed: self = .failed
        }
    }
}

extension CloudGatewayMacControllerView.SetupState {
    init(_ state: CloudGatewayMacSetupState) {
        switch state {
        case .required: self = .required
        case .updateRequired: self = .updateRequired
        case .invalidBundle: self = .invalidBundle
        case .activating: self = .activating
        case .awaitingApproval: self = .awaitingApproval
        case .awaitingRestart: self = .awaitingRestart
        case .checkingConnection: self = .checkingConnection
        case .ready: self = .ready
        case .failed(let code): self = .failed(code: code)
        case .unavailable: self = .unavailable
        }
    }
}
