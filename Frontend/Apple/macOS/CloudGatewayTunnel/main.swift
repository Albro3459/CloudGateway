import CloudGatewayMacIPC
import Foundation
import NetworkExtension

NEProvider.startSystemExtensionMode()
let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
let listener = try CloudGatewayMacXPCListener(
    service: CloudGatewayMacTunnelRuntime.secretService,
    teamIdentifier: teamIdentifier
)
listener.start()
RunLoop.main.run()
