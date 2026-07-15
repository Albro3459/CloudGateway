import Testing
@testable import CloudGatewayKit

@Test func stopDeadlineCompletesWhenAdapterCallbackNeverArrives() {
    var completionCount = 0
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.deadlineExceeded()
    completion.adapterStopped()

    #expect(completionCount == 1)
}

@Test func adapterStopCompletesBeforeDeadlineOnlyOnce() {
    var completionCount = 0
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.adapterStopped()
    completion.deadlineExceeded()

    #expect(completionCount == 1)
}
