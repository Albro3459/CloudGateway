import Testing
@testable import CloudGatewayKit

@Test func stopDeadlineCompletesWhenAdapterCallbackNeverArrives() {
    var completionCount = 0
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.deadlineExceeded()
    completion.adapterStopped()
    completion.healthStopped()

    #expect(completionCount == 1)
}

@Test func normalStopWaitsForAdapterAndHealthCleanup() {
    var completionCount = 0
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.adapterStopped()
    #expect(completionCount == 0)
    completion.healthStopped()
    #expect(completionCount == 1)
    completion.deadlineExceeded()

    #expect(completionCount == 1)
}

@Test func normalStopSignalsCanArriveInEitherOrder() {
    var completionCount = 0
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.healthStopped()
    #expect(completionCount == 0)
    completion.adapterStopped()
    completion.healthStopped()

    #expect(completionCount == 1)
}
