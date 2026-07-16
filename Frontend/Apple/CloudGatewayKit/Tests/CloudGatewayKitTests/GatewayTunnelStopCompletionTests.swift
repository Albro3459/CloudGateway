import Foundation
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

@Test func deadlineCleanupInstalledAfterDeadlineRunsImmediately() {
    var completionCount = 0
    let cleanupCount = LockedStopCounter()
    let completion = GatewayTunnelStopCompletion {
        completionCount += 1
    }

    completion.deadlineExceeded()
    completion.setDeadlineCleanup {
        cleanupCount.increment()
    }

    #expect(completionCount == 1)
    #expect(cleanupCount.value == 1)
}

@Test func stopSubmissionSerializesDeadlineBehindClaimedSubmission() async {
    let queue = DispatchQueue(
        label: "GatewayTunnelStopSubmissionTests",
        attributes: .concurrent
    )
    let entered = AsyncStopSignal()
    let release = DispatchSemaphore(value: 0)
    let deadlineFinished = AsyncStopSignal()
    let submissionCount = LockedStopCounter()
    let deadlineCount = LockedStopCounter()
    let submission = GatewayTunnelStopSubmission(targetQueue: queue) {
        entered.signal()
        release.wait()
        submissionCount.increment()
    }

    submission.submit()
    await entered.wait()
    submission.submit {
        deadlineCount.increment()
        deadlineFinished.signal()
    }

    #expect(deadlineCount.value == 0)
    release.signal()
    await deadlineFinished.wait()

    #expect(submissionCount.value == 1)
    #expect(deadlineCount.value == 1)
}

private final class AsyncStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        lock.lock()
        guard let continuation else {
            signaled = true
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !signaled else {
                signaled = false
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class LockedStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
