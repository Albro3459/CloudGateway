import CloudGatewayAppCore
import CloudGatewayKit
import Foundation

@MainActor
struct CloudGatewayScreenshotComposition {
    let viewModel: CloudGatewayViewModel
    let serverHealthViewModel: CloudGatewayServerHealthViewModel
}

@MainActor
enum CloudGatewayScreenshotFixtureFactory {
    static func make() -> CloudGatewayScreenshotComposition {
        let service = CloudGatewayScreenshotService()
        return CloudGatewayScreenshotComposition(
            viewModel: makeViewModel(service: service),
            serverHealthViewModel: CloudGatewayServerHealthViewModel(service: service)
        )
    }

    private static func makeViewModel(service: CloudGatewayScreenshotService) -> CloudGatewayViewModel {
        CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: CloudGatewayScreenshotTunnelManager(
                    statuses: service.clients.reduce(into: [String: CloudGatewayTunnelStatus]()) { statuses, client in
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
    private(set) var meshRegions: [CloudGatewayMeshRegion]
    private let meshDocs: [String: CloudGatewayMeshDoc]

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
        let meshRegions: [CloudGatewayMeshRegion] = [
            CloudGatewayMeshRegion(
                regionId: "us-sanjose-1",
                displayName: "California",
                enabled: true,
                displayOrder: 10,
                meshEnabled: true,
                wireguardPublicKey: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=",
                wireguardEndpointHostname: "wg.us-sanjose-1.gocloudlaunch.com",
                wireguardPort: 51820,
                tunnelNetworkV4: "10.0.5.0/24",
                tunnelNetworkV6: "fd42:42:42:5::/64"
            ),
            CloudGatewayMeshRegion(
                regionId: "us-ashburn-1",
                displayName: "Chicago",
                enabled: true,
                displayOrder: 20,
                meshEnabled: true,
                wireguardPublicKey: "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=",
                wireguardEndpointHostname: "wg.us-ashburn-1.gocloudlaunch.com",
                wireguardPort: 51820,
                tunnelNetworkV4: "10.0.9.0/24",
                tunnelNetworkV6: "fd42:42:42:9::/64"
            )
        ]
        self.meshRegions = meshRegions
        self.meshDocs = Self.makeMeshDocs(regions: meshRegions)
    }

    // Every region's Mesh/* doc carries an "applied" peer entry for every other
    // region, built directly from that peer's own current snapshot fields, so
    // link rows render bothApplied rather than stale.
    private static func makeMeshDocs(regions: [CloudGatewayMeshRegion]) -> [String: CloudGatewayMeshDoc] {
        let appliedAt = Date().addingTimeInterval(-15 * 60)
        var docs: [String: CloudGatewayMeshDoc] = [:]
        for region in regions {
            var peers: [String: CloudGatewayMeshPeerEntry] = [:]
            for peer in regions where peer.regionId != region.regionId {
                peers[peer.regionId] = CloudGatewayMeshPeerEntry(
                    endpointHostname: peer.wireguardEndpointHostname,
                    endpointPort: peer.wireguardPort,
                    publicKey: peer.wireguardPublicKey,
                    allowedNetworkV4: peer.tunnelNetworkV4,
                    allowedNetworkV6: peer.tunnelNetworkV6,
                    status: .applied,
                    reasonCode: nil,
                    appliedAt: appliedAt
                )
            }
            docs[region.regionId] = CloudGatewayMeshDoc(
                regionId: region.regionId,
                meshEnabled: region.meshEnabled,
                updatedAt: appliedAt,
                peers: peers
            )
        }
        return docs
    }

    var installedSnapshots: [CloudGatewayConfigSnapshot] {
        clientOptions.compactMap { try? CloudGatewayConfigSelection.snapshot(from: $0, readAt: Self.fixtureDate) }
    }

    var configsByReference: [CloudGatewayConfigSecretReference: CloudGatewayWireGuardConfig] {
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

    func addAuthStateListener(
        _ listener: @escaping (AuthenticatedUser?) -> Void
    ) -> CloudGatewayAuthStateListenerRegistration {
        Task { @MainActor in
            listener(screenshotUser)
        }
        return CloudGatewayAuthStateListenerRegistration {}
    }

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

    func reauthenticateWithApple(idToken: String, rawNonce: String, authorizationCode: String, revoke: Bool) async throws {}

    func reauthenticateWithGoogle(revoke: Bool) async throws {}

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

    func checkAccess(idToken: String) async throws -> CloudGatewayAccessCheck {
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

    func syncRegions(regionIds: [String], idToken: String) async -> [CloudGatewayRegionSyncOutcome] {
        regionIds.map { regionId in
            let region = meshRegions.first { $0.regionId == regionId }
            let response = CloudGatewayRegionSyncResponse(
                regionId: regionId,
                syncedAt: "2026-07-06T12:00:00Z",
                added: 0,
                updated: 0,
                removed: 0,
                noChanges: true,
                log: "Screenshot fixture account is a normal user; sync is unavailable.",
                meshUpdated: 0,
                meshEnabled: (region?.enabled ?? false) && (region?.meshEnabled ?? false),
                meshApplied: 0,
                meshAdded: 0,
                meshRemoved: 0,
                meshSkipped: 0,
                meshRoutesAdded: 0,
                meshRoutesRemoved: 0,
                meshStatusWritten: true,
                meshPeers: []
            )
            return CloudGatewayRegionSyncOutcome(regionId: regionId, result: .success(response))
        }
    }

    func fetchMeshRegions() async throws -> [CloudGatewayMeshRegion] {
        meshRegions
    }

    func fetchMeshDocs() async throws -> [String: CloudGatewayMeshDoc] {
        meshDocs
    }

    func setRegionMeshEnabled(regionId: String, enabled: Bool) async throws {
        guard let index = meshRegions.firstIndex(where: { $0.regionId == regionId }) else { return }
        let region = meshRegions[index]
        meshRegions[index] = CloudGatewayMeshRegion(
            regionId: region.regionId,
            displayName: region.displayName,
            enabled: region.enabled,
            displayOrder: region.displayOrder,
            meshEnabled: enabled,
            wireguardPublicKey: region.wireguardPublicKey,
            wireguardEndpointHostname: region.wireguardEndpointHostname,
            wireguardPort: region.wireguardPort,
            tunnelNetworkV4: region.tunnelNetworkV4,
            tunnelNetworkV6: region.tunnelNetworkV6
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
    private var statuses: [String: CloudGatewayTunnelStatus]

    init(statuses: [String: CloudGatewayTunnelStatus]) {
        self.statuses = statuses
    }

    func installedStatuses(for identifiers: [String]) async throws -> [String: CloudGatewayTunnelStatus] {
        identifiers.reduce(into: [String: CloudGatewayTunnelStatus]()) { result, identifier in
            if let status = statuses[identifier] {
                result[identifier] = status
            }
        }
    }

    func allInstalledStatuses() async throws -> [String: CloudGatewayTunnelStatus] {
        statuses
    }

    func installTunnel(_ tunnel: CloudGatewayTunnelConfiguration) async throws {
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
    private var configs: [CloudGatewayConfigSecretReference: CloudGatewayWireGuardConfig]

    init(configs: [CloudGatewayConfigSecretReference: CloudGatewayWireGuardConfig]) {
        self.configs = configs
    }

    func saveConfig(_ config: CloudGatewayWireGuardConfig, for reference: CloudGatewayConfigSecretReference) throws {
        configs[reference] = config
    }

    func loadConfig(for reference: CloudGatewayConfigSecretReference) throws -> CloudGatewayWireGuardConfig {
        guard let config = configs[reference] else {
            throw CloudGatewayVPNError.keychainReadFailed(-25300)
        }
        return config
    }

    func deleteConfig(for reference: CloudGatewayConfigSecretReference) throws {
        configs[reference] = nil
    }
}
