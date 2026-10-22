import Foundation
import Testing
import CloudGatewayKit
import CloudGatewayMacIPC
@testable import CloudGatewayMacCore

struct CloudGatewayMacSetupStateTests {
    @Test func pendingAndFailedSetupNeverPresentReadiness() {
        let notReady: [CloudGatewayMacSetupState] = [
            .required, .updateRequired, .invalidBundle, .activating, .awaitingApproval, .awaitingRestart,
            .checkingConnection, .failed(code: 1), .unavailable
        ]
        for state in notReady {
            #expect(state != .ready)
        }
    }

    @Test func pendingRequestsCannotSubmitAnotherActivation() {
        for state in [CloudGatewayMacSetupState.activating, .awaitingApproval, .checkingConnection] {
            #expect(!state.canActivate)
        }
        #expect(CloudGatewayMacSetupState.required.canActivate)
        #expect(CloudGatewayMacSetupState.failed(code: 1).canActivate)
    }

    @Test func requiredRestartBlocksActivation() {
        let state = CloudGatewayMacSetupState.awaitingRestart
        #expect(!state.canActivate)
    }

    @Test func ordinarySetupStatesAllowActivationRetries() {
        for state in [CloudGatewayMacSetupState.required, .updateRequired, .failed(code: 1), .unavailable, .ready] {
            #expect(state.canActivate)
        }
    }

    @Test func matchingExtensionVersionIsRequiredForReadiness() throws {
        let bundled = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
            "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"
        ], codeHash: String(repeating: "a", count: 64)))
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: bundled, bundledVersion: bundled) == .ready)
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: nil, bundledVersion: bundled) == .updateRequired)
        for (build, release) in [("41", "1.2.0"), ("42", "1.1.0"), ("43", "1.2.0")] {
            let running = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
                "CFBundleVersion": build, "CFBundleShortVersionString": release
            ], codeHash: bundled.codeHash))
            #expect(CloudGatewayMacSetupState.readiness(runningVersion: running, bundledVersion: bundled) == .updateRequired)
        }
    }

    @Test func matchingVersionWithDifferentSignedCodeRequiresUpdate() throws {
        let info = ["CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"]
        let bundled = try #require(CloudGatewayMacExtensionVersion(
            infoDictionary: info, codeHash: String(repeating: "a", count: 64)
        ))
        let running = try #require(CloudGatewayMacExtensionVersion(
            infoDictionary: info, codeHash: String(repeating: "b", count: 64)
        ))
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: running, bundledVersion: bundled) == .updateRequired)
    }

    @Test func missingSignedCodeHashNeverClaimsReadiness() throws {
        let info = ["CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"]
        let legacy = try #require(CloudGatewayMacExtensionVersion(infoDictionary: info))
        let signed = try #require(CloudGatewayMacExtensionVersion(
            infoDictionary: info, codeHash: String(repeating: "a", count: 64)
        ))
        for (running, bundled) in [(legacy, signed), (signed, legacy), (legacy, legacy)] {
            #expect(CloudGatewayMacSetupState.readiness(runningVersion: running, bundledVersion: bundled) == .updateRequired)
        }
    }

    @Test func malformedWireCodeHashNeverClaimsReadiness() throws {
        let version = try JSONDecoder().decode(CloudGatewayMacExtensionVersion.self, from: Data(
            "{\"bundleVersion\":\"42\",\"bundleShortVersion\":\"1.2.0\",\"codeHash\":\"invalid\"}".utf8
        ))
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: version, bundledVersion: version) == .updateRequired)
    }

    @Test func replacingExtensionRequiresEveryOwnedTunnelToBeIdle() {
        #expect(CloudGatewayMacSetupState.canReplaceExtension(isCurrentBuild: true, ownedTunnelStatuses: []))
        #expect(CloudGatewayMacSetupState.canReplaceExtension(
            isCurrentBuild: true, ownedTunnelStatuses: [.invalid, .disconnected]
        ))
        for status in [CloudGatewayTunnelStatus.connecting, .connected, .reasserting, .disconnecting] {
            #expect(!CloudGatewayMacSetupState.canReplaceExtension(
                isCurrentBuild: true, ownedTunnelStatuses: [.disconnected, status]
            ))
        }
    }

    @Test func replacingExtensionRejectsUnavailablePreferencesOrReplacedApp() {
        #expect(!CloudGatewayMacSetupState.canReplaceExtension(isCurrentBuild: true, ownedTunnelStatuses: nil))
        #expect(!CloudGatewayMacSetupState.canReplaceExtension(isCurrentBuild: false, ownedTunnelStatuses: []))
    }

    @Test func invalidEmbeddedBundleCannotActivate() {
        #expect(!CloudGatewayMacSetupState.invalidBundle.canActivate)
    }
}
