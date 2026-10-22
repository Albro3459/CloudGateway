import Testing
import CloudGatewayKit
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
