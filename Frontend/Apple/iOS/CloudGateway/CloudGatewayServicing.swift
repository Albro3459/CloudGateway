import CloudGatewayKit
import Foundation

enum CloudGatewayAppError: LocalizedError {
    case missingCurrentUser
    case noEnabledRegions
    case missingSelectedRegion
    case invalidAPIResponse
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingCurrentUser:
            "Sign in again to continue."
        case .noEnabledRegions:
            "No enabled CloudGateway regions are available."
        case .missingSelectedRegion:
            "Choose a region first."
        case .invalidAPIResponse:
            "CloudGateway returned an invalid response."
        case .accessDenied(let message):
            message
        }
    }
}

struct AuthenticatedUser: Equatable, Sendable {
    let uid: String
    let email: String?
}

struct CloudGatewayAccessCheck: Decodable, Equatable {
    let userId: String
    let email: String?
    let role: String
}

struct CloudGatewayDeleteClientResponse: Decodable, Equatable {
    let userId: String
    let clientId: String
    let regionId: String
    let status: CloudGatewayClientStatus
}

struct CloudGatewayRegionSyncResponse: Decodable, Equatable {
    let regionId: String
    let syncedAt: String
    let added: Int
    let updated: Int
    let removed: Int
    let noChanges: Bool
}

/// App-side seam over Firebase Auth + the regional API so `CloudGatewayViewModel`
/// can be exercised with a mock. Firebase-free on purpose: the only conformer that
/// touches Firebase is `CloudGatewayFirebaseService`.
protocol CloudGatewayServicing {
    var currentUser: AuthenticatedUser? { get }
    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any
    func removeAuthStateListener(_ token: Any)
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signOut() throws
    func idToken() async throws -> String
    func fetchUserRole(uid: String) async throws -> String?
    func fetchRegions() async throws -> [CloudGatewayRegion]
    func checkAccess(idToken: String, regions: [CloudGatewayRegion]) async throws -> CloudGatewayAccessCheck
    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion]
    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient]
    func createClient(regionId: String, clientName: String?, idToken: String) async throws -> CloudGatewayClient
    func deleteClient(clientId: String, userId: String, regionId: String, idToken: String) async throws -> CloudGatewayDeleteClientResponse
    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse
}
