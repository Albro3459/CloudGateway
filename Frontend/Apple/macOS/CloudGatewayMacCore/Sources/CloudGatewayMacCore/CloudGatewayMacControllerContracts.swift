import CloudGatewayAppCore
import CloudGatewayKit
import Foundation

@MainActor
public protocol CloudGatewayMacControllerAuthServicing: CloudGatewayCustomTokenAuthServicing {
    func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration
}

@MainActor
public protocol CloudGatewayMacInventoryServicing: AnyObject {
    func checkAccess(for user: AuthenticatedUser) async throws -> CloudGatewayMacAccountRole
    func fetchOptions(for user: AuthenticatedUser, role: CloudGatewayMacAccountRole) async throws -> [CloudGatewayClientOption]
    func fetchCreateRegions(for user: AuthenticatedUser) async throws -> [CloudGatewayRegion]
    func createClient(regionId: String, clientName: String, for user: AuthenticatedUser) async throws -> String
    func deleteClient(
        clientId: String, ownerUid: String, regionId: String, for user: AuthenticatedUser,
        authorize: @escaping @MainActor () async throws -> Void,
        onDispatch: @escaping @MainActor () -> Void
    ) async throws -> CloudGatewayDeleteClientResponse
}

public struct CloudGatewayMacClientCreationContext: Equatable, Sendable {
    let session: CloudGatewayMacSessionToken
    let controllerId: UUID
}

public enum CloudGatewayMacCommandFailure: String, Codable, Sendable {
    case signInRequired, accessDenied
    case setupRequired, credentialsUnavailable, incompatibleVersion
    case extensionMismatch, initialSetupRequired, approvalRequired, restartRequired, invalidBundle, checkingReadiness, activationFailed
    case configUnavailable, selectionUnavailable, clientActive, networkUnavailable, busy
    case stopTimedOut, vpnFailed, internalError
}

public enum CloudGatewayMacCommandWarning: String, Codable, Sendable {
    case selectionNotSaved, inventoryNotRefreshed, localCleanupIncomplete, reconnectSuppressionNotPersisted
}

// A start result means macOS accepted the request, not that the tunnel connected
public enum CloudGatewayMacCommandOutcome: Codable, Equatable, Sendable {
    case startRequested(identifier: String, warning: CloudGatewayMacCommandWarning?)
    case alreadyActive(identifier: String, warning: CloudGatewayMacCommandWarning?)
    case completed(warning: CloudGatewayMacCommandWarning?)
    case failed(CloudGatewayMacCommandFailure)
    case unknown
    case expired
}

// Offline refreshes mark authorized saved inventory as cached, otherwise unavailable
public enum CloudGatewayMacRefreshResult: String, Codable, Sendable {
    case refreshed, unavailable, denied, signInRequired, skipped, superseded, timedOut
}

public enum CloudGatewayMacAccessState: String, Codable, Sendable {
    case unverified, checking, online, offline, denied, unreachable
}

// Firebase reports no user both when signed out and when stored credentials are unreadable
public enum CloudGatewayMacCredentialEvidence: String, Codable, Sendable {
    case available, unknown
}

public enum CloudGatewayMacClientEligibility: String, Codable, Sendable {
    case eligible, inactive, configMissing, regionUnavailable
}

public enum CloudGatewayMacInventorySource: String, Codable, Sendable {
    case cloud, cache
}

public enum CloudGatewayMacInventoryFreshness: String, Equatable, Sendable {
    case unavailable
    case refreshing
    case current
    case cached
}

public struct CloudGatewayMacDomainSnapshot: Equatable, Sendable {
    public let accountId: String?
    public let hasRetainedSession: Bool
    public let accessAuthorized: Bool
    public let access: CloudGatewayMacAccessState
    public let credentials: CloudGatewayMacCredentialEvidence
    public let inventoryFreshness: CloudGatewayMacInventoryFreshness
    public let installedIdentifiers: [String]
    public let observedProfiles: [CloudGatewayMacObservedProfile]
    public let observationIsFresh: Bool
    public let profilesObservedAt: Date?
    public let commandInFlight: Bool
    public let clients: [CloudGatewayMacClientMetadata]
}

public struct CloudGatewayMacClientMetadata: Equatable, Sendable {
    public let identifier: String
    public let regionId: String
    public let regionName: String
    public let regionOrder: Int
    public let clientName: String
    public let ownerLabel: String?
    public let internalIp: String?
    public var connectionUrl: String? = nil
    public let cloudState: CloudGatewayClientStatus
    public let eligibility: CloudGatewayMacClientEligibility
    public let isInstalled: Bool
    public let source: CloudGatewayMacInventorySource
    public let readAt: Date
    public let updatedAt: Date?
    public let status: CloudGatewayTunnelStatus?

    public var clientId: String { String(identifier.split(separator: "/").last ?? "") }
}

public struct CloudGatewayMacObservedProfile: Equatable, Sendable {
    public let identifier: String
    public let status: CloudGatewayTunnelStatus
}

public struct CloudGatewayMacControllerSnapshot: Equatable, Sendable {
    public let domain: CloudGatewayMacDomainSnapshot
    public let lastSelectedIdentifier: String?
    public let browserState: CloudGatewayMacBrowserAuthState
    public var login: CloudGatewayMacLoginStatus? = nil
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let canCreateClient: Bool
    public let errorMessage: String?
}
