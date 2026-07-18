import CloudGatewayAppCore
import CloudGatewayFirebaseAuthAdapter
import CloudGatewayKit
import FirebaseCore
import FirebaseFirestore
import Foundation

@MainActor
struct CloudGatewayIOSComposition {
    let viewModel: CloudGatewayViewModel
    let notificationAuthorizer: any CloudGatewayNotificationAuthorizing
}

@MainActor
enum CloudGatewayIOSCompositionRoot {
    private static let keychainAccessGroupInfoKey = "CGKeychainAccessGroup"

    static func make(bundle: Bundle = .main) -> CloudGatewayIOSComposition {
        FirebaseApp.configure()

        let database = Firestore.firestore()
        // WireGuard configs can pass through Firestore; configure memory-only
        // storage before the repository or auth listener can trigger a read.
        let firestoreSettings = FirestoreSettings()
        firestoreSettings.cacheSettings = MemoryCacheSettings()
        database.settings = firestoreSettings

        let platform = CloudGatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.gocloudlaunch.gateway",
            appBundleIdentifier: "com.gocloudlaunch.gateway",
            providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
            tunnelDisplayName: "CloudGateway",
            keychainAccessGroupIdentifier: keychainAccessGroup(from: bundle)
        )
        let notificationAuthorizer = SystemCloudGatewayNotificationAuthorizer()
        let service = CloudGatewayAppServiceFacade(
            auth: CloudGatewayFirebaseAuthAdapter(),
            repository: CloudGatewayIOSFirestoreRepository(database: database),
            controlPlane: CloudGatewayControlPlaneClient(originHost: "gocloudlaunch.com"),
            googlePresenter: CloudGatewayIOSGoogleSignInPresenter(
                clientID: FirebaseApp.app()?.options.clientID
            )
        )
        let viewModel = CloudGatewayViewModel(
            service: service,
            configManager: CloudGatewayConfigManager(
                tunnelManager: CloudGatewayVPNManager(platform: platform),
                cache: CloudGatewayConfigCache(platform: platform),
                secretStore: CloudGatewayKeychainConfigSecretStore(
                    accessGroup: platform.keychainAccessGroupIdentifier
                ),
                configSecretServiceName: platform.configSecretServiceName
            ),
            healthReader: CloudGatewayTunnelHealthReader(
                store: CloudGatewayTunnelHealthStore(
                    appGroupIdentifier: platform.appGroupIdentifier
                )
            ),
            notificationAuthorizer: notificationAuthorizer
        )
        return CloudGatewayIOSComposition(
            viewModel: viewModel,
            notificationAuthorizer: notificationAuthorizer
        )
    }

    private static func keychainAccessGroup(from bundle: Bundle) -> String {
        do {
            return try CloudGatewayRuntimeConfiguration.keychainAccessGroup(
                bundle.object(forInfoDictionaryKey: keychainAccessGroupInfoKey)
            )
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }
}
