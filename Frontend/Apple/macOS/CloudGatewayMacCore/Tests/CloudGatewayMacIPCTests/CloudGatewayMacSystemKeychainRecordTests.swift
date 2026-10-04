import CloudGatewayKit
import Foundation
import Testing
@testable import CloudGatewayMacIPC

private let recordConfig = """
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
"""

@Test(arguments: [false, true])
func macSystemKeychainRecordRoundTripsWithinReadBound(isCommitted: Bool) throws {
    let record = CloudGatewayMacStoredSecret(
        ownerUserId: 501, configId: "a", config: recordConfig, isCommitted: isCommitted
    )
    let data = try CloudGatewayMacSystemKeychainStore.encodeRecord(record)
    #expect(data.count <= CloudGatewayMacSecretBounds.requestBytes)
    let decoded = try JSONDecoder().decode(CloudGatewayMacStoredSecret.self, from: data)
    #expect(decoded.ownerUserId == record.ownerUserId)
    #expect(decoded.configId == record.configId)
    #expect(decoded.config == record.config)
    #expect(decoded.isCommitted == record.isCommitted)
}

@Test func macSystemKeychainRecordRejectsEscapedConfigThatFitsInstallRequest() throws {
    let prefix = recordConfig + "\n#"
    let requestPrefix = ["action": "install", "configId": "a", "config": prefix]
    let availableBytes = CloudGatewayMacSecretBounds.requestBytes - (try JSONEncoder().encode(requestPrefix)).count
    let config = prefix + String(repeating: "\0", count: availableBytes / 6)
        + String(repeating: "x", count: availableBytes % 6)
    let validated = try CloudGatewayWireGuardConfig(config)
    let request = ["action": "install", "configId": "a", "config": validated.rawValue]
    #expect(validated.rawValue.utf8.count <= CloudGatewayMacSecretBounds.configBytes)
    #expect(try JSONEncoder().encode(request).count == CloudGatewayMacSecretBounds.requestBytes)
    let record = CloudGatewayMacStoredSecret(
        ownerUserId: 501, configId: "a", config: validated.rawValue, isCommitted: false
    )
    #expect(try JSONEncoder().encode(record).count > CloudGatewayMacSecretBounds.requestBytes)
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSystemKeychainStore.encodeRecord(record)
    }
}
