import CloudGatewayKit
import CloudGatewayMacCore
import Foundation

extension CloudGatewayMacControllerView {
    public init(snapshot: CloudGatewayMacControllerSnapshot, setupState: CloudGatewayMacSetupState) {
        let accountId = snapshot.accountId
        self.init(
            groups: accountId == nil ? [] : snapshot.groups.map { group in
                Region(title: ControllerDisplayText.normalize(group.title, bytes: 1024), rows: group.rows.map { row in
                    Client(identifier: row.identifier, title: ControllerDisplayText.normalize(row.title, bytes: 2048),
                           status: row.status.map(TunnelStatus.init), isEnabled: row.isEnabled)
                })
            },
            statusTitle: snapshot.statusTitle, canToggleVPN: snapshot.canToggleVPN,
            canTurnOff: snapshot.canTurnOff, hasActiveTunnel: snapshot.hasActiveTunnel,
            reconnectIdentifier: accountId == nil ? nil : snapshot.reconnectIdentifier,
            canRefresh: snapshot.canRefresh, canSignOut: snapshot.canSignOut,
            accountId: accountId, lastSelectedIdentifier: accountId == nil ? nil : snapshot.lastSelectedIdentifier,
            browserState: BrowserState(snapshot.browserState), setupState: SetupState(setupState),
            isRestoringSession: snapshot.isRestoringSession, isAuthSettling: snapshot.isAuthSettling,
            hasRetainedSession: snapshot.hasRetainedSession, inventoryInFlight: snapshot.inventoryInFlight,
            canCreateClient: snapshot.canCreateClient, errorMessage: ControllerVisibleError.sanitize(snapshot.errorMessage),
            hasUnlistedActiveProfile: snapshot.hasUnlistedActiveProfile
        )
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
        "Unable to reach CloudGateway. No installed configs are available for this account",
        "Unable to refresh inventory. Try Refresh again",
        "Unable to read VPN preferences. Try Refresh again",
        "Unable to save the VPN profile. Refresh before trying again",
        "The VPN profile was saved, but secure storage did not finish. Refresh before retrying",
        "The VPN profile was saved, but offline metadata could not be saved. Refresh before retrying",
        "VPN command could not finish. Refresh preferences before trying again",
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
