import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func passiveProfileValidationRejectsMalformedAndDuplicateMetadata() throws {
    let identifier = "account/region/mac"
    let valid: [String: Any] = [
        CloudGatewayMacProviderKey.configId: identifier,
        CloudGatewayProviderConfigurationKey.tunnelIdentifier: identifier,
        CloudGatewayMacProviderKey.secretReference: UUID().uuidString.lowercased()
    ]
    let profile = try CloudGatewayMacProfileMetadata.decode(valid, status: .disconnected)
    try CloudGatewayMacProfileMetadata.validateUnique([profile])
    #expect(profile.identifier == identifier)
    for key in [CloudGatewayMacProviderKey.configId, CloudGatewayProviderConfigurationKey.tunnelIdentifier,
                CloudGatewayMacProviderKey.secretReference] {
        var malformed = valid
        malformed[key] = "invalid"
        #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
            try CloudGatewayMacProfileMetadata.decode(malformed, status: .connected)
        }
    }
    #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try CloudGatewayMacProfileMetadata.validateUnique([profile, profile])
    }
    var invalidIdentifier = valid
    invalidIdentifier[CloudGatewayMacProviderKey.configId] = "malformed"
    invalidIdentifier[CloudGatewayProviderConfigurationKey.tunnelIdentifier] = "malformed"
    #expect(throws: CloudGatewayMacConfigError.invalidConfig) {
        try CloudGatewayMacProfileMetadata.decode(invalidIdentifier, status: .connected)
    }
    try CloudGatewayMacProfileMetadata.validateUnique([])
}
