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
}

public struct CloudGatewayMacClientCreationContext: Equatable, Sendable {
    let session: CloudGatewayMacSessionToken
    let controllerId: UUID
}

public enum CloudGatewayMacCommandResult: String, Equatable, Sendable {
    case completed
    case failed
    case unknown
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
    public let inventoryFreshness: CloudGatewayMacInventoryFreshness
    public let installedIdentifiers: [String]
    public let observedProfiles: [CloudGatewayMacObservedProfile]
    public let observationIsFresh: Bool
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
    public let isEligible: Bool
    public let status: CloudGatewayTunnelStatus?
}

public struct CloudGatewayMacObservedProfile: Equatable, Sendable {
    public let identifier: String
    public let status: CloudGatewayTunnelStatus
}

public struct CloudGatewayMacControllerSnapshot: Equatable, Sendable {
    public let domain: CloudGatewayMacDomainSnapshot
    public let lastSelectedIdentifier: String?
    public let browserState: CloudGatewayMacBrowserAuthState
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let canCreateClient: Bool
    public let errorMessage: String?
}
