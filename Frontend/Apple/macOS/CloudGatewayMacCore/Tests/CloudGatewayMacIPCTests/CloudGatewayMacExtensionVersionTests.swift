import Foundation
import Testing
@testable import CloudGatewayMacIPC

@Test func readinessReplyIncludesRunningBundleVersionAndSurvivesEncoding() throws {
    let version = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
        "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"
    ]))
    let data = try JSONEncoder().encode(SecretReply(extensionVersion: version))
    #expect(data.count <= CloudGatewayMacSecretBounds.responseBytes)
    let decoded = try JSONDecoder().decode(SecretReply.self, from: data)
    #expect(decoded.extensionVersion == version)
    #expect(decoded.error == nil)
    #expect(decoded.reference == nil)
    #expect(decoded.grant == nil)
}

@Test func legacyReadinessReplyDoesNotClaimAMatchingVersion() throws {
    let reply = try JSONDecoder().decode(SecretReply.self, from: Data("{}".utf8))
    #expect(reply.extensionVersion == nil)
    #expect(reply.error == nil)
}

@Test func missingOrInvalidBundledVersionIsRejected() {
    #expect(CloudGatewayMacExtensionVersion(infoDictionary: [:]) == nil)
    #expect(CloudGatewayMacExtensionVersion(infoDictionary: [
        "CFBundleVersion": 42, "CFBundleShortVersionString": "1.2.0"
    ]) == nil)
    #expect(CloudGatewayMacExtensionVersion(infoDictionary: [
        "CFBundleVersion": "42", "CFBundleShortVersionString": ""
    ]) == nil)
}
