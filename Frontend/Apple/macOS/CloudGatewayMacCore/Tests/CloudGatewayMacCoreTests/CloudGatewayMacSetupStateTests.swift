import Testing
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

    @Test func requiredRestartBlocksReadinessRefreshAndActivation() {
        let state = CloudGatewayMacSetupState.awaitingRestart
        #expect(!state.canRefreshReadiness)
        #expect(!state.canActivate)
    }

    @Test func ordinarySetupStatesAllowReadinessRefreshAndActivationRetries() {
        for state in [CloudGatewayMacSetupState.required, .updateRequired, .failed(code: 1), .unavailable, .ready] {
            #expect(state.canRefreshReadiness)
            #expect(state.canActivate)
        }
    }

    @Test func matchingExtensionVersionIsRequiredForReadiness() throws {
        let bundled = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
            "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.0"
        ]))
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: bundled, bundledVersion: bundled) == .ready)
        #expect(CloudGatewayMacSetupState.readiness(runningVersion: nil, bundledVersion: bundled) == .updateRequired)
        for (build, release) in [("41", "1.2.0"), ("42", "1.1.0"), ("43", "1.2.0")] {
            let running = try #require(CloudGatewayMacExtensionVersion(infoDictionary: [
                "CFBundleVersion": build, "CFBundleShortVersionString": release
            ]))
            #expect(CloudGatewayMacSetupState.readiness(runningVersion: running, bundledVersion: bundled) == .updateRequired)
        }
    }

    @Test func invalidEmbeddedBundleCannotActivate() {
        #expect(!CloudGatewayMacSetupState.invalidBundle.canActivate)
    }
}
