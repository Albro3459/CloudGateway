import CloudGatewayKit
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
    public let canSetMode: Bool
    public let selectedMode: CloudGatewayRoutingMode?
    public let activeMode: CloudGatewayRoutingMode?
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
        hasUnlistedActiveProfile: Bool = false, canUpdateExtension: Bool = false,
        selectedMode: CloudGatewayRoutingMode? = nil, activeMode: CloudGatewayRoutingMode? = nil, canSetMode: Bool = false
    ) {
        self.groups = groups
        self.statusTitle = statusTitle
        self.canToggleVPN = canToggleVPN
        self.canSetMode = canSetMode
        self.selectedMode = selectedMode
        self.activeMode = activeMode
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

    private enum CodingKeys: String, CodingKey {
        case groups, statusTitle, canToggleVPN, canSetMode, selectedMode, activeMode
        case canTurnOff, hasActiveTunnel, reconnectIdentifier, canRefresh, canSignOut, accountId
        case lastSelectedIdentifier, browserState, login, setupState, isRestoringSession, isAuthSettling
        case hasRetainedSession, inventoryInFlight, canCreateClient, canRemoveClient, errorMessage, hasUnlistedActiveProfile
        case canUpdateExtension
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            groups: try values.decode([Region].self, forKey: .groups),
            statusTitle: try values.decode(String.self, forKey: .statusTitle),
            canToggleVPN: try values.decode(Bool.self, forKey: .canToggleVPN),
            canTurnOff: try values.decode(Bool.self, forKey: .canTurnOff),
            hasActiveTunnel: try values.decode(Bool.self, forKey: .hasActiveTunnel),
            reconnectIdentifier: try values.decodeIfPresent(String.self, forKey: .reconnectIdentifier),
            canRefresh: try values.decode(Bool.self, forKey: .canRefresh),
            canSignOut: try values.decode(Bool.self, forKey: .canSignOut),
            accountId: try values.decodeIfPresent(String.self, forKey: .accountId),
            lastSelectedIdentifier: try values.decodeIfPresent(String.self, forKey: .lastSelectedIdentifier),
            browserState: try values.decode(BrowserState.self, forKey: .browserState),
            login: try values.decodeIfPresent(CloudGatewayMacLoginStatus.self, forKey: .login),
            setupState: try values.decode(SetupState.self, forKey: .setupState),
            isRestoringSession: try values.decode(Bool.self, forKey: .isRestoringSession),
            isAuthSettling: try values.decode(Bool.self, forKey: .isAuthSettling),
            hasRetainedSession: try values.decode(Bool.self, forKey: .hasRetainedSession),
            inventoryInFlight: try values.decode(Bool.self, forKey: .inventoryInFlight),
            canCreateClient: try values.decode(Bool.self, forKey: .canCreateClient),
            canRemoveClient: try values.decode(Bool.self, forKey: .canRemoveClient),
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            hasUnlistedActiveProfile: try values.decode(Bool.self, forKey: .hasUnlistedActiveProfile),
            canUpdateExtension: try values.decode(Bool.self, forKey: .canUpdateExtension),
            selectedMode: try values.decodeIfPresent(CloudGatewayRoutingMode.self, forKey: .selectedMode),
            activeMode: try values.decodeIfPresent(CloudGatewayRoutingMode.self, forKey: .activeMode),
            canSetMode: try values.decodeIfPresent(Bool.self, forKey: .canSetMode) ?? false
        )
    }
}
