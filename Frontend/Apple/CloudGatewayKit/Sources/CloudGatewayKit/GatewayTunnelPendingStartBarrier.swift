import Foundation

public final class GatewayTunnelPendingStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var pendingID: UInt64?
    private var stopCompletion: (@Sendable () -> Void)?

    public init() {}

    public func begin() -> UInt64 {
        lock.lock()
        nextID &+= 1
        pendingID = nextID
        stopCompletion = nil
        let id = nextID
        lock.unlock()
        return id
    }

    public func prepareToStop(
        completion: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        guard pendingID != nil else {
            lock.unlock()
            return false
        }
        stopCompletion = completion
        lock.unlock()
        return true
    }

    public func complete(_ id: UInt64) {
        lock.lock()
        guard pendingID == id else {
            lock.unlock()
            return
        }
        pendingID = nil
        let completion = stopCompletion
        stopCompletion = nil
        lock.unlock()
        completion?()
    }
}
