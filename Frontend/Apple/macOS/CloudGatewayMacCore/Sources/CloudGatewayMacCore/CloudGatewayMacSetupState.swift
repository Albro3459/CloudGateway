import CloudGatewayKit

public enum CloudGatewayMacSetupState: Equatable, Sendable {
    case required
    case updateRequired
    case invalidBundle
    case activating
    case awaitingApproval
    case awaitingRestart
    case checkingConnection
    case ready
    case failed(code: Int)
    case unavailable

    public var canActivate: Bool {
        switch self {
        case .activating, .awaitingApproval, .awaitingRestart, .checkingConnection, .invalidBundle: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .required: "VPN setup required"
        case .updateRequired: "VPN extension update required"
        case .invalidBundle: "The bundled VPN extension is missing or invalid. Reinstall CloudGateway"
        case .activating: "Setting up VPN…"
        case .awaitingApproval: "Approve CloudGateway in System Settings → Login Items & Extensions"
        case .awaitingRestart: "Restart your Mac to finish VPN setup"
        case .checkingConnection: "Checking VPN extension…"
        case .ready: "VPN extension ready"
        case .failed(let code): "VPN setup failed (error \(code)); check approval and signing"
        case .unavailable: "Move CloudGateway to /Applications, then set up VPN"
        }
    }

    public static func canReplaceExtension(
        isCurrentBuild: Bool, ownedTunnelStatuses: [CloudGatewayTunnelStatus]?
    ) -> Bool {
        guard isCurrentBuild, let ownedTunnelStatuses else { return false }
        return ownedTunnelStatuses.allSatisfy { $0 == .invalid || $0 == .disconnected }
    }
}
