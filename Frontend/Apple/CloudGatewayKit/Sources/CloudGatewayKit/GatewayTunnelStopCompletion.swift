import Foundation

public final class GatewayTunnelStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    public init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    public func adapterStopped() {
        complete()
    }

    public func deadlineExceeded() {
        complete()
    }

    private func complete() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}
