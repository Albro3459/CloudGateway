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

    // Injectable errors.
    var idTokenError: Error?
    var signInError: Error?
    var signInWithAppleError: Error?
    var signInWithGoogleError: Error?
    var sendPasswordResetError: Error?
    var fetchRegionsError: Error?
    var checkAccessError: Error?
    var fetchUserRoleError: Error?
    var fetchOwnedClientsError: Error?
    var createClientError: Error?
    var deleteClientError: Error?
    var syncRegionError: Error?
    var grantAccessError: Error?

    // Grant-access response tuning.
    var grantAccessAlreadyExisted = false

    // Captured inputs.
    private(set) var sendPasswordResetEmail: String?
    private(set) var grantAccessEmail: String?
    private(set) var grantAccessRegionId: String?

    // Call counters.
    private(set) var fetchRegionsCallCount = 0
    private(set) var fetchUserRoleCallCount = 0
    private(set) var fetchOwnedClientsCallCount = 0
    private(set) var addCapacityCallCount = 0
    private(set) var checkAccessCallCount = 0
    private(set) var signInCallCount = 0
    private(set) var signInWithAppleCallCount = 0
    private(set) var signInWithGoogleCallCount = 0
    private(set) var sendPasswordResetCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var createClientCallCount = 0
    private(set) var deleteClientCallCount = 0
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

    func idToken() async throws -> String {
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

    func createClient(regionId: String, clientName: String?, idToken: String) async throws -> CloudGatewayClient {
        createClientCallCount += 1
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
            noChanges: false
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
        status: CloudGatewayClientStatus = .active
    ) -> CloudGatewayClient {
        CloudGatewayClient(
            clientId: id,
            clientName: id,
            regionId: regionId,
            status: status,
            wireGuardConfig: usableConfig
        )
    }
}
