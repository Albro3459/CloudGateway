import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        // WireGuard configs (including private keys) are read through Firestore.
        // Force a memory-only cache before any read so secret material never
        // lands in Firestore's on-disk persistence; the Keychain stays the only
        // at-rest store. Must run before the first Firestore access.
        let firestoreSettings = FirestoreSettings()
        firestoreSettings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = firestoreSettings
        // The packet-tunnel extension posts a local "VPN not responding"
        // notification when the tunnel blackholes traffic. Set the delegate so
        // the banner can present while foregrounded; authorization is requested
        // in context at first VPN install/connect rather than at launch.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show the dead-tunnel notification as a banner even while the app is
    // foregrounded (iOS suppresses it by default otherwise).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@main
struct CloudGatewayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.cloudGatewayTheme, CloudGatewayTheme())
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
