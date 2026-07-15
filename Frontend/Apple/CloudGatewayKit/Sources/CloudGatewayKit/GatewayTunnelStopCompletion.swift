import Foundation

public final class GatewayTunnelStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var adapterHasStopped = false
    private var healthHasStopped = false
    private var deadlineHasExceeded = false
    private var deadlineCleanup: (@Sendable () -> Void)?

    public init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    public func adapterStopped() {
        signal(adapter: true)
    }

    public func healthStopped() {
        signal(adapter: false)
    }

    public func deadlineExceeded() {
        lock.lock()
        deadlineHasExceeded = true
        let cleanup = deadlineCleanup
        deadlineCleanup = nil
        lock.unlock()
        cleanup?()
        complete()
    }

    public func setDeadlineCleanup(
        _ cleanup: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        let runImmediately = deadlineHasExceeded
        if !runImmediately {
            deadlineCleanup = cleanup
        }
        lock.unlock()
        if runImmediately { cleanup() }
    }

    private func signal(adapter: Bool) {
        lock.lock()
        if adapter {
            adapterHasStopped = true
        } else {
            healthHasStopped = true
        }
        let shouldComplete = adapterHasStopped && healthHasStopped
        lock.unlock()
        if shouldComplete { complete() }
    }

    private func complete() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        deadlineCleanup = nil
        lock.unlock()
        completion?()
    }
}
