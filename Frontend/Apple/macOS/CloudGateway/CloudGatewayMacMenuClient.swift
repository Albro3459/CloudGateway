import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Foundation

typealias CloudGatewayMacMenuClient = CloudGatewayMacFrontendClient

extension CloudGatewayMacFrontendClient {
    convenience init(
        identity: CloudGatewayMacBuildIdentity,
        teamIdentifier team: String = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
    ) {
        self.init(identity: identity, transport: { request in
            let client = try CloudGatewayMacControllerClient(teamIdentifier: team, appVersion: identity.version,
                                                              appBuild: identity.build, buildIdentity: identity)
            defer { client.invalidate() }
            return try await client.request(request)
        }, bootstrap: {
            let installed = URL(fileURLWithPath: "/Applications/CloudGateway.app")
            let directory = CloudGatewayMacControllerRuntime.directory
            let task = Task.detached(priority: .utility) {
                _ = try CloudGatewayMacSignedBundle.installed(at: installed, teamIdentifier: team,
                    bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier)
                try Task.checkCancellation()
                let launcher = try CloudGatewayMacControllerLauncher(
                    executableURL: installed.appendingPathComponent("Contents/MacOS/CloudGateway"), directory: directory
                )
                _ = try await launcher.bootstrap()
            }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        })
    }
}
