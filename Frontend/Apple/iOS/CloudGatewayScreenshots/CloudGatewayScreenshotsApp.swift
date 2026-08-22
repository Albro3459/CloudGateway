import CloudGatewayAppCore
import SwiftUI

@main
struct CloudGatewayScreenshotsApp: App {
    @StateObject private var viewModel: CloudGatewayViewModel
    @StateObject private var serverHealthViewModel: CloudGatewayServerHealthViewModel

    @MainActor
    init() {
        let composition = CloudGatewayScreenshotFixtureFactory.make()
        _viewModel = StateObject(wrappedValue: composition.viewModel)
        _serverHealthViewModel = StateObject(wrappedValue: composition.serverHealthViewModel)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                notificationAuthorizer: NoopCloudGatewayNotificationAuthorizer(),
                serverHealthViewModel: serverHealthViewModel
            )
                .environment(\.cloudGatewayTheme, CloudGatewayTheme())
                .preferredColorScheme(.dark)
        }
    }
}
