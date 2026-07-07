import CloudGatewayKit
import Foundation

extension CloudGatewayViewModel {
    convenience init() {
        let service = CloudGatewayScreenshotService()
        self.init(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: CloudGatewayScreenshotTunnelManager(
                    statuses: service.clients.reduce(into: [String: GatewayTunnelStatus]()) { statuses, client in
                        statuses[client.clientId] = .disconnected
                    }
                ),
                cache: CloudGatewayScreenshotConfigCache(snapshots: service.installedSnapshots),
                secretStore: CloudGatewayScreenshotSecretStore(configs: service.configsByReference)
            )
        )
    }
}

final class CloudGatewayScreenshotService: CloudGatewayServicing {
    let screenshotUser = AuthenticatedUser(uid: "screenshot-john", email: "john@test.com")
    let regions: [CloudGatewayRegion]
    private(set) var clients: [CloudGatewayClient]

    var currentUser: AuthenticatedUser? {
        screenshotUser
    }

    init() {
        regions = [
            CloudGatewayRegion(
                regionId: "us-sanjose-1",
                displayName: "California",
                enabled: true,
                displayOrder: 10,
                capacity: .known(limit: 20, allocated: 3)
            ),
            CloudGatewayRegion(
                regionId: "us-ashburn-1",
                displayName: "Chicago",
                enabled: true,
                displayOrder: 20,
                capacity: .known(limit: 20, allocated: 5)
            )
        ]
        clients = [
            CloudGatewayClient(
                clientId: "john-iphone",
                clientName: "John's iPhone",
                regionId: "us-sanjose-1",
                status: .active,
                wireGuardConfig: Self.wireGuardConfig(address: "10.42.0.11/32", endpoint: "wg.us-sanjose-1.gocloudlaunch.com:51820"),
                updatedAt: Self.fixtureDate,
                ownerUid: "screenshot-john",
                ownerEmail: "john@test.com"
            ),
            CloudGatewayClient(
                clientId: "john-ipad",
                clientName: "John's iPad",
                regionId: "us-ashburn-1",
                status: .active,
                wireGuardConfig: Self.wireGuardConfig(address: "10.43.0.12/32", endpoint: "wg.us-ashburn-1.gocloudlaunch.com:51820"),
                updatedAt: Self.fixtureDate,
                ownerUid: "screenshot-john",
                ownerEmail: "john@test.com"
            )
        ]
    }

    var installedSnapshots: [CloudGatewayConfigSnapshot] {
        clientOptions.compactMap { try? CloudGatewayConfigSelection.snapshot(from: $0, readAt: Self.fixtureDate) }
    }

    var configsByReference: [GatewayConfigSecretReference: GatewayWireGuardConfig] {
        Dictionary(uniqueKeysWithValues: clientOptions.compactMap { option in
            guard let snapshot = try? CloudGatewayConfigSelection.snapshot(from: option, readAt: Self.fixtureDate),
                  let config = try? CloudGatewayConfigSelection.wireGuardConfig(from: option) else {
                return nil
            }
            return (snapshot.secretReference, config)
        })
    }

    private var clientOptions: [CloudGatewayClientOption] {
        CloudGatewayConfigSelection.clientOptions(clients: clients, regions: regions)
    }

    func addAuthStateListener(_ listener: @escaping (AuthenticatedUser?) -> Void) -> Any {
        Task { @MainActor in
            listener(screenshotUser)
        }
        return NSObject()
    }

    func removeAuthStateListener(_ token: Any) {}

    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        screenshotUser
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        screenshotUser
    }

    func signInWithGoogle() async throws -> AuthenticatedUser {
        screenshotUser
    }

    func providerIds() -> [String] {
        ["password"]
    }

    func linkEmailPassword(email: String, password: String) async throws -> AuthenticatedUser {
        screenshotUser
    }

    func linkApple(idToken: String, rawNonce: String) async throws -> AuthenticatedUser {
        screenshotUser
    }

    func linkGoogle() async throws -> AuthenticatedUser {
        screenshotUser
    }

    func reauthenticateWithPassword(_ password: String) async throws {}

    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String) async throws {}

    func reauthenticateWithGoogle() async throws {}

    func sendPasswordReset(email: String) async throws {}

    func signOut() throws {}

    func idToken(forceRefresh: Bool) async throws -> String {
        "screenshot-token"
    }

    func fetchUserRole(uid: String) async throws -> String? {
        "user"
    }

    func fetchRegions() async throws -> [CloudGatewayRegion] {
        CloudGatewayConfigSelection.sortedRegions(regions)
    }

    func checkAccess(idToken: String, regions: [CloudGatewayRegion]) async throws -> CloudGatewayAccessCheck {
        CloudGatewayAccessCheck(userId: screenshotUser.uid, email: screenshotUser.email, role: "user")
    }

    func addCapacity(to regions: [CloudGatewayRegion], idToken: String) async -> [CloudGatewayRegion] {
        CloudGatewayConfigSelection.sortedRegions(regions)
    }

    func fetchOwnedClients(uid: String) async throws -> [CloudGatewayClient] {
        clients
    }

    func fetchAllClients() async throws -> [CloudGatewayClient] {
        clients
    }

    func createClient(regionId: String, clientName: String, idToken: String) async throws -> CloudGatewayClient {
        let client = CloudGatewayClient(
            clientId: "created-\(clients.count + 1)",
            clientName: clientName,
            regionId: regionId,
            status: .active,
            wireGuardConfig: Self.wireGuardConfig(address: "10.44.0.\(clients.count + 20)/32", endpoint: "wg.\(regionId).gocloudlaunch.com:51820"),
            updatedAt: Self.fixtureDate,
            ownerUid: screenshotUser.uid,
            ownerEmail: screenshotUser.email
        )
        clients.append(client)
        return client
    }

    func deleteClient(clientId: String, userId: String, regionId: String, idToken: String) async throws -> CloudGatewayDeleteClientResponse {
        clients.removeAll { $0.clientId == clientId && $0.regionId == regionId }
        return CloudGatewayDeleteClientResponse(userId: userId, clientId: clientId, regionId: regionId, status: .removed)
    }

    func deleteAccount(idToken: String) async throws -> CloudGatewayDeleteAccountResponse {
        CloudGatewayDeleteAccountResponse(userId: screenshotUser.uid, deletedClientCount: clients.count)
    }

    func syncRegion(regionId: String, idToken: String) async throws -> CloudGatewayRegionSyncResponse {
        CloudGatewayRegionSyncResponse(
            regionId: regionId,
            syncedAt: "2026-07-06T12:00:00Z",
            added: 0,
            updated: 0,
            removed: 0,
            noChanges: true,
            log: "Screenshot fixture account is a normal user; sync is unavailable."
        )
    }

    func grantAccess(email: String, regionId: String, idToken: String) async throws -> CloudGatewayGrantAccessResponse {
        CloudGatewayGrantAccessResponse(email: email, alreadyExisted: false)
    }

    private static let fixtureDate = Date(timeIntervalSince1970: 1_783_344_000)

    private static func wireGuardConfig(address: String, endpoint: String) -> String {
        """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = \(address)
        DNS = 1.1.1.1

        [Peer]
        PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = \(endpoint)
        PersistentKeepalive = 25
        """
    }
}

actor CloudGatewayScreenshotTunnelManager: CloudGatewayTunnelManaging {
    private var statuses: [String: GatewayTunnelStatus]

    init(statuses: [String: GatewayTunnelStatus]) {
        self.statuses = statuses
    }

    func installedStatus(for identifier: String) async throws -> GatewayTunnelStatus {
        guard let status = try await installedStatuses(for: [identifier])[identifier] else {
            throw GatewayVPNError.missingInstalledTunnel
        }
        return status
    }

    func installedStatuses(for identifiers: [String]) async throws -> [String: GatewayTunnelStatus] {
        identifiers.reduce(into: [String: GatewayTunnelStatus]()) { result, identifier in
            if let status = statuses[identifier] {
                result[identifier] = status
            }
        }
    }

    func installTunnel(_ tunnel: GatewayTunnelConfiguration) async throws {
        statuses[tunnel.identifier] = .disconnected
    }

    func startTunnel(identifier: String) async throws {
        statuses[identifier] = .connected
    }

    func stopTunnel(identifier: String) async throws {
        statuses[identifier] = .disconnected
    }

    func removeTunnel(identifier: String) async throws {
        statuses[identifier] = nil
    }
}

actor CloudGatewayScreenshotConfigCache: CloudGatewayConfigCaching {
    private var snapshots: [CloudGatewayConfigSnapshot]

    init(snapshots: [CloudGatewayConfigSnapshot]) {
        self.snapshots = snapshots
    }

    func load() async throws -> [CloudGatewayConfigSnapshot] {
        snapshots
    }

    func save(_ snapshot: CloudGatewayConfigSnapshot) async throws {
        snapshots.removeAll { $0.clientId == snapshot.clientId }
        snapshots.append(snapshot)
    }

    func clear(identifier: String) async throws {
        snapshots.removeAll { $0.clientId == identifier }
    }
}

final class CloudGatewayScreenshotSecretStore: CloudGatewayConfigSecretStoring, @unchecked Sendable {
    private var configs: [GatewayConfigSecretReference: GatewayWireGuardConfig]

    init(configs: [GatewayConfigSecretReference: GatewayWireGuardConfig]) {
        self.configs = configs
    }

    func saveConfig(_ config: GatewayWireGuardConfig, for reference: GatewayConfigSecretReference) throws {
        configs[reference] = config
    }

    func loadConfig(for reference: GatewayConfigSecretReference) throws -> GatewayWireGuardConfig {
        guard let config = configs[reference] else {
            throw GatewayVPNError.keychainReadFailed(-25300)
        }
        return config
    }

    func deleteConfig(for reference: GatewayConfigSecretReference) throws {
        configs[reference] = nil
    }
}
