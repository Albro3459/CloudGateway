import CloudGatewayAppCore
import SwiftUI

@main
struct CloudGatewayScreenshotsApp: App {
    @StateObject private var viewModel: CloudGatewayViewModel

    @MainActor
    init() {
        _viewModel = StateObject(
            wrappedValue: CloudGatewayScreenshotFixtureFactory.makeViewModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                notificationAuthorizer: NoopCloudGatewayNotificationAuthorizer()
            )
                .environment(\.cloudGatewayTheme, CloudGatewayTheme())
                .preferredColorScheme(.dark)
        }
    }
}
