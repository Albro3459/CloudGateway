import Foundation
import Testing
@testable import CloudGatewayKit

@Test func startStopJoinWaitsForStartAfterMonitorStops() {
    let completed = LockedStartStopJoinCounter()
    let join = CloudGatewayTunnelStartStopJoin { completed.increment() }

    join.monitorStopped()
    #expect(completed.value == 0)
    join.startFinished()

    #expect(completed.value == 1)
}

@Test func startStopJoinWaitsForMonitorAfterStartFinishes() {
    let completed = LockedStartStopJoinCounter()
    let join = CloudGatewayTunnelStartStopJoin { completed.increment() }

    join.startFinished()
    #expect(completed.value == 0)
    join.monitorStopped()

    #expect(completed.value == 1)
}

@Test func startStopJoinCompletesOnlyOnceForDuplicateSignals() {
    let completed = LockedStartStopJoinCounter()
    let join = CloudGatewayTunnelStartStopJoin { completed.increment() }

    join.monitorStopped()
    join.monitorStopped()
    join.startFinished()
    join.startFinished()

    #expect(completed.value == 1)
}

@Test func pendingStartBarrierAndMonitorCleanupBothGateStop() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let startID = barrier.begin()
    let completed = LockedStartStopJoinCounter()
    let join = barrier.prepareJoinedStop { completed.increment() }

    join.monitorStopped()
    #expect(completed.value == 0)
    barrier.complete(startID)

    #expect(completed.value == 1)
}

@Test func joinedStopPreSignalsWhenNoStartIsPending() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let completed = LockedStartStopJoinCounter()
    let join = barrier.prepareJoinedStop { completed.increment() }

    join.monitorStopped()

    #expect(completed.value == 1)
}

private final class LockedStartStopJoinCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
