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

public struct CloudGatewayMacControllerSnapshot: Equatable, Sendable {
    public let groups: [CloudGatewayMacMenuRegion]
    public let statusTitle: String
    public let canToggleVPN: Bool
    public let canTurnOff: Bool
    public let hasActiveTunnel: Bool
    public let reconnectIdentifier: String?
    public let canRefresh: Bool
    public let canSignOut: Bool
    public let accountId: String?
    public let lastSelectedIdentifier: String?
    public let browserState: CloudGatewayMacBrowserAuthState
    public let isRestoringSession: Bool
    public let isAuthSettling: Bool
    public let hasRetainedSession: Bool
    public let inventoryInFlight: Bool
    public let canCreateClient: Bool
    public let errorMessage: String?
    public let hasUnlistedActiveProfile: Bool
}
