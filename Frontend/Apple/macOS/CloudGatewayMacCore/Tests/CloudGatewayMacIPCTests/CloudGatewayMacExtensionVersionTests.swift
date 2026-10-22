import Foundation
import Testing
@testable import CloudGatewayMacIPC

@Test func tunnelEndpointUsesTheExtensionBuild() throws {
    #expect(try CloudGatewayMacTunnelEndpoint.name(extensionBuild: "4") == "group.com.gocloudlaunch.gateway.macos.tunnel.4")
    #expect(try CloudGatewayMacTunnelEndpoint.name(extensionBuild: "4.1") == "group.com.gocloudlaunch.gateway.macos.tunnel.4.1")
    #expect(try CloudGatewayMacTunnelEndpoint.name(extensionBuild: "4") != CloudGatewayMacTunnelEndpoint.name(extensionBuild: "3"))
}

@Test func tunnelEndpointRejectsMalformedBuilds() {
    for build in ["", ".4", "4.", "4..1", "4/1", "4\n", "４", "4a", String(repeating: "4", count: 65)] {
        #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
            try CloudGatewayMacTunnelEndpoint.name(extensionBuild: build)
        }
    }
}

@Test func readinessReplyIncludesRunningBundleVersionAndSurvivesEncoding() throws {
    let version = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
        "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"
    ], codeHash: String(repeating: "a", count: 64)))
    let data = try JSONEncoder().encode(SecretReply(extensionVersion: version))
    #expect(data.count <= CloudGatewayMacSecretBounds.responseBytes)
    let decoded = try JSONDecoder().decode(SecretReply.self, from: data)
    #expect(decoded.extensionVersion == version)
    #expect(decoded.extensionVersion?.codeHash == String(repeating: "a", count: 64))
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

@Test func legacyExtensionVersionDecodesWithoutCodeHash() throws {
    let version = try JSONDecoder().decode(CloudGatewayMacExtensionVersion.self, from: Data(
        "{\"bundleVersion\":\"42\",\"bundleShortVersion\":\"1.2.0\"}".utf8
    ))
    #expect(version.codeHash == nil)
    #expect(!version.hasCodeHash)
}

@Test func extensionCodeHashMustBeCanonicalSHA256() {
    let info = ["CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"]
    for hash in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                 String(repeating: "g", count: 64), String(repeating: "A", count: 64)] {
        #expect(CloudGatewayMacExtensionVersion(infoDictionary: info, codeHash: hash) == nil)
    }
}
