import Foundation

public final class GatewayTunnelStartStopJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    private var monitorHasStopped = false
    private var startHasFinished = false

    public init(completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    public func monitorStopped() {
        signal(monitor: true)
    }

    public func startFinished() {
        signal(monitor: false)
    }

    private func signal(monitor: Bool) {
        lock.lock()
        if monitor {
            monitorHasStopped = true
        } else {
            startHasFinished = true
        }
        let completion = monitorHasStopped && startHasFinished
            ? self.completion
            : nil
        if completion != nil {
            self.completion = nil
        }
        lock.unlock()
        completion?()
    }
}
