import Testing
@testable import CloudGatewayMacCore

struct CloudGatewayMacSetupStateTests {
    @Test func pendingAndFailedSetupNeverPresentReadiness() {
        let notReady: [CloudGatewayMacSetupState] = [
            .required, .activating, .awaitingApproval, .awaitingRestart,
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
}
