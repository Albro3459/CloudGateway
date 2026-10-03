import CloudGatewayMacIPC
import Foundation
import NetworkExtension

let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
let listener = try CloudGatewayMacXPCListener(
    service: CloudGatewayMacTunnelRuntime.secretService,
    teamIdentifier: teamIdentifier
)
listener.start()
NEProvider.startSystemExtensionMode()
RunLoop.main.run()
