import CloudGatewayKit
import Foundation

@MainActor
public protocol CloudGatewayNotificationAuthorizing {
    func requestAuthorization()
    func requestAuthorizationIfUndetermined()
}

public struct NoopCloudGatewayNotificationAuthorizer: CloudGatewayNotificationAuthorizing {
    public nonisolated init() {}

    public func requestAuthorization() {}
    public func requestAuthorizationIfUndetermined() {}
}

@MainActor
public enum CloudGatewayExistingInstallNotificationAuthorization {
    public static func requestIfNeeded(
        hasInstalledConfig: Bool,
        authorizer: CloudGatewayNotificationAuthorizing
    ) {
        guard hasInstalledConfig else { return }
        authorizer.requestAuthorizationIfUndetermined()
    }
}

@MainActor
public enum CloudGatewayFirstInstallNotificationAuthorization {
    public static func request(authorizer: CloudGatewayNotificationAuthorizing) {
        authorizer.requestAuthorization()
    }
}

public enum CloudGatewayAppError: LocalizedError {
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

    public var errorDescription: String? {
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

public enum CloudGatewayRuntimeConfiguration {
    public enum Error: LocalizedError, Equatable {
        case missingKeychainAccessGroup

        public var errorDescription: String? {
            switch self {
            case .missingKeychainAccessGroup:
                "CloudGateway keychain access group is missing or unresolved."
            }
        }
    }

    public static func keychainAccessGroup(_ value: Any?) throws -> String {
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

public enum CloudGatewayAPIURLBuilder {
    public static func apexAPIURL(originHost: String, path: String) throws -> URL {
        try apiURL(host: "api.\(originHost)", path: path)
    }

    public static func regionalAPIURL(originHost: String, regionId: String, path: String) throws -> URL {
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

    public static func validatedClientId(_ clientId: String) throws -> String {
        guard clientId.range(
            of: #"^[A-Za-z0-9_-]{1,128}$"#,
            options: .regularExpression
        ) != nil else {
            throw CloudGatewayAppError.invalidAPIResponse
        }
        return clientId
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

public struct AuthenticatedUser: Equatable, Sendable {
    public let uid: String
    public let email: String?

    public init(uid: String, email: String?) {
        self.uid = uid
        self.email = email
    }
}

/// Owns an auth-listener cancellation closure so actor-isolated app models can
/// unregister safely from their nonisolated deinitializer. The lock protects
/// the closure and guarantees exact-once cancellation across explicit cancel
/// and deinitialization.
public final class CloudGatewayAuthStateListenerRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    public init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public nonisolated func cancel() {
        let cancellation = lock.withLock {
            defer { self.cancellation = nil }
            return self.cancellation
        }
        cancellation?()
    }

    deinit {
        cancel()
    }
}

public struct CloudGatewayAccessCheck: Decodable, Equatable {
    public let userId: String
    public let email: String?
    public let role: String

    public init(userId: String, email: String?, role: String) {
        self.userId = userId
        self.email = email
        self.role = role
    }
}

public struct CloudGatewayDeleteClientResponse: Decodable, Equatable {
    public let userId: String
    public let clientId: String
    public let regionId: String
    public let status: CloudGatewayClientStatus

    public init(userId: String, clientId: String, regionId: String, status: CloudGatewayClientStatus) {
        self.userId = userId
        self.clientId = clientId
        self.regionId = regionId
        self.status = status
    }
}

public struct CloudGatewayDeleteAccountResponse: Decodable, Equatable {
    public let userId: String
    public let deletedClientCount: Int

    public init(userId: String, deletedClientCount: Int) {
        self.userId = userId
        self.deletedClientCount = deletedClientCount
    }
}

public struct CloudGatewayRegionSyncResponse: Decodable, Equatable {
    public let regionId: String
    public let syncedAt: String
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let noChanges: Bool
    public let log: String

    public init(
        regionId: String,
        syncedAt: String,
        added: Int,
        updated: Int,
        removed: Int,
        noChanges: Bool,
        log: String
    ) {
        self.regionId = regionId
        self.syncedAt = syncedAt
        self.added = added
        self.updated = updated
        self.removed = removed
        self.noChanges = noChanges
        self.log = log
    }
}

public struct CloudGatewayGrantAccessResponse: Decodable, Equatable {
    public let email: String
    public let alreadyExisted: Bool

    public init(email: String, alreadyExisted: Bool) {
        self.email = email
        self.alreadyExisted = alreadyExisted
    }
}

@MainActor
public protocol CloudGatewayServicing: AnyObject {
    var currentUser: AuthenticatedUser? { get }
    func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func signInWithGoogle() async throws -> AuthenticatedUser
    func providerIds() -> [String]
    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser
    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser
    func linkGoogle() async throws -> AuthenticatedUser
    func reauthenticateWithPassword(_ password: String) async throws
    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String, revoke: Bool) async throws
    func reauthenticateWithGoogle(revoke: Bool) async throws
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

public extension CloudGatewayServicing {
    func idToken() async throws -> String {
        try await idToken(forceRefresh: false)
    }
}

@MainActor
public protocol CloudGatewayTunnelHealthReading {
    func currentSnapshot() -> CloudGatewayTunnelHealthSnapshot?
}

public struct NoopTunnelHealthReader: CloudGatewayTunnelHealthReading {
    public nonisolated init() {}

    public func currentSnapshot() -> CloudGatewayTunnelHealthSnapshot? { nil }
}
