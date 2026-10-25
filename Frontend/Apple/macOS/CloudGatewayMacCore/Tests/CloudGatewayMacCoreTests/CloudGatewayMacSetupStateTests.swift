import Testing
import CloudGatewayKit
@testable import CloudGatewayMacCore

struct CloudGatewayMacSetupStateTests {
    @Test func activationPolicyAllowsRetriesAndBlocksPendingOrInvalidSetup() {
        let cases: [(CloudGatewayMacSetupState, Bool)] = [
            (.required, true), (.updateRequired, true), (.invalidBundle, false),
            (.activating, false), (.awaitingApproval, false), (.awaitingRestart, false),
            (.checkingConnection, false), (.ready, true), (.failed(code: 1), true), (.unavailable, true)
        ]
        for (state, canActivate) in cases {
            #expect(state.canActivate == canActivate)
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
}
