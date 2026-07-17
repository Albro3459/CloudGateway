import Foundation
import Testing
@testable import CloudGatewayKit

@Test func pendingStartHoldsStopUntilStartCleanupCompletes() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let stopped = LockedPendingStartFlag()
    let startID = barrier.begin()

    #expect(barrier.prepareToStop { stopped.set() })
    #expect(!stopped.value)
    barrier.complete(startID)

    #expect(stopped.value)
}

@Test func staleStartCannotReleaseReplacementStop() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let oldStartID = barrier.begin()
    let replacementStartID = barrier.begin()
    let stopped = LockedPendingStartFlag()

    #expect(barrier.prepareToStop { stopped.set() })
    barrier.complete(oldStartID)
    #expect(!stopped.value)
    barrier.complete(replacementStartID)

    #expect(stopped.value)
}

@Test func stopRejectsAdapterStartCompletionRegisteredBeforeIt() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let stopped = LockedPendingStartFlag()
    let adapterStartID = barrier.begin()

    #expect(barrier.canContinue(adapterStartID))
    #expect(barrier.prepareToStop { stopped.set() })
    #expect(!barrier.canContinue(adapterStartID))
    #expect(!stopped.value)

    barrier.complete(adapterStartID)
    #expect(stopped.value)
}

@Test func adapterStartSubmissionIsRejectedAfterStopReservation() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let startID = barrier.begin()
    let submitted = LockedPendingStartFlag()

    #expect(barrier.prepareToStop {})
    #expect(!barrier.performIfCanContinue(startID) { submitted.set() })
    #expect(!submitted.value)
}

@Test func acceptedAdapterStartSubmissionPrecedesStopReservation() {
    let barrier = CloudGatewayTunnelPendingStartBarrier()
    let startID = barrier.begin()
    let submitted = LockedPendingStartFlag()

    #expect(barrier.performIfCanContinue(startID) { submitted.set() })
    #expect(submitted.value)
    #expect(barrier.prepareToStop {})
}

private final class LockedPendingStartFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
