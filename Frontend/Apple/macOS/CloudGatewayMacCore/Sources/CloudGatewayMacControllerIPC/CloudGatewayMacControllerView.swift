import CloudGatewayMacCore
import Foundation

public struct CloudGatewayMacControllerView: Codable, Equatable, Sendable {
    public enum TunnelStatus: String, Codable, Sendable {
        case invalid, disconnected, connecting, connected, reasserting, disconnecting
    }

    public enum BrowserState: Codable, Equatable, Sendable {
        case signedOut, requestingCode, exchangingToken, signedIn, failed
        case waitingForApproval(userCode: String, verificationURL: URL)
    }

    public enum SetupState: Codable, Equatable, Sendable {
        case required, updateRequired, invalidBundle, activating, awaitingApproval
        case awaitingRestart, checkingConnection, ready, unavailable
        case failed(code: Int)
    }

    public enum RemovalPermission: String, Codable, Sendable {
        case inactive, active, unavailable
    }

    public struct Client: Codable, Equatable, Sendable {
        public let identifier: String
        public let title: String
        public let status: TunnelStatus?
        public let isEnabled: Bool
        public let removalPermission: RemovalPermission

        public init(identifier: String, title: String, status: TunnelStatus?, isEnabled: Bool,
                    removalPermission: RemovalPermission = .unavailable) {
            self.identifier = identifier
            self.title = title
            self.status = status
            self.isEnabled = isEnabled
            self.removalPermission = removalPermission
        }
    }

    public struct Region: Codable, Equatable, Sendable {
        public let regionId: String
        public let title: String
        public let rows: [Client]

        public init(regionId: String = "", title: String, rows: [Client]) {
            self.regionId = regionId
            self.title = title
            self.rows = rows
        }
    }

    public let groups: [Region]
    public let statusTitle: String
    public let canToggleVPN: Bool
    public let canTurnOff: Bool
    public let hasActiveTunnel: Bool
    public let reconnectIdentifier: String?
    public let canRefresh: Bool
    public let canSignOut: Bool
    public let accountId: String?
    public let lastSelectedIdentifier: String?
    public let browserState: BrowserState
    public let login: CloudGatewayMacLoginStatus?
    public let setupState: SetupState
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let hasRetainedSession: Bool
    public let inventoryInFlight: Bool
    public let canCreateClient: Bool
    public let canRemoveClient: Bool
    public let errorMessage: String?
    public let hasUnlistedActiveProfile: Bool
    public let canUpdateExtension: Bool

    public init(
        groups: [Region] = [], statusTitle: String = "Signed out",
        canToggleVPN: Bool = false, canTurnOff: Bool = false, hasActiveTunnel: Bool = false,
        reconnectIdentifier: String? = nil, canRefresh: Bool = false, canSignOut: Bool = false,
        accountId: String? = nil, lastSelectedIdentifier: String? = nil,
        browserState: BrowserState = .signedOut, login: CloudGatewayMacLoginStatus? = nil, setupState: SetupState = .required,
        isRestoringSession: Bool = false, isAuthSettling: Bool = false,
        hasRetainedSession: Bool = false, inventoryInFlight: Bool = false,
        canCreateClient: Bool = false, canRemoveClient: Bool = false, errorMessage: String? = nil,
        hasUnlistedActiveProfile: Bool = false, canUpdateExtension: Bool = false
    ) {
        self.groups = groups
        self.statusTitle = statusTitle
        self.canToggleVPN = canToggleVPN
        self.canTurnOff = canTurnOff
        self.hasActiveTunnel = hasActiveTunnel
        self.reconnectIdentifier = reconnectIdentifier
        self.canRefresh = canRefresh
        self.canSignOut = canSignOut
        self.accountId = accountId
        self.lastSelectedIdentifier = lastSelectedIdentifier
        self.browserState = browserState
        self.login = login
        self.setupState = setupState
        self.isRestoringSession = isRestoringSession
        self.isAuthSettling = isAuthSettling
        self.hasRetainedSession = hasRetainedSession
        self.inventoryInFlight = inventoryInFlight
        self.canCreateClient = canCreateClient
        self.canRemoveClient = canRemoveClient
        self.errorMessage = errorMessage
        self.hasUnlistedActiveProfile = hasUnlistedActiveProfile
        self.canUpdateExtension = canUpdateExtension
    }
}
