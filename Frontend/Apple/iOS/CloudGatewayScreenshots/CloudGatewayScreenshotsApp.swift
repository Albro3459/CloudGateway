import SwiftUI

@main
struct CloudGatewayScreenshotsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.cloudGatewayTheme, CloudGatewayTheme())
                .preferredColorScheme(.dark)
        }
    }
}
