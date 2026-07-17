import Foundation
import Testing
@testable import CloudGatewayKit

@Test func submissionArbiterNormalStopPreservesAdmittedFIFO() {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("first")
        _ = ticket
    })
    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("second")
        _ = ticket
    })
    #expect(arbiter.closeCurrent() == 1)
    #expect(!arbiter.submit(generation: 1) { _ in
        events.append("late")
    })
    arbiter.enqueueNormalStop(generation: 1) {
        events.append("stop")
    }

    executor.runAll()

    #expect(events.values == ["first", "second", "stop"])
}

@Test func submissionArbiterQueuedDeadlineUsesExactOnceStopBridge() async {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    let deadlineProcessed = LockedHealthAsyncSignal()
    let stopCompletion = CloudGatewayTunnelStopCompletion {
        events.append("stop-complete")
    }
    let adapterStop = CloudGatewayTunnelStopSubmission {
        events.append("adapter-stop")
        stopCompletion.adapterStopped()
    }
    let token = CloudGatewayTunnelHealthStopToken(
        generation: 1,
        effectArbiter: arbiter,
        cleanup: {}
    )
    arbiter.open(generation: 1)

    #expect(arbiter.submit(
        generation: 1,
        onCancelled: { events.append("effect-cancelled") }
    ) { _ in
        events.append("effect-submitted")
    })
    #expect(arbiter.closeCurrent() == 1)
    token.enqueueAfterSubmittedEffects {
        adapterStop.submit()
    }
    token.cancelQueuedEffectsAndEnqueue {
        adapterStop.submit {
            stopCompletion.deadlineExceeded()
            deadlineProcessed.signal()
        }
    }

    executor.runAll()
    await deadlineProcessed.wait()

    #expect(!events.values.contains("effect-submitted"))
    #expect(events.values.filter { $0 == "effect-cancelled" }.count == 1)
    #expect(events.values.filter { $0 == "adapter-stop" }.count == 1)
    #expect(events.values.filter { $0 == "stop-complete" }.count == 1)
}

@Test func submissionArbiterStartedDeadlineRepairsAfterExactOnceStop() async throws {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    let ticketHolder = LockedHealthSubmissionTicket()
    let deadlineProcessed = LockedHealthAsyncSignal()
    let stopCompletion = CloudGatewayTunnelStopCompletion {
        events.append("stop-complete")
    }
    let adapterStop = CloudGatewayTunnelStopSubmission {
        events.append("adapter-stop")
        stopCompletion.adapterStopped()
    }
    let token = CloudGatewayTunnelHealthStopToken(
        generation: 1,
        effectArbiter: arbiter,
        cleanup: { events.append("cleanup") }
    )
    stopCompletion.setDeadlineCleanup {
        token.bestEffortDeadlineCleanup()
    }
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("effect-submitted")
        ticketHolder.set(ticket)
    })
    #expect(executor.runNext())
    #expect(arbiter.closeCurrent() == 1)
    token.enqueueAfterSubmittedEffects {
        adapterStop.submit()
    }
    token.cancelQueuedEffectsAndEnqueue {
        adapterStop.submit {
            stopCompletion.deadlineExceeded()
            deadlineProcessed.signal()
        }
    }

    executor.runAll()
    await deadlineProcessed.wait()

    #expect(events.values == [
        "effect-submitted",
        "adapter-stop",
        "cleanup",
        "stop-complete",
    ])

    let ticket = try #require(ticketHolder.value)
    ticket.drain()
    ticket.drain()

    #expect(events.values == [
        "effect-submitted",
        "adapter-stop",
        "cleanup",
        "stop-complete",
        "cleanup",
    ])
}

@Test func submissionArbiterDeadlineCancelsQueuedTicketsBeforeStop() {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(
        generation: 1,
        onCancelled: { events.append("first-cancelled") }
    ) { _ in
        events.append("first-submitted")
    })
    #expect(arbiter.submit(
        generation: 1,
        onCancelled: { events.append("second-cancelled") }
    ) { _ in
        events.append("second-submitted")
    })
    #expect(arbiter.closeCurrent() == 1)
    arbiter.cancelQueuedAndEnqueueDeadlineStop(generation: 1) {
        events.append("stop")
    }

    #expect(events.values == ["first-cancelled", "second-cancelled"])
    executor.runAll()

    #expect(events.values == ["first-cancelled", "second-cancelled", "stop"])
}

@Test func submissionArbiterDeadlineCannotOvertakeStartedSubmission() throws {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    let startedTicket = LockedHealthSubmissionTicket()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("effect-submitted")
        startedTicket.set(ticket)
    })
    #expect(executor.runNext())
    #expect(arbiter.closeCurrent() == 1)
    arbiter.addPostDrainRepair(generation: 1) {
        events.append("repair")
    }
    arbiter.cancelQueuedAndEnqueueDeadlineStop(generation: 1) {
        events.append("stop")
    }

    executor.runAll()
    #expect(events.values == ["effect-submitted", "stop"])

    let ticket = try #require(startedTicket.value)
    ticket.drain()
    ticket.drain()

    #expect(events.values == ["effect-submitted", "stop", "repair"])
}

@Test func submissionArbiterDeadlineCancelsSecondEffectBehindStartedEffect() {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { _ in
        events.append("first-submitted")
    })
    #expect(arbiter.submit(
        generation: 1,
        onCancelled: { events.append("second-cancelled") }
    ) { _ in
        events.append("second-submitted")
    })
    #expect(executor.runNext())
    #expect(arbiter.closeCurrent() == 1)
    arbiter.cancelQueuedAndEnqueueDeadlineStop(generation: 1) {
        events.append("stop")
    }

    executor.runAll()

    #expect(events.values == ["first-submitted", "second-cancelled", "stop"])
}

@Test func submissionArbiterTracksSynchronousDrainAtSubmissionBoundary() {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("effect-submitted")
        arbiter.addPostDrainRepair(generation: 1) {
            events.append("repair")
        }
        ticket.drain()
    })
    #expect(arbiter.closeCurrent() == 1)

    executor.runAll()

    #expect(events.values == ["effect-submitted", "repair"])
}

@Test func submissionArbiterReopenPreservesOlderAdmittedFIFO() {
    let executor = ManualHealthSubmissionExecutor()
    let arbiter = CloudGatewayTunnelHealthEffectSubmissionArbiter(
        executor: executor,
        waitsForSubmission: false
    )
    let events = LockedHealthSubmissionEvents()
    arbiter.open(generation: 1)

    #expect(arbiter.submit(generation: 1) { ticket in
        events.append("old-effect")
        ticket.drain()
    })
    #expect(arbiter.closeCurrent() == 1)
    arbiter.enqueueNormalStop(generation: 1) {
        events.append("old-stop")
    }
    arbiter.open(generation: 2)
    #expect(arbiter.submit(generation: 2) { ticket in
        events.append("new-effect")
        ticket.drain()
    })

    executor.runAll()

    #expect(events.values == ["old-effect", "old-stop", "new-effect"])
}

private final class ManualHealthSubmissionExecutor:
    CloudGatewayTunnelHealthEffectSubmissionExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []

    func enqueue(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    func waitForPrecedingActions() {}

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard !actions.isEmpty else {
            lock.unlock()
            return false
        }
        let action = actions.removeFirst()
        lock.unlock()
        action()
        return true
    }

    func runAll() {
        while runNext() {}
    }
}

private final class LockedHealthSubmissionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        let values = storage
        lock.unlock()
        return values
    }
}

private final class LockedHealthSubmissionTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CloudGatewayTunnelHealthEffectSubmissionTicket?

    func set(_ ticket: CloudGatewayTunnelHealthEffectSubmissionTicket) {
        lock.lock()
        storage = ticket
        lock.unlock()
    }

    var value: CloudGatewayTunnelHealthEffectSubmissionTicket? {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

private final class LockedHealthAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signalled = true
        let waiters = waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
