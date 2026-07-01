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
    var fetchEnabledRegionsError: Error?
    var checkAccessError: Error?
    var fetchUserRoleError: Error?
    var fetchOwnedClientsError: Error?
    var createClientError: Error?
    var deleteClientError: Error?
    var syncRegionError: Error?

    // Call counters.
    private(set) var fetchEnabledRegionsCallCount = 0
    private(set) var fetchUserRoleCallCount = 0
    private(set) var fetchOwnedClientsCallCount = 0
    private(set) var addCapacityCallCount = 0
    private(set) var checkAccessCallCount = 0
    private(set) var signInCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var createClientCallCount = 0
    private(set) var deleteClientCallCount = 0
    private(set) var syncRegionCallCount = 0

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

    func fetchEnabledRegions() async throws -> [CloudGatewayRegion] {
        fetchEnabledRegionsCallCount += 1
        if let fetchEnabledRegionsError {
            throw fetchEnabledRegionsError
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

    static func client(_ id: String, regionId: String) -> CloudGatewayClient {
        CloudGatewayClient(
            clientId: id,
            clientName: id,
            regionId: regionId,
            status: .active,
            wireGuardConfig: usableConfig
        )
    }
}
