import CloudGatewayMacIPC
import Foundation
import NetworkExtension

let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
let secretService = CloudGatewayMacSecretService()
let listener = try CloudGatewayMacXPCListener(service: secretService, teamIdentifier: teamIdentifier)
listener.start()
NEProvider.startSystemExtensionMode()
RunLoop.main.run()
