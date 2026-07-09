import CloudGatewayKit
import Foundation

/// Configurable mock of `CloudGatewayServicing` for view-model tests. Records call
/// counts and returns canned data; inject errors to exercise failure branches.
final class MockGatewayService: CloudGatewayServicing {
    // Canned state.
    var currentUser: AuthenticatedUser?
    var enabledRegions = [CloudGatewayRegion]()
    var ownedClients = [CloudGatewayClient]()
    var userRole: String? = "user"
    var accessRole = "user"
    var providerIdsValue = ["password"]

    // Injectable errors.
    var idTokenError: Error?
    var signInError: Error?
    var signInWithAppleError: Error?
    var signInWithGoogleError: Error?
    var linkEmailPasswordError: Error?
    var linkAppleError: Error?
    var linkGoogleError: Error?
    var linkAppleErrors = [Error]()
    var linkGoogleErrors = [Error]()
    var sendPasswordResetError: Error?
    var reauthenticateWithPasswordError: Error?
    var reauthenticateWithAppleError: Error?
    var reauthenticateWithGoogleError: Error?
    var fetchRegionsError: Error?
    var checkAccessError: Error?
    var fetchUserRoleError: Error?
    var fetchOwnedClientsError: Error?
    var createClientError: Error?
    var deleteClientError: Error?
    var deleteAccountError: Error?
    var syncRegionError: Error?
    var grantAccessError: Error?

    // Grant-access response tuning.
    var grantAccessAlreadyExisted = false

    // Captured inputs.
    private(set) var sendPasswordResetEmail: String?
    private(set) var linkEmail: String?
    private(set) var linkPassword: String?
    private(set) var reauthenticatePassword: String?
    private(set) var createClientName: String?
    private(set) var deleteClientUserId: String?
    private(set) var deleteClientClientId: String?
    private(set) var grantAccessEmail: String?
    private(set) var grantAccessRegionId: String?

    // Call counters.
    private(set) var fetchRegionsCallCount = 0
    private(set) var fetchUserRoleCallCount = 0
    private(set) var fetchOwnedClientsCallCount = 0
    private(set) var fetchAllClientsCallCount = 0
    private(set) var addCapacityCallCount = 0
    private(set) var checkAccessCallCount = 0
    private(set) var signInCallCount = 0
    private(set) var signInWithAppleCallCount = 0
    private(set) var signInWithGoogleCallCount = 0
    private(set) var linkEmailPasswordCallCount = 0
    private(set) var linkAppleCallCount = 0
    private(set) var linkGoogleCallCount = 0
    private(set) var sendPasswordResetCallCount = 0
    private(set) var reauthenticateWithPasswordCallCount = 0
    private(set) var reauthenticateWithAppleCallCount = 0
    private(set) var reauthenticateWithGoogleCallCount = 0
    private(set) var reauthenticateWithAppleRevokeValues: [Bool] = []
    private(set) var reauthenticateWithGoogleRevokeValues: [Bool] = []
    private(set) var idTokenForceRefreshValues: [Bool] = []
    private(set) var signOutCallCount = 0
    private(set) var createClientCallCount = 0
    private(set) var deleteClientCallCount = 0
    private(set) var deleteAccountCallCount = 0
    private(set) var syncRegionCallCount = 0
    private(set) var grantAccessCallCount = 0

    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any {
        // Intentionally does not fire so tests drive loads explicitly.
        NSObject()
    }

    func removeAuthStateListener(_ token: Any) {}

    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        signInCallCount += 1
        if let signInError {
            throw signInError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: email)
        currentUser = user
        return user
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        signInWithAppleCallCount += 1
        if let signInWithAppleError {
            throw signInWithAppleError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: currentUser?.email ?? "apple@example.com")
        currentUser = user
        return user
    }

    func signInWithGoogle() async throws -> AuthenticatedUser {
        signInWithGoogleCallCount += 1
        if let signInWithGoogleError {
            throw signInWithGoogleError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: currentUser?.email ?? "google@example.com")
        currentUser = user
        return user
    }

    func providerIds() -> [String] {
        providerIdsValue
    }

    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
        linkEmailPasswordCallCount += 1
        linkEmail = email
        linkPassword = password
        if let linkEmailPasswordError {
            throw linkEmailPasswordError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: currentUser?.email ?? email)
        currentUser = user
        return user
    }

    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        linkAppleCallCount += 1
        if !linkAppleErrors.isEmpty {
            throw linkAppleErrors.removeFirst()
        }
        if let linkAppleError {
            throw linkAppleError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: currentUser?.email ?? "apple@example.com")
        currentUser = user
        return user
    }

    func linkGoogle() async throws -> AuthenticatedUser {
        linkGoogleCallCount += 1
        if !linkGoogleErrors.isEmpty {
            throw linkGoogleErrors.removeFirst()
        }
        if let linkGoogleError {
            throw linkGoogleError
        }
        let user = AuthenticatedUser(uid: currentUser?.uid ?? "test-uid", email: currentUser?.email ?? "google@example.com")
        currentUser = user
        return user
    }

    func reauthenticateWithPassword(_ password: String) async throws {
        reauthenticateWithPasswordCallCount += 1
        reauthenticatePassword = password
        if let reauthenticateWithPasswordError {
            throw reauthenticateWithPasswordError
        }
    }

    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String, revoke: Bool) async throws {
        reauthenticateWithAppleCallCount += 1
        reauthenticateWithAppleRevokeValues.append(revoke)
        if let reauthenticateWithAppleError {
            throw reauthenticateWithAppleError
        }
    }

    func reauthenticateWithGoogle(revoke: Bool) async throws {
        reauthenticateWithGoogleCallCount += 1
        reauthenticateWithGoogleRevokeValues.append(revoke)
        if let reauthenticateWithGoogleError {
            throw reauthenticateWithGoogleError
        }
    }

    func sendPasswordReset(email: String) async throws {
        sendPasswordResetCallCount += 1
        sendPasswordResetEmail = email
        if let sendPasswordResetError {
            throw sendPasswordResetError
        }
    }

    func signOut() throws {
        signOutCallCount += 1
        currentUser = nil
    }

    func idToken(forceRefresh: Bool) async throws -> String {
        idTokenForceRefreshValues.append(forceRefresh)
        if let idTokenError {
            throw idTokenError
        }
        return "test-token"
    }

    func fetchUserRole(uid: String) async throws -> String? {
        fetchUserRoleCallCount += 1
        if let fetchUserRoleError {
            throw fetchUserRoleError
        }
        return userRole
    }

    func fetchRegions() async throws -> [CloudGatewayRegion] {
        fetchRegionsCallCount += 1
        if let fetchRegionsError {
            throw fetchRegionsError
        }
        return CloudGatewayConfigSelection.sortedRegions(enabledRegions)
    }

    func checkAccess(idToken: String, regions: [CloudGatewayRegion]) async throws -> CloudGatewayAccessCheck {
        checkAccessCallCount += 1
        if let checkAccessError {
            throw checkAccessError
        }
        return CloudGatewayAccessCheck(
            userId: currentUser?.uid ?? "test-uid",
            email: currentUser?.email,
            role: accessRole
        )
    }

    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion] {
        addCapacityCallCount += 1
        return CloudGatewayConfigSelection.sortedRegions(regions)
    }

    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        fetchOwnedClientsCallCount += 1
        if let fetchOwnedClientsError {
            throw fetchOwnedClientsError
        }
        return ownedClients
    }

    func fetchAllClients() async throws -> [CloudGatewayClient] {
        fetchAllClientsCallCount += 1
        if let fetchOwnedClientsError {
            throw fetchOwnedClientsError
        }
        return ownedClients
    }

    func createClient(regionId: String, clientName: String, idToken: String) async throws -> CloudGatewayClient {
        createClientCallCount += 1
        createClientName = clientName
        if let createClientError {
            throw createClientError
        }
        return CloudGatewayClient(
            clientId: "created-\(createClientCallCount)",
            clientName: clientName,
            regionId: regionId,
            status: .active,
            wireGuardConfig: TestFixtures.usableConfig
        )
    }

    func deleteClient(clientId: String, userId: String, regionId: String, idToken: String) async throws -> CloudGatewayDeleteClientResponse {
        deleteClientCallCount += 1
        deleteClientUserId = userId
        deleteClientClientId = clientId
        if let deleteClientError {
            throw deleteClientError
        }
        return CloudGatewayDeleteClientResponse(
            userId: userId,
            clientId: clientId,
            regionId: regionId,
            status: .removed
        )
    }

    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        deleteAccountCallCount += 1
        if let deleteAccountError {
            throw deleteAccountError
        }
        currentUser = nil
        return CloudGatewayDeleteAccountResponse(
            userId: "test-uid",
            deletedClientCount: ownedClients.count
        )
    }

    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        syncRegionCallCount += 1
        if let syncRegionError {
            throw syncRegionError
        }
        return CloudGatewayRegionSyncResponse(
            regionId: regionId,
            syncedAt: "2026-01-01T00:00:00Z",
            added: 1,
            updated: 0,
            removed: 0,
            noChanges: false,
            log: "CloudGateway peer sync audit log\nregion: \(regionId)\nsummary: added=1 updated=0 removed=0"
        )
    }

    func grantAccess(email: String, regionId: String, idToken: String) async throws -> CloudGatewayGrantAccessResponse {
        grantAccessCallCount += 1
        grantAccessEmail = email
        grantAccessRegionId = regionId
        if let grantAccessError {
            throw grantAccessError
        }
        return CloudGatewayGrantAccessResponse(email: email, alreadyExisted: grantAccessAlreadyExisted)
    }
}

enum TestFixtures {
    static let usableConfig = """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

    [Peer]
    PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
    """

    static func region(
        _ id: String,
        displayOrder: Int = 10,
        enabled: Bool = true,
        capacity: CloudGatewayRegionCapacity? = nil
    ) -> CloudGatewayRegion {
        CloudGatewayRegion(
            regionId: id,
            displayName: id,
            enabled: enabled,
            displayOrder: displayOrder,
            capacity: capacity
        )
    }

    static func client(
        _ id: String,
        regionId: String,
        status: CloudGatewayClientStatus = .active,
        ownerUid: String? = nil,
        ownerEmail: String? = nil
    ) -> CloudGatewayClient {
        CloudGatewayClient(
            clientId: id,
            clientName: id,
            regionId: regionId,
            status: status,
            wireGuardConfig: usableConfig,
            ownerUid: ownerUid,
            ownerEmail: ownerEmail
        )
    }

    static func snapshot(
        _ id: String,
        regionId: String
    ) -> CloudGatewayConfigSnapshot {
        try! CloudGatewayConfigSnapshot(
            clientId: id,
            regionId: regionId,
            clientName: id,
            regionDisplayName: regionId,
            status: .active,
            wireGuardConfig: usableConfig,
            readAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
