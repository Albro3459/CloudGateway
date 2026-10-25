import CloudGatewayKit
import Foundation

public struct CloudGatewayMacManagedUpdateObservation: Equatable, Sendable {
    public struct Profile: Equatable, Sendable {
        public let identifier: String
        public let status: CloudGatewayTunnelStatus

        public init(identifier: String, status: CloudGatewayTunnelStatus) {
            self.identifier = identifier
            self.status = status
        }

        public var needsStop: Bool { status != .invalid && status != .disconnected }
    }

    public let accountId: String?
    public let profiles: [Profile]
    public let authorizedIdentifiers: [String]
    public let isRestoringSession: Bool
    public let accessAuthorized: Bool

    public init(accountId: String?, profiles: [Profile], authorizedIdentifiers: [String],
                isRestoringSession: Bool = false, accessAuthorized: Bool = true) {
        self.accountId = accountId
        self.profiles = profiles
        self.authorizedIdentifiers = authorizedIdentifiers
        self.isRestoringSession = isRestoringSession
        self.accessAuthorized = accessAuthorized
    }
}
