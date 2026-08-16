import CloudGatewayAppCore
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The packet-tunnel extension posts a local "VPN connection interrupted"
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
    @StateObject private var viewModel: CloudGatewayViewModel
    @StateObject private var serverHealthViewModel: CloudGatewayServerHealthViewModel
    private let notificationAuthorizer: any CloudGatewayNotificationAuthorizing

    @MainActor
    init() {
        let composition = CloudGatewayIOSCompositionRoot.make()
        _viewModel = StateObject(wrappedValue: composition.viewModel)
        _serverHealthViewModel = StateObject(wrappedValue: composition.serverHealthViewModel)
        notificationAuthorizer = composition.notificationAuthorizer
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                notificationAuthorizer: notificationAuthorizer,
                serverHealthViewModel: serverHealthViewModel
            )
                .environment(\.cloudGatewayTheme, CloudGatewayTheme())
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
