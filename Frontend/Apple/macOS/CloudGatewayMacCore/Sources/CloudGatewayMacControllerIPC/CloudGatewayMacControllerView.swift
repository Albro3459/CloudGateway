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

    public struct Client: Codable, Equatable, Sendable {
        public let identifier: String
        public let title: String
        public let status: TunnelStatus?
        public let isEnabled: Bool

        public init(identifier: String, title: String, status: TunnelStatus?, isEnabled: Bool) {
            self.identifier = identifier
            self.title = title
            self.status = status
            self.isEnabled = isEnabled
        }
    }

    public struct Region: Codable, Equatable, Sendable {
        public let title: String
        public let rows: [Client]

        public init(title: String, rows: [Client]) {
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
    public let setupState: SetupState
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let hasRetainedSession: Bool
    public let inventoryInFlight: Bool
    public let canCreateClient: Bool
    public let errorMessage: String?
    public let hasUnlistedActiveProfile: Bool

    public init(
        groups: [Region] = [], statusTitle: String = "Signed out",
        canToggleVPN: Bool = false, canTurnOff: Bool = false, hasActiveTunnel: Bool = false,
        reconnectIdentifier: String? = nil, canRefresh: Bool = false, canSignOut: Bool = false,
        accountId: String? = nil, lastSelectedIdentifier: String? = nil,
        browserState: BrowserState = .signedOut, setupState: SetupState = .required,
        isRestoringSession: Bool = false, isAuthSettling: Bool = false,
        hasRetainedSession: Bool = false, inventoryInFlight: Bool = false,
        canCreateClient: Bool = false, errorMessage: String? = nil,
        hasUnlistedActiveProfile: Bool = false
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
        self.setupState = setupState
        self.isRestoringSession = isRestoringSession
        self.isAuthSettling = isAuthSettling
        self.hasRetainedSession = hasRetainedSession
        self.inventoryInFlight = inventoryInFlight
        self.canCreateClient = canCreateClient
        self.errorMessage = errorMessage
        self.hasUnlistedActiveProfile = hasUnlistedActiveProfile
    }

    func validate() throws {
        let bounds = CloudGatewayMacControllerProtocol.self
        guard groups.count <= 256, groups.reduce(0, { $0 + $1.rows.count }) <= 4096,
              bounds.boundedText(statusTitle, bytes: 1024),
              errorMessage.map({ bounds.boundedText($0, bytes: 2048) && ControllerVisibleError.sanitize($0) == $0 }) ?? true else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        guard accountId.map(bounds.validComponent) ?? true,
              accountId != nil || (groups.isEmpty && lastSelectedIdentifier == nil && reconnectIdentifier == nil) else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        func belongsToAccount(_ identifier: String) -> Bool {
            guard let accountId else { return false }
            return bounds.validIdentifier(identifier) && identifier.hasPrefix("\(accountId)/")
        }
        guard lastSelectedIdentifier.map(belongsToAccount) ?? true,
              reconnectIdentifier.map(belongsToAccount) ?? true else {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        var identifiers = Set<String>()
        for group in groups {
            guard bounds.boundedText(group.title, bytes: 1024) else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
            for row in group.rows {
                guard belongsToAccount(row.identifier), identifiers.insert(row.identifier).inserted,
                      bounds.boundedText(row.title, bytes: 2048) else {
                    throw CloudGatewayMacControllerFailure.invalidRequest
                }
            }
        }
        if case .waitingForApproval(let code, let url) = browserState {
            guard accountId == nil, bounds.validChallenge(code: code, url: url) else {
                throw CloudGatewayMacControllerFailure.invalidRequest
            }
        }
        if browserState == .signedIn, accountId == nil {
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
    }
}
