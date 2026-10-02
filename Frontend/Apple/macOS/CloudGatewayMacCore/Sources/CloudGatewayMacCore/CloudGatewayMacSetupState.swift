public enum CloudGatewayMacSetupState: Equatable, Sendable {
    case required
    case activating
    case awaitingApproval
    case awaitingRestart
    case checkingConnection
    case ready
    case failed(code: Int)
    case unavailable

    public var canActivate: Bool {
        switch self {
        case .activating, .awaitingApproval, .checkingConnection: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .required: "VPN setup required"
        case .activating: "Setting up VPN…"
        case .awaitingApproval: "Approve CloudGateway in System Settings → Login Items & Extensions"
        case .awaitingRestart: "Restart your Mac to finish VPN setup"
        case .checkingConnection: "Checking VPN extension…"
        case .ready: "VPN extension ready"
        case .failed(let code): "VPN setup failed (error \(code)); check approval and signing"
        case .unavailable: "Move CloudGateway to /Applications, then set up VPN"
        }
    }
}
