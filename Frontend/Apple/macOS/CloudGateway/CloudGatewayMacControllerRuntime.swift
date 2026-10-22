import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import CloudGatewayMacCore
import CloudGatewayMacIPC
import FirebaseCore
import FirebaseFirestore
import Foundation

extension CloudGatewayFirebaseAuthAdapter: @retroactive CloudGatewayMacControllerAuthServicing {}

@MainActor
final class CloudGatewayMacControllerRuntime {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudGateway/macOS", isDirectory: true)
    }

    let controller: CloudGatewayMacController
    private let profiles: CloudGatewayMacVPNProfileAdapter

    init() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let firebaseOptions = FirebaseOptions(contentsOfFile: path),
              firebaseOptions.bundleID == "com.gocloudlaunch.gateway.macos" else {
            preconditionFailure("The macOS Firebase configuration is missing or has the wrong bundle ID")
        }
        FirebaseApp.configure(options: firebaseOptions)
        let database = Firestore.firestore()
        let settings = FirestoreSettings()
        settings.cacheSettings = MemoryCacheSettings()
        database.settings = settings
        let auth = CloudGatewayFirebaseAuthAdapter()
        let inventory = CloudGatewayMacInventoryService(auth: auth, database: database)
        let cache = CloudGatewayMacAccountCache(directory: Self.directory)
        let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        let secrets: CloudGatewayMacXPCSecretClient
        do {
            let identity = try CloudGatewayMacSignedBundle.installed(
                at: Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"
                ), teamIdentifier: teamIdentifier, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos"
            )
            secrets = try CloudGatewayMacXPCSecretClient(teamIdentifier: teamIdentifier, extensionBuild: identity.build)
        } catch { preconditionFailure("The bundled macOS VPN extension is invalid") }
        profiles = CloudGatewayMacVPNProfileAdapter()
        let configs = CloudGatewayMacConfigCoordinator(secrets: secrets, profiles: profiles, snapshots: cache)
        let dashboard = URL(string: "https://gocloudlaunch.com")!
        controller = CloudGatewayMacController(
            auth: auth,
            deviceAuth: CloudGatewayDeviceAuthClient(originHost: "gocloudlaunch.com", dashboardOrigin: dashboard),
            inventory: inventory, profiles: profiles, cache: cache, configs: configs,
            dashboardOrigin: dashboard
        )
        profiles.onChange = { [weak controller] in controller?.profilesDidChange() }
    }

    func shutdown() {
        profiles.onChange = nil
        controller.shutdown()
    }

    func hasAnyActiveTunnel() async throws -> Bool {
        try await profiles.hasAnyActiveTunnel()
    }
}
