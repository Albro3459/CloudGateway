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

@Test func legacyProfileModeIsFullAndMalformedModeKeepsStopIdentity() throws {
    let identifier = "account/region/mac"
    var metadata: [String: Any] = [
        CloudGatewayMacProviderKey.configId: identifier,
        CloudGatewayProviderConfigurationKey.tunnelIdentifier: identifier,
        CloudGatewayMacProviderKey.secretReference: UUID().uuidString.lowercased()
    ]
    #expect(try CloudGatewayMacProfileMetadata.decode(metadata, status: .connected).mode == .full)
    metadata[CloudGatewayMacProviderKey.routingMode] = "mesh"
    #expect(try CloudGatewayMacProfileMetadata.decode(metadata, status: .connected).mode == .mesh)
    for invalid in ["unsupported" as Any, 42, NSNull()] {
        metadata[CloudGatewayMacProviderKey.routingMode] = invalid
        let profile = try CloudGatewayMacProfileMetadata.decode(metadata, status: .connected)
        #expect(profile.mode == nil)
        #expect(profile.identifier == identifier)
        #expect(profile.needsConfirmedStop)
    }
}
