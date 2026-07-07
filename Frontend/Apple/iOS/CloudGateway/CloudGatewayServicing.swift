import CloudGatewayKit
import Foundation

enum CloudGatewayAppError: LocalizedError {
    case missingCurrentUser
    case noEnabledRegions
    case missingSelectedRegion
    case invalidAPIResponse
    case accessDenied(String)
    case cancelled
    case appleSignInFailed
    case requiresRecentLogin
    case credentialAlreadyInUse
    case providerAlreadyLinked
    case invalidEmail
    case weakPassword
    case invalidSignInCredentials
    case wrongPassword

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
        case .cancelled:
            "Sign in was cancelled."
        case .appleSignInFailed:
            "Apple sign in failed."
        case .requiresRecentLogin:
            "Sign in again before linking another sign-in method."
        case .credentialAlreadyInUse:
            "That sign-in method is already used by another CloudGateway account. Sign in with that account directly or contact support."
        case .providerAlreadyLinked:
            "That sign-in method is already linked to this account."
        case .invalidEmail:
            "Enter a valid email address."
        case .weakPassword:
            "Enter a stronger password."
        case .invalidSignInCredentials:
            "Invalid email or password."
        case .wrongPassword:
            "The current password is incorrect."
        }
    }
}

enum CloudGatewayFirebaseAuthErrorCode {
    static func signInError(forRawCode code: Int) -> CloudGatewayAppError? {
        switch code {
        case 17008:
            return .invalidEmail
        case 17004, 17009, 17011:
            return .invalidSignInCredentials
        case 17005:
            return .accessDenied("This account has been disabled. Contact support.")
        default:
            return nil
        }
    }
}

enum CloudGatewayRuntimeConfiguration {
    enum Error: LocalizedError, Equatable {
        case missingKeychainAccessGroup

        var errorDescription: String? {
            switch self {
            case .missingKeychainAccessGroup:
                "CloudGateway keychain access group is missing or unresolved."
            }
        }
    }

    static func keychainAccessGroup(_ value: Any?) throws -> String {
        guard let accessGroup = value as? String else {
            throw Error.missingKeychainAccessGroup
        }
        let trimmedAccessGroup = accessGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessGroup.isEmpty,
              !trimmedAccessGroup.contains("$") else {
            throw Error.missingKeychainAccessGroup
        }
        return trimmedAccessGroup
    }
}

enum CloudGatewayAPIURLBuilder {
    static func apexAPIURL(originHost: String, path: String) throws -> URL {
        try apiURL(host: "api.\(originHost)", path: path)
    }

    static func regionalAPIURL(originHost: String, regionId: String, path: String) throws -> URL {
        try apiURL(host: "\(normalizedRegionId(regionId)).\(originHost)", path: path)
    }

    private static func normalizedRegionId(_ regionId: String) throws -> String {
        var normalizedRegionId = regionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedRegionId.hasPrefix("www.") {
            normalizedRegionId.removeFirst(4)
        }
        guard normalizedRegionId.range(
            of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#,
            options: .regularExpression
        ) != nil else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        return normalizedRegionId
    }

    private static func apiURL(host: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        guard let url = components.url else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        return url
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

struct CloudGatewayDeleteAccountResponse: Decodable, Equatable {
    let userId: String
    let deletedClientCount: Int
}

struct CloudGatewayRegionSyncResponse: Decodable, Equatable {
    let regionId: String
    let syncedAt: String
    let added: Int
    let updated: Int
    let removed: Int
    let noChanges: Bool
    let log: String
}

struct CloudGatewayGrantAccessResponse: Decodable, Equatable {
    let email: String
    let alreadyExisted: Bool
}

/// App-side seam over Firebase Auth + the regional API so `CloudGatewayViewModel`
/// can be exercised with a mock. Firebase-free on purpose: the only conformer that
/// touches Firebase is `CloudGatewayFirebaseService`.
protocol CloudGatewayServicing {
    var currentUser: AuthenticatedUser? { get }
    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any
    nonisolated func removeAuthStateListener(_ token: Any)
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func signInWithGoogle() async throws -> AuthenticatedUser
    func providerIds() -> [String]
    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser
    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func linkGoogle() async throws -> AuthenticatedUser
    func reauthenticateWithPassword(_ password: String) async throws
    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String) async throws
    func reauthenticateWithGoogle() async throws
    func sendPasswordReset(email: String) async throws
    func signOut() throws
    func idToken(forceRefresh: Bool) async throws -> String
    func fetchUserRole(uid: String) async throws -> String?
    func fetchRegions() async throws -> [CloudGatewayRegion]
    func checkAccess(idToken: String, regions: [CloudGatewayRegion]) async throws -> CloudGatewayAccessCheck
    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion]
    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient]
    func fetchAllClients() async throws -> [CloudGatewayClient]
    func createClient(regionId: String, clientName: String, idToken: String) async throws -> CloudGatewayClient
    func deleteClient(clientId: String, userId: String, regionId: String, idToken: String) async throws -> CloudGatewayDeleteClientResponse
    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse
    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse
    func grantAccess(email: String, regionId: String, idToken: String) async throws -> CloudGatewayGrantAccessResponse
}

extension CloudGatewayServicing {
    func idToken() async throws -> String {
        try await idToken(forceRefresh: false)
    }
}
